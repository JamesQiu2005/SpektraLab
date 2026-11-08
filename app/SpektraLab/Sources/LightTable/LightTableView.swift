//  LightTableView.swift — the light table on a page: a Metal view that draws only when something changed.
//
//  An `MTKView` in a `UIViewRepresentable`. It is paused with `enableSetNeedsDisplay` on, so it
//  draws when the controller says something changed (`onChange` → `setNeedsDisplay`), and runs
//  at the display's rate only while something is on its way — a film easing to its place, the zoom,
//  the loupe fading, the lamp's gloss drifting in the 20 s after a touch — or while fingers are on
//  the table, then pauses again (the website's loop: "an idle page draws nothing").
//
//  **The display's rate is the screen's own** (the owner, 2026-10-17: "This page should have a 120hz
//  render enabled during pinch and scroll"): `preferredFramesPerSecond` is the screen's
//  `maximumFramesPerSecond` — 120 on a ProMotion display — and while fingers are down the view runs on its display
//  link rather than on `setNeedsDisplay`, so every frame the screen shows gets a picture that frame's
//  touches moved. Still, nothing is drawn on a tick where nothing changed (`advance` returns nil).
//  `frameClock` counts what was drawn during a gesture, for the log.
//
//  The layer is Display P3 (`LightTableShaders`: the library's pictures are), 8 bits, the
//  drawable's own scale. No gesture is here: the page puts its own on the view, and talks to
//  the table through the controller's intents.
//
//  `LightTableStill` is the same picture made offscreen, for the snapshot harness, whose window is
//  never shown and is captured by `drawHierarchy`, which does not see a Metal layer's contents.

import MetalKit
import SwiftUI
import UIKit

final class LightTableMetalView: MTKView, MTKViewDelegate {
    let controller: LightTableController
    /// The room the page's controls leave round the table, points.
    var inset = LightTableViewport.Insets() { didSet { setNeedsLayout() } }
    /// The chosen film's ring, 4 points out, drawn over the picture and moved with it at every
    /// picture, so it follows the film as it eases, is carried and turned. Nil colour: no ring (the
    /// harness draws its own). The page's is `ringWhite`.
    var ringColor: UIColor? { didSet { placeRing() } }
    private let ring = CAShapeLayer()
    /// A soft dark edge under the ring, so a light ring still reads on the lit pad.
    private let ringEdge = CAShapeLayer()

    /// The ring round a chosen film (the owner, 2026-10-17: "a little bit grey-ish white (not as grey
    /// as the other icons)"): a warm light grey, lighter than the app's grey discs (`Theme.card`) and
    /// the secondary glyphs, a little under the app's white, so it reads as the selection without
    /// shouting; on the lit pad it is held by a soft dark edge (`ringEdge`).
    static let ringWhite = UIColor(red: 0.906, green: 0.898, blue: 0.882, alpha: 1)

    /// What was drawn while fingers were on the table: ticks of the display link, pictures put on the
    /// screen, and the gaps between them — so the log can say whether a pinch ran at 120 Hz.
    struct FrameClock {
        private(set) var ticks = 0
        private(set) var presents = 0
        private var start = 0.0
        private var first = 0.0
        private var last = 0.0
        private var gaps: [Double] = []
        var link = 0
        var screen = 0

        mutating func start(at t: Double) {
            ticks = 0; presents = 0; start = t; first = 0; last = 0
            gaps.removeAll(keepingCapacity: true)
        }
        mutating func tick() { ticks += 1 }
        mutating func presented(at t: Double) {
            if presents > 0 { if gaps.count < 4096 { gaps.append(t - last) } } else { first = t }
            last = t
            presents += 1
        }

        func fields(at t: Double) -> [String: Any] {
            func fps(_ gap: Double) -> Double { gap > 0 ? LightTableTrace.round(1 / gap) : 0 }
            let sorted = gaps.sorted()
            var out: [String: Any] = ["frames": presents, "ticks": ticks, "link_fps": link, "screen_fps": screen]
            if presents > 1, last > first {
                out["fps_avg"] = LightTableTrace.round(Double(presents - 1) / (last - first))
                out["fps_median"] = fps(sorted[sorted.count / 2])
                out["fps_best"] = fps(sorted[sorted.count / 10])
            }
            if t > start { out["ticks_per_s"] = LightTableTrace.round(Double(ticks) / (t - start)) }
            return out
        }
    }
    var frameClock = FrameClock()

    /// What VoiceOver is told (the page's words): a film's label and value, its actions, what
    /// activating it does; the table's own value, its zoom and its escape.
    var describe: ((UUID) -> (label: String, value: String))?
    var filmActions: ((UUID) -> [UIAccessibilityCustomAction])?
    var activate: ((UUID) -> Void)?
    var tableValue: (() -> String)?
    var escape: (() -> Void)?
    private var elements: [UUID: FilmElement] = [:]
    private lazy var tableElement = TableElement(view: self)

    init(controller: LightTableController) {
        self.controller = controller
        super.init(frame: .zero, device: controller.renderer?.device)
        colorPixelFormat = LightTableRenderer.pixelFormat
        framebufferOnly = true
        clearColor = controller.darkDesk ? LightTableRenderer.clearDark : LightTableRenderer.clear
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        isOpaque = true
        // A picture of the old shape, while the host turns, is shown at its own size, not
        // stretched to the new one (the table is never drawn out of its proportions).
        layer.contentsGravity = .center
        backgroundColor = controller.darkDesk ? .black : UIColor(red: 0.913, green: 0.913, blue: 0.922, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        matchScreenRate(UIScreen.main)
        ringEdge.fillColor = nil
        ringEdge.lineWidth = 4
        ringEdge.strokeColor = UIColor(white: 0, alpha: 0.2).cgColor
        ringEdge.isHidden = true
        layer.addSublayer(ringEdge)
        ring.fillColor = nil
        ring.lineWidth = 2.25
        ring.isHidden = true
        layer.addSublayer(ring)
        controller.onChange = { [weak self] in self?.setNeedsDisplay() }
    }

    /// The display link at the screen's own most: 120 on ProMotion.
    private func matchScreenRate(_ screen: UIScreen) {
        let most = max(60, screen.maximumFramesPerSecond)
        if preferredFramesPerSecond != most { preferredFramesPerSecond = most }
        frameClock.link = preferredFramesPerSecond
        frameClock.screen = screen.maximumFramesPerSecond
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen { matchScreenRate(screen) }
        if window != nil, displayWatch.isEmpty {
            displayWatch = MacDisplay.watch { [weak self] in self?.setNeedsLayout() }
        } else if window == nil {
            for w in displayWatch { NotificationCenter.default.removeObserver(w) }
            displayWatch = []
        }
    }

    /// AppKit's news of the window on another display, or a display's mode changed: Actual Size read again.
    private var displayWatch: [NSObjectProtocol] = []
    /// Mac: what a right click on a film offers (`MacLightTableMenu`), kept with the view.
    var contextMenu: AnyObject?
    /// Mac: the table takes the keyboard when its menu opens, so the menu's commands have a responder chain.
    override var canBecomeFirstResponder: Bool { contextMenu != nil }

    /// The develop ring of each film whose picture is being made (`LightTableController.making`): the
    /// library tile's (`ProgressRing`, 26 points, an accent arc over a faint track), at the film's middle.
    private var developRings: [UUID: (track: CAShapeLayer, arc: CAShapeLayer)] = [:]

    private func placeDevelopRings() {
        let rings = controller.makingRings
        let ids = Set(rings.map(\.id))
        for (id, layers) in developRings where !ids.contains(id) {
            layers.track.removeFromSuperlayer(); layers.arc.removeFromSuperlayer()
            developRings[id] = nil
        }
        let d: CGFloat = 26
        let path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d), transform: nil)
        for r in rings {
            let layers = developRings[r.id] ?? {
                let track = CAShapeLayer(), arc = CAShapeLayer()
                for l in [track, arc] {
                    l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                    l.path = path
                    l.fillColor = nil
                    l.lineWidth = 2.5
                    layer.addSublayer(l)
                }
                track.strokeColor = UIColor(white: 1, alpha: 0.25).cgColor
                arc.strokeColor = UIColor(Theme.accent).cgColor
                arc.lineCap = .round
                arc.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
                developRings[r.id] = (track, arc)
                return (track, arc)
            }()
            layers.track.position = r.centre
            layers.arc.position = r.centre
            layers.arc.isHidden = r.progress < 0
            layers.arc.strokeEnd = CGFloat(max(0, min(1, r.progress)))
        }
    }

    /// The ring where the chosen film is drawn this moment.
    private func placeRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        placeDevelopRings()
        guard let ringColor, let r = controller.ring, !controller.loupeOn else { ring.isHidden = true; ringEdge.isHidden = true; return }
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: 3, cornerHeight: 3, transform: nil)
        for l in [ringEdge, ring] {
            l.isHidden = false
            l.bounds = CGRect(origin: .zero, size: r.size)
            l.position = r.centre
            l.path = path
            l.setAffineTransform(CGAffineTransform(rotationAngle: r.angle))
        }
        ring.strokeColor = ringColor.cgColor
    }

    // MARK: VoiceOver: the table, then each film, top first

    override var isAccessibilityElement: Bool { get { false } set {} }

    override var accessibilityElements: [Any]? {
        get {
            guard describe != nil else { return nil }
            var out: [Any] = [tableElement]
            tableElement.accessibilityFrameInContainerSpace = bounds
            tableElement.accessibilityValue = tableValue?()
            var seen = Set<UUID>()
            for id in controller.model.order.reversed() {
                guard let box = controller.screenBox(id), let words = describe?(id) else { continue }
                let e = elements[id] ?? FilmElement(view: self, id: id)
                elements[id] = e
                e.accessibilityFrameInContainerSpace = box.intersection(bounds).isNull ? box : box.intersection(bounds)
                e.accessibilityLabel = words.label
                e.accessibilityValue = words.value
                e.accessibilityTraits = controller.selected == id ? [.button, .selected] : .button
                e.accessibilityCustomActions = filmActions?(id)
                out.append(e)
                seen.insert(id)
            }
            for id in elements.keys where !seen.contains(id) { elements[id] = nil }
            return out
        }
        set {}
    }

    fileprivate final class FilmElement: UIAccessibilityElement {
        let id: UUID
        weak var view: LightTableMetalView?
        init(view: LightTableMetalView, id: UUID) {
            self.id = id
            self.view = view
            super.init(accessibilityContainer: view)
        }
        override func accessibilityActivate() -> Bool { view?.activate?(id); return view?.activate != nil }
        override func accessibilityPerformEscape() -> Bool { view?.escape?(); return view?.escape != nil }
    }

    /// The table: adjustable (a swipe up or down zooms by 1.5), with escape to put the choice back.
    fileprivate final class TableElement: UIAccessibilityElement {
        weak var view: LightTableMetalView?
        init(view: LightTableMetalView) {
            self.view = view
            super.init(accessibilityContainer: view)
            accessibilityLabel = L("Light Table")
            accessibilityTraits = [.adjustable, .allowsDirectInteraction]
        }
        override func accessibilityIncrement() {
            guard let c = view?.controller else { return }
            c.zoom(to: min(LightTable.zoomMax, c.viewport.zoom * 1.5))
        }
        override func accessibilityDecrement() {
            guard let c = view?.controller else { return }
            c.zoom(to: max(1, c.viewport.zoom / 1.5))
        }
        override func accessibilityPerformEscape() -> Bool { view?.escape?(); return view?.escape != nil }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The size last laid out: a different one is the host turned (or the page's bands changed).
    private var laidOut = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if laidOut != .zero && bounds.size != laidOut {
            // The view changed shape under fingers (the host turned in the middle of a pinch or a
            // carry): every recogniser is cancelled, so none goes on with points of the old shape;
            // the controller has already set down what they held (`layout`).
            for r in gestureRecognizers ?? [] where r.isEnabled {
                r.isEnabled = false
                r.isEnabled = true
            }
        }
        let reshaped = laidOut != .zero && bounds.size != laidOut
        laidOut = bounds.size
        // The window's Actual Size: the screen this view is on, in points a millimetre (nil on the host).
        // the display the window is on, from its own size
        // (`MacDisplay`), read again when the window goes to another display.
        controller.setPointsPerMM(MacDisplay.pointsPerMM(for: window))
        controller.layout(size: bounds.size, inset: inset, scale: Double(window?.screen.scale ?? contentScaleFactor))
        if reshaped {
            // Drawn now, at the new size, inside the turn's own animation: otherwise the operating system turns the
            // last picture, stretched to the new shape, until the next display tick (seen in the
            // simulator's recording, 2026-10-19).
            draw()
        }
        setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { setNeedsDisplay() }

    func draw(in view: MTKView) {
        defer { pace(); placeRing() }
        frameClock.tick()
        guard let renderer = controller.renderer, let frame = controller.advance() else { return }
        guard let drawable = currentDrawable, let cb = renderer.queue.makeCommandBuffer() else { return }
        let vp = controller.viewport
        renderer.draw(frame.scene, centre: CGPoint(x: vp.cx, y: vp.cy), s: vp.s, view: vp.size,
                      scale: Double(drawableSize.width / max(bounds.width, 1)), loupe: frame.loupe,
                      into: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
        frameClock.presented(at: CACurrentMediaTime())
    }

    /// At the display's rate while something moves; paused, drawn on asking, otherwise.
    private func pace() {
        let run = controller.needsFrames
        if run == !isPaused { return }
        isPaused = !run
        enableSetNeedsDisplay = !run
    }
}

/// The light table as a SwiftUI view. `configure` lets a page put its gestures on the view.
struct LightTableView: UIViewRepresentable {
    let controller: LightTableController
    var inset = LightTableViewport.Insets()
    var configure: ((LightTableMetalView) -> Void)? = nil

    func makeUIView(context: Context) -> LightTableMetalView {
        let v = LightTableMetalView(controller: controller)
        v.inset = inset
        configure?(v)
        return v
    }

    func updateUIView(_ view: LightTableMetalView, context: Context) {
        if view.inset != inset { view.inset = inset }
    }

    static func dismantleUIView(_ view: LightTableMetalView, coordinator: ()) {
        view.isPaused = true
        view.delegate = nil
    }
}

extension LightTableRenderer {
    /// The view's picture made offscreen at `view × scale` pixels, with the loupe, read back: what
    /// `LightTableMetalView` would put on the screen this moment.
    func still(_ scene: Scene, centre: CGPoint, s: Double, view: CGSize, scale: Double, loupe: Loupe?) -> CGImage? {
        let w = Int((view.width * scale).rounded()), h = Int((view.height * scale).rounded())
        guard w > 0, h > 0, let cb = queue.makeCommandBuffer() else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d) else { return nil }
        draw(scene, centre: centre, s: s, view: view, scale: scale, loupe: loupe, into: target, commandBuffer: cb)
        return readBack(target, commandBuffer: cb)
    }
}

/// The table drawn once, offscreen, as a picture: for the snapshot harness.
struct LightTableStill: View {
    let controller: LightTableController

    var body: some View {
        GeometryReader { geo in
            if let image = controller.still(size: geo.size, scale: 2) {
                Image(decorative: image, scale: 2).resizable().frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

extension LightTableController {
    /// The view's picture now, made offscreen: the films read at once at the size they need (a
    /// check's way; a page never waits on a read), everything at rest.
    func still(size: CGSize, scale: Double, inset: LightTableViewport.Insets = .init()) -> CGImage? {
        still = true
        layout(size: size, inset: inset, scale: scale)
        settleNow()
        requestTexturesNow()
        settleNow()
        guard let renderer, let frame = advance() else { return nil }
        let vp = viewport
        return renderer.still(frame.scene, centre: CGPoint(x: vp.cx, y: vp.cy), s: vp.s, view: vp.size, scale: scale, loupe: frame.loupe)
    }
}
