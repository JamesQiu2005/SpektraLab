//  AppServices+DoubleDarkroom.swift — what the double exposure's darkroom asks of the model (RFC-050 §4, PRD 2 §4).
//
//  Every write is one call of `AppServices.changeDouble` — the one place a kept double exposure's piece is written —
//  and so one step of the open page's Undo (`DevelopRevision.double`), its develop asked by the page's session as
//  for any control. Nothing here develops anything by itself. An extension in a file of its own: `AppServices.swift`
//  is the other lanes' too (the phase-2 build's rule).

import CoreGraphics
import Foundation

extension DoubleExposure.Exposure {
    /// This exposure's meter as the Film tab's pill says it (the pair's `Hole.meter(film:)`): its own intent,
    /// or Custom — the meter off, the picture exposed as it was shot. Metered when its own switch and the
    /// whole's are both on (`DoubleExposure.stops`).
    func meter(film: FilmParams) -> AEMethod {
        guard autoExposure, film.autoExposure else { return .custom }
        return ExposureMethod(rawValue: meterMethod).map(AEMethod.metered) ?? .legacy
    }

    /// Take a meter from the pill. Custom leaves the intent alone, as for a photograph (`AEMethod.apply`).
    mutating func take(meter: AEMethod) {
        switch meter {
        case .custom: autoExposure = false
        case .metered(let m):
            autoExposure = true
            meterMethod = m.rawValue
        case .legacy:
            autoExposure = true
            meterMethod = "legacy"
        }
    }
}

extension DoubleExposure {
    /// An exposure's own meter, from its pill. Where the whole's switch is off — both exposed as shot —
    /// metering one turns the whole's on and leaves the other as it was, unmetered: the choice is that
    /// exposure's, and has to do something (the pair's `take(meter:on:look:)`).
    mutating func take(meter: AEMethod, on position: Position, look: inout FilmParams) {
        if case .custom = meter {} else if !look.autoExposure {
            look.autoExposure = true
            if self[position.other]?.autoExposure == true { self[position.other]?.autoExposure = false }
        }
        self[position]?.take(meter: meter)
    }

    /// "Covers the frame · 1.30×": where an exposure lies, for its Place row (K4). It always covers the
    /// frame (zoom ≥ 1), so the words say so and how far it is enlarged.
    static func placedText(_ placement: Placement) -> String {
        L("Covers the frame") + Fmt.dot + Fmt.times(placement.held.base.scale)
    }
}

extension AppServices {
    /// **Balance** to `s` (10–90 %), the frame's light held (RFC-047 §4): one step of Undo — a tap, a typed
    /// value, a step of the keyboard. A drag is `balanceDrag`.
    func setDoubleBalance(_ id: LibraryFrame.ID, _ s: Double) {
        changeDouble(id) { double, _ in double.setBalance(s) }
    }

    /// Where a finger is in a Balance drag (`balanceDrag`).
    enum DragPhase: Sendable { case began, changed, ended }

    /// **Balance under a finger, developed while it moves** (the UX review's R2: a share written only on
    /// release leaves the picture standing still under the drag). Every value is written to the piece as it comes
    /// (`changeDouble`), so the page's session asks for the frame at **the live tier** (`OpenFrameSession.ask`:
    /// `.live`, the canvas's size) the moment the finger rests (`filmSidePause`, as every film-side control) —
    /// the decodes of a double are other pixels, so it is the film side. The whole gesture is **one step of
    /// Undo** (`began` opens the page's history transaction, `ended` closes it: every `changeDouble` in
    /// between records into it), the guide is owed while the finger is down and drawn once on lift
    /// (`drawOwedDoubleGuide`), and the log has one `double.balance` record, on lift (RFC-047 §8). With no page
    /// open (the harness, the queue) each value is a write and a queued develop, as `setDoubleBalance`.
    func balanceDrag(_ id: LibraryFrame.ID, _ phase: DragPhase, to s: Double? = nil) {
        let session = openSession(id)
        switch phase {
        case .began:
            session?.began(.shoot)
            if let s { changeDouble(id) { double, _ in double.setBalance(s) } }
        case .changed:
            if let s { changeDouble(id) { double, _ in double.setBalance(s) } }
        case .ended:
            if let s { changeDouble(id) { double, _ in double.setBalance(s) } }
            session?.ended()
            drawOwedDoubleGuide(id)
            if let double = library.frame(id)?.double { Log.doubleBalance(id, double) }
        }
    }

    /// **Whose white balance a Decode control writes** with this layer picked (the UX review's R3): an
    /// exposure's photograph, and only with that exposure picked — never the bottom's on behalf of the whole.
    /// With the whole (胶片) picked there is none: the page shows Film Exposure and one way into each exposure's
    /// own white balance (the 图层 panel's rows), and a white balance pasted onto the whole goes to neither.
    func decodePosition(_ id: LibraryFrame.ID, on layer: DoubleExposure.Layer) -> DoubleExposure.Position? {
        library.frame(id)?.double?.decodePosition(on: layer)
    }

    /// An exposure's white balance or lens correction, written to its photograph (`changeDecode(of:inDouble:)`)
    /// — **refused with the whole picked** (R3): the call names the layer the page has picked, and only an
    /// exposure's layer reaches a photograph. True when it was written.
    @discardableResult
    func changeDecode(on layer: DoubleExposure.Layer, inDouble id: LibraryFrame.ID, _ mutate: (inout DecodeSettings) -> Void) -> Bool {
        guard let position = decodePosition(id, on: layer) else { return false }
        changeDecode(of: position, inDouble: id, mutate)
        return true
    }

    /// The meter an exposure of a double was made with: its photograph's own intent ("legacy" for none).
    func madeMeter(_ photograph: UUID) -> String {
        library.frame(photograph)?.edit.params.autoExposureMethod ?? "legacy"
    }

    /// **Flip an exposure** across (the 图层 row's flip): one step of Undo. Mirrors the window's content, not
    /// the window (`DoubleExposure.Placement.flipped`), so a drag after it moves the picture the same way.
    func flipDouble(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position) {
        changeDouble(id) { double, _ in double[position]?.placement.flipped.toggle() }
    }

    /// **One exposure alone** (the UX review's R9, the 图层 panel's eye per exposure row): the page shows that
    /// exposure as it would develop by itself — its own light as metered, the whole's Film Exposure, without
    /// the share it gave the other (`DoubleExposure.alone`) — and nil shows the double again. The page's state
    /// (`OpenFrameSession.alone`), not the piece's: nothing is written, nothing is undone. The render itself is
    /// `developAlone`; the guide of that exposure alone stands in while it develops (`DoubleGuide`).
    func showAlone(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position?) {
        guard let session = openSession(id), session.double != nil else { return }
        session.alone = position.flatMap { session.double?[$0] == nil ? nil : $0 }
    }

    /// **An exposure developed alone** at the page's size, in an engine session of its own that goes with the
    /// job (`EngineRouter.prepareAlone`, `EngineHost.leavesEditingAlone`): the page's own session — the
    /// double composed, its negative cached — stays the engine's editing session, so the next edit of the
    /// double still reprints from it. Nil where there is nothing to develop, or no engine.
    func developAlone(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position) async -> CGImage? {
        guard let item = library.frame(id), item.double?[position] != nil else { return nil }
        let look = openSession(id)?.edit ?? item.edit
        let canvas = item.canvas(look)
        let job = RenderJob(frameID: EngineRouter.aloneSession(id, position), kind: .canvasDevelop, tier: .live, canvas: canvas,
                            layers: [.shoot], what: "double alone", decodesOriginal: true,
                            original: darkroom.decodeSize(item), opens: nil)
        guard darkroom.prepareAlone(job, item: item, position: position, look: look,
                                    longEdge: item.previewDevelopLongEdge(look)) else { return nil }
        let jobID = scheduler.submit(job)
        let outcome = await scheduler.outcome(of: jobID)
        defer { darkroom.forget(jobID) }
        guard case .finished = outcome else { return nil }
        return darkroom.takeAlone(jobID)
    }

    /// **An exposure's own stops** (K2's dial): its number alone; the frame's light and Balance both move.
    func setDoubleExposure(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position, ev: Double) {
        changeDouble(id) { double, _ in double.exposure(ev, of: position) }
    }

    /// An exposure's own meter, from its pill (pro-control).
    func setDoubleMeter(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position, _ method: AEMethod) {
        changeDouble(id) { double, look in double.take(meter: method, on: position, look: &look.params) }
    }

    /// **↺ on a double exposure** (PRD 2 §4.2), in one transaction and one step of Undo: the film's develop
    /// back to what a new one starts with (the stocks kept, as a photograph's ↺), Balance to 50 % and both
    /// exposures' own stops and meter as made (−1 EV each, metered alone with their photographs' intent).
    /// **Not** the placements, the flips or the order: the pair's rule.
    func resetDouble(_ id: LibraryFrame.ID) {
        changeDouble(id) { double, look in
            double.resetExposures()
            for position in DoubleExposure.Position.allCases {
                guard let e = double[position] else { continue }
                double[position]?.meterMethod = madeMeter(e.frame)
            }
            look.resetDevelop()
            look = double.startingLook(look)
        }
    }

    /// Each exposure's picture as its photograph frames it, by position, for `double` as given (another
    /// photograph in a layer included): what `fill` and `swap` lay the frame again from.
    func framed(_ double: DoubleExposure) -> DoubleExposure.Framed {
        double.framed(darkroom.held(by: double))
    }

    /// **Replace** an exposure's photograph (or fill an empty layer: *Add Exposure*, K7) with `photo`, laid in
    /// the middle at −1 EV and metered alone (`Exposure(frame:sourceEdit:sourceGeometry:)`). Refused for the
    /// photograph the double exposure began with (`mayChange`) and for anything that is not a photograph.
    /// True when it was done.
    @discardableResult
    func replaceDouble(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position, with photo: LibraryFrame.ID) -> Bool {
        guard let was = library.frame(id)?.double, let chosen = library.frame(photo), !chosen.isComposite,
              was.mayChange(position) || library.frame(was[position]?.frame) == nil else { return false }
        let exposure = DoubleExposure.Exposure(frame: chosen.id, sourceEdit: chosen.edit, sourceGeometry: chosen.pictureGeometry)
        var after = was
        after[position] = exposure
        let before = framed(was), now = framed(after)
        var done = false
        changeDouble(id) { double, _ in
            // A photograph that has left the library is nobody's to keep: its layer takes another.
            if double.origin == double[position]?.frame, library.frame(double[position]?.frame) == nil { double.origin = nil }
            done = double.fill(position, with: exposure, before: before, after: now)
        }
        return done
    }

    /// **Remove** an exposure's photograph from the double exposure (the photograph stays in the library):
    /// its layer is left empty, unexposed film. Refused for the photograph it began with, and for the last
    /// exposure left — a double exposure with none is not one (the pair's rule for its last frame).
    @discardableResult
    func removeDouble(_ id: LibraryFrame.ID, _ position: DoubleExposure.Position) -> Bool {
        guard let was = library.frame(id)?.double, was[position] != nil, was[position.other] != nil,
              was.mayChange(position) else { return false }
        var after = was
        after[position] = nil
        let before = framed(was), now = framed(after)
        var done = false
        changeDouble(id) { double, _ in done = double.fill(position, with: nil, before: before, after: now) }
        return done
    }

    /// **Place's Done** (K6): each exposure laid as the cover left it, in one `changeDouble` — one step of
    /// Undo for all it moved — and a `double.place` record for each exposure that moved. Nothing for a cover
    /// that moved nothing.
    func placeDouble(_ id: LibraryFrame.ID, _ placed: [DoubleExposure.Position: DoubleExposure.Placement]) {
        guard let was = library.frame(id)?.double else { return }
        let moved = placed.filter { position, p in was[position] != nil && was[position]?.placement.held != p.held }
        guard !moved.isEmpty else { return }
        changeDouble(id) { double, _ in
            for (position, p) in moved where double[position] != nil { double[position]?.placement = p.held }
        }
        for (position, p) in moved.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { Log.doublePlace(id, position, p) }
    }
}
