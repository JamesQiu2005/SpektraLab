import Foundation

/// Decide once: vertical intent never mutates the control later in the gesture.
struct DragOwnership {
    enum Axis { case undecided, horizontal, vertical }
    private(set) var axis = Axis.undecided
    mutating func update(x: Double, y: Double) -> Bool {
        if axis == .undecided, max(abs(x), abs(y)) >= 8 {
            axis = abs(x) > abs(y) * 1.25 ? .horizontal : .vertical
        }
        return axis == .horizontal
    }
}
