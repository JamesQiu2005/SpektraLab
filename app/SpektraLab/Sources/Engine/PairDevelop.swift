//  PairDevelop.swift — a half-frame pair, as the engine is handed it.
//
//  Two halves, both made on the main actor when a pair's job is submitted
//  (`EngineRouter.preparePair`):
//
//  - **the piece** (`HalfFramePair.piece`): which picture lies under which
//    hole at the size the job renders, in plain values for the host
//    (`PieceAsk`; `FrameDecoder` composes it on the engine's queue);
//  - **the wire** (`FrameEdit.pairWire`): the pair's own look — one film, one
//    paper, one enlarger — and what the engine has to be told of a pair.
//
//  **What the engine is told** (the desktop's `Session.resolved`,
//  `FilmEdgeSettings.wire`, `DateBackSettings.wire`):
//
//  - `auto_exposure` off and no exposure of the piece's own: each picture
//    carries its exposure in its pixels (`PieceAsk.Exposure`). **The look's
//    own meter switch and Film Exposure are the develop page's Film tab, and
//    on a pair they stand for both frames**: the meter's intent is each
//    frame's unless it has its own, Custom exposes both as shot, and Film
//    Exposure moves both by the same stops on top of each frame's own (the
//    pair's page). Neither reaches the wire. (The desktop's pair has no such
//    control and turns both off in its look; a look made by
//    `HalfFramePair.look` is given its meter back when the pair is kept.)
//  - `film_format_mm` for the whole piece — the engine is handed 37 mm of
//    film where Film Format describes one half frame of it
//    (`HalfFramePair.filmFormatMM`);
//  - no cut: the piece is whole, each picture already cut by the host;
//  - with a film edge, `overscan_format` = `135_half` and `overscan_pair`:
//    "the input carries both pictures, the second one advance along"
//    (`overscan.cpp`). The engine wants the gate and one advance, 37 × 24 —
//    which is the piece at the camera's own 1.00 mm
//    (`HalfFramePair.effectiveSpacingMM` on a strip);
//
//    **a pair's film edge is the pair's own switch** (`HalfFramePair.onStrip`),
//    and its look's `filmEdge.active` stays off (`FrameEdit.asPairLook`). The
//    look keeps how the film is drawn — the view, the gate, the holes, fog and
//    leaks — but a film edge that is *on* in an edit means one frame in one
//    gate to every page that reads it (its framing, its turn, the layout the
//    pages draw before a develop lands), and none of that is a pair's;
//  - with a date, `date_imprint_text_b`: each frame carries its own date, and
//    without a film edge the pair is named here (`overscan_pair`), since the
//    film edge's own rows are not sent. **Each frame decides whether the back
//    printed on it** (`HalfFramePair.Hole.dated`, the owner, 2026-10-10): a
//    frame switched off hands the engine no text, as an empty hole does
//    (`EngineRouter.wire`), and the engine prints the other alone.
//
//  - **a Scene Placement a frame** (since 2026-10-10, the desktop's way; the
//    owner: "just as what we get from the desktop side"): the first frame's
//    curve on the engine's own rows and the second's on `scene_latitude_b_*`,
//    from `scene_latitude_split` along the piece's long edge
//    (`FilmParams.pairPlacementWire`, `HalfFramePair.hold`). Each is fitted on
//    its own frame — the Fit and the Latitude card ask the engine for that
//    frame's `region` (`OpenFrameSession`) — so neither is placed by a scene
//    that is not its own.
//
//  **A frame's own print is not on this wire.** The wire is the film's print;
//  a frame that prints differently is printed again from the same negative
//  and cut in along its hole (`Engine/PrintLayers.swift`).
//
//  **Not sent**: a film turned half round (the name below, or on the left):
//  the engine has the two directions it reads from the piece's own shape —
//  across for a pair held level, down for one turned — and the host's turn of
//  a single frame's film (`FilmEdgeSettings.hostTurns`) is not made for a
//  piece, whose first picture has to stay at the start of the film.

import CoreGraphics
import Foundation

extension LibraryFrame {
    /// The size of the file the engine develops from (`developSource`): the
    /// original's — a frame read in place from Photos too, whose original is
    /// brought into the working copies. Only a frame the app has no more of
    /// than a preview copy (the drawings' own) is its preview copy's size.
    /// (Until 2026-10-10 every Photos frame was: a pair made of two of them
    /// then was laid out at their preview sizes, and is laid out again at
    /// launch: `AppServices.holdPairsToTheirFrames`.)
    var developSize: PixelSize { source == .photos && !readsFromPhotos ? previewSize : originalSize }

    /// The canvas a develop of `edit` makes of this item at preview size, for
    /// pricing the job before it runs: a photograph's (`FrameEdit.canvas`), or
    /// a pair's piece and the film round it.
    func canvas(_ edit: FrameEdit) -> PixelSize {
        guard let pair else { return edit.canvas(preview: previewSize) }
        return pair.canvas(piece: previewSize, look: edit)
    }
}

extension HalfFramePair {
    /// The frames a pair's holes hold, as the library has them now. A side
    /// with no entry is an empty hole, or a frame the library no longer has.
    typealias Frames = [Side: LibraryFrame]

    /// The pair with each hole's decode and cut read again from its frame:
    /// the shot stays the frame's (`mirror`).
    func mirrored(_ frames: Frames) -> HalfFramePair {
        var pair = self
        for side in Side.allCases {
            if let frame = frames[side] { pair.mirror(side, decode: frame.edit.decode, geometry: frame.pictureGeometry) }
        }
        return pair
    }

    /// Each filled hole's picture as its frame cuts it, at the size of the
    /// file it is developed from.
    func framed(_ frames: Frames) -> [Side: CGSize] {
        var sizes: [Side: CGSize] = [:]
        for side in Side.allCases {
            guard let hole = self[side], let frame = frames[side] else { continue }
            let own = frame.developSize
            sizes[side] = hole.geometry.outputSize(for: CGSize(width: own.width, height: own.height))
        }
        return sizes
    }

    /// The piece for a job whose frame is `longEdge` at most on its long edge;
    /// nil is the piece's own size, in which neither picture is enlarged
    /// (`pieceLayout`). A smaller piece is the same piece: its holes keep
    /// their shape and the gap its millimetres.
    func layout(_ frames: Frames, longEdge: Int?) -> Layout {
        let own = pieceLayout(sizes: framed(frames))
        let long = max(own.size.width, own.size.height)
        guard let longEdge, long > CGFloat(longEdge), long > 0 else { return own }
        let across = turned ? own.hole.width : own.hole.height
        return Self.layout(holeHeight: Int((across * CGFloat(longEdge) / long).rounded(.down)),
                           spacingMM: effectiveSpacingMM, turned: turned)
    }

    /// The piece's size in pixels at `longEdge`: what the engine is handed.
    func pieceSize(_ frames: Frames, longEdge: Int?) -> PixelSize {
        let size = layout(frames, longEdge: longEdge).size
        return PixelSize(width: Int(size.width), height: Int(size.height))
    }

    /// The canvas a develop of a piece `piece` pixels large makes: the piece
    /// itself, or — with a film edge — the film round it. An estimate, for
    /// pricing the job before it runs, as `FilmEdgeSettings.canvasEstimate`
    /// is for a frame: the strip's width (35 mm) and the widest margin a
    /// half-frame body draws past the two gates, on a piece 37 mm long.
    func canvas(piece: PixelSize, look: FrameEdit) -> PixelSize {
        guard wearsFilmEdge else { return piece }
        let long = Double(max(piece.longEdge, 1)), short = Double(max(min(piece.width, piece.height), 1))
        let px = pieceLongMM / long                                   // mm per pixel
        let margin = look.filmEdge.mode == .strip ? 0.5 : 1.0
        let along = Int(long + 2 * (margin / px).rounded())
        let across = look.filmEdge.mode == .strip ? Int((FilmEdgeFormat.half.filmWidthMM / px).rounded()) : Int(short + (2.2 / px).rounded())
        return turned ? PixelSize(width: across, height: along) : PixelSize(width: along, height: across)
    }

    /// The part of a hole's picture the hole shows, as fractions of the
    /// picture with a top-left origin. `framed` is the picture as its frame
    /// cuts it and the placement turns it; the answer is the same at any size
    /// of it (`sourceRect`).
    func window(_ hole: Hole, of framed: CGSize) -> CGRect {
        guard framed.width > 0, framed.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let cut = Self.sourceRect(for: hole.placement, source: framed, aspect: holeAspect)
        return CGRect(x: cut.minX / framed.width, y: cut.minY / framed.height,
                      width: cut.width / framed.width, height: cut.height / framed.height)
    }

    /// The piece as the host is asked for it: each filled hole whose frame
    /// has a file to develop from, cut and placed, at the job's size.
    func piece(_ frames: Frames, look: FrameEdit, longEdge: Int?) -> PieceAsk {
        let layout = layout(frames, longEdge: longEdge)
        var pictures: [PieceAsk.Picture] = []
        for side in Side.allCases {
            guard let hole = self[side], let frame = frames[side], let url = frame.developSource else { continue }
            let own = frame.developSize
            let framed = Self.turned(hole.geometry.outputSize(for: CGSize(width: own.width, height: own.height)), by: hole.placement)
            guard framed.width > 0, framed.height > 0 else { continue }
            let window = window(hole, of: framed)
            let method = hole.meterMethod ?? look.params.autoExposureMethod
            let key = Self.meterKey(hole: hole, method: method ?? "legacy")
            // The frame's own stops, and the piece's (the Film tab's Film Exposure), in its pixels.
            let stops = hole.exposureEV + look.params.exposureCompensationEV
            let exposure: PieceAsk.Exposure = hole.autoExposure && look.params.autoExposure
                ? .metered(reading: hole.meteredFor == key ? hole.meteredEV : nil, plus: stops, key: key)
                : .own(stops)
            pictures.append(PieceAsk.Picture(
                index: side.rawValue, url: url, isRAW: frame.developsFromRAW, settings: hole.decode,
                longEdge: PieceAsk.longEdge(original: own, framed: framed, window: window, hole: layout.hole),
                cut: hole.geometry, quarterTurns: hole.placement.quarterTurns, window: window,
                hole: layout.rect(side), exposure: exposure, meterWire: look.meterWire(method: method)))
        }
        return PieceAsk(size: PixelSize(width: Int(layout.size.width), height: Int(layout.size.height)), pictures: pictures)
    }

    /// True when the engine draws the film round the piece: the pair's own
    /// switch, where this build has Film Edge at all.
    var wearsFilmEdge: Bool { FeatureFlags.filmEdge && onStrip }

    /// "Level · 1.0 mm apart": the develop page's row for the pair.
    var rowValue: String {
        (turned ? L("Turned", as: "a pair") : L("Level", as: "a pair")) + " · " + String(format: L("%.1f mm apart"), effectiveSpacingMM)
    }

    /// A reading of the engine's meter, kept: for the hole it was read for,
    /// and only while that hole is still what was read (`meterKey`). False
    /// when the pair has moved on and the reading is dropped.
    @discardableResult
    mutating func keep(reading ev: Double, of index: Int, for key: String, method pairMethod: String?) -> Bool {
        guard let side = Side(rawValue: index), var hole = self[side] else { return false }
        guard Self.meterKey(hole: hole, method: (hole.meterMethod ?? pairMethod) ?? "legacy") == key else { return false }
        hole.meteredEV = ev
        hole.meteredFor = key
        self[side] = hole
        return true
    }
}

extension FrameEdit {
    /// This edit as a pair's look is kept: no cut of its own — the piece is
    /// whole, each picture cut by its frame — and no film edge *on*: a pair's
    /// film edge is the pair's own switch (`HalfFramePair.onStrip`), and the
    /// settings here only say how that film is drawn. Held wherever an edit
    /// enters a pair, as `held(to:)` is for a frame.
    var asPairLook: FrameEdit {
        var look = self
        look.geometry = .default
        look.filmEdge.active = false
        look.filmEdge.format = .half
        look.filmEdge.framing = nil
        look.filmEdge.turn = 0
        return look
    }

    /// The wire the engine's meter is opened with for one picture of a pair
    /// alone (the desktop's `Session.pairExposure`): this look with the meter
    /// on and its intent, no exposure of its own, no film edge and no date, on
    /// one half frame of film.
    func meterWire(method: String?) -> [String: ParamValue] {
        var alone = self
        alone.params.autoExposure = true
        alone.params.autoExposureMethod = method
        alone.params.exposureCompensationEV = 0
        alone.params.filmFormatMM = HalfFramePair.holeMM.across
        alone.geometry = .default
        return alone.engineWire(previewLongEdge: nil)
    }

    /// Everything `spk_open` is handed for a pair's piece under this look,
    /// complete. `film` is the first frame's side of a film edge and a date
    /// (`FilmWire`), `secondDate` the second frame's date as the back writes
    /// it. The frame handed over beside this wire has to be the piece
    /// (`HalfFramePair.piece`).
    func pairWire(_ pair: HalfFramePair, previewLongEdge: Int?, film: FilmWire, secondDate: String) -> [String: ParamValue] {
        var look = self
        // The piece is whole — each picture was cut by the host — and each
        // carries its own exposure in its pixels.
        look.geometry = .default
        look.params.autoExposure = false
        look.params.exposureCompensationEV = 0
        look.params.filmFormatMM = pair.filmFormatMM()
        // A placement a frame: the first frame's on the engine's own rows, the
        // second's from where it begins along the piece (`FilmParams.pairPlacementWire`).
        // The split is the piece's, whatever the kept look was last told.
        pair.hold(&look.params)
        look.filmEdge.format = .half
        look.filmEdge.framing = nil
        look.filmEdge.turn = 0
        look.filmEdge.active = pair.onStrip
        var wire = look.engineWire(previewLongEdge: previewLongEdge, film: film)
        if look.filmEdge.effective { wire["overscan_pair"] = .bool(true) }
        // Each frame of a pair carries its own date, and only a frame that is
        // there: `film.dateText` and `secondDate` are "" for an empty hole
        // (`EngineRouter.wire`). The rows a frame's wire wrote from the first text
        // alone are taken out, and the pair's put in (`DateBackSettings.pairRows`).
        wire = wire.filter { !$0.key.hasPrefix("date_imprint_") }
        for row in look.dateBack.pairRows(first: film.dateText, second: secondDate, filmEdge: look.filmEdge) {
            wire[row.name] = row.value
        }
        return wire
    }
}
