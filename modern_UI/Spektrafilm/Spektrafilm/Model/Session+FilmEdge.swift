//  Session+FilmEdge.swift — what the host owes the engine for RFC-032's film
//  edge and RFC-031's date back, and what the rest of the app must do while a
//  film edge is on.
//
//  The engine takes the frame it is given as the gate (`overscan_layout`:
//  gate = frame px × pitch, pitch = the format's long edge ÷ the frame's long
//  edge). This app normally hands the engine the whole decode and cuts the
//  crop on the canvas, so with a film edge that would put the gate around the
//  uncropped photograph and then crop the film away. So while the film edge
//  is on:
//
//    decode ─ cut by the crop (here, Core Image) ─ engine ─ the film canvas
//
//  the crop is part of the negative, the print is the film canvas, and every
//  surface draws it with no geometry of its own (`canvasGeometry`). The crop
//  is held at the gate's aspect (`filmEdgeWillChange`), the crop tool frames
//  the picture over the undeveloped decode (README §4, "the GUIDE ... over
//  the undeveloped picture"), and leaving it develops the new framing.
//
//  Everything the engine cannot tell the host yet — where the gate sits in
//  the canvas — is `spk_overscan_geometry` (API-SPEC §13, proposed). Until it
//  exists the surfaces that would need it say no rather than guess: the
//  before/after split, Space's original and the white-balance picker are off
//  while the canvas shows film.

import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Metal

// MARK: - shooting data, from EXIF

/// The handful of EXIF values the imprint may print, typed (RFC-033 §4,
/// answers E7–E10). This is the one place metadata becomes pixels: the date
/// back's text and the gate's f-number. Nothing else of the EXIF dictionary
/// crosses into the engine, and a field the file does not carry is left out —
/// never invented.
struct ShootingData: Equatable, Sendable {
    struct Day: Equatable, Sendable { var year: Int, month: Int, day: Int }

    /// `DateTimeOriginal`: when the shutter fired.
    var captureDay: Day?
    var exposureTime: Double?
    var fNumber: Double?
    /// `ExposureProgram`: 1 manual, 2 program, 3 aperture priority, 4 shutter
    /// priority. The scene programs (5–8) have no letter on a data back.
    var program: Int?
    /// `ExposureBiasValue`: the camera's own compensation (answer E9). Never
    /// the Film Exposure slider, which is a development decision.
    var bias: Double?
    /// `FocalLenIn35mmFilm`: the 135 equivalent, which is what a 135 data
    /// back would print.
    var focal35: Double?

    init() {}

    init(exif: [CFString: Any]?) {
        guard let exif else { return }
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String { captureDay = Self.day(s) }
        exposureTime = Self.positive(exif[kCGImagePropertyExifExposureTime])
        fNumber = Self.positive(exif[kCGImagePropertyExifFNumber])
        program = (exif[kCGImagePropertyExifExposureProgram] as? NSNumber)?.intValue
        bias = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue
        focal35 = Self.positive(exif[kCGImagePropertyExifFocalLenIn35mmFilm])
    }

    /// EXIF's `yyyy:MM:dd HH:mm:ss`; anything else is no date.
    static func day(_ s: String) -> Day? {
        let parts = s.prefix(10).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              parts[0] > 1800 else { return nil }
        return Day(year: parts[0], month: parts[1], day: parts[2])
    }

    private static func positive(_ v: Any?) -> Double? {
        guard let d = (v as? NSNumber)?.doubleValue, d.isFinite, d > 0 else { return nil }
        return d
    }

    /// The date as the `lcd` and `dots` faces print it, or "" with no date
    /// (an empty text prints nothing).
    func dateText(order: DateBackOrder) -> String {
        guard let d = captureDay else { return "" }
        return DateBackSettings.format(year: d.year, month: d.month, day: d.day, order: order)
    }

    /// The longest line Nikon's between-frames imprint holds (RFC-033 §5):
    /// `1/250 F5.6 A +0.3 24mm` is exactly this long.
    static let dataLineMax = 22

    /// The `data` face's line, after the F6: shutter, aperture, mode,
    /// compensation, focal length. No ISO and no name line (answer E7), the
    /// real f-number (E8), the camera's compensation, omitted at zero (E9).
    /// Fields drop from the right until the line fits. Only characters the
    /// 5×7 face draws: the seconds mark is `s`, since the face has no `"`.
    var dataText: String {
        var fields: [String] = []
        if let t = exposureTime { fields.append(Self.shutter(t)) }
        if let f = fNumber { fields.append("F" + Self.trimmed(f)) }
        if let m = program.flatMap(Self.mode) { fields.append(m) }
        if let b = bias, let s = Self.compensation(b) { fields.append(s) }
        if let mm = focal35 { fields.append("\(Int(mm.rounded()))mm") }
        while fields.joined(separator: " ").count > Self.dataLineMax { fields.removeLast() }
        return fields.joined(separator: " ")
    }

    static func shutter(_ t: Double) -> String {
        if t >= 1 { return trimmed(t) + "s" }
        return "1/\(Int((1 / t).rounded()))"
    }

    static func mode(_ program: Int) -> String? {
        switch program {
        case 1: "M"
        case 2: "P"
        case 3: "A"
        case 4: "S"
        default: nil
        }
    }

    /// `+0.3`, `-1.0`; nil at zero.
    static func compensation(_ ev: Double) -> String? {
        let r = (ev * 10).rounded() / 10
        guard r != 0 else { return nil }
        return String(format: "%+.1f", r)
    }

    /// One decimal, without a trailing `.0`: `1.8`, `2`, `11`.
    static func trimmed(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

// MARK: - the film canvas, estimated

/// How big the engine's film canvas will be, before the engine is asked.
///
/// A stand-in for `spk_overscan_geometry` (API-SPEC §13, not built), from the
/// engine's own layout arithmetic (`overscan_layout`) at its widest draws, so
/// it errs large: it is for the memory forecast and the texture-limit refusal,
/// which must not under-count, and never for placing anything on the picture.
enum FilmCanvasEstimate {
    static func size(picture: CGSize, format: FilmEdgeFormat, view: FilmEdgeView) -> CGSize {
        let w = Double(picture.width), h = Double(picture.height)
        guard w > 0, h > 0 else { return .zero }
        let gate = format.gateMM
        let px = gate.long / max(w, h)                        // mm per pixel
        // The film runs along the picture axis that is not the gate's across
        // size (the engine's `vertical`).
        let acrossMM = format.gauge == "135" ? 24.0 : 56.0
        let vertical = abs(w * px - acrossMM) < abs(h * px - acrossMM) && w != h
        let alongPx = vertical ? h : w
        let marginMM: Double
        let acrossCanvasMM: Double
        switch view {
        case .strip:
            // 135 advances 38 mm for 36 (0.75–0.95 a side), half frame 19 for
            // 18 (0.40–0.50); 120's spacing is the camera's, ±0.25 per frame.
            marginMM = format == .f135Half ? 0.5 : (format.isPerforated ? 0.95 : 2.35)
            acrossCanvasMM = format.filmWidthMM
        case .filed:
            marginMM = 1.0
            acrossCanvasMM = (vertical ? w : h) * px + 2.2
        }
        let along = alongPx + 2 * (marginMM / px).rounded()
        let across = (acrossCanvasMM / px).rounded()
        return vertical ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
    }
}

/// A film edge the engine could render but the canvas could not hold: the
/// film around the picture is wider than the GPU's largest texture. Worded so
/// `EngineMessage` files it as a size refusal, with the badge that goes with
/// one, rather than as an unknown engine error.
struct FilmEdgeTooLarge: Error, CustomStringConvertible {
    let canvas: CGSize
    let limit: Int
    let format: FilmEdgeFormat
    var description: String {
        "the film edge is too large for this GPU: the \(format.rawValue) film around this picture would be "
            + "about \(Int(canvas.width)) x \(Int(canvas.height)) px, above the device's \(limit) px texture "
            + "limit — crop the picture smaller or choose a format whose film is narrower"
    }
}

// MARK: - the session's half

extension Session {
    // MARK: what the host resolves

    /// The stock's edge print, as desktop prints it: the real name (answer
    /// B16), in capitals the way the film carries it. A push is a processing
    /// choice, not another film, so `(Push 1)` is not printed.
    nonisolated static func edgeText(for stock: Stock?) -> String {
        guard let stock else { return "" }
        var name = stock.name
        if let open = name.firstIndex(of: "(") { name = String(name[..<open]) }
        return name.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// The framing key the print stamp carries while a film edge is on.
    nonisolated static func framingKey(_ g: Geometry) -> String {
        let c = g.crop
        return String(format: "%.6f,%.6f,%.6f,%.6f,%.4f,%d,%d,%d",
                      c.x, c.y, c.width, c.height, g.angle,
                      ((g.quarterTurns % 4) + 4) % 4, g.flipH ? 1 : 0, g.flipV ? 1 : 0)
    }

    /// Everything the session fills in on the frame's behalf, as a pure
    /// function of the frame, its EXIF and its stock — so resolving twice is
    /// resolving once, and an undo snapshot taken before a resolve is still a
    /// state that resolves to itself.
    nonisolated static func resolvedFilmEdge(_ p: FilmParams, geometry: Geometry,
                                             shooting: ShootingData, stock: Stock?) -> FilmParams {
        var p = p
        p.filmEdge.edgeText = edgeText(for: stock)
        p.filmEdge.fNumber = shooting.fNumber ?? 0
        p.filmEdge.framing = framingKey(geometry)
        p.dateBack.framing = geometry.isIdentity ? "" : framingKey(geometry)
        p.dateBack.text = p.dateBack.face == .data
            ? shooting.dataText : shooting.dateText(order: p.dateBack.order)
        return p
    }

    /// `resolvedFilmEdge`, plus the date back's camera from Film Format.
    func resolved(_ p: FilmParams) -> FilmParams {
        var r = Self.resolvedFilmEdge(p, geometry: sidecar.geometry, shooting: shootingData,
                                      stock: catalog.stock(p.filmStock))
        if !r.filmEdge.effective {
            let long = r.filmFormatMM, short = long / max(physicalAspect, 1)
            r.dateBack.camera = Self.dateBackCamera(longMM: long, shortMM: short)
        } else {
            r.dateBack.camera = r.filmEdge.format
        }
        if let frame = nativeSourceSize, frame.width > 0, frame.height > 0 {
            let cut = sidecar.geometry.outputSize(for: frame)
            r.dateBack.frameScale = max(cut.width, cut.height) / max(frame.width, frame.height)
        }
        return r
    }

    /// A new frame's own frame seed: stable for the file (the first one it is
    /// given is stored with the edit and never re-derived), distinct between
    /// files.
    nonisolated static func frameSeed(for url: URL) -> Int {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let v = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Int(v & 0x7FFF_FFFF)
    }

    /// The shooting data of the frame on screen.
    var shootingData: ShootingData { exif?.shooting ?? ShootingData() }

    /// Write what the host owes the engine into the frame's settings. No undo
    /// step: this is derived state, and it is the same for every snapshot.
    func resolveFilmEdge() {
        holdFilmEdgeCrop()
        let resolved = resolved(sidecar.params)
        if resolved != sidecar.params { sidecar.params = resolved }
    }

    /// With a film edge on, the crop is the gate's shape: the `params` setter
    /// sees to that. A sidecar from elsewhere — hand-written, or from a build
    /// that did not hold it — can carry a film edge over a crop of another
    /// shape, which the engine refuses by name. It is held here, before the
    /// develop, and the crop it had is kept to give back as usual.
    func holdFilmEdgeCrop() {
        let p = sidecar.params
        guard p.filmEdge.effective, let size = nativeSourceSize, size.width > 0, size.height > 0 else { return }
        let g = sidecar.geometry
        let pw = g.crop.width * size.width, ph = g.crop.height * size.height
        guard pw > 0, ph > 0 else { return }
        let wanted = Self.gateRatio(p.filmEdge.format, landscape: pw >= ph)
        if abs((pw / ph) / wanted - 1) <= 0.02, g.lockedRatio == wanted { return }
        if sidecar.heldCrop == nil { sidecar.heldCrop = g }
        sidecar.geometry = Self.gateFramed(g, format: p.filmEdge.format, imageSize: size)
    }

    /// Give a frame its seeds the first time it is opened: a frame seed of its
    /// own, and the user's body (`FilmEdgeSettings.bodySeed`).
    func seedFilmEdge(for url: URL, defaults: UserDefaults = .standard) {
        guard !sidecar.params.filmEdge.seeded else { return }
        sidecar.params.filmEdge.frameSeed = Self.frameSeed(for: url)
        sidecar.params.filmEdge.cameraSeed = FilmEdgeSettings.bodySeed(in: defaults)
        sidecar.params.filmEdge.seeded = true
    }

    /// Whether the stock in use was made on the film `format` runs on
    /// (answer D3). The Format menu greys the rest.
    func filmStockIsMade(in format: FilmEdgeFormat) -> Bool {
        catalog.isMade(params.filmStock, in: format)
    }

    // MARK: the crop, held by the gate

    /// The gate's ratio for a crop of this orientation: width ÷ height of the
    /// crop rectangle in source pixels. A landscape crop gets the gate on its
    /// side, a portrait one gets it upright; either is the format (a portrait
    /// 135 runs the film down the picture).
    nonisolated static func gateRatio(_ format: FilmEdgeFormat, landscape: Bool) -> Double {
        let g = format.gateMM
        return landscape ? g.long / g.short : g.short / g.long
    }

    /// `g` reshaped to the gate's aspect, about its centre, in the crop's
    /// current orientation, and held there (`Geometry.lockedRatio`).
    nonisolated static func gateFramed(_ g: Geometry, format: FilmEdgeFormat,
                                       imageSize: CGSize) -> Geometry {
        guard imageSize.width > 0, imageSize.height > 0 else { return g }
        let pw = g.crop.width * imageSize.width, ph = g.crop.height * imageSize.height
        var framed = g
        framed.lockedRatio = gateRatio(format, landscape: pw >= ph)
        return framed.constrained(in: imageSize)
    }

    /// Called by the `params` setter before a change lands: switching the film
    /// edge on takes the crop into the gate and keeps the user's own, switching
    /// it off gives it back, and a new format reshapes the framing. The body
    /// the user picks becomes their body for new frames.
    func filmEdgeWillChange(from old: FilmParams, to new: FilmParams) {
        if new.filmEdge.cameraSeed != old.filmEdge.cameraSeed {
            FilmEdgeSettings.setBodySeed(new.filmEdge.cameraSeed, in: .standard)
        }
        let was = old.filmEdge.effective, now = new.filmEdge.effective
        let size = sourceImageSize
        if !was && now {
            sidecar.heldCrop = sidecar.geometry
            sidecar.geometry = Self.gateFramed(sidecar.geometry, format: new.filmEdge.format, imageSize: size)
        } else if was && !now {
            sidecar.geometry = sidecar.heldCrop ?? Self.unheld(sidecar.geometry)
            sidecar.heldCrop = nil
        } else if now && new.filmEdge.format != old.filmEdge.format {
            sidecar.geometry = Self.gateFramed(sidecar.geometry, format: new.filmEdge.format, imageSize: size)
        }
    }

    /// The crop with no gate holding it.
    nonisolated static func unheld(_ g: Geometry) -> Geometry {
        var g = g
        g.lockedRatio = nil
        return g
    }

    /// The other orientation of the gate — portrait for landscape — without
    /// turning the picture: the Framing row's ↔. A no-op with no film edge.
    func flipFilmEdgeGate() {
        guard params.filmEdge.effective else { return }
        var g = geometry
        let landscape = (g.lockedRatio ?? 1) >= 1
        g.lockedRatio = Self.gateRatio(params.filmEdge.format, landscape: !landscape)
        geometry = g.constrained(in: sourceImageSize)
    }

    // MARK: what the canvas draws

    /// True while the canvas shows the engine's own cut of the picture rather
    /// than the photograph with the crop applied on top: a film edge, or the
    /// date alone under a crop, a turn or a flip (`FilmParams.cutsFrame`),
    /// while the crop tool is not framing it.
    var filmEdgeShowsFilm: Bool { params.cutsFrame && tool != .crop }

    /// True while the crop tool frames a picture the engine is handed cut.
    var filmEdgeFraming: Bool { params.cutsFrame && tool == .crop }

    /// True when a change of geometry is a change of the negative: the frame
    /// is cut before the engine, or would be once the geometry is not the
    /// identity (the date alone).
    var geometryIsInTheNegative: Bool {
        params.filmEdge.effective || params.dateBack.effective(filmEdge: params.filmEdge)
    }

    /// The geometry the canvas, the thumbnails and the export apply to the
    /// print: none while it is the film canvas (the crop is already in it).
    var canvasGeometry: Geometry { filmEdgeShowsFilm ? .default : geometry }

    /// The geometry an exported print takes: the film canvas is already cut.
    var printGeometry: Geometry { params.cutsFrame ? .default : geometry }

    /// The crop the engine's frame is cut with, or nil for the whole decode.
    var filmEdgeCut: Geometry? { params.cutsFrame ? geometry : nil }

    /// The framing key the engine's frame must have been cut with for the
    /// session it holds to still be this frame (nil: the whole decode).
    var wantedEngineFraming: String? {
        params.engineFramingKey
    }

    /// The linear decode as the engine is to take it: whole, or cut by the
    /// crop with a film edge on. Through the same arithmetic the canvas
    /// samples with (`Geometry.outputToSourceTransform`), in Core Image's
    /// bottom-left space; clamped first, so a straightened crop's resampling
    /// at the edge never reaches transparent pixels.
    nonisolated static func engineImage(_ linear: CIImage, size: CGSize, cut: Geometry?) -> CIImage {
        guard let g = cut, !g.isIdentity, size.width > 0, size.height > 0 else { return linear }
        let out = g.outputSize(for: size)
        let toSource = g.outputToSourceTransform(imageSize: size)        // top-left pixels
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: out.height)
        let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        // CI output point -> top-left output -> top-left source -> CI source.
        let outputToSourceCI = flipOut.concatenating(toSource).concatenating(flipSource)
        let origin = linear.extent.origin
        let placed = linear.transformed(by: .init(translationX: -origin.x, y: -origin.y))
        return placed.clampedToExtent()
            .transformed(by: outputToSourceCI.inverted())
            .cropped(to: CGRect(origin: .zero, size: out))
    }

    /// The picture the engine is handed for this frame, in pixels.
    func enginePictureSize(_ decodedSize: CGSize) -> CGSize {
        guard let g = filmEdgeCut else { return decodedSize }
        return g.outputSize(for: decodedSize)
    }

    /// The film canvas at the frame's own resolution, from a print of any
    /// tier: the engine renders the picture at `min(preview, picture)` on the
    /// live tier and the film around it, so the native canvas is the print
    /// scaled by the picture's own long edge over that. What the viewport is
    /// expressed against while the canvas shows film (D4). `frame` is the
    /// decode's own size, nil before it is known — the print is then its own
    /// measure, as any print is before its decode lands.
    func filmCanvasLogicalSize(for print: MTLTexture, frame: CGSize?) -> CGSize {
        let tex = CGSize(width: print.width, height: print.height)
        guard let frame else { return tex }
        let picture = enginePictureSize(frame)
        let pictureLong = max(picture.width, picture.height)
        guard pictureLong > 0 else { return tex }
        let k = pictureLong / min(CGFloat(previewLongEdge), pictureLong)
        return CGSize(width: (tex.width * k).rounded(), height: (tex.height * k).rounded())
    }

    /// The size the viewport is expressed against for a print made from `p`:
    /// the frame's own pixels, or the film canvas.
    func printLogicalSize(for print: MTLTexture, params p: FilmParams, frame: CGSize?) -> CGSize? {
        p.cutsFrame ? filmCanvasLogicalSize(for: print, frame: frame) : frame
    }

    /// The print's own pixels, as a file of it would be: the crop at the
    /// frame's resolution, or — with a film edge — the film canvas (the
    /// native render's when it has landed, else the estimate from the live
    /// print). For naming and captions; the export measures its own texture.
    var printPixelSize: CGSize {
        if params.cutsFrame {
            if let full = renderer.fullRender { return CGSize(width: full.width, height: full.height) }
            if let live = renderer.live { return filmCanvasLogicalSize(for: live, frame: nativeSourceSize) }
        }
        let size = sourceImageSize
        guard size.width > 0 else { return .zero }
        let out = geometry.outputSize(for: size)
        let scale = sourceLongEdge > 0 ? sourceLongEdge / max(size.width, size.height) : 1
        return CGSize(width: (out.width * scale).rounded(), height: (out.height * scale).rounded())
    }

    // MARK: the date back's camera

    /// Which camera prints the date when there is no film edge: the one the
    /// right rail's Film Format describes (drawing 4, "Camera: 135, from Film
    /// Format"). Only where that is unambiguous — a 36 × 24 frame is 135, a
    /// 24 × 18 one half frame, a 56 × 41.5 one 645 — and nil otherwise, since
    /// the engine draws a date on nothing else. Long edge ± 1 mm, short ± 1.
    nonisolated static func dateBackCamera(longMM: Double, shortMM: Double) -> FilmEdgeFormat? {
        let candidates: [FilmEdgeFormat] = [.f135, .f135Half, .f645]
        return candidates.first {
            abs($0.gateMM.long - longMM) <= 1 && abs($0.gateMM.short - shortMM) <= 1
        }
    }

    /// The Film Format frame, both sides, in millimetres: the wire's long
    /// edge and the photograph's aspect (`physicalAspect`).
    var filmFormatSidesMM: (long: Double, short: Double) {
        let long = params.filmFormatMM
        return (long, long / max(physicalAspect, 1))
    }

    /// The camera the date back is on: the film edge's format while it is
    /// on, Film Format's otherwise.
    var dateBackCamera: FilmEdgeFormat? {
        if params.filmEdge.effective { return params.filmEdge.format }
        let sides = filmFormatSidesMM
        return Self.dateBackCamera(longMM: sides.long, shortMM: sides.short)
    }

    // MARK: memory and size

    /// The pixels a develop of this frame will hold: the film canvas when a
    /// film edge is on, which is up to ~1.5× the picture (README §2).
    func developForecastPixels(_ decodedSize: CGSize) -> Int {
        let picture = enginePictureSize(decodedSize)
        let edge = params.filmEdge
        guard edge.effective else { return Int(picture.width * picture.height) }
        let canvas = FilmCanvasEstimate.size(picture: picture, format: edge.format, view: edge.view)
        return Int(canvas.width * canvas.height)
    }

    /// Nil, or why this frame's film cannot be rendered whole-frame here: the
    /// striped executor refuses overscan (API-SPEC §13), so the whole canvas
    /// must be one texture.
    func filmEdgeRefusal(_ decodedSize: CGSize) -> FilmEdgeTooLarge? {
        let edge = params.filmEdge
        guard edge.effective, let limit = maxTextureEdge else { return nil }
        let canvas = FilmCanvasEstimate.size(picture: enginePictureSize(decodedSize),
                                             format: edge.format, view: edge.view)
        guard max(canvas.width, canvas.height) > CGFloat(limit) else { return nil }
        return FilmEdgeTooLarge(canvas: canvas, limit: limit, format: edge.format)
    }
}
