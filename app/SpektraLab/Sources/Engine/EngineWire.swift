//  EngineWire.swift — a frame's whole edit, as the engine is told it.
//
//  `FilmParams.wire` is the engine's parameters; an edit is more than that.
//  This is the one place that puts the rest beside it, so the develop page, a
//  shot's develop and an export all hand the engine the same words:
//
//  - **the cut**: the engine's eight geometry fields (crop, straighten, quarter
//    turns, flips), transliterated from the desktop's `Geometry` — normalised
//    crop with a top-left origin, rotation positive clockwise. The engine
//    applies them right after the frame is read and before the meter, so the
//    picture it hands back is already cut and nothing may cut it again;
//  - **`product_defaults`**: not a schema field but a switch — it selects the
//    product's defaults, which turn the enlarger's print-exposure
//    compensation off so that Film Exposure moves the finished print. It
//    belongs in every open (the bench and the desktop send it);
//  - **`preview_long_edge`**: the size of the engine's `live` tier, which is
//    1,600 px without it. Sent for a job below the full tier, with the frame
//    decoded no larger (`FrameSource.decode`), so the engine renders the
//    job's canvas and not a tier of its own.
//
//  - **the film and the date** (`FilmWire`): `overscan_*` and
//    `date_imprint_*`, in the model's own words (`FilmEdgeSettings.wire`,
//    `DateBackSettings.wire` — the fields `tools/film_edge_parity.py` sends).
//    The engine draws the film: the rebate, the holes, the edge print and the
//    date are exposure on the negative, and the picture it hands back is the
//    film's canvas, larger than the picture (API-SPEC §15, "the output
//    grows").
//
//  - **With a film edge the host cuts the picture, not the engine**
//    (`FrameEdit.hostCut`, made in `FrameDecoder`), and the wire's own cut is
//    none. The engine takes the frame it is handed as the gate — "the host
//    crops first" (API-SPEC §15), as the desktop does (`Session+FilmEdge`) —
//    and it sets the film's millimetres from the frame's long edge *before*
//    its own cut (`film_prefix`: "the pitch is the pre-crop long edge's"). Cut
//    by the engine, a square taken from a 4:3 photo was laid on the film as
//    42 mm of a 56 mm gate, with 9.5 mm of rebate either side of it (seen in
//    the simulator, 2026-10-07: asked 1952 x 1966, rendered 1978 x 2614); so
//    was any framing enlarged in the gate. A film turned half round is the
//    host's doing too (`FilmEdgeSettings.hostTurns`): the picture goes in
//    turned back, in the same cut, and the canvas comes out to be turned
//    forward (`FrameEdit.hostTurns`, `EngineHost`).
//
//    Until 2026-10-07 both were sent as off and the page drew a film of its
//    own round the developed picture — flat ink, white holes, no grain, no
//    halation. The owner, from the host: "the film edge is never truly
//    rendered."
//
//  Nothing here is conditional on the engine being linked: the words are the
//  app's, and `tools/selftest.sh` can hold them against the schema.

import CoreGraphics
import Foundation

extension Geometry {
    /// The engine's geometry fields (`engine/src/core/params.cpp`, `io.geometry.*`).
    var wire: [(name: String, value: ParamValue, layer: ParamLayer)] {
        [
            ("geometry_crop_x", .double(crop.x.clamped(to: 0...1)), .shoot),
            ("geometry_crop_y", .double(crop.y.clamped(to: 0...1)), .shoot),
            ("geometry_crop_w", .double(crop.width.clamped(to: 1e-4...1)), .shoot),
            ("geometry_crop_h", .double(crop.height.clamped(to: 1e-4...1)), .shoot),
            ("geometry_rotation_deg", .double(angle.clamped(to: -Geometry.maxAngle...Geometry.maxAngle)), .shoot),
            // An integer on the wire, 0…3, whichever way the page counted its turns.
            ("geometry_quarter_turns", .double(Double(((quarterTurns % 4) + 4) % 4)), .shoot),
            ("geometry_flip_h", .bool(flipH), .shoot),
            ("geometry_flip_v", .bool(flipV), .shoot),
        ]
    }

    /// The cut as a word — what of it moves pixels, and nothing of how the
    /// crop tool remembers it: for a develop's stamp and for telling one
    /// source from another (`EngineHost.Request.sourceKey`).
    var cutKey: String {
        let key = wire.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
        // The perspective is the host's (`HostCut`), never the engine's: it is
        // in the key, and only when there is one, so every key made before it
        // is the same word and every kept develop still matches its stamp.
        guard hasPerspective else { return key }
        return key + ";keystone_v=\(vertical);keystone_h=\(horizontal)"
    }
}

/// What a film edge and a date need of the frame they are on, which an edit
/// does not hold: the stock's own words for the edge print, the lens's
/// f-number, the date as the back writes it, and the host's body.
struct FilmWire: Equatable, Sendable {
    /// `overscan_edge_text`: the film's edge words (`Stock.edgeText(gauge:)`).
    var edgeText = ""
    var fNumber = 0.0
    /// The date, or the shooting data, as text; empty prints nothing.
    var dateText = ""
    /// The frame's shutter and aperture as the data line prints them, beside a
    /// date face (`DateBackSettings.alsoData`); empty prints nothing.
    var dataText = ""
    /// The body a film edge with none of its own is shot through
    /// (`AppSettings.bodySeed`).
    var bodySeed = 1

    init(edgeText: String = "", fNumber: Double = 0, dateText: String = "", bodySeed: Int = 1) {
        self.edgeText = edgeText
        self.fNumber = fNumber
        self.dateText = dateText
        self.bodySeed = bodySeed
    }

    /// The same answers the page's own layout is made from (`FilmEdgeResolver.resolve`).
    init(frame: LibraryFrame, edit: FrameEdit, bodySeed: Int) {
        edgeText = StockCatalog.shared.stock(edit.params.filmStock)?.edgeText(gauge: edit.filmEdge.format.gauge) ?? ""
        fNumber = ShootingLine.fNumber(frame.exposure)
        dateText = FilmEdgeResolver.dateText(edit.dateBack, frame: frame)
        dataText = ShootingLine.dataText(frame.exposure)
        self.bodySeed = bodySeed
    }
}

extension FrameEdit {
    /// The cut the engine is handed for a source of this size: the film's own
    /// framing while a film edge is on, the photo's crop otherwise
    /// (`LibraryFrame.pictureGeometry`, for an edit that is not yet the frame's).
    func pictureGeometry(source: PixelSize) -> Geometry {
        guard filmEdge.effective else { return geometry }
        return FilmFraming.resolved(filmEdge, source: CGSize(width: source.width, height: source.height), photo: geometry)
    }

    /// The quarter turns, clockwise, the host gives the engine's canvas for
    /// this edit: the film's half turn (`FilmEdgeSettings.hostTurns`), and
    /// none without a film edge.
    func hostTurns(source: PixelSize) -> Int {
        guard filmEdge.effective else { return 0 }
        let cut = pictureGeometry(source: source).gateSize(for: CGSize(width: source.width, height: source.height))
        return filmEdge.hostTurns(cut: PixelSize(width: Int(cut.width), height: Int(cut.height)))
    }

    /// The cut the **host** makes of the decode before the engine sees it, or
    /// nil when the engine cuts for itself (no film edge: the photo's crop is
    /// on the wire). The film's own framing, turned back by what the host
    /// turns the canvas afterwards. The cut's quarter turns come before its
    /// flips, and a turn carried past one flip changes hands (R⁻¹F = FR), so
    /// with exactly one flip on the turns are added.
    ///
    /// **Without a film edge, a perspective is the host's too** (Develop's
    /// Vertical and Horizontal, 2026-10-20): the engine has no keystone, so the
    /// host re-projects the decode (`HostCut`, `Geometry.perspectiveOnly`) —
    /// the whole frame, at its own size — and the engine makes the crop, the
    /// straighten, the turns and the flips from the wire as it always has, in
    /// the corrected frame they were made in. The engine therefore still lays
    /// the film's millimetres across the whole frame and meters after its own
    /// cut. Under a film edge the photo's crop is held, and its perspective
    /// with it.
    func hostCut(source: PixelSize) -> Geometry? {
        guard filmEdge.effective else { return geometry.hasPerspective ? geometry.perspectiveOnly : nil }
        var g = pictureGeometry(source: source)
        let k = hostTurns(source: source)
        guard k != 0 else { return g }
        g.quarterTurns = (((g.quarterTurns + (g.flipH != g.flipV ? k : -k)) % 4) + 4) % 4
        return g
    }

    /// The cut as the engine is told it: the photo's crop, and none at all
    /// while the host cuts (`hostCut`) — the frame it is handed is then the
    /// gate, whole.
    var engineGeometry: Geometry { filmEdge.effective ? .default : geometry }

    /// The canvas a develop of this edit makes from a preview of this size:
    /// the preview itself, or — with a film edge — the film round the cut,
    /// which is the costliest render the host makes (RFC-035 §2) and is
    /// priced as what it is (`FilmEdgeSettings.canvasEstimate`).
    func canvas(preview: PixelSize) -> PixelSize {
        guard filmEdge.effective else { return preview }
        let size = CGSize(width: preview.width, height: preview.height)
        let cut = FilmFraming.resolved(filmEdge, source: size, photo: geometry).gateSize(for: size)
        return filmEdge.canvasEstimate(picture: PixelSize(width: Int(cut.width), height: Int(cut.height)))
    }

    /// Everything `spk_open` is handed for this edit, complete. `previewLongEdge`
    /// is the job's canvas for a develop below the full tier, nil for a
    /// full-size one. `film` is the frame's side of a film edge and a date;
    /// without it neither is sent. The engine is later sent only what changed
    /// (`SpkEngine`). With a film edge the frame handed over beside this wire
    /// has to be the host's cut of it (`hostCut`).
    func engineWire(previewLongEdge: Int?, film: FilmWire? = nil) -> [String: ParamValue] {
        // Through the catalogue: a slide film is scanned, whatever the edit
        // holds (`StockCatalog.wire(for:)`, and the rule above it).
        var wire = StockCatalog.shared.wire(for: params)
        for field in engineGeometry.wire { wire[field.name] = field.value }
        wire["product_defaults"] = .bool(true)
        if let previewLongEdge {
            wire["preview_long_edge"] = .double(Double(previewLongEdge.clamped(to: 800...8192)))
        }
        guard let film else {
            wire["overscan_active"] = .bool(false)
            wire["date_imprint_active"] = .bool(false)
            return wire
        }
        // The film first: the date names its camera only when there is no film.
        var edge = filmEdge
        if edge.cameraSeed == 0 { edge.cameraSeed = film.bodySeed }
        for field in edge.wire(edgeText: film.edgeText, frameSeed: frameSeed, fNumber: film.fNumber) { wire[field.name] = field.value }
        for field in dateBack.wire(text: film.dateText, filmEdge: filmEdge, dataText: film.dataText) { wire[field.name] = field.value }
        return wire
    }
}
