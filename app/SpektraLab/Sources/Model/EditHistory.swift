import Foundation

/// Session-local value history. A gesture records its before/after once;
/// pixel buffers, source files and scheduler jobs never enter the history.
struct EditHistory<State: Equatable> {
    private struct Step { let before: State; let after: State }
    private var past: [Step] = []
    private var future: [Step] = []
    let limit: Int

    init(limit: Int = 64) { self.limit = max(1, limit) }
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var count: Int { past.count }

    mutating func record(from before: State, to after: State) {
        guard before != after else { return }
        past.append(Step(before: before, after: after))
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }
    mutating func undo() -> State? {
        guard let step = past.popLast() else { return nil }
        future.append(step)
        return step.before
    }
    mutating func redo() -> State? {
        guard let step = future.popLast() else { return nil }
        past.append(step)
        return step.after
    }
}
