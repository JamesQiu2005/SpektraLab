import Foundation

/// Accounting and policy for the app's large resident allocations. The arena
/// never owns the objects: an evict closure only gives the caller a place to
/// drop its own reference.
final class MemoryArena: @unchecked Sendable {
    enum Class { case pinned, evictable }
    struct Handle: Hashable { fileprivate let id: UUID }

    /// Evictions since the last report was drained. The report is kept by the
    /// arena because admission can evict between samples; the sampler drains
    /// it into the next `memory` record.
    struct EvictionReport: Sendable, Equatable {
        var bytes = 0
        var kinds: [String: Int] = [:]

        mutating func add(_ other: EvictionReport) {
            bytes += other.bytes
            for (kind, amount) in other.kinds { kinds[kind, default: 0] += amount }
        }
    }

    private struct Entry {
        let bytes: Int
        let cls: Class
        let kind: String
        let costMs: Double
        let evict: @Sendable () -> Void
        var lastTouch: UInt64
    }
    private struct State {
        var entries: [UUID: Entry] = [:]
        var nextTouch: UInt64 = 0
        /// The last sample and limits handed to the arena. Admission consults
        /// these without asking the kernel itself.
        var lastSample: MemorySample?
        var lastReserve: UInt64 = 0
        var lastCap: UInt64 = .max
        var evictionReport = EvictionReport()
    }
    private let state = NSLock()
    private var value = State()

    /// Register an allocation. The caller may pass nil only for an evictable
    /// cache entry; pinned registrations are never refused because refusing
    /// one would make the accounting lie about an object the app already has.
    ///
    /// The most recent sample handed to `enforce`/`observe` is the admission
    /// reading. That can be one sample period stale: this method deliberately
    /// does not ask the kernel (RFC-019 rule 4), and the next enforcement pass
    /// re-reads free memory after making room.
    @discardableResult
    func admit(bytes: Int, cls: Class, kind: String, costMs: Double,
               evict: @escaping @Sendable () -> Void) -> Handle? {
        let bytes = max(0, bytes)
        var evicted: [Entry] = []

        if cls == .evictable {
            state.lock()
            guard let needed = admissionNeedLocked(bytes: bytes),
                  UInt64(evictableBytesLocked()) >= needed else {
                state.unlock()
                return nil
            }
            evicted = removeLowestPriorityLocked(needed: needed)
            state.unlock()
            // Run the drop closures outside the arena lock. A store's closure
            // may take its own lock, and it must never be asked to do that
            // while this arena is holding one.
            evicted.forEach { $0.evict() }
        }

        let handle = Handle(id: UUID())
        state.lock()
        value.entries[handle.id] = Entry(bytes: bytes, cls: cls, kind: kind,
                                         costMs: costMs, evict: evict,
                                         lastTouch: nextTouchLocked())
        state.unlock()
        return handle
    }

    func release(_ h: Handle) { state.lock(); value.entries.removeValue(forKey: h.id); state.unlock() }
    func touch(_ h: Handle) {
        state.lock()
        if var entry = value.entries[h.id] {
            entry.lastTouch = nextTouchLocked()
            value.entries[h.id] = entry
        }
        state.unlock()
    }

    var totalBytes: Int { state.lock(); defer { state.unlock() }; return value.entries.values.reduce(0) { $0 + $1.bytes } }
    var evictableBytes: Int { state.lock(); defer { state.unlock() }; return value.entries.values.reduce(0) { $0 + ($1.cls == .evictable ? $1.bytes : 0) } }

    func breakdown() -> [(kind: String, bytes: Int, count: Int)] {
        state.lock(); defer { state.unlock() }
        var grouped: [String: (Int, Int)] = [:]
        for entry in value.entries.values {
            let previous = grouped[entry.kind] ?? (0, 0)
            grouped[entry.kind] = (previous.0 + entry.bytes, previous.1 + 1)
        }
        return grouped.map { (kind: $0.key, bytes: $0.value.0, count: $0.value.1) }
            .sorted { $0.bytes == $1.bytes ? $0.kind < $1.kind : $0.bytes > $1.bytes }
    }

    /// Hand the arena a sample and limits without running policy. `enforce`
    /// calls this first; keeping it separate lets admission consult the same
    /// latest reading while still making the sampler the only kernel reader.
    func observe(sample: MemorySample, reserve: UInt64, cap: UInt64) {
        state.lock()
        value.lastSample = sample
        value.lastReserve = reserve
        value.lastCap = cap
        state.unlock()
    }

    /// Can this entry be admitted without a later admission eviction failing?
    /// This is the same prediction as `admit`, without registering anything.
    func wouldAdmit(bytes: Int, cls: Class) -> Bool {
        state.lock(); defer { state.unlock() }
        guard cls == .evictable, let needed = admissionNeedLocked(bytes: max(0, bytes)) else { return true }
        return UInt64(evictableBytesLocked()) >= needed
    }

    /// Record the latest sample and evict one batch of the lowest-priority
    /// EVICTABLE entries. The sampler calls this again with a fresh sample
    /// whenever bytes were evicted, so the next batch is never decided from a
    /// stale free-memory reading.
    ///
    /// Step 2 ranks by last-touch order. The GDSF value function lands in
    /// step 4 and replaces this ranking in ONE place: the eviction helpers
    /// below. Callers must not sort entries themselves.
    @discardableResult
    func enforce(sample: MemorySample, reserve: UInt64, cap: UInt64) -> Int {
        state.lock()
        value.lastSample = sample
        value.lastReserve = reserve
        value.lastCap = cap

        let freeNeed = sample.freeBytes < reserve ? reserve - sample.freeBytes : 0
        let evictable = UInt64(evictableBytesLocked())
        let capNeed = evictable > cap ? evictable - cap : 0
        let needed = max(freeNeed, capNeed)

        guard needed > 0 else {
            state.unlock()
            return 0
        }

        let evicted = removeLowestPriorityLocked(needed: needed)
        state.unlock()
        evicted.forEach { $0.evict() }
        return evicted.reduce(0) { $0 + $1.bytes }
    }

    /// Evictions accumulated since the last call, including those performed
    /// by admission. Draining is what keeps the log record scoped to one sample.
    func takeEvictionReport() -> EvictionReport {
        state.lock(); defer { state.unlock() }
        let report = value.evictionReport
        value.evictionReport = EvictionReport()
        return report
    }

    // MARK: - locked policy helpers

    private func nextTouchLocked() -> UInt64 {
        let touch = value.nextTouch
        value.nextTouch &+= 1
        return touch
    }

    private func evictableBytesLocked() -> Int {
        value.entries.values.reduce(0) { $0 + ($1.cls == .evictable ? $1.bytes : 0) }
    }

    private func admissionNeedLocked(bytes: Int) -> UInt64? {
        guard let sample = value.lastSample else { return 0 }
        let requested = UInt64(bytes)

        let reserveNeed: UInt64
        if sample.freeBytes < value.lastReserve {
            let gap = (value.lastReserve - sample.freeBytes).addingReportingOverflow(requested)
            reserveNeed = gap.overflow ? .max : gap.partialValue
        } else {
            let room = sample.freeBytes - value.lastReserve
            reserveNeed = requested > room ? requested - room : 0
        }

        let evictable = UInt64(evictableBytesLocked())
        let withEntry = evictable.addingReportingOverflow(requested)
        let capNeed: UInt64
        if withEntry.overflow || withEntry.partialValue > value.lastCap {
            capNeed = withEntry.overflow ? .max : withEntry.partialValue - value.lastCap
        } else {
            capNeed = 0
        }

        return max(reserveNeed, capNeed)
    }

    /// Remove lowest last-touch entries until their accounted bytes cover
    /// `needed`. Accounting is the batch estimate; the sampler re-reads free
    /// memory after the batch and calls again if reality did not follow.
    private func removeLowestPriorityLocked(needed: UInt64) -> [Entry] {
        var selected: [Entry] = []
        var freed: UInt64 = 0

        while freed < needed {
            guard let id = value.entries
                .filter({ $0.value.cls == .evictable })
                .min(by: { $0.value.lastTouch < $1.value.lastTouch })?.key,
                  let entry = value.entries.removeValue(forKey: id) else { break }
            selected.append(entry)
            freed = freed.addingReportingOverflow(UInt64(entry.bytes)).partialValue
        }

        for entry in selected {
            value.evictionReport.bytes += entry.bytes
            value.evictionReport.kinds[entry.kind, default: 0] += entry.bytes
        }
        return selected
    }
}
