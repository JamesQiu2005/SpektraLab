import Foundation

// `EditHistory` (Model/EditHistory.swift): the linear list and its cursor, at the limit a develop session keeps
// (256, PRD-F §3.1, §7.2), and the store's numbers it shares with `EditHistoryStore`.
@main struct HistorySelftest {
    static func main() {
        var passed = 0
        func expect(_ ok: Bool, _ name: String) {
            guard ok else { print("FAIL: \(name)"); exit(1) }
            passed += 1
        }
        var h = EditHistory<Int>(limit: 2)
        expect(h.undo() == nil && h.redo() == nil, "empty history is safe")
        h.record(from: 0, to: 1); h.record(from: 1, to: 2)
        expect(h.undo() == 1, "undo returns the previous revision")
        h.record(from: 1, to: 1)
        expect(h.redo() == 2, "a no-op does not erase redo")
        _ = h.undo(); h.record(from: 1, to: 3)
        expect(h.redo() == nil, "a new branch erases the abandoned future")
        h.record(from: 3, to: 4)
        expect(h.count == 2, "history retains at most its configured limit")
        expect(h.undo() == 3 && h.undo() == 1 && h.undo() == nil, "bounded history keeps the correct reachable revision")
        expect(h.redo() == 3 && h.redo() == 4 && h.redo() == nil, "redo restores the bounded branch in order")

        // PRD-F §3.1: a develop session's history is 256 steps; the 257th drops the oldest, and the state it led
        // to becomes the base, which is then *Earlier edits*, not *Original*.
        var d = EditHistory<Int>()
        expect(d.limit == 256, "a session's history keeps 256 steps by default")
        for i in 0..<256 { d.record(from: i, to: i + 1) }
        expect(d.count == 256 && !d.baseIsEarlier && d.states.first == 0, "256 steps keep the frame's first state as Original")
        d.record(from: 256, to: 257)
        expect(d.count == 256, "the 257th step keeps 256 (\(d.count))")
        expect(d.states.first == 1 && d.baseSeq == 1, "the 257th drops the oldest: the base is the state it led to")
        expect(d.baseIsEarlier, "and the base relabels: Earlier edits")
        var walked = 0
        while d.undo() != nil { walked += 1 }
        expect(walked == 256 && d.current == 1, "256 undos reach the base and no further (\(walked), at \(String(describing: d.current)))")
        expect(d.undo() == nil, "nothing before Earlier edits")
        // A new edit after an undo drops the redo tail, whatever its length.
        _ = d.redo(); _ = d.redo()
        let tailBefore = d.count - d.cursor
        d.record(from: 3, to: 1_000)
        expect(tailBefore > 0 && !d.canRedo && d.count == 3 && d.current == 1_000, "a new edit after undos drops the redo tail")
        // The state a step began from takes the cursor's place (what was read since, folded in).
        d.record(from: 1_001, to: 1_002)
        expect(d.undo() == 1_001, "Undo goes back to the state as the step found it")
        // Clear: the edit as it stands is the base, Original, and nothing else is held.
        d.clear()
        expect(d.count == 0 && d.current == 1_001 && !d.baseIsEarlier && !d.canUndo && !d.canRedo, "Clear keeps the edit as Original")
        let clearedAt = d.baseSeq
        d.record(from: 1_001, to: 7)
        expect(d.cursorSeq == clearedAt + 1 && d.undo() == 1_001, "a step after Clear begins from the kept edit")

        // A window as a store hands it: states known by number, some not read; an undo stops where none is read.
        var w = EditHistory<Int>(baseSeq: 40, steps: 20, cursorSeq: 55, baseIsEarlier: true, loaded: [53: 53, 54: 54, 55: 55, 56: 56])
        expect(w.count == 20 && w.cursorSeq == 55 && w.current == 55 && w.baseIsEarlier, "a window keeps the store's numbers")
        expect(w.undo() == 54 && w.undo() == 53 && w.undo() == nil && w.cursorSeq == 53, "an undo past what was read waits for it")
        expect(w.undoSeq == 52 && w.missing(around: 53, radius: 2) == [51, 52], "and says which state it needs")
        w.take([52: 52, 51: 51, 99: 99])
        expect(w.undo() == 52 && w.state(99) == nil, "read, the undo goes on; a number the history does not hold is ignored")
        expect(w.redo() == 53 && w.redo() == 54 && w.redo() == 55 && w.redo() == 56 && w.redo() == nil, "redo stops at the unread too")
        w.record(from: 56, to: 1)
        expect(w.lastSeq == 57 && !w.canRedo, "a step after the window drops the tail beyond it")

        // Many steps on a small limit: the numbers keep counting, as the store's do.
        var n = EditHistory<Int>(limit: 3)
        for i in 0..<10 { n.record(from: i, to: i + 1) }
        expect(n.baseSeq == 7 && n.cursorSeq == 10 && n.states.compactMap { $0 } == [7, 8, 9, 10], "the base's number follows the trim")
        print("Session history: \(passed) passed, 0 failed")
    }
}
