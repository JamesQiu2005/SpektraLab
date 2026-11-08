//  FilmEdgeJourney.swift — the Film Edge flow's steps, and what each option
//  needs to mean anything, with no view in them.
//
//  A tester (2026-10-18): a step in the bar opened only once *Next* had been
//  pressed as far as it. The owner, 2026-10-19: "So far it is one full journey
//  all the way, but we do not restrain user behaviour. Instead we grey out
//  certain options when some are not selected." So Next and Back still walk
//  Film → Frame → Edge → Date in the order the decisions depend on
//  (design/overscan §1), and the bar goes to any step from the first moment.
//  Nothing a step needs is missing when it is reached early: a format is
//  always chosen (135 until another is), the picture's cut is the largest one
//  until it is placed, and the film edge goes on the frame whenever the flow
//  leaves the guide for the developed film, by Next or by the bar alike.
//
//  What a choice makes meaningless is greyed where it sits, with the reason
//  in the panel's note — never hidden, and never a step held shut. The rules
//  below are held by `tools/film_edge_steps_selftest.swift`, the frame number's
//  against the app's port of the engine's own layout.

import CoreGraphics
import Foundation

enum FilmEdgeStep: Int, CaseIterable, Identifiable, Sendable {
    case film, frame, edge, date
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .film: L("Film")
        case .frame: L("Frame", as: "placing the picture")
        case .edge: L("Edge")
        case .date: L("Date")
        }
    }
    /// The step's capsule, as drawn (`m_steps`).
    var width: CGFloat { [56, 66, 56, 54][rawValue] }
    /// Film and Frame show the guide over the undeveloped picture; Edge and
    /// Date the developed film.
    var showsGuide: Bool { self == .film || self == .frame }
}

/// Where the flow is, and what moving costs. A value, so the page keeps it
/// as state and a check can walk it.
struct FilmEdgeJourney: Equatable, Sendable {
    private(set) var step: FilmEdgeStep
    /// Entered from *Date Back* with no film edge: the flow is that one step.
    let dateAlone: Bool

    init(entry: FilmEdgeStep, dateAlone: Bool) {
        step = dateAlone ? .date : entry
        self.dateAlone = dateAlone
    }

    /// Every step can be tapped from the start: none waits for *Next*.
    func isOpen(_ s: FilmEdgeStep) -> Bool { dateAlone ? s == .date : true }

    /// What a move asks of the page.
    enum Move: Equatable, Sendable {
        /// Nothing: already there, or nowhere to go.
        case stay
        /// To this step; `writes` when the film edge goes on the frame first.
        case to(FilmEdgeStep, writes: Bool)
        /// *Develop*: the flow ends; `writes` when the film edge is still outstanding.
        case develop(writes: Bool)
    }

    /// Leaving the guide for the developed film, whichever way: Next from
    /// Frame, or a tap on Edge or Date from Film or Frame. Back to the guide
    /// writes nothing — what is changed there goes on the frame when the flow
    /// comes forward again, and never if it is cancelled.
    func writes(to s: FilmEdgeStep) -> Bool { !dateAlone && step.showsGuide && !s.showsGuide }

    /// A step in the bar.
    func go(to s: FilmEdgeStep) -> Move {
        guard isOpen(s), s != step else { return .stay }
        return .to(s, writes: writes(to: s))
    }

    /// *Next*, or on the last step *Develop*.
    func next(filmEdgeOn: Bool) -> Move {
        guard let following = FilmEdgeStep(rawValue: step.rawValue + 1), !dateAlone else {
            return .develop(writes: !dateAlone && !filmEdgeOn)
        }
        return .to(following, writes: writes(to: following))
    }

    /// *Back*: one step, never past the first.
    func back() -> Move {
        guard !dateAlone, let previous = FilmEdgeStep(rawValue: step.rawValue - 1) else { return .stay }
        return .to(previous, writes: false)
    }

    /// The page made the move.
    mutating func arrive(_ move: Move) {
        if case .to(let s, _) = move { step = s }
    }

    /// The draft as it goes on the frame when the flow leaves the guide: on,
    /// with the body it was shot through (the host's own, the first time),
    /// and the cut the guide showed.
    static func written(_ draft: FrameEdit, bodySeed: Int, framing: Geometry?) -> FrameEdit {
        var e = draft
        e.filmEdge.active = true
        if e.filmEdge.cameraSeed == 0 { e.filmEdge.cameraSeed = bodySeed }
        if let framing { e.filmEdge.framing = framing }
        return e
    }
}

/// What an option needs, so a panel can grey it where it sits and say why.
/// Each is true when the option changes the picture.
enum FilmEdgeOptions {
    // MARK: Edge

    /// Holes: only a perforated film has them — not 120.
    static func holes(_ edge: FilmEdgeSettings) -> Bool { edge.format.isPerforated }

    /// The frame's number is part of the edge print, so it is seen only where
    /// the print is in the scan. A filed carrier's sliver stops short of the
    /// band it is printed on — on 135, and on Kodak's 120, whose number is the
    /// digit by the triangles on the far edge (the near edge's count is the
    /// roll's, not the frame's) — and a motion-picture stock prints no frame
    /// numbers on 135 at all. Fujifilm's 120 prints it by the gate, in the
    /// sliver either way.
    static func frameNumber(_ edge: FilmEdgeSettings, stockID: String) -> Bool {
        frameNumberReason(edge, stockID: stockID) == nil
    }

    /// Why the frame's number is not seen, for the Body panel's note; nil when it is.
    static func frameNumberReason(_ edge: FilmEdgeSettings, stockID: String) -> String? {
        let look = EdgeLook.of(stockID)
        if edge.format.isPerforated, look.k135 == .cine { return L("This film’s edge prints no frame numbers.") }
        let nearGate = !edge.format.isPerforated && look.k120 == .fuji
        if edge.mode == .filed, !nearGate { return L("Filed: this film’s frame number is outside the sliver.") }
        return nil
    }

    // MARK: Date

    /// No back on this camera printed anything: the whole Date step stands down.
    static func printsNothing(_ back: DateBackSettings, _ edge: FilmEdgeSettings) -> Bool {
        edge.effective && !back.camera(filmEdge: edge).drawsAnyDate
    }

    /// A face: the date is on, and this camera's back printed the face.
    static func face(_ face: DateBackFace, _ back: DateBackSettings, _ edge: FilmEdgeSettings) -> Bool {
        back.active && !printsNothing(back, edge) && back.prints(face, filmEdge: edge)
    }

    /// The corner: a date in the frame, on. The data face goes beside the frame.
    static func corner(_ back: DateBackSettings, _ edge: FilmEdgeSettings) -> Bool {
        back.active && !printsNothing(back, edge) && back.style != .data && back.placement == .frame
    }

    /// The size: any date, on.
    static func size(_ back: DateBackSettings, _ edge: FilmEdgeSettings) -> Bool {
        back.active && !printsNothing(back, edge)
    }
}
