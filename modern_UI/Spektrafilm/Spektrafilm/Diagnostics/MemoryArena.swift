import Foundation

/// Accounting and policy for the app's large resident allocations. The arena
/// never owns the objects: an evict closure only gives the caller a place to
/// drop its own reference.
final class MemoryArena: @unchecked Sendable {
    enum Class { case pinned, evictable }
    struct Handle: Hashable { fileprivate let id: UUID }

    private struct Entry {
        let bytes: Int
        let cls: Class
        let kind: String
        let costMs: Double
        let evict: @Sendable () -> Void
    }
    private struct State { var entries: [UUID: Entry] = [:] }
    private let state = NSLock()
    private var value = State()

    /// Step 1 is accounting only: admission never fails, and no eviction is
    /// performed. The closure is retained for the later policy step but is not
    /// called here; it drops the caller's reference, not an arena-owned object.
    @discardableResult
    func admit(bytes: Int, cls: Class, kind: String, costMs: Double,
               evict: @escaping @Sendable () -> Void) -> Handle? {
        let handle = Handle(id: UUID())
        state.lock(); value.entries[handle.id] = Entry(bytes: max(0, bytes), cls: cls,
                                                        kind: kind, costMs: costMs, evict: evict); state.unlock()
        return handle
    }

    func release(_ h: Handle) { state.lock(); value.entries.removeValue(forKey: h.id); state.unlock() }
    func touch(_ h: Handle) { /* Step 1: report-only; admission order is policy's concern. */ }

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

    /// Called by MemorySampler. Step 1 records only: it never evicts and
    /// always returns zero. `reserve` and `cap` are intentionally unused until
    /// the enforcement step, so a user operation can never be refused here.
    @discardableResult
    func enforce(sample: MemorySample, reserve: UInt64, cap: UInt64) -> Int { 0 }
}
