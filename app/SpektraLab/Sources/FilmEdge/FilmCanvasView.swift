//  FilmCanvasView.swift — a film drawn from its geometry.
//
//  One painter, two faces of the same `FilmGeometry`:
//
//  - **the GUIDE** (`gen_overscan.film_mask`): the virtual mask the Film and
//    Frame steps lay over the undeveloped picture — a dashed canvas, a brown
//    wash over the rebate, the gate with its family's cuts, outlined holes,
//    and the edge print ghosted where it will be exposed; the picture beyond
//    the gate dimmed, as the crop tool dims it.
//  - **the developed film, drawn**: flat ink for the edge print, flat light
//    for the date, no grain, no halation, no fog. It stands only where there
//    is no develop of the engine's to show: the drawings' own frames, a build
//    with no engine in it, a frame the queue has not reached. **A frame the
//    engine has developed shows the engine's own canvas** (`DevelopedFrameView`):
//    its film is exposure on the negative, and since 2026-10-07 the film edge
//    and the date are sent to the engine (`EngineWire.swift`).
//
//  Both read the same geometry, so the guide's holes, gate, name, numbers and
//  DX bars are where the developed film has them. Nothing here decides where
//  anything is.

import CoreImage
import SwiftUI
import UIKit

struct FilmCanvasView: View, Animatable {
    enum Style { case guide, developed }

    let geometry: FilmGeometry
    var style: Style = .developed
    /// The frame's picture, and the cut it is drawn through.
    var picture: PictureRef? = nil
    var sourceSize: CGSize = .zero
    var framing: Geometry = .default
    /// The long edge the picture is decoded for, in points.
    var pointSize: CGFloat = 393
    /// The guide's crop handles: the gate's frame, its thirds, its brackets.
    var handles = true
    /// The developed film's edge print.
    var ink: Color = Theme.edgeInk
    /// Where the caller puts the film: points per millimetre and the canvas's
    /// top-left. Nil fits the canvas in the view, centred.
    var placement: Placement? = nil
    /// The guide's gate fill when there is no picture (a format's silhouette).
    var gateFill: Color = Color(hex: 0x6F6F6C)
    /// How far the picture is carried past where its cut lets it go, in
    /// points: a drag at the end of its travel still follows the finger a
    /// little and settles back (`FilmEdgeFlow`). Animatable, so it settles.
    var nudge = CGSize.zero

    struct Placement: Equatable { var k: CGFloat; var origin: CGPoint }

    @Environment(\.displayScale) private var scale
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var image: UIImage?

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(nudge.width, nudge.height) }
        set { nudge = CGSize(width: newValue.first, height: newValue.second) }
    }

    private var maxPixel: Int? {
        let zoom = 1 / max(min(framing.crop.width, framing.crop.height), 0.1)
        return PictureLoading.maxPixel(points: pointSize, scale: scale, zoom: min(zoom, 4))
    }

    var body: some View {
        Canvas { ctx, size in
            // The picture for this size; until it has been decoded, the same
            // picture at whatever size is already here. A gate is never left
            // as flat ground while its picture is on the way (the owner, from
            // the host, 2026-10-07: "the canvas itself can be greyed out").
            let shown = picture.flatMap { p in
                image ?? (isSnapshot ? maxPixel.flatMap { ThumbnailStore.shared.load(p, maxPixel: $0) }
                                     : maxPixel.flatMap { ThumbnailStore.shared.cached(p, maxPixel: $0) } ?? ThumbnailStore.shared.cachedAny(p))
            }
            let place = placement ?? Self.fit(geometry, in: size)
            FilmPainter(geometry: geometry, style: style, image: shown, sourceSize: sourceSize, framing: framing,
                        handles: handles, ink: ink, gateFill: picture == nil ? gateFill : Theme.plot,
                        nudgeMM: CGSize(width: nudge.width / max(place.k, 0.0001), height: nudge.height / max(place.k, 0.0001)))
                .draw(&ctx, k: place.k, origin: place.origin)
        }
        .task(id: "\(String(describing: picture))-\(maxPixel ?? 0)") {
            guard !isSnapshot, let picture, let maxPixel else { return }
            // The picture shown stays until the one for this size lands.
            if let made = await PictureLoading.picture(picture, maxPixel: maxPixel) { image = made }
        }
        .accessibilityHidden(true)
    }

    /// The canvas fitted in an area, centred.
    static func fit(_ g: FilmGeometry, in size: CGSize) -> Placement {
        let mm = g.canvasMM
        let k = min(size.width / max(mm.width, 0.001), size.height / max(mm.height, 0.001))
        return Placement(k: k, origin: CGPoint(x: (size.width - mm.width * k) / 2, y: (size.height - mm.height * k) / 2))
    }
}

/// The drawing itself, in a `GraphicsContext`.
struct FilmPainter {
    let geometry: FilmGeometry
    var style: FilmCanvasView.Style
    var image: UIImage?
    var sourceSize: CGSize
    var framing: Geometry
    var handles: Bool
    var ink: Color
    var gateFill: Color
    /// The picture carried past its cut's limit, in canvas millimetres.
    var nudgeMM = CGSize.zero

    /// The developed rebate: unexposed film through the print — its black,
    /// a little warm. Nothing on the canvas is anything else: a strip scan
    /// ends at the film's long edges (the engine's `overscan_carrier` = `none`).
    static let rebatePrint = Color(hex: 0x0E0B09)
    static let holeWhite = Color(hex: 0xF6F4F0)
    static let holeBlack = Color.black
    /// The date back's light through the film: red-orange (RFC-031 §3).
    static let dateLight = Color(.sRGB, red: 1.0, green: 0.40, blue: 0.14, opacity: 1)

    func draw(_ ctx: inout GraphicsContext, k: CGFloat, origin: CGPoint) {
        let g = geometry
        let mm = g.canvasMM
        let toCanvas = g.filmToCanvas
        let canvasRect = CGRect(origin: .zero, size: mm)
        let opening = g.gateOpening.applying(toCanvas)

        var c = ctx
        c.translateBy(x: origin.x, y: origin.y)
        c.scaleBy(x: k, y: k)                               // canvas millimetres from here on
        let hair = 1 / max(k, 0.0001)                        // one point, in millimetres

        switch style {
        case .guide:
            // the picture beyond the gate, dimmed; then inside it
            if image != nil {
                var spare = c
                spare.opacity = 0.42
                drawPicture(&spare)
            }
            var inside = c
            inside.clip(to: Path(canvasRect))
            var gate = inside
            gate.clip(to: opening)
            if image != nil { drawPicture(&gate) } else { gate.fill(Path(canvasRect), with: .color(gateFill)) }
            // the rebate: unexposed film, a brown wash
            var wash = Path(canvasRect.insetBy(dx: -1, dy: -1))
            wash.addPath(opening)
            inside.fill(wash, with: .color(Theme.rebate.opacity(image != nil ? 0.8 : 1)), style: FillStyle(eoFill: true))
            let holes = g.holesPath.applying(toCanvas)
            inside.fill(holes, with: .color(Theme.text.opacity(0.16)))
            inside.stroke(holes, with: .color(Theme.secondaryText.opacity(0.75)), lineWidth: 0.8 * hair)
            let (text, polys) = Self.split(g.edge)
            inside.fill(FilmGeometry.outline(text).applying(toCanvas), with: .color(Theme.secondaryText.opacity(0.5)))
            inside.fill(FilmGeometry.outline(polys).applying(toCanvas), with: .color(Theme.secondaryText.opacity(0.4)))
            if !g.date.isEmpty {
                inside.fill(g.dateOutline.applying(toCanvas), with: .color(Self.dateLight.opacity(0.7)))
            }
            if handles { drawHandles(&inside, toCanvas: toCanvas, hair: hair) }
            c.stroke(Path(canvasRect), with: .color(Theme.secondaryText.opacity(0.55)),
                     style: StrokeStyle(lineWidth: 0.9 * hair, dash: [4 * hair, 3 * hair]))

        case .developed:
            var inside = c
            inside.clip(to: Path(canvasRect))
            // Film from edge to edge: under the corners a tilted scan carries
            // past the film's edge the engine draws the film on, so no black
            // band and no wedge of anything that is not film.
            inside.fill(Path(canvasRect), with: .color(Self.rebatePrint))
            var gate = inside
            gate.clip(to: opening)
            if image != nil { drawPicture(&gate) } else { gate.fill(Path(canvasRect), with: .color(gateFill)) }
            inside.fill(g.holesPath.applying(toCanvas),
                        with: .color(g.request.holes == .white ? Self.holeWhite : Self.holeBlack))
            inside.fill(g.edgeOutline.applying(toCanvas), with: .color(ink))
            if !g.date.isEmpty {
                var light = inside
                light.blendMode = .plusLighter
                light.fill(g.dateOutline.applying(toCanvas), with: .color(Self.dateLight))
            }
        }
    }

    /// The picture, through its cut, in the gate: upright, with the scan's
    /// residual tilt about the gate's centre.
    private func drawPicture(_ c: inout GraphicsContext) {
        guard let image, sourceSize.width > 0, sourceSize.height > 0 else { return }
        let (box, tilt, centre) = geometry.pictureBox
        let out = framing.outputSize(for: sourceSize)
        var p = c
        p.translateBy(x: nudgeMM.width, y: nudgeMM.height)
        p.translateBy(x: centre.x, y: centre.y)
        p.rotate(by: .degrees(tilt))
        p.translateBy(x: -centre.x, y: -centre.y)
        p.translateBy(x: box.minX, y: box.minY)
        p.scaleBy(x: box.width / max(out.width, 1), y: box.height / max(out.height, 1))      // the cut's pixels
        p.concatenate(framing.outputToSourceTransform(imageSize: sourceSize).inverted())     // the source's pixels
        // The cut is made in the corrected frame (`Keystone`), which no affine map reaches: the
        // picture is re-projected first, as the host's cut re-projects the decode (`HostCut`).
        let drawn = framing.hasPerspective ? Self.corrected(image, by: framing, sourceSize: sourceSize) : image
        p.draw(Image(uiImage: drawn), in: CGRect(origin: .zero, size: sourceSize))
    }

    /// A picture re-projected by a geometry's Vertical and Horizontal, at its
    /// own size: the corrected frame the framing's crop is made in. The
    /// keystone is the source's (`sourceSize`); the picture is a smaller decode
    /// of it, and a homography conjugated by a scale is the same keystone at
    /// that scale, so the four corners are scaled across. One render a picture
    /// and perspective, kept: the guide is drawn again on every drag event.
    static func corrected(_ image: UIImage, by g: Geometry, sourceSize: CGSize) -> UIImage {
        let key = "\(ObjectIdentifier(image).hashValue)|\(g.vertical)|\(g.horizontal)|\(sourceSize.width)x\(sourceSize.height)" as NSString
        // The entry holds the picture it was made of, so its address cannot be another's while it is kept.
        if let kept = correctedCache.object(forKey: key), kept.source === image { return kept.made }
        guard let cg = image.cgImage else { return image }
        let size = CGSize(width: cg.width, height: cg.height)
        let ks = g.keystone(in: sourceSize)
        let sx = size.width / max(sourceSize.width, 1), sy = size.height / max(sourceSize.height, 1)
        // Core Image's y runs upward.
        func corner(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let c = ks.corrected(CGPoint(x: x * sourceSize.width, y: y * sourceSize.height))
            return CIVector(x: c.x * sx, y: size.height - c.y * sy)
        }
        let filter = CIFilter(name: "CIPerspectiveTransform")
        filter?.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
        filter?.setValue(corner(0, 0), forKey: "inputTopLeft")
        filter?.setValue(corner(1, 0), forKey: "inputTopRight")
        filter?.setValue(corner(1, 1), forKey: "inputBottomRight")
        filter?.setValue(corner(0, 1), forKey: "inputBottomLeft")
        let frame = CGRect(origin: .zero, size: size)
        guard let made = filter?.outputImage?.cropped(to: frame).clampedToExtent().cropped(to: frame),
              let out = correctedContext.createCGImage(made, from: frame) else { return image }
        let result = UIImage(cgImage: out, scale: image.scale, orientation: .up)
        correctedCache.setObject(Corrected(source: image, made: result), forKey: key)
        return result
    }

    private final class Corrected {
        let source: UIImage, made: UIImage
        init(source: UIImage, made: UIImage) { self.source = source; self.made = made }
    }

    nonisolated(unsafe) private static let correctedCache: NSCache<NSString, Corrected> = {
        let c = NSCache<NSString, Corrected>()
        c.countLimit = 8
        return c
    }()
    nonisolated(unsafe) private static let correctedContext = CIContext()

    /// The crop tool's own marks on the gate: its frame, thirds and brackets.
    private func drawHandles(_ c: inout GraphicsContext, toCanvas: CGAffineTransform, hair: CGFloat) {
        let g = geometry
        let s0 = g.gateS0, t0 = g.gateT0, w = g.gateAlong, h = g.gateAcross
        c.stroke(Path(CGRect(x: s0, y: t0, width: w, height: h)).applying(toCanvas),
                 with: .color(Theme.text.opacity(0.85)), lineWidth: hair)
        var thirds = Path()
        for i in [1.0, 2.0] {
            thirds.move(to: CGPoint(x: s0 + w * i / 3, y: t0)); thirds.addLine(to: CGPoint(x: s0 + w * i / 3, y: t0 + h))
            thirds.move(to: CGPoint(x: s0, y: t0 + h * i / 3)); thirds.addLine(to: CGPoint(x: s0 + w, y: t0 + h * i / 3))
        }
        c.stroke(thirds.applying(toCanvas), with: .color(Theme.text.opacity(0.3)), lineWidth: 0.7 * hair)
        let b = 0.07 * min(w, h)
        var brackets = Path()
        for (cx, cy, sx, sy) in [(s0, t0, 1.0, 1.0), (s0 + w, t0, -1.0, 1.0), (s0, t0 + h, 1.0, -1.0), (s0 + w, t0 + h, -1.0, -1.0)] {
            brackets.move(to: CGPoint(x: cx, y: cy + sy * b))
            brackets.addLine(to: CGPoint(x: cx, y: cy))
            brackets.addLine(to: CGPoint(x: cx + sx * b, y: cy))
        }
        c.stroke(brackets.applying(toCanvas), with: .color(Theme.text), lineWidth: 3 * hair)
    }

    /// Text marks, and everything else: the guide ghosts them differently.
    static func split(_ marks: [FilmMark]) -> (text: [FilmMark], polys: [FilmMark]) {
        var text: [FilmMark] = [], polys: [FilmMark] = []
        for m in marks { if case .text = m { text.append(m) } else { polys.append(m) } }
        return (text, polys)
    }
}

/// A date printed on the bare frame — no film edge — over the picture.
struct DateAloneOverlay: View {
    let marks: [FilmMark]
    /// Millimetres per pixel of the picture the marks were laid out on.
    let px: Double
    let size: PixelSize

    var body: some View {
        Canvas { ctx, area in
            // picture millimetres → the view
            let k = area.width / max(CGFloat(Double(size.width) * px), 0.001)
            var c = ctx
            c.scaleBy(x: k, y: k)
            c.blendMode = .plusLighter
            c.fill(FilmGeometry.outline(marks), with: .color(FilmPainter.dateLight))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A frame as it is shown once developed: plain, with its date, or in its film.
///
/// The one view the develop page, the library's top frame and the Frame tab
/// use for a frame's picture, so a film edge looks the same everywhere and is
/// the same shape everywhere (`shownAspect`).
///
/// **A develop of the engine's is the frame as it prints** — cut by the
/// framing it was handed, in its film when the edit had one, its date exposed
/// — so it is drawn whole and nothing is drawn over it. The film and the date
/// are drawn here only where there is no such develop.
struct DevelopedFrameView: View {
    let frame: LibraryFrame
    /// The edit to show in place of the frame's own: the develop session's.
    var edit: FrameEdit? = nil
    let pointSize: CGFloat
    var showsOriginal = false
    /// A develop to show in place of the frame's kept one: the develop page's
    /// own, just landed and still in memory (`OpenFrameSession.developed`).
    var developed: DevelopedPicture? = nil
    /// The original set where the film holds the picture, in a frame the
    /// shape of the film's canvas: Compare's left half over a developed film.
    var originalInGate = false
    /// Edit's crop of the finished picture (`FrameEdit.printCrop`, 2026-10-20)
    /// drawn here: on everywhere but the develop page's canvas, which lays it
    /// over its own picture and Edit's live layer together (`DevelopCanvas`),
    /// and Edit's crop page, which shows the whole of what it cuts.
    var cropsPrint = true

    @Environment(AppServices.self) private var model

    var body: some View {
        let e = edit ?? frame.edit
        if cropsPrint, !showsOriginal, !e.printCrop.isIdentity, !frame.isPair {
            let base = Self.finishedSize(frame: frame, edit: e, model: model, developed: developed)
            GeometryPicture(geometry: e.printCrop.onFinished(base), imageSize: base) { _ in whole(e) }
        } else {
            whole(e)
        }
    }

    /// The finished picture's size, or a size of its shape: its develop's,
    /// else the drawn film's or the picture's cut (`shownAspect`).
    @MainActor
    static func finishedSize(frame: LibraryFrame, edit: FrameEdit, model: AppServices, developed: DevelopedPicture? = nil) -> CGSize {
        if let made = developed ?? frame.developed, made.size.width > 0, made.size.height > 0 {
            return CGSize(width: made.size.width, height: made.size.height)
        }
        let a = shownAspect(frame: frame, edit: edit, model: model, developed: developed, cropsPrint: false)
        return CGSize(width: 4000 * max(a, 0.01), height: 4000)
    }

    @ViewBuilder private func whole(_ e: FrameEdit) -> some View {
        // A develop whose file is gone (`DevelopedPicture.markedMissing`: Delete Previews, a catalog moved
        // without its Cache) is not drawn: the film or the camera's preview stands in until the page's own
        // develop lands. Its size still shapes the frame (`finishedSize`, `shownAspect`).
        let made = developed ?? frame.shownDevelop
        if showsOriginal {
            // The frame before the film, through the cut the develop is of.
            let cut = e.pictureGeometry(source: frame.originalSize)
            let original = FrameView(frame: frame, pointSize: pointSize, contentMode: .fit, geometry: cut, showsOriginal: true)
            if originalInGate, made != nil, let film = model.filmEdge(for: frame, edit: e) {
                GeometryReader { geo in
                    let mm = film.geometry.canvasMM
                    let k = geo.size.width / max(mm.width, 0.001)
                    let (box, tilt, centre) = film.geometry.pictureBox
                    original
                        .frame(width: box.width * k, height: box.height * k)
                        .rotationEffect(.degrees(tilt))
                        .position(x: centre.x * k, y: centre.y * k)
                }
            } else {
                original
            }
        } else if let made {
            // The frame's kept develop, with Edit's layer on it where it carries one (`Layer2Copies`);
            // a page's own develop (`developed`) is drawn as it is — the develop page lays the layer on live.
            FramePicture(picture: developed == nil ? (Layer2Copies.shared.served(frame) ?? made.picture) : made.picture,
                         pointSize: pointSize, contentMode: .fit)
        } else if let film = model.filmEdge(for: frame, edit: e) {
            FilmCanvasView(geometry: film.geometry, style: .developed, picture: frame.picture,
                           sourceSize: CGSize(width: frame.originalSize.width, height: frame.originalSize.height),
                           framing: film.framing, pointSize: pointSize,
                           ink: EdgeLook.of(e.params.filmStock).ink(on: e.filmEdge.format))
        } else {
            FrameView(frame: frame, pointSize: pointSize, contentMode: .fit, geometry: e.geometry)
                .overlay {
                    // Not over a half-frame pair's guide: a pair carries a date in each of its
                    // frames, which only its develop shows (`FrameEdit.pairWire`).
                    if !frame.isPair, let date = FilmEdgeResolver.dateAlone(frame: frame, edit: e, source: model.filmGeometry) {
                        DateAloneOverlay(marks: date.marks, px: date.px, size: date.size)
                    }
                }
        }
    }

    /// The shape the frame is shown at: its develop's own where the engine
    /// has made one — a film's canvas is the engine's to size — else the
    /// drawn film's, or the picture's cut.
    @MainActor
    static func shownAspect(frame: LibraryFrame, edit: FrameEdit, model: AppServices, showsOriginal: Bool = false,
                            developed: DevelopedPicture? = nil, cropsPrint: Bool = true) -> Double {
        // Edit's crop, of the finished picture: its cut's shape.
        if cropsPrint, !showsOriginal, !edit.printCrop.isIdentity, !frame.isPair {
            let base = finishedSize(frame: frame, edit: edit, model: model, developed: developed)
            let out = edit.printCrop.onFinished(base).outputSize(for: base)
            return Double(out.width / max(out.height, 1))
        }
        if !showsOriginal {
            if let made = developed ?? frame.developed, made.size.width > 0, made.size.height > 0 { return made.size.aspect }
            if let film = model.filmEdge(for: frame, edit: edit) { return film.film.aspect }
        }
        return frame.displaySizeUnder(edit.pictureGeometry(source: frame.originalSize)).aspect
    }
}
