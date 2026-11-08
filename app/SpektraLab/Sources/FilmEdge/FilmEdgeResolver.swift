//  FilmEdgeResolver.swift — a frame's film edge, resolved: what the engine is told.
//
//  The page keeps a few choices (`FilmEdgeSettings`, `DateBackSettings`); the
//  engine needs a picture already cut to the gate, its size in pixels, the
//  stock's words, the lens's f-number and the date as text. This is the one
//  place that turns the first into the second, so the Frame step's guide, the
//  ledger, the Frame tab's rows, the develop page's picture and an export all
//  work from the same answer.
//
//  The pixel math is the design's (design/overscan §2): the canvas is
//  calculated from the pixels left inside the gate, the rebate is added
//  outside the picture and takes none of its pixels, and when the film would
//  exceed the device's film budget the *picture* is scaled before the develop
//  — and the ledger says so (AGENTS.md: nothing reduced is labelled full).

import CoreGraphics
import Foundation

extension DevicePolicy {
    /// The largest film canvas a film edge develops at, in megapixels.
    /// **A placeholder**: 12 MP is the drawings' first hardware target
    /// (design/overscan §2 and §9.1), not a measurement. The scheduler's
    /// measured number replaces it (RFC-035 §11 has 48 MP canvases at
    /// 1.4-2.0 GB after the overscan path was banded).
    var filmBudgetMegapixels: Double { 12 }
}

/// The frame's metadata, as a data back prints it.
enum ShootingLine {
    /// "1/250 s · f/5.6 · ISO 100" → 5.6; 0 when the file does not say.
    static func fNumber(_ exposure: String?) -> Double {
        guard let part = parts(exposure).first(where: { $0.lowercased().hasPrefix("f/") }) else { return 0 }
        return Double(part.dropFirst(2)) ?? 0
    }

    /// The `data` face's line, after the F6's between-frames imprint: shutter
    /// and aperture (RFC-033; no ISO, answer sheet E7). Only characters the
    /// 5 × 7 face draws: `1/250 F5.6`.
    static func dataText(_ exposure: String?) -> String {
        var fields: [String] = []
        for part in parts(exposure) {
            let lower = part.lowercased()
            if lower.hasSuffix(" s") { fields.append(String(part.dropLast(2))) }
            else if lower.hasPrefix("f/") { fields.append("F" + part.dropFirst(2)) }
        }
        return fields.joined(separator: " ")
    }

    private static func parts(_ exposure: String?) -> [String] {
        (exposure ?? "").components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The picture in the gate: a crop at the gate's shape.
///
/// **The gate replaces the photo's crop rectangle and nothing else** (the
/// owner, 2026-10-25: with a film edge or a date back "the current version
/// won't respect the changes made in crop other than cropping the image AT
/// ALL, mostly the 梯形校正 and straighten"). Until then a framing was made
/// from a blank `Geometry` with only the turns and flips copied in, so the
/// straighten and Vertical/Horizontal never reached the picture in the gate —
/// not on the page, not in the develop, not in an export — although the host
/// cut (`HostCut`) has made both since 2026-10-20. Now the photo's corrections
/// are the framing's: its perspective (the gate is cut in the corrected frame,
/// which has the source's size, `Keystone`), its straighten (the gate's shape
/// at the largest size that fits at that angle, `Geometry.straightened`), its
/// turns and flips. Only where the gate sits and how large it is are the
/// framing's own (`FilmEdgeSettings.framing`).
enum FilmFraming {
    /// The largest cut of the source at the gate's shape for a turn, about the
    /// middle, through the photo's own corrections (`corrected`) and none of
    /// its crop.
    static func largest(format: FilmEdgeFormat, turn: Int, source: CGSize, photo: Geometry) -> Geometry {
        var g = Geometry()
        g.quarterTurns = photo.quarterTurns
        g.flipH = photo.flipH
        g.flipV = photo.flipV
        g.vertical = photo.vertical
        g.horizontal = photo.horizontal
        let gate = format.gateSize(turn: turn)
        // The crop is in the source's own axes; a quarter turn swaps them.
        let seen = Double(gate.width / gate.height)
        let ratio = g.quarterTurns % 2 == 0 ? seen : 1 / seen
        let w = max(Double(source.width), 1), h = max(Double(source.height), 1)
        var cw = w, ch = w / ratio
        if ch > h { ch = h; cw = h * ratio }
        g.crop = CropRect(x: (1 - cw / w) / 2, y: (1 - ch / h) / 2, width: cw / w, height: ch / h)
        // Level, this is the largest cut, and no size was chosen: straightened,
        // it is the largest of the gate's shape that fits at the photo's angle.
        return photo.angle == 0 ? g : g.straightened(to: photo.angle, in: source)
    }

    /// A kept framing under the photo's corrections as they are now: the
    /// photo's perspective, turns and flips, and its straighten — about the
    /// framing's own centre, at its own size or the largest that still fits
    /// (`Geometry.straightened`). The framing keeps only where the gate sits
    /// and how large it is. A framing kept before 2026-10-25 was made level
    /// and uncorrected whatever the photo had, and it is read the same way.
    static func corrected(_ kept: Geometry, photo: Geometry, source: CGSize) -> Geometry {
        var g = kept
        g.vertical = photo.vertical
        g.horizontal = photo.horizontal
        g.flipH = photo.flipH
        g.flipV = photo.flipV
        // A half turn keeps the cut's shape; an odd one does not, and the
        // framing then no longer fits the gate (`resolved` takes the largest).
        g.quarterTurns = photo.quarterTurns
        return g.angle == photo.angle ? g : g.straightened(to: photo.angle, in: source)
    }

    /// Whether a framing still has the gate's shape (the engine refuses a
    /// frame more than 5 % off it).
    static func fits(_ g: Geometry, format: FilmEdgeFormat, turn: Int, source: CGSize) -> Bool {
        let out = g.outputSize(for: source)
        let gate = format.gateSize(turn: turn)
        let ratio = Double(out.width / max(out.height, 1)) / Double(gate.width / gate.height)
        return abs(ratio - 1) < 0.01
    }

    /// The framing in force: the kept one, under the photo's corrections,
    /// while it has the gate's shape; the largest cut otherwise.
    static func resolved(_ edge: FilmEdgeSettings, source: CGSize, photo: Geometry) -> Geometry {
        if let kept = edge.framing.map({ corrected($0, photo: photo, source: source) }),
           fits(kept, format: edge.format, turn: edge.turn, source: source) { return kept }
        return largest(format: edge.format, turn: edge.turn, source: source, photo: photo)
    }

    // MARK: placing the picture under the gate

    // The Frame step's hand (`FilmEdgeFlow`: `placeGesture`, `enlarged`), for Develop's crop page on the
    // Mac, where the gate stands in for the crop box (the owner, 2026-10-25: "This is handled actually by
    // the crop, only that in the crop, the crop frame is replaced by the film overscan frames"). `shown`
    // is the gate's picture box on the screen, in points.

    /// `base` moved so the picture follows a drag of `t` points, and how far the picture's edge held it
    /// back, in points, already at the third the Frame step gives it (its rubber band, `nudge`).
    static func dragged(_ base: Geometry, by t: CGSize, shown: CGRect, source: CGSize) -> (framing: Geometry, nudge: CGSize) {
        // The picture follows the finger, so the cut moves the other way.
        let n = CGPoint(x: 0.5 - t.width / max(shown.width, 1), y: 0.5 - t.height / max(shown.height, 1))
        let a = base.sourcePoint(forOutput: CGPoint(x: 0.5, y: 0.5), imageSize: source)
        let b = base.sourcePoint(forOutput: n, imageSize: source)
        let moved = base.moved(by: CGSize(width: b.x - a.x, height: b.y - a.y), in: source)
        let reached = base.outputPoint(forSource: moved.centre, imageSize: source)
        let got = CGSize(width: (0.5 - reached.x) * shown.width, height: (0.5 - reached.y) * shown.height)
        return (moved, CGSize(width: (t.width - got.width) * 0.3, height: (t.height - got.height) * 0.3))
    }

    /// `base` `m` times enlarged about `at` (screen points): the point of the picture under it stays
    /// under it. No smaller than the handles allow, no larger than the gate's largest cut; back inside
    /// the picture by sliding first, smaller only where a straighten leaves no room.
    static func enlarged(_ base: Geometry, by m: CGFloat, at: CGPoint, shown: CGRect, edge: FilmEdgeSettings,
                         source: CGSize, photo: Geometry) -> Geometry {
        let m = max(m, 0.05)
        let full = largest(format: edge.format, turn: edge.turn, source: source, photo: photo)
        let minW = Geometry.minSide / max(source.width, 1)
        let w = min(max(base.crop.width / m, minW), max(full.crop.width, minW))
        let ratio = w / max(base.crop.width, 1e-9)
        let h = base.crop.height * ratio
        let u = CGPoint(x: (at.x - shown.minX) / max(shown.width, 1), y: (at.y - shown.minY) / max(shown.height, 1))
        let under = base.sourcePoint(forOutput: u, imageSize: source)
        let c = base.centre
        let centre = CGPoint(x: under.x - (under.x - c.x) * ratio, y: under.y - (under.y - c.y) * ratio)
        var g = base
        g.crop = CropRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
        g = g.moved(by: .zero, in: source).fitted(in: source)
        g.intendedSize = CGSize(width: g.crop.width, height: g.crop.height)
        return g
    }

    /// How much the picture is enlarged in the gate: 1 is the largest cut.
    static func zoom(_ g: Geometry, format: FilmEdgeFormat, turn: Int, source: CGSize, photo: Geometry) -> Double {
        let full = largest(format: format, turn: turn, source: source, photo: photo)
        return full.crop.width / max(g.crop.width, 1e-6)
    }
}

/// One frame's film edge, ready to draw and to develop.
struct ResolvedFilmEdge: Equatable, Sendable {
    var request: FilmEdgeRequest
    var geometry: FilmGeometry
    /// The cut: the frame's picture as the engine is handed it.
    var framing: Geometry
    /// The cut on the original, before the budget.
    var cut: PixelSize
    /// The picture as it develops: the cut, scaled when the film would exceed the budget.
    var picture: PixelSize { request.frame }
    var film: PixelSize { geometry.out }
    var isScaled: Bool { picture.megapixels < cut.megapixels - 0.05 }
    var budgetMP: Double
    /// The date as the back prints it; empty when no date is drawn.
    var dateText: String
}

enum FilmEdgeResolver {
    /// The date's words for a frame: its capture date, or its shooting data.
    static func dateText(_ back: DateBackSettings, frame: LibraryFrame) -> String {
        if let custom = back.customText { return custom }
        return back.style == .data ? ShootingLine.dataText(frame.exposure)
                                   : DateBackSettings.dateText(frame.captureDate, order: back.order)
    }

    static func dateRequest(_ back: DateBackSettings, edge: FilmEdgeSettings, frame: LibraryFrame) -> DateRequest? {
        guard back.effective(filmEdge: edge) else { return nil }
        let text = dateText(back, frame: frame)
        guard !text.isEmpty else { return nil }
        // The data line beside a date face, as the wire sends it (`DateBackSettings.wire`).
        let data = back.printsDataLine(filmEdge: edge) ? ShootingLine.dataText(frame.exposure) : ""
        return DateRequest(text: text, style: back.style, placement: back.placement, corner: back.corner,
                           insetXMM: back.insetXMM, insetYMM: back.insetYMM,
                           size: back.wireSize(on: back.camera(filmEdge: edge), dataLine: !data.isEmpty), dataText: data)
    }

    /// The film edge for `frame` under `edit`, or nil while it is off.
    /// `forcing` lays it out even when the switch is off — the flow's own
    /// preview, before anything is committed.
    static func resolve(frame: LibraryFrame, edit: FrameEdit, bodySeed: Int, source: FilmGeometrySource,
                        budgetMP: Double = DevicePolicy.current.filmBudgetMegapixels,
                        forcing: Bool = false) -> ResolvedFilmEdge? {
        let edge = edit.filmEdge
        guard FeatureFlags.filmEdge, edge.active || forcing else { return nil }
        let original = CGSize(width: frame.originalSize.width, height: frame.originalSize.height)
        let framing = FilmFraming.resolved(edge, source: original, photo: edit.geometry)
        let out = framing.gateSize(for: original)
        let cut = PixelSize(width: Int(out.width), height: Int(out.height))
        let stock = StockCatalog.shared.stock(edit.params.filmStock)

        var active = edge
        active.active = true
        var request = FilmEdgeRequest(format: edge.format, mode: edge.mode, gate: edge.gate, holes: edge.holes,
                                      cameraSeed: edge.cameraSeed > 0 ? edge.cameraSeed : bodySeed,
                                      frameSeed: edit.frameSeed, frameNumber: edge.frameNumber, turn: edge.turn,
                                      frame: cut, stockID: edit.params.filmStock, edgeText: stock?.edgeText(gauge: edge.format.gauge) ?? "",
                                      fNumber: ShootingLine.fNumber(frame.exposure),
                                      date: dateRequest(edit.dateBack, edge: active, frame: frame))
        guard var geometry = source.geometry(request) else { return nil }
        // The budget scales the picture, never the film alone.
        if geometry.out.megapixels > budgetMP {
            let s = (budgetMP / geometry.out.megapixels).squareRoot()
            request.frame = PixelSize(width: max(1, Int((Double(cut.width) * s).rounded())),
                                      height: max(1, Int((Double(cut.height) * s).rounded())))
            guard let scaled = source.geometry(request) else { return nil }
            geometry = scaled
        }
        return ResolvedFilmEdge(request: request, geometry: geometry, framing: framing, cut: cut, budgetMP: budgetMP,
                                dateText: request.date?.text ?? "")
    }

    /// A date on the bare frame: its marks in the picture's millimetres. The
    /// bare frame is a 135 body's, 36 mm on its long edge.
    static func dateAlone(frame: LibraryFrame, edit: FrameEdit, source: FilmGeometrySource) -> (marks: [FilmMark], px: Double, size: PixelSize)? {
        guard !edit.filmEdge.effective, let date = dateRequest(edit.dateBack, edge: edit.filmEdge, frame: frame) else { return nil }
        let shown = frame.displaySizeUnder(edit.geometry)
        let laid = source.dateAlone(date, camera: edit.dateBack.camera(filmEdge: edit.filmEdge), frame: shown,
                                    longEdgeMM: edit.params.filmFormatMM)
        return laid.marks.isEmpty ? nil : (laid.marks, laid.px, shown)
    }
}

extension LibraryFrame {
    /// The picture's shape under a geometry that is not (yet) the frame's own.
    func displaySizeUnder(_ geometry: Geometry) -> PixelSize {
        let out = geometry.outputSize(for: CGSize(width: originalSize.width, height: originalSize.height))
        return PixelSize(width: Int(out.width), height: Int(out.height))
    }
}
