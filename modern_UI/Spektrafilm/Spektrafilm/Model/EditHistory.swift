//  EditHistory.swift — a value history with one record per gesture.
//
//  A gesture records its before and after once, when it ends: a slider drag
//  that sets the value two hundred times is one step, a double-click back to
//  rest is one step, a run of arrow keys is one step. What is kept is the
//  value and nothing else — no texture, no file, no render — so a step costs
//  the size of the value.
//
//  Each step carries a **stamp** from the session's clock, which is how a
//  second history beside this one (the sidecar's own undo stack) is put in
//  order with it: ⌘Z takes whichever has the newer step (`Session.undoLatest`).

import Foundation

struct EditHistory<State: Equatable> {
    struct Step: Equatable {
        let before: State
        let after: State
        let stamp: Int
    }

    private(set) var past: [Step] = []
    private(set) var future: [Step] = []
    let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    /// The newest step's stamp, nil when there is nothing to undo.
    var lastStamp: Int? { past.last?.stamp }

    /// A gesture that changed nothing records nothing. A new step ends redo:
    /// what was undone is not the future of what was just done.
    mutating func record(from before: State, to after: State, stamp: Int) {
        guard before != after else { return }
        past.append(Step(before: before, after: after, stamp: stamp))
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    /// The newest step, moved to the redo side; apply its `before`.
    mutating func undo() -> Step? {
        guard let step = past.popLast() else { return nil }
        future.append(step)
        return step
    }

    /// The last undone step, moved back; apply its `after`.
    mutating func redo() -> Step? {
        guard let step = future.popLast() else { return nil }
        past.append(step)
        return step
    }

    /// Something outside this history changed the state: what was undone can
    /// no longer be redone on top of it.
    mutating func dropRedo() { future.removeAll() }
}
