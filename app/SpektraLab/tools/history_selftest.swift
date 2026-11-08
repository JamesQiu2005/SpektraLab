import Foundation

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
        print("Session history: \(passed) passed, 0 failed")
    }
}
