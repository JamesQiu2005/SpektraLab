//  DevelopCanvas.swift — the develop page's picture: fitted, zoomed, dragged, compared.
//
//  The owner, 2026-10-04: "snap and zoom should be enabled, unlike the
//  current fixed canvas and scale", and a Compare "working the same way as
//  the desktop version". So this is the desktop's canvas, on a finger
//  (`Canvas/ViewportState.swift`, `Canvas/CompareOverlay.swift` in the
//  desktop app):
//
//  - **Fit** is home: the picture fitted in the area, centred. A pinch zooms
//    about the fingers, up to 100 % of the preview copy's pixels or 3×,
//    whichever is more; a drag pans once there is more picture than area.
//  - **One clamp** (the desktop's): along an axis where the picture is
//    smaller than the area it is centred; where it is larger, its edges stay
//    outside. A gesture may overshoot; when it lifts the picture settles back.
//  - **A double tap** goes between fit and 100 %, about the tap.
//  - **Compare** is the desktop's split: the original to the left of a line,
//    the develop to the right, the line anchored to the picture — drag the
//    picture and it goes with it, so the comparison stays on the same eye.
//    The grip, or the line itself, takes the drag; the rest of the picture
//    still pans.
//
//  The picture is decoded for the size it is shown at, in steps of two, and
//  never past the preview copy's own pixels (`ThumbnailStore` decodes at the
//  size asked, no larger).
//
//  **Past the preview, the original's own pixels** (2026-10-20: the owner, "the
//  RAW preview, when zoomed in can really show the original resolution"). 100 %
//  is now one of the original's pixels to one of the screen's, and the zoom
//  goes that far; past the preview's own pixels the frame's render at full size
//  is asked for (`FullView`, an export's at Full, through the scheduler) and the
//  part on screen is laid over the preview at the screen's pixels — read and
//  made only when the picture rests (`detailKey`), never during a gesture.
//
//  **With Edit's Light, Curve or Colour on the frame** (Layer 2, design/v5 §2)
//  the develop is drawn through the page's own pass (`Layer2Picture`, over the
//  session's `layer2`), at the same size, in the same place: zoom, pan, the
//  compare split and the original are this page's as before, and the
//  original is the frame before the film, unedited. A frame with no edit
//  draws exactly as it did.

import SwiftUI

struct DevelopCanvas: View {
    let frame: LibraryFrame
    let edit: FrameEdit
    /// The frame as decoded, before the film, over the whole picture.
    var showsOriginal = false
    /// The split: original left, develop right, with the line at `split`.
    var comparing = false
    @Binding var split: Double
    /// Where the canvas opens, as a multiple of fit (the snapshot harness).
    var initialZoom: CGFloat = 1
    /// The page's own develop, just landed: shown in place of the frame's kept one.
    var developed: DevelopedPicture? = nil
    /// The develop under way, 0…1: the bar on the picture's bottom edge. Nil hides it.
    var progress: Double? = nil
    /// A half-frame pair: its frames on the picture, the picked layer's white
    /// frame, and what a touch picks. Nil for a photograph.
    var piece: PieceMarks? = nil

    /// V5 momentary source preview. Legacy split fixtures remain unchanged.
    var allowsOriginalHold = false
    /// A library photo in the pager: told whether a swipe may turn the page
    /// now — fitted, and no pinch under way. The pager owns that swipe; this
    /// canvas then leaves a fitted drag alone and pans only once zoomed.
    var onPageable: ((Bool) -> Void)? = nil
    /// The zoom stops at one of the preview copy's pixels to one of the screen's, and goes no
    /// further: a canvas with no page's full render to show past it (the window's Export proof,
    /// `ExportProof`), which would only draw the preview larger than it was made. The double
    /// tap goes between fit and that; where the preview has no more pixels than the fit, the
    /// picture stays fitted.
    var stopsAtPreviewPixels = false
    @GestureState private var holdingOriginal = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var sourceReady = false
    @State private var sourceLoading = true
    @State private var pairOriginal: UIImage?
    @State private var holdCancelled = false
    private var requestsOriginal: Bool {
        showsOriginal || (allowsOriginalHold && holdingOriginal && !holdCancelled && pinchBase == nil && dragBase == nil && scenePhase == .active)
    }
    private var displaysOriginal: Bool { requestsOriginal && (!allowsOriginalHold || sourceReady) }

    @Environment(AppServices.self) private var model
    @Environment(\.gamutProof) private var gamutProof
    @Environment(\.displayScale) private var displayScale
    /// The screen's pixels to one of this page's points. The window's: `displayScale`. **The Mac's
    /// (Catalyst, "scaled Catalyst mode") is 77 % of it**: UIKit draws a 1,330-point window at 2x
    /// (2,660 px) and the Mac shows it in 1,024 points at 2x (2,048 px) — measured 2026-10-23,
    /// `displayScale` 2.00, the window 1,024 Mac points wide. Read as 2, the canvas took itself
    /// for 1.3x the pixels it has: the full-size render was asked for at any zoom past fit even
    /// where the preview still had pixels to spare, its part on screen was made at 1.69x the
    /// pixels shown, and 100 % was 130 %. PAGES.md, render-parity.
    private var pixelsPerPoint: CGFloat {
        return UIDevice.current.userInterfaceIdiom == .pad ? displayScale * 0.77 : displayScale
    }

    @State private var zoom: CGFloat
    @State private var offset = CGSize.zero
    /// The zoom the picture is decoded for: steps of two, set when a gesture lifts.
    @State private var decodeZoom: CGFloat
    @State private var pinchBase: (zoom: CGFloat, offset: CGSize)?
    /// The Mac scroll's travel dropped past the zoom band's stops (`CanvasZoom.heldTravel`).
    @State private var scrollOrigin: CGFloat = 0
    @GestureState private var pinchIsActive = false
    /// The offset when the drag took over, and the finger's travel at that
    /// moment: a finger left down after a pinch has travelled already.
    @State private var dragBase: (offset: CGSize, translation: CGSize)?
    private enum DragOwner { case page, picture }
    @State private var dragOwner: DragOwner?
    @GestureState private var dragIsActive = false

    init(frame: LibraryFrame, edit: FrameEdit, showsOriginal: Bool = false, comparing: Bool = false,
         split: Binding<Double>, initialZoom: CGFloat = 1, developed: DevelopedPicture? = nil, progress: Double? = nil,
         piece: PieceMarks? = nil, allowsOriginalHold: Bool = false, onPageable: ((Bool) -> Void)? = nil,
         stopsAtPreviewPixels: Bool = false) {
        self.onPageable = onPageable
        self.stopsAtPreviewPixels = stopsAtPreviewPixels
        self.allowsOriginalHold = allowsOriginalHold
        self.piece = piece
        self.frame = frame
        self.edit = edit
        self.showsOriginal = showsOriginal
        self.comparing = comparing
        _split = split
        self.initialZoom = initialZoom
        self.developed = developed
        self.progress = progress
        _zoom = State(initialValue: initialZoom)
        _decodeZoom = State(initialValue: Self.decodeStep(initialZoom))
    }

    /// Something to compare the develop with: the demo frame's undeveloped
    /// scene, or — once the engine has developed a frame — the frame's own
    /// picture before the film.
    private var hasOriginal: Bool { frame.originalPicture != nil || developed != nil || frame.developed != nil }
    private var showsSplit: Bool { comparing && hasOriginal && (!allowsOriginalHold || sourceReady) }

    var body: some View {
        // The canvas in the space the person chose to judge it in (`CanvasGamut`, the "···" menu).
        canvas.environment(\.gamutProof, model.settings.canvasGamut)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let area = geo.size
            let fit = fitSize(in: area)
            let hundred = hundredZoom(fit: fit)
            let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
            let centre = CGPoint(x: area.width / 2 + offset.width, y: area.height / 2 + offset.height)
            let shown = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                               width: size.width, height: size.height)
            ZStack {
                Theme.background
                printCropped(size: size, pointSize: max(fit.width, fit.height) * min(decodeZoom, decodeCap(fit: fit)))
                    .frame(width: size.width, height: size.height)
                    .position(centre)
            }
            .frame(width: area.width, height: area.height)
            .clipped()
            .contentShape(Rectangle())
            // Mac: the wheel and the trackpad's two-finger scroll zoom about the pointer (Sources/Mac/MacScrollZoom.swift).
            .macScrollZoom { phase, dy, at in scrollZoom(phase, travel: dy, at: at, fit: fit, area: area, hundred: hundred) }
            .background {
                if MacShellPath.develop(model.router.path) != nil {
                    let free = MacShellPath.split(model.router.path).stacked.isEmpty && model.router.cover == nil
                        && model.router.sheets.isEmpty && model.router.inlineCrop == nil && !MacLibraryBrowser.shared.modal
                    MacShortcutButton(.fit, enabled: free) { changeZoom(to: 1, fit: fit, area: area, hundred: hundred) }
                    MacShortcutButton(.actualSize, enabled: free) { changeZoom(to: hundred, fit: fit, area: area, hundred: hundred) }
                    MacShortcutButton(.zoomIn, enabled: free) { changeZoom(to: zoom * 1.5, fit: fit, area: area, hundred: hundred) }
                    MacShortcutButton(.zoomOut, enabled: free) { changeZoom(to: zoom / 1.5, fit: fit, area: area, hundred: hundred) }
                }
            }
            .gesture(doubleTap(area: area, fit: fit, hundred: hundred))
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: MacDriver.zoomHundred)) { note in
                changeZoom(to: (note.object as? Bool) == true ? hundred : 1, fit: fit, area: area, hundred: hundred)
            }
            #endif
            .simultaneousGesture(drag(area: area, fit: fit))
            .simultaneousGesture(pinch(area: area, fit: fit, hundred: hundred))
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holdingOriginal) { value, holding, _ in
                        guard allowsOriginalHold, hasOriginal, !showsSplit else { return }
                        if case .second(true, let drag) = value {
                            holding = drag.map { abs($0.translation.width) < 8 && abs($0.translation.height) < 8 } ?? true
                        }
                    }
            )
            .overlay(alignment: .topLeading) {
                if displaysOriginal || (requestsOriginal && allowsOriginalHold) {
                    Text(displaysOriginal ? L("Original", as: "the picture") : (sourceLoading ? L("Loading original") : L("Original unavailable")))
                        .font(Theme.Font.ui(12, .medium)).padding(8)
                        // White on the dark capsule whatever the appearance (Light Mode, the Mac's and window's).
                        .foregroundStyle(Color.white)
                        .background(.black.opacity(0.7), in: Capsule()).padding(8)
                        .allowsHitTesting(false)
                }
            }
            // A half-frame pair: a touch on a frame of the piece picks it, a touch on
            // the film picks the film (the desktop's click on its canvas). At once, and
            // beside the double tap: a frame tapped twice is picked, then looked at closer.
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard let piece, !showsSplit, shown.width > 1, shown.height > 1 else { return }
                let n = CGPoint(x: (tap.location.x - shown.minX) / shown.width, y: (tap.location.y - shown.minY) / shown.height)
                piece.pick(piece.layer(at: n))
            })
            .overlay {
                if let piece, !showsSplit { PieceFrame(marks: piece, picture: shown).allowsHitTesting(false) }
            }
            .overlay {
                if showsSplit {
                    CompareLine(picture: shown, area: area, split: $split)
                }
            }
            // `picture()`: the develop bar is on the picture's bottom edge and
            // as wide as the picture — a 3:2 frame's, or an upright one's, not
            // the room's. Zoomed past the room, that is the room's own edge.
            .overlay(alignment: .topLeading) {
                let x0 = max(shown.minX, 0), x1 = min(shown.maxX, area.width)
                DevelopProgressBar(progress: progress)
                    .frame(width: max(x1 - x0, 0))
                    .offset(x: x0, y: min(shown.maxY, area.height) - 2)
                    .allowsHitTesting(false)
            }
            // The area changed under the picture (the panel folded), or its
            // shape did (Original, a crop, a film edge on or off): what was
            // fitted stays fitted, what was zoomed stays inside.
            .onChange(of: area) { _, now in
                let f = fitSize(in: now)
                withAnimation(.easeOut(duration: 0.2)) { offset = clamped(offset, zoom: zoom, fit: f, area: now) }
            }
            #if DEBUG
            .onAppear {
                let long = CGFloat(max(frame.previewSize.width, frame.previewSize.height)), fitLong = max(fit.width, fit.height)
                NSLog("[canvas] fit %.0fx%.0f pt, %.2f px/pt (UIKit says %.2f): preview %.0f px, the full render past %.2fx (read at UIKit's scale: %.2fx)",
                      fit.width, fit.height, pixelsPerPoint, displayScale, long,
                      max(previewOverFit(fit: fit), 1) * 1.02, max(long / max(fitLong * displayScale * cropZoom, 1), 1) * 1.02)
            }
            #endif
            .onChange(of: fit) { _, now in
                withAnimation(.easeOut(duration: 0.2)) { offset = clamped(offset, zoom: zoom, fit: now, area: area) }
            }
            .onChange(of: pinchIsActive) { _, active in
                // GestureState resets on cancellation too; onEnded does not.
                guard !active, pinchBase != nil else { return }
                pinchBase = nil
                dragBase = nil
                settle(fit: fit, area: area, hundred: hundred)
            }
            .onChange(of: zoom <= 1.001 && pinchBase == nil, initial: true) { _, fitted in
                onPageable?(fitted)
            }
            .onChange(of: dragIsActive) { _, active in
                guard !active, dragOwner != nil else { return }
                dragOwner = nil
                dragBase = nil
                settle(fit: fit, area: area, hundred: hundred)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                dragOwner = nil
                pinchBase = nil
                dragBase = nil
                settle(fit: fit, area: area, hundred: hundred)
            }
            #if SPK_ENGINE
            // Past the preview's pixels: the render at full size, the part on screen of it.
            .task(id: DetailKey(zoom: zoom, offset: offset, area: area, adjustments: edit.adjustments,
                                ready: fullView?.state == .ready, moving: pinchBase != nil || dragBase != nil,
                                showsOriginal: displaysOriginal)) {
                guard let fullView, pinchBase == nil, dragBase == nil else { return }
                guard !displaysOriginal, zoom > max(previewOverFit(fit: fit), 1) * 1.02 else { fullView.unwant(); return }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                fullView.want()
                if let ask = detailAsk(area: area, fit: fit) { fullView.show(ask) }
            }
            .overlay(alignment: .topLeading) {
                if let words = fullSizeWords {
                    Text(words)
                        .font(Theme.Font.ui(12, .medium)).padding(8)
                        // White on the dark capsule whatever the appearance (Light Mode, the Mac's and window's).
                        .foregroundStyle(Color.white)
                        .background(.black.opacity(0.7), in: Capsule()).padding(8)
                        .allowsHitTesting(false)
                }
            }
            #endif
            .accessibilityAction(named: L("Zoom in")) {
                changeZoom(to: zoom * 2, fit: fit, area: area, hundred: hundred)
            }
            .accessibilityAction(named: L("Fit picture")) {
                changeZoom(to: 1, fit: fit, area: area, hundred: hundred)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displaysOriginal ? L("The original, as decoded")
                            : (showsSplit ? L("Original and developed, split") : L("The developed picture")))
        .accessibilityValue(zoomText)
        .task(id: originalKey) {
            guard allowsOriginalHold else { return }
            sourceReady = false; sourceLoading = true
            if let pair = frame.pair {
                pairOriginal = nil
                let made = await PairOriginalPreview.make(pair: pair, frames: model.darkroom.held(by: pair),
                                     rects: piece?.rects, aspect: aspect)
                guard !Task.isCancelled else { return }
                pairOriginal = made; sourceReady = made != nil; sourceLoading = false
                #if DEBUG
                PairOriginalPreview.onCanvasReady?(frame.id, made)
                #endif
                return
            }
            let image = await PictureLoading.picture(frame.originalPicture ?? frame.picture, maxPixel: 1600)
            guard !Task.isCancelled else { return }
            sourceReady = image != nil; sourceLoading = false
        }
        .onChange(of: holdingOriginal) { _, active in if !active { holdCancelled = false } }
        .onChange(of: pinchBase != nil) { _, active in if active { holdCancelled = true } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { holdCancelled = true } }
    }

    // MARK: the picture

    private var originalKey: String {
        if let pair = frame.pair {
            return frame.id.uuidString + PairOriginalPreview.key(pair: pair, frames: model.darkroom.held(by: pair),
                                                                 rects: piece?.rects, aspect: aspect)
        }
        return "\(frame.id)-\(frame.originalPicture ?? frame.picture)"
    }

    @ViewBuilder private func originalPicture(pointSize: CGFloat) -> some View {
        if frame.isPair, allowsOriginalHold, let pairOriginal {
            Image(uiImage: pairOriginal).resizable().scaledToFit()
        } else {
            DevelopedFrameView(frame: frame, edit: edit, pointSize: pointSize, showsOriginal: true,
                               developed: developed, originalInGate: allowsOriginalHold || showsSplit, cropsPrint: false)
        }
    }

    /// Edit's crop of the finished picture (2026-10-20), laid over everything
    /// the canvas draws — the develop, Edit's live layer on it, the original
    /// in its gate and Compare's split — so they are cut alike. Nothing is
    /// rendered for it: the whole picture is drawn larger, through the cut.
    @ViewBuilder private func printCropped(size: CGSize, pointSize: CGFloat) -> some View {
        if showsSplit {
            // Each half cut alike, then split on the cut picture's own width.
            ZStack {
                cut(size: size, pointSize: pointSize) { developedPicture(pointSize: $0) }
                cut(size: size, pointSize: pointSize) { originalPicture(pointSize: $0) }
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, size.width * CGFloat(split)))
                    }
            }
        } else if displaysOriginal {
            cut(size: size, pointSize: pointSize) { originalPicture(pointSize: $0) }
        } else {
            cut(size: size, pointSize: pointSize) { developedPicture(pointSize: $0) }
        }
    }

    /// One of the canvas's pictures through Edit's crop, where it has one.
    @ViewBuilder private func cut<V: View>(size: CGSize, pointSize: CGFloat,
                                           @ViewBuilder _ content: @escaping (CGFloat) -> V) -> some View {
        if frame.isPair || edit.printCrop.isIdentity || (!allowsOriginalHold && showsOriginal && !showsSplit) {
            content(pointSize)
        } else {
            let base = DevelopedFrameView.finishedSize(frame: frame, edit: edit, model: model, developed: developed)
            GeometryPicture(geometry: edit.printCrop.onFinished(base), imageSize: base) { points in
                // The decode keeps the canvas's own ratio of pixels to points.
                content(points * pointSize / max(size.width, size.height, 1))
            }
        }
    }

    /// The develop, and over it, where the frame carries Edit's layer, the
    /// develop with the layer on it — the page's pass, at the size drawn.
    @ViewBuilder private func developedPicture(pointSize: CGFloat) -> some View {
        let base = DevelopedFrameView(frame: frame, edit: edit, pointSize: pointSize, developed: developed, cropsPrint: false)
        Group {
            if edit.adjustments.isActive, let live = model.openSession(frame.id)?.layer2, live.picture != nil {
                Layer2Picture(live: live, pointSize: pointSize) { base }
            } else {
                base
            }
        }
        #if SPK_ENGINE
        .overlay {
            // The part on screen of the render at full size, where it is of the edit as it stands.
            if let d = fullView?.detail, d.adjustments == edit.adjustments, zoom > 1.01 {
                GeometryReader { g in
                    Image(decorative: GamutProof.shared.proofed(d.image, gamutProof), scale: 1)
                        .resizable()
                        .frame(width: d.rect.width * g.size.width, height: d.rect.height * g.size.height)
                        .position(x: d.rect.midX * g.size.width, y: d.rect.midY * g.size.height)
                }
                .allowsHitTesting(false)
            }
        }
        #endif
    }

    #if SPK_ENGINE
    /// The page's full render, where a page holds this frame (`OpenFrameSession.fullView`).
    private var fullView: FullView? { allowsOriginalHold || onPageable != nil ? model.openSession(frame.id)?.fullView : nil }

    /// What the full render's detail is made again for, once the picture rests.
    private struct DetailKey: Equatable {
        var zoom: CGFloat
        var offset: CGSize
        var area: CGSize
        var adjustments: Adjustments
        var ready: Bool
        var moving: Bool
        var showsOriginal: Bool
    }

    /// The label over the picture while the zoom waits on the full render.
    private var fullSizeWords: String? {
        guard let fullView, !displaysOriginal, zoom > 1.01 else { return nil }
        switch fullView.state {
        case .rendering(let f):
            let done = "\(Int((f * 100).rounded()))%"
            return L("Developing full size · \(done)")
        case .waiting(let why): return L(shown: why)
        case .failed: return L("Full size unavailable")
        case .ready: return fullView.detail == nil ? nil : L("Full size")
        case .off: return nil
        }
    }

    /// The part of the finished picture on screen, and the screen's pixels it
    /// covers: normalised, top-left origin, through Edit's crop where there is one.
    private func detailAsk(area: CGSize, fit: CGSize) -> FullView.Ask? {
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        let shown = CGRect(x: area.width / 2 + offset.width - size.width / 2, y: area.height / 2 + offset.height - size.height / 2,
                           width: size.width, height: size.height)
        let visible = shown.intersection(CGRect(origin: .zero, size: area))
        guard !visible.isNull, visible.width >= 1, visible.height >= 1, shown.width > 0, shown.height > 0 else { return nil }
        // On the picture as shown: Edit's crop's cut, or the finished picture itself.
        let n = CGRect(x: (visible.minX - shown.minX) / shown.width, y: (visible.minY - shown.minY) / shown.height,
                       width: visible.width / shown.width, height: visible.height / shown.height)
        var rect = n
        var perUnit = CGSize(width: shown.width * pixelsPerPoint, height: shown.height * pixelsPerPoint)
        if !frame.isPair, !edit.printCrop.isIdentity {
            let base = DevelopedFrameView.finishedSize(frame: frame, edit: edit, model: model, developed: developed)
            let g = edit.printCrop.onFinished(base)
            let out = g.outputSize(for: base), t = g.outputToSourceTransform(imageSize: base)
            let corners = [CGPoint(x: n.minX, y: n.minY), CGPoint(x: n.maxX, y: n.minY), CGPoint(x: n.minX, y: n.maxY), CGPoint(x: n.maxX, y: n.maxY)]
                .map { CGPoint(x: $0.x * out.width, y: $0.y * out.height).applying(t) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            rect = CGRect(x: xs.min()! / base.width, y: ys.min()! / base.height,
                          width: (xs.max()! - xs.min()!) / base.width, height: (ys.max()! - ys.min()!) / base.height)
            perUnit = CGSize(width: perUnit.width * base.width / max(out.width, 1), height: perUnit.height * base.height / max(out.height, 1))
        }
        rect = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let pixels = PixelSize(width: max(1, Int((rect.width * perUnit.width).rounded(.up))),
                               height: max(1, Int((rect.height * perUnit.height).rounded(.up))))
        return FullView.Ask(rect: rect, pixels: pixels, adjustments: edit.adjustments)
    }
    #endif

    /// The picture's shape: the film's canvas when it wears a film, else the
    /// picture's cut. Comparing shows the develop's shape.
    private var aspect: CGFloat {
        CGFloat(DevelopedFrameView.shownAspect(frame: frame, edit: edit, model: model,
                                               showsOriginal: !allowsOriginalHold && showsOriginal && !showsSplit, developed: developed))
    }

    private func fitSize(in whole: CGSize) -> CGSize {
        // Mac (the owner, 2026-10-27): an even small inset round the picture at the fit — the library
        // viewer's 12 Mac points (its `pt(12)` on a Mac-point page), in this page's scene points.
        let inset = (12 * 10 / 9 / InterfaceScale.padTarget).rounded()
        let area = CGSize(width: max(whole.width - inset * 2, 1), height: max(whole.height - inset * 2, 1))
        let a = max(aspect, 0.0001)
        return area.width / max(area.height, 1) > a
            ? CGSize(width: (area.height * a).rounded(), height: area.height)
            : CGSize(width: area.width, height: (area.width / a).rounded())
    }

    /// How much more of the source a cut needs decoded than a whole frame:
    /// a quarter of the frame shown at the fit needs the source at twice the
    /// size (`CroppedPicture.maxPixel` multiplies by the same).
    private var cropZoom: CGFloat {
        let g = edit.geometry
        return min(1 / max(min(g.crop.width, g.crop.height), 0.1), 4)
    }

    /// The preview copy's pixels over the fit's, for the cut shown: the zoom
    /// at which one of its pixels is one of the screen's.
    private func previewOverFit(fit: CGSize) -> CGFloat {
        let px = CGFloat(max(frame.previewSize.width, frame.previewSize.height))
        let fitPx = max(fit.width, fit.height) * max(pixelsPerPoint, 1)
        return px / max(fitPx * cropZoom, 1)
    }

    /// 100 %: one of the original's pixels per pixel of the screen, where the
    /// page can show them (`FullView`: an export's size at Full, so never past
    /// this device's cap); else one of the preview copy's. Never under 1.5×,
    /// so the double tap always goes somewhere.
    private func hundredZoom(fit: CGSize) -> CGFloat {
        if stopsAtPreviewPixels { return max(1, previewOverFit(fit: fit)) }
        return max(1.5, previewOverFit(fit: fit) * fullOverPreview)
    }

    /// How many of the original's pixels — as an export at Full has them —
    /// there are to one of the preview copy's: 1 where the page shows the preview only.
    private var fullOverPreview: CGFloat {
        #if SPK_ENGINE
        guard fullView != nil, FullView.hasMore(frame), frame.previewSize.longEdge > 0 else { return 1 }
        let own = CGFloat(frame.originalSize.longEdge) / CGFloat(frame.previewSize.longEdge)
        let cap = min(1, (DevicePolicy.current.developCapMegapixels / max(frame.originalSize.megapixels, 0.01)).squareRoot())
        return max(1, own * CGFloat(cap))
        #else
        return 1
        #endif
    }

    /// The decode never goes past the preview copy's own pixels, whatever
    /// the zoom (RAM first: a 48 MP original is not decoded whole to zoom
    /// into it). Past that the picture is drawn larger than it was decoded.
    private func decodeCap(fit: CGSize) -> CGFloat { max(0.5, previewOverFit(fit: fit)) }

    private func maxZoom(hundred: CGFloat) -> CGFloat { stopsAtPreviewPixels ? hundred : max(3, hundred) }

    /// Decoded in steps of two, so a pinch does not ask for a decode at every size.
    private static func decodeStep(_ z: CGFloat) -> CGFloat {
        z <= 1 ? 1 : pow(2, ceil(log2(z)))
    }

    private var zoomText: String {
        abs(zoom - 1) < 0.01 ? L("Fitted") : L("Zoomed \(Int((zoom * 100).rounded())) percent of fit")
    }

    // MARK: the clamp

    /// The one clamp: centred where the picture is smaller than the area,
    /// edges outside where it is larger.
    private func clamped(_ o: CGSize, zoom z: CGFloat, fit: CGSize, area: CGSize) -> CGSize {
        let w = fit.width * z, h = fit.height * z
        var o = o
        o.width = w <= area.width + 0.5 ? 0 : o.width.clamped(to: -(w - area.width) / 2 ... (w - area.width) / 2)
        o.height = h <= area.height + 0.5 ? 0 : o.height.clamped(to: -(h - area.height) / 2 ... (h - area.height) / 2)
        return o
    }

    /// The offset that keeps the picture point under `anchor` where it is
    /// when the zoom goes from `from` to `to`.
    private func offsetKeeping(_ anchor: CGPoint, from: (zoom: CGFloat, offset: CGSize), to z: CGFloat,
                               area: CGSize) -> CGSize {
        let c = CGPoint(x: area.width / 2, y: area.height / 2)
        let k = z / max(from.zoom, 0.0001)
        return CGSize(width: anchor.x - c.x - (anchor.x - c.x - from.offset.width) * k,
                      height: anchor.y - c.y - (anchor.y - c.y - from.offset.height) * k)
    }

    /// A gesture lifted: back inside the bounds, and the decode for this size.
    private func settle(fit: CGSize, area: CGSize, hundred: CGFloat, about anchor: CGPoint? = nil) {
        let top = maxZoom(hundred: hundred)
        var z = zoom, o = offset
        // A pinch let go a hair past fit looks fitted, and would keep the
        // pager's swipe from turning the page: it is fit.
        if z < 1.05 { z = 1; o = .zero }
        if z > top {
            if let anchor { o = offsetKeeping(anchor, from: (zoom, offset), to: top, area: area) }
            z = top
        }
        o = clamped(o, zoom: z, fit: fit, area: area)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            zoom = z
            offset = o
        }
        decodeZoom = min(Self.decodeStep(z), top)
    }

    // MARK: gestures

    private func pinch(area: CGSize, fit: CGSize, hundred: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .updating($pinchIsActive) { _, active, _ in active = true }
            .onChanged { v in
                if pinchBase == nil {
                    if dragOwner != nil { dragOwner = .picture }
                    pinchBase = (zoom, offset)
                    dragBase = nil
                }
                guard let base = pinchBase else { return }
                let z = CanvasZoom.scale(base: base.zoom, magnification: v.magnification, limit: maxZoom(hundred: hundred))
                let anchor = CGPoint(x: v.startAnchor.x * area.width, y: v.startAnchor.y * area.height)
                zoom = z
                offset = offsetKeeping(anchor, from: base, to: z, area: area)
            }
            .onEnded { v in
                pinchBase = nil
                let anchor = CGPoint(x: v.startAnchor.x * area.width, y: v.startAnchor.y * area.height)
                settle(fit: fit, area: area, hundred: hundred, about: anchor)
            }
    }

    /// A drag pans once there is more picture than area; fitted, it is left
    /// to the pager (or, with no pager, simply ignored: nothing else lives on
    /// the picture).
    private func drag(area: CGSize, fit: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { v in
                if dragOwner == nil {
                    dragOwner = pinchBase != nil ? .picture
                        : (zoom <= 1.001 && onPageable != nil ? .page : .picture)
                }
                guard pinchBase == nil else {
                    dragOwner = .picture
                    return
                }
                guard dragOwner == .picture, zoom > 1.001 else { return }
                if dragBase == nil { dragBase = (offset, v.translation) }
                guard let base = dragBase else { return }
                let free = CGSize(width: base.offset.width + v.translation.width - base.translation.width,
                                  height: base.offset.height + v.translation.height - base.translation.height)
                let held = clamped(free, zoom: zoom, fit: fit, area: area)
                // Past an edge the picture follows at a third: the rubber band.
                offset = CGSize(width: held.width + (free.width - held.width) * 0.3,
                                height: held.height + (free.height - held.height) * 0.3)
            }
            .onEnded { v in
                dragOwner = nil
                guard dragBase != nil else { return }
                dragBase = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    offset = clamped(offset, zoom: zoom, fit: fit, area: area)
                }
            }
    }

    /// Fit ↔ 100 %, about the tap (the desktop's double click, `Z`).
    private func doubleTap(area: CGSize, fit: CGSize, hundred: CGFloat) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { v in
                changeZoom(to: zoom > 1.01 ? 1 : hundred, about: v.location,
                           fit: fit, area: area, hundred: hundred)
            }
    }

    /// Mac: a scroll zooms as a pinch does — about the pointer, held as the pinch's base so the
    /// full render waits for it to rest, and settled when it ends. 100 pt of travel is ×1.8.
    private func scrollZoom(_ phase: MacScrollZoom.Phase, travel: CGFloat, at anchor: CGPoint,
                            fit: CGSize, area: CGSize, hundred: CGFloat) {
        switch phase {
        case .began, .changed:
            if pinchBase == nil { pinchBase = (zoom, offset); dragBase = nil; scrollOrigin = 0 }
            guard let base = pinchBase else { return }
            let top = maxZoom(hundred: hundred)
            // The travel spun past the band's stops is not kept: a turn back answers at once.
            let held = CanvasZoom.heldTravel(travel, origin: scrollOrigin, base: base.zoom, limit: top)
            scrollOrigin = held.origin
            let z = CanvasZoom.scale(base: base.zoom, magnification: exp(held.travel * 0.006), limit: top)
            zoom = z
            offset = offsetKeeping(anchor, from: base, to: z, area: area)
        case .ended:
            pinchBase = nil
            settle(fit: fit, area: area, hundred: hundred, about: anchor)
        }
        #if DEBUG
        if MacScrollZoom.logs { NSLog("macscroll canvas zoom %.3f", zoom) }
        #endif
    }

    /// Double tap and accessibility actions share the same bounded viewport.
    private func changeZoom(to requested: CGFloat, about anchor: CGPoint? = nil,
                            fit: CGSize, area: CGSize, hundred: CGFloat) {
        if dragOwner != nil { dragOwner = .picture }
        let top = maxZoom(hundred: hundred), z = min(max(requested, 1), top)
        let point = anchor ?? CGPoint(x: area.width / 2, y: area.height / 2)
        let o = z == 1 ? CGSize.zero
            : clamped(offsetKeeping(point, from: (zoom, offset), to: z, area: area), zoom: z, fit: fit, area: area)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { zoom = z; offset = o }
        decodeZoom = min(Self.decodeStep(z), top)
    }
}

/// A half-frame pair on the develop page's picture: where each of its frames
/// is, which layer is picked, and what a touch picks (design/pair v2).
struct PieceMarks {
    /// Each frame's rectangle on the picture shown, normalised with a top-left
    /// origin: the piece's holes, or on its strip the engine's gates
    /// (`OpenFrameSession.frameRects`). Nil while a strip's gates are not known.
    var rects: [HalfFramePair.Side: CGRect]?
    var picked: HalfFramePair.Layer
    var pick: (HalfFramePair.Layer) -> Void

    /// What is under a point of the picture, normalised: a frame's hole, or
    /// the film — between the frames, round them, and everywhere off the picture.
    func layer(at n: CGPoint) -> HalfFramePair.Layer {
        rects?.first { $0.value.contains(n) }.map { HalfFramePair.Layer($0.key) } ?? .film
    }
}

/// The picked layer's white frame: on the frame's own edge, or — for the film
/// — round the whole piece, inside its edge, since the piece runs to the
/// page's own edges. Selection is the white frame, never the accent.
private struct PieceFrame: View {
    let marks: PieceMarks
    /// Where the picture is, in the area.
    let picture: CGRect

    var body: some View {
        let r: CGRect? = {
            guard let side = marks.picked.side else { return picture.insetBy(dx: 1, dy: 1) }
            guard let n = marks.rects?[side] else { return nil }
            return CGRect(x: picture.minX + n.minX * picture.width, y: picture.minY + n.minY * picture.height,
                          width: n.width * picture.width, height: n.height * picture.height)
        }()
        if let r {
            Rectangle().stroke(Theme.selectionFrame, lineWidth: 2)
                .frame(width: max(r.width, 0), height: max(r.height, 0))
                .position(x: r.midX, y: r.midY)
        }
    }
}

/// The split's line, grip and labels, drawn in the area's own points so they
/// stay one point and 30 pt at any zoom (the desktop's `CompareOverlay`).
/// The line and the grip take the drag; the rest of the picture still pans.
private struct CompareLine: View {
    /// Where the picture is, in the area.
    let picture: CGRect
    let area: CGSize
    @Binding var split: Double

    private static let grip: CGFloat = 15

    var body: some View {
        let x = picture.minX + CGFloat(split) * picture.width
        let y0 = max(0, min(picture.minY, area.height))
        let y1 = max(0, min(picture.maxY, area.height))
        let midY = (y0 + y1) / 2
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: x, y: y0))
                p.addLine(to: CGPoint(x: x, y: y1))
            }
            .stroke(Theme.selectionFrame, lineWidth: 1)
            .shadow(color: .black.opacity(0.6), radius: 1)
            grip.position(x: x, y: midY)
            let left = max(picture.minX, 0) + 34
            let right = min(picture.maxX, area.width) - 34
            let labelY = y0 + 16
            if x - left > 24 { label(L("Before")).position(x: left, y: labelY) }
            if right - x > 24 { label(L("After")).position(x: right, y: labelY) }
        }
        .frame(width: area.width, height: area.height)
        // Only a band about the line takes the finger: 48 pt wide, the
        // picture's height on screen.
        .contentShape(Path(CGRect(x: x - 24, y: y0, width: 48, height: max(y1 - y0, 1))))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard picture.width > 1 else { return }
                    split = Double((g.location.x - picture.minX) / picture.width).clamped(to: 0...1)
                }
        )
        .accessibilityElement()
        .accessibilityLabel(L("Compare split"))
        .accessibilityValue(L("\(Int((split * 100).rounded())) percent"))
        .accessibilityAdjustableAction { d in
            split = (split + (d == .increment ? 0.05 : -0.05)).clamped(to: 0...1)
        }
    }

    private var grip: some View {
        ZStack {
            Circle().fill(Theme.card.opacity(0.55))
            Circle().strokeBorder(Theme.selectionFrame, lineWidth: 1)
            HStack(spacing: 3) {
                Triangle(left: true).fill(Theme.selectionFrame).frame(width: 5, height: 7)
                Triangle(left: false).fill(Theme.selectionFrame).frame(width: 5, height: 7)
            }
        }
        .frame(width: Self.grip * 2, height: Self.grip * 2)
        .shadow(color: .black.opacity(0.5), radius: 2)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.ui(11, .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.card.opacity(0.8), in: Capsule())
            .fixedSize()
    }

    /// The grip's two small pointers, the desktop's `arrowtriangle` glyphs.
    private struct Triangle: Shape {
        let left: Bool
        func path(in r: CGRect) -> Path {
            var p = Path()
            if left {
                p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            } else {
                p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            }
            p.closeSubpath()
            return p
        }
    }
}

/// The small pill with a chevron that folds the panel under the picture away
/// and brings it back (the desktop's `CollapseTab`, on the status band).
struct CollapseHandle: View {
    let collapsed: Bool
    /// How tall the handle's own ground is: the band it sits on, so that a
    /// finger on the picture above or on the Latitude card below is theirs.
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // `fold_pill`: the chevron at the glyph's own size, 8 wide and 1.5 pt.
            Icon(.chevronDown, size: 22, color: Theme.text)
                .rotationEffect(.degrees(collapsed ? 180 : 0))
                .frame(width: 36, height: 18)
                .background(Capsule().fill(Theme.card))
                .frame(width: 44, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(collapsed ? L("Show the controls") : L("Fold the controls away"))
    }
}
