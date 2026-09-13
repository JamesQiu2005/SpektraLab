//  FrameFraming.swift — how a thumbnail is marked, as a value.
//
//  There are two marks in the editor and they mean two different things: the
//  **open** frame is the one on the canvas, and a **picked** frame is one of
//  the set an export or an apply-to-all would run over. The open frame is
//  always a member of the set — `Session.click` keeps it so — which is why
//  this is one enum and not two booleans: there is no such thing as a cell
//  that is open and unpicked, so there is no way for a view to spell one.
//
//  Session answers `framing(of:)` and both surfaces draw what it returns. The
//  filmstrip and the Browse grid disagreeing about which frames are selected
//  is a defect this file exists to make impossible, not to fix again.

import SwiftUI

enum FrameFraming {
    /// Not picked, and not on the canvas.
    case none
    /// In the set, but not the frame on the canvas.
    case picked
    /// The frame on the canvas.
    case open

    /// The white frame. The open frame is the strongest mark and a picked one
    /// is the same frame held back, rather than a second colour: the two are
    /// one scale, so adding a frame to the set reads as a change of degree
    /// and not as a change of kind.
    var lineWidth: CGFloat {
        switch self {
        case .none: 0
        case .picked: 1
        case .open: 1.5
        }
    }

    /// Applied to the stroke. `lineWidth` 0 already draws nothing; this is
    /// what makes `.picked` read as the weaker of the two framed states on a
    /// thumbnail whose own pixels can be any colour at all.
    var opacity: Double {
        switch self {
        case .none: 0
        case .picked: 0.5
        case .open: 1
        }
    }

    /// Filmstrip only: the state badge is suppressed on the frame that
    /// already has the most on it. Kept to `.open` rather than "any framed
    /// cell", because a picked batch is exactly where "which of these has a
    /// print behind it" is worth reading (`Filmstrip.swift`).
    var suppressesBadge: Bool { self == .open }

    var isFramed: Bool { self != .none }
}
