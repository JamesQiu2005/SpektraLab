//  DevelopStatus.swift — the line under the picture.
//
//  "What the app says while it works" (design/flow): each state names what is
//  happening, and none hides a reduction.
//
//  - **Developing · Film Exp. +0.3** — a film-side change: the negative
//    develops again.
//  - **Printing · Yellow +0.10** — a print-side change: a fast reprint from the
//    negative. The user learns which edits are cheap without being told about
//    layers.
//  - **Developed · Porta 400 · Supera Enduro** — done.
//  - a job that is waiting says why (RFC-036 §3.5).

import Foundation

struct DevelopStatus: Equatable, Sendable {
    var text: String
    /// The accent dot and the bar: something is under way, or waiting to be.
    var busy: Bool
    /// 0…1 while a job runs; nil when there is nothing to show a bar for.
    var progress: Double?

    /// What a frame's page shows, from the scheduler's view of its job.
    /// `hasDevelop`: the frame has a picture the engine made — kept, or just
    /// landed on the page. `engineFailure`: why the engine is not running where
    /// it should be (`EngineRouter.failure`).
    static func of(_ snapshot: JobSnapshot?, frame: LibraryFrame, catalog: StockCatalog = .shared,
                   thermal: FrontendState.Thermal = .nominal, engineIsSimulated: Bool = false,
                   hasDevelop: Bool = true, engineFailure: String? = nil) -> DevelopStatus {
        let atRest = snapshot.map({ s in
            if case .running = s.state { false } else if case .queued = s.state { false }
            else if case .waiting = s.state { false } else { true }
        }) ?? true
        // A frame that is not one of the bundled demo pictures has not been
        // developed by anything where no engine runs: what is on the page is its
        // camera's own preview. Nothing reduced is passed off as the real thing.
        // (A half-frame pair has no camera's preview: until it is developed it
        // shows a guide made of its two frames' own, `PairGuide`.)
        let shown = frame.isPair ? L("A guide of its two frames") : L("The camera's own preview")
        if engineIsSimulated && !frame.isDemo, atRest {
            return DevelopStatus(text: shown + Fmt.dot + (engineFailure == nil ? L("no engine in this build") : L("the engine is not running")),
                                 busy: false, progress: nil)
        }
        // The engine runs and this frame has no develop of its own yet: its
        // original is away, or its develop has not come up in the queue.
        if !engineIsSimulated && !frame.isDemo && !hasDevelop, atRest {
            return DevelopStatus(text: shown + Fmt.dot + L("not developed yet"), busy: false, progress: nil)
        }
        // At rest the line names the stocks, or the film edge when the frame
        // wears one (`the page layout`: "Developed · Film edge on").
        // A slide names no paper: "Developed · Ectochrome 100 · scanned".
        // With Apply Film Emulation off there is no film to name: Apple's decode.
        let rest = !frame.edit.appliesFilm ? L("Film emulation off")
            : frame.edit.filmEdge.effective || (frame.pair?.wearsFilmEdge ?? false)
            ? L("Film edge on")
            : catalog.pairText(frame.edit.params).replacingOccurrences(of: " · ", with: Fmt.dot)
        // A HEIF or a JPEG comes in already developed by its camera: the film
        // starts from that picture, not from RAW — and the line says so.
        // A pair is a piece of film the app laid out: there is no camera's picture of it.
        let done = frame.isDemo || frame.developsFromRAW || frame.isPair ? L("Developed") : L("From the camera's picture")
        guard let snapshot else {
            return DevelopStatus(text: done + Fmt.dot + rest, busy: false, progress: nil)
        }
        let what = snapshot.job.what.isEmpty ? "" : Fmt.dot + snapshot.job.what
        switch snapshot.state {
        case .running(let p):
            // Heat lowers pace, never the effects — and says so.
            let hot = thermal >= .serious && snapshot.job.kind.isCanvas ? Fmt.dot + L("Mac is hot, slower") : ""
            return DevelopStatus(text: L(shown: snapshot.job.verb) + what + hot, busy: true, progress: p.fraction)
        case .queued:
            return DevelopStatus(text: L(shown: snapshot.job.verb) + what, busy: true, progress: 0)
        case .waiting(let why):
            return DevelopStatus(text: L(shown: why.text), busy: true, progress: nil)
        case .failed(let message):
            return DevelopStatus(text: L("Could not develop") + Fmt.dot + message, busy: false, progress: nil)
        case .done, .cancelled:
            return DevelopStatus(text: done + Fmt.dot + rest, busy: false, progress: nil)
        }
    }
}

/// What changed between two edits, as the status line and Info say it.
enum ChangeDescriber {
    /// The one change to name: the first that differs, in the tabs' order.
    static func what(from old: FrameEdit, to new: FrameEdit, catalog: StockCatalog = .shared) -> String {
        let a = old.params, b = new.params
        if old.appliesFilm != new.appliesFilm { return new.appliesFilm ? L("Film emulation on") : L("Film emulation off") }
        if a.filmStock != b.filmStock { return catalog.stock(b.filmStock)?.shortName ?? b.filmStock }
        if a.exposureCompensationEV != b.exposureCompensationEV { return L("Film Exp. ") + Fmt.signed(b.exposureCompensationEV) }
        // Pro's pill beside Film Exposure: the meter's intent, or the meter off.
        if a.autoExposure != b.autoExposure || a.autoExposureMethod != b.autoExposureMethod {
            return b.autoExposure ? L("Meter ") + ExposureMethod.title(forWire: b.autoExposureMethod) : L("Meter off")
        }
        // A slide's own change is its film's, named above; this is a negative
        // going to a scan or back to a paper.
        if a.scanFilm != b.scanFilm { return b.scanFilm ? L("Scanned") : catalog.stock(b.printStock)?.shortName ?? L("Printed") }
        // The Digital Intermediate takes the paper's place, or gives it back.
        if a.digitalIntermediate != b.digitalIntermediate {
            return b.digitalIntermediate ? L("Digital Intermediate") : catalog.stock(b.printStock)?.shortName ?? L("Printed")
        }
        if a.printStock != b.printStock { return catalog.stock(b.printStock)?.shortName ?? b.printStock }
        if a.printBrightnessStops != b.printBrightnessStops { return L("Brightness ") + Fmt.signed(b.printBrightnessStops) }
        if a.yFilterShift != b.yFilterShift { return L("Yellow ") + Fmt.signed(b.yFilterShift, decimals: 2) }
        if a.mFilterShift != b.mFilterShift { return L("Magenta ") + Fmt.signed(b.mFilterShift, decimals: 2) }
        if a.preflashExposure != b.preflashExposure { return String(format: L("Pre-flash %.3f"), b.preflashExposure) }
        if a.sceneLatitude.highlightPullBack != b.sceneLatitude.highlightPullBack {
            return String(format: L("Highlight placement %.2f"), b.sceneLatitude.highlightPullBack)
        }
        if a.sceneLatitude.shadowPullBack != b.sceneLatitude.shadowPullBack {
            return String(format: L("Shadow placement %.2f"), b.sceneLatitude.shadowPullBack)
        }
        // As the drawing says it (P3: "Developing · Temperature 5200 K"); back
        // to the camera's own is neither number's doing.
        if old.decode.whiteBalance != new.decode.whiteBalance, new.decode.whiteBalance != .custom { return L("White balance") }
        if old.decode.temperature != new.decode.temperature { return L("Temperature \(Int(new.decode.temperature.rounded())) K") }
        if old.decode.tint != new.decode.tint { return L("Tint ") + Fmt.signed(new.decode.tint, decimals: 0) }
        if old.decode.whiteBalance != new.decode.whiteBalance { return L("White balance") }
        if old.decode.lensCorrection != new.decode.lensCorrection { return L("Lens correction") }
        if a.filmFrame != b.filmFrame || a.filmFormatMM != b.filmFormatMM { return L("Film size \(b.filmFrame)") }
        if a.effects.grain != b.effects.grain || a.grainActive != b.grainActive { return L("Grain ") + Fmt.times(b.effects.grain) }
        if a.effects.grainLayered != b.effects.grainLayered { return b.effects.grainLayered ? L("Grain in three layers") : L("Grain in one layer") }
        if a.effects.halation != b.effects.halation || a.halationActive != b.halationActive {
            return L("Halation ") + Fmt.times(b.effects.halation)
        }
        if a.effects.scatter != b.effects.scatter { return String(format: L("Scatter %.2f"), b.effects.scatter) }
        if a.effects.couplers != b.effects.couplers || a.effects.couplersActive != b.effects.couplersActive {
            return L("Couplers ") + Fmt.times(b.effects.couplers)
        }
        if a.effects.glare != b.effects.glare || a.glareActive != b.glareActive { return String(format: L("Glare %.1f×"), b.effects.glare) }
        if old.geometry != new.geometry { return L("Crop") }
        if FeatureFlags.filmEdge, old.filmEdge != new.filmEdge {
            let (a, b) = (old.filmEdge, new.filmEdge)
            if a.active != b.active { return b.active ? L("Film edge \(b.format.label)") : L("Film edge off") }
            if a.format != b.format || a.mode != b.mode { return L("Film edge \(b.format.label) · \(b.mode.label)") }
            if a.gate != b.gate { return L("Gate \(b.gate.label)") }
            if a.holes != b.holes { return L("Holes \(b.holes.label)") }
            if a.fog != b.fog { return String(format: L("Edge fog %.1f"), b.fog) }
            if a.leaks != b.leaks { return String(format: L("Spool leaks %.1f"), b.leaks) }
            if a.cameraSeed != b.cameraSeed { return L("Body No. \(b.cameraSeed)") }
            if a.frameNumber != b.frameNumber { return b.frameNumber == 0 ? L("Frame no. auto") : L("Frame no. \(b.frameNumber)") }
            return L("Film edge")
        }
        if FeatureFlags.dateBack, old.dateBack != new.dateBack {
            return new.dateBack.active ? L("Date back \(new.dateBack.style.label)") : L("Date back off")
        }
        if old.frameSeed != new.frameSeed { return L("Another frame") }
        return ""
    }

    /// Which layers an edit touches. Anything outside `FilmParams` — the
    /// decode, the crop — changes what the film sees, so it develops again.
    static func layers(from old: FrameEdit, to new: FrameEdit) -> Set<ParamLayer> {
        var layers = new.params.delta(from: old.params).layers
        if old.decode != new.decode || old.geometry != new.geometry { layers.insert(.shoot) }
        // Apply Film Emulation: the film, or Apple's decode, from the start.
        if old.appliesFilm != new.appliesFilm { layers.insert(.shoot) }
        if FeatureFlags.filmEdge && old.filmEdge != new.filmEdge { layers.insert(.shoot) }
        if FeatureFlags.dateBack && old.dateBack != new.dateBack { layers.insert(.shoot) }
        // The advance and the scan: only a film edge shows them.
        if old.frameSeed != new.frameSeed && new.filmEdge.effective { layers.insert(.shoot) }
        return layers
    }
}
