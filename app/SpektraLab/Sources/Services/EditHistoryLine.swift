//  EditHistoryLine.swift — the main actor's one way to the edit history store, in order (PRD-F §3.2, §5).
//
//  Every session, the one door for changes made with no page open (`AppServices.recordStep`), the history page
//  (`MacHistoryPage`) and Settings' size go through this line, and the store sees their calls in the order they were
//  made: a step recorded on a page, the frame switched, the next page's open of the same frame — the open must find
//  that step. Each call is a task that waits for the one before it, so nothing on the main actor waits for the store: a step's encode,
//  compress and write are the store's, off the main actor (the ≤ 1 ms budget on the main thread is the diff and
//  the hand-off). `ask` is the one call that waits, and only its caller does.
//
//  A call the store refuses is said in the log once per kind of refusal and dropped: the edit itself is in the
//  library either way, and a page goes on with its history in memory (`OpenFrameSession.historyLanded`).

import Foundation
import Observation

@MainActor
@Observable
final class EditHistoryLine {
    @ObservationIgnored let store: any EditHistoryStore
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var said: Set<String> = []
    /// Counts the writes sent (a step, a move, an amend, a Clear; an open that reconciled): what the history page
    /// watches to read its listing again (`MacHistoryPage`), so a step made on the page behind it, an Undo or a
    /// paste from the grid shows while it is open. The read it then makes is after the write (the line's order).
    private(set) var writes = 0
    /// Calls sent and not yet made: what a quit waits for (`drainAtQuit`). Counted under a lock: a call is made off the
    /// main actor and says so there.
    @ObservationIgnored private let pending = PendingCalls()

    init(store: any EditHistoryStore) { self.store = store }

    /// A write, after every call sent before it. Nothing waits for it.
    func send(_ what: String, _ call: @escaping @Sendable (any EditHistoryStore) async throws -> Void) {
        writes &+= 1
        began()
        let previous = tail, store = store, pending = pending
        // Detached: the line runs on the store's actor and the pool, never waiting for the main actor, so a quit that
        // holds the main thread can wait for it (`drainAtQuit`). Only a refusal comes back to the main actor, to be said.
        tail = Task.detached { [weak self] in
            await previous?.value
            do { try await call(store) } catch { Task { @MainActor in self?.refused(what, error) } }
            pending.end()
        }
    }

    /// A read (or a read that writes, as an open's reconciliation does: `writes`), after every call sent before
    /// it; its answer, or the store's refusal.
    func ask<T: Sendable>(_ what: String, writes: Bool = false,
                          _ call: @escaping @Sendable (any EditHistoryStore) async throws -> T) async throws -> T {
        if writes { self.writes &+= 1 }
        began()
        defer { ended() }
        let previous = tail, store = store
        let asked = Task.detached { () async throws -> T in
            await previous?.value
            return try await call(store)
        }
        tail = Task.detached { _ = try? await asked.value }
        do { return try await asked.value } catch {
            refused(what, error)
            throw error
        }
    }

    /// Every call sent so far has been made: a check's quit, a test's read of the store.
    func drained() async {
        await tail?.value
    }

    private func began() { pending.begin() }

    /// An `ask`'s end, on the main actor; a `send`'s ends off it.
    private func ended() { pending.end() }

    /// **At quit** (`AppServices.settleForQuit`): the calls still in the line are made before the process ends, for
    /// at most `seconds`. The quit is on the main thread and cannot await; the line runs off the main actor, so the
    /// main thread waits for it, until none is left or the time is up — a quit is never held longer than that,
    /// whatever the store does. (Spinning the main run loop instead ran nothing: the quit's notifications are posted
    /// from the main queue, which a nested run loop does not drain — measured, 40 of 40 calls left.) A step is about a millisecond's write
    /// (`tools/history_store_selftest`). What is still in the line then is lost, as a crash loses it, and the next
    /// open's guard reconciles to the library (PRD-F §3.2). How many calls were left.
    @discardableResult
    func drainAtQuit(within seconds: Double) -> Int {
        let began = Date(), end = began.addingTimeInterval(seconds), had = pending.count
        // The line runs off the main actor (`send`): the main thread only waits, it never runs a call itself.
        while pending.count > 0, Date() < end { usleep(1000) }
        let left = pending.count
        Log.note(.library, "edit history at quit", ["calls": had, "left": left, "ms": Int(Date().timeIntervalSince(began) * 1000)])
        #if DEBUG
        print("history-check: drained at quit: \(had) calls in \(Int(Date().timeIntervalSince(began) * 1000)) ms, \(left) left")
        #endif
        return left
    }

    private func refused(_ what: String, _ error: Error) {
        let kind = "\(what): \(error)"
        guard said.insert(kind).inserted else { return }
        Log.note(.library, "edit history refused", ["call": what, "error": String(describing: error)], level: .warn)
    }
}

/// The line's calls not yet made, counted from either side of the main actor.
final class PendingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// One more; the count now.
    @discardableResult func begin() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    func end() { lock.lock(); n = max(0, n - 1); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
