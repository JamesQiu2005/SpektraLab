import Foundation

/// A linear value history (PRD-F §3.1): the states an edit has been in, oldest first, and a cursor on the one it
/// is in now. Undo moves the cursor back, Redo forward; a new step after an Undo drops the states ahead of the
/// cursor. Pixel buffers, source files and scheduler jobs never enter it.
///
/// `states[0]` is the **base**: the state the first step held began from — "Original" on the history page, or,
/// once a step past `limit` has dropped the oldest, *Earlier edits* (`baseIsEarlier`): the page never claims the
/// frame's true first state once that is gone. So `count` steps lie between `count + 1` states.
///
/// A frame's history is also kept on disk (`EditHistoryStore`), where every state has a number: the base's is
/// `baseSeq`, each later one's the next. The store applies the same arithmetic as this type, op for op, so the
/// numbers here are the store's. A session holds only the states around its cursor (`nil` where one is not read
/// yet, `missing`) and reads the rest when an undo or redo reaches them.
///
/// The develop page's sessions keep 256 steps (the owner, PRD-F §8.5); a flow's own history (`MacFlowHistory`)
/// 64, in memory: a flow is one sitting, and its result is one step on the frame.
struct EditHistory<State: Equatable> {
    let limit: Int
    private(set) var states: [State?] = []
    private(set) var cursor = 0
    private(set) var baseIsEarlier = false
    private(set) var baseSeq = 0

    init(limit: Int = 256) { self.limit = max(1, limit) }

    /// A history as a store holds it: `count + 1` states from `baseSeq`, the cursor on `cursorSeq`, and those of
    /// them that were read (`loaded`, by number).
    init(limit: Int = 256, baseSeq: Int, steps: Int, cursorSeq: Int, baseIsEarlier: Bool, loaded: [Int: State]) {
        self.limit = max(1, limit)
        self.baseSeq = baseSeq
        self.baseIsEarlier = baseIsEarlier
        states = (0...max(0, steps)).map { loaded[baseSeq + $0] }
        cursor = min(max(0, cursorSeq - baseSeq), states.count - 1)
    }

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor + 1 < states.count }
    /// The steps held: behind the cursor and ahead of it.
    var count: Int { max(0, states.count - 1) }
    var isEmpty: Bool { states.isEmpty }
    /// The state the cursor is on; nil for a history with nothing in it.
    var current: State? { states.isEmpty ? nil : states[cursor] }
    var cursorSeq: Int { baseSeq + cursor }
    var lastSeq: Int { baseSeq + count }

    /// The number an undo would reach, and one a redo would, if there is one.
    var undoSeq: Int? { canUndo ? cursorSeq - 1 : nil }
    var redoSeq: Int? { canRedo ? cursorSeq + 1 : nil }
    /// The state numbered `seq`, if it is held and read.
    func state(_ seq: Int) -> State? {
        let i = seq - baseSeq
        return states.indices.contains(i) ? states[i] : nil
    }
    /// The numbers within `radius` of the cursor that are held but not read.
    func missing(around seq: Int, radius: Int) -> [Int] {
        guard !states.isEmpty else { return [] }
        let lo = max(baseSeq, seq - radius), hi = min(lastSeq, seq + radius)
        guard lo <= hi else { return [] }
        return (lo...hi).filter { state($0) == nil }
    }

    /// A step from `before` to `after`; nothing where the two are the same. `before` takes the cursor's place:
    /// what was there may differ from it by what was read rather than set since (a meter, As Shot, a placement
    /// solved), and an Undo of this step goes back to the state as it really was. Returns whether a step was made.
    @discardableResult
    mutating func record(from before: State, to after: State) -> Bool {
        guard before != after else { return false }
        if states.isEmpty {
            states = [before]
            cursor = 0
        } else {
            states[cursor] = before
            states.removeSubrange((cursor + 1)...)
        }
        states.append(after)
        cursor += 1
        // The step past the limit drops the oldest: the state it led to is the base now, *Earlier edits*.
        let over = states.count - 1 - limit
        if over > 0 {
            states.removeFirst(over)
            cursor -= over
            baseSeq += over
            baseIsEarlier = true
        }
        return true
    }

    /// Back one step: the state before, or nil where there is none — or it is not read yet (`undoSeq`).
    mutating func undo() -> State? {
        guard canUndo, let state = states[cursor - 1] else { return nil }
        cursor -= 1
        return state
    }

    /// Forward one step: the state the last undo left, or nil where there is none or it is not read yet.
    mutating func redo() -> State? {
        guard canRedo, let state = states[cursor + 1] else { return nil }
        cursor += 1
        return state
    }

    /// The cursor straight onto `seq` (Go to This Step): its state, or nil — the cursor where it was — where the
    /// history does not hold it or it is not read.
    mutating func move(to seq: Int) -> State? {
        guard let state = state(seq) else { return nil }
        cursor = seq - baseSeq
        return state
    }

    /// The cursor's state as it is now, with nothing recorded: what was read rather than set since the step that
    /// led here (a pair's placement shown for the frame picked, a placement the engine solved).
    mutating func amend(_ state: State) {
        guard !states.isEmpty else { return }
        states[cursor] = state
    }

    /// States read since (by number); a number the history does not hold is ignored.
    mutating func take(_ loaded: [Int: State]) {
        for (seq, state) in loaded where states.indices.contains(seq - baseSeq) { states[seq - baseSeq] = state }
    }

    /// Clear History (PRD-F §4): the edit as it stands is kept and becomes the base, *Original*.
    mutating func clear() {
        guard !states.isEmpty else { return }
        let kept = states[cursor]
        baseSeq += cursor
        states = [kept]
        cursor = 0
        baseIsEarlier = false
    }
}
