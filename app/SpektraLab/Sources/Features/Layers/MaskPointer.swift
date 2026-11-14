//  MaskPointer.swift — the pointer over the picture while a mask tool is lit, in UIKit (2.4.0 A1; MASKS-SPEC §6.2):
//  the press, the drag with every sample the event carries, the hover, the brush's circle, and the layer a stroke is
//  drawn live into (`MaskLive`).
//
//  **Why not SwiftUI's.** The stage's `DragGesture` and `onContinuousHover` wrote the pointer into `@State`, so the
//  brush's circle moved only when the stage's body was evaluated again and drawn — after the session's work for the
//  move, in the next SwiftUI update — and a drag delivered one location per update, the samples between dropped. Here
//  the circle is a layer moved in the event's own handler (implicit animations off), so it is under the pointer in the
//  frame that event is drawn in, whatever the main actor does next; and a drag hands `MaskStage` the event's coalesced
//  touches, oldest first, so a fast stroke keeps the pointer's own path.
//
//  The view is on the stage whether or not a tool is lit (it is where the stage tells `MaskLive` its place), and takes
//  the pointer only while one is: with none it is not hit, and the canvas's own gestures have the picture.

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct MaskPointer: UIViewRepresentable {
    /// A tool is lit: the view takes the pointer.
    var lit: Bool
    var label: String
    /// What the brush's circle is drawn from, as a word: a change (a size key, the tool, the zoom) redraws it.
    var ringKey: String
    var place: MaskLive.Place?
    /// The circle's radius and its hardness's inner radius at a point (view points); nil: no circle there.
    var ring: (CGPoint) -> (r: CGFloat, inner: CGFloat)?
    var began: (CGPoint) -> Void
    var moved: (CGPoint, [CGPoint], TimeInterval?) -> Void
    var ended: () -> Void
    var hovered: (CGPoint?) -> Void

    func makeUIView(context: Context) -> MaskPointerView { MaskPointerView() }

    func updateUIView(_ v: MaskPointerView, context: Context) {
        v.ring = ring
        v.began = began
        v.moved = moved
        v.ended = ended
        v.hovered = hovered
        v.isUserInteractionEnabled = lit
        v.isAccessibilityElement = lit
        v.accessibilityLabel = label
        if place != MaskLive.shared.place { MaskLive.shared.place = place }
        if v.ringKey != ringKey { v.ringKey = ringKey; v.refreshRing() }
    }

    static func dismantleUIView(_ v: MaskPointerView, coordinator: ()) {
        if MaskLive.shared.layer === v.live { MaskLive.shared.uncover() }
    }
}

final class MaskPointerView: UIView {
    var ring: (CGPoint) -> (r: CGFloat, inner: CGFloat)? = { _ in nil }
    var began: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint, [CGPoint], TimeInterval?) -> Void = { _, _, _ in }
    var ended: () -> Void = {}
    var hovered: (CGPoint?) -> Void = { _ in }
    var ringKey = ""

    /// The live stroke's layer (`MaskLive`), under the circle.
    let live = CAMetalLayer()
    private let circle = CALayer()
    private let shade = CAShapeLayer(), rim = CAShapeLayer(), inner = CAShapeLayer(), cross = CAShapeLayer()
    private var drawn: (r: CGFloat, inner: CGFloat)?
    /// Where the pointer is (view points), as the last event left it.
    private(set) var at: CGPoint?
    private var start: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "mask.stage"
        accessibilityTraits = .allowsDirectInteraction
        live.pixelFormat = .bgra8Unorm
        live.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        live.isOpaque = false
        live.framebufferOnly = true
        live.maximumDrawableCount = 3
        live.displaySyncEnabled = false
        live.isHidden = true
        live.device = MTLCreateSystemDefaultDevice()
        live.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        layer.addSublayer(live)
        // The circle as the stage drew it (§6.2): a dark rim under a white one, the hardness's dashed circle, a cross.
        shade.strokeColor = UIColor.black.withAlphaComponent(0.4).cgColor; shade.lineWidth = 3
        rim.strokeColor = UIColor.white.cgColor; rim.lineWidth = 1.5
        inner.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor; inner.lineWidth = 1; inner.lineDashPattern = [3, 3]
        cross.strokeColor = UIColor.white.cgColor; cross.lineWidth = 1
        cross.shadowColor = UIColor.black.cgColor; cross.shadowOpacity = 0.6; cross.shadowRadius = 0.5; cross.shadowOffset = .zero
        let c = UIBezierPath()
        c.move(to: CGPoint(x: -4, y: 0)); c.addLine(to: CGPoint(x: 4, y: 0))
        c.move(to: CGPoint(x: 0, y: -4)); c.addLine(to: CGPoint(x: 0, y: 4))
        cross.path = c.cgPath
        for s in [shade, rim, inner, cross] {
            s.fillColor = nil
            s.actions = ["path": NSNull(), "position": NSNull(), "hidden": NSNull()]
            circle.addSublayer(s)
        }
        circle.actions = ["position": NSNull(), "hidden": NSNull(), "bounds": NSNull()]
        circle.isHidden = true
        layer.addSublayer(circle)
        MaskLive.shared.layer = live
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        addGestureRecognizer(MaskPress(target: self, action: #selector(press(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { MaskLive.shared.layer = live }
        live.contentsScale = window?.screen.scale ?? 2
        if let fps = window?.screen.maximumFramesPerSecond, fps > 0 { MaskLive.shared.frameSeconds = 1 / Double(fps) }
        // The display's own frame where the window is (a Mac's screens differ: 160 Hz, 120 Hz), read from a display
        // link of the window's screen for a few frames.
        frameProbe?.invalidate(); frameProbe = nil
        if let screen = window?.windowScene?.screen, let link = screen.displayLink(withTarget: self, selector: #selector(frame(_:))) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 240, preferred: 240)
            link.add(to: .main, forMode: .common)
            frameProbe = link
            frames = []
        }
    }

    private var frameProbe: CADisplayLink?
    private var frames: [CFTimeInterval] = []

    @objc private func frame(_ link: CADisplayLink) {
        frames.append(link.targetTimestamp - link.timestamp)
        guard frames.count >= 12 else { return }
        let sorted = frames.sorted()
        MaskLive.shared.frameSeconds = sorted[sorted.count / 2]
        link.invalidate()
        frameProbe = nil
    }

    // MARK: the circle

    /// The circle at `p`, now: moved in this event's transaction, its paths redrawn only when its size changed.
    func place(_ p: CGPoint?) {
        at = p
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let p, let g = ring(p) else { circle.isHidden = true; return }
        if drawn.map({ abs($0.r - g.r) > 0.25 || abs($0.inner - g.inner) > 0.25 }) ?? true {
            drawn = g
            let o = CGRect(x: -g.r, y: -g.r, width: 2 * g.r, height: 2 * g.r)
            shade.path = UIBezierPath(ovalIn: o).cgPath
            rim.path = shade.path
            if g.inner > 0 {
                inner.path = UIBezierPath(ovalIn: CGRect(x: -g.inner, y: -g.inner, width: 2 * g.inner, height: 2 * g.inner)).cgPath
                inner.isHidden = false
            } else {
                inner.isHidden = true
            }
        }
        circle.position = p
        circle.isHidden = false
    }

    #if DEBUG
    /// The circle as its layer stands now (its model, before any frame is drawn): where and how large; nil hidden.
    var ringNow: (at: CGPoint, r: CGFloat)? { circle.isHidden ? nil : (circle.position, drawn?.r ?? 0) }
    #endif

    /// The circle's settings changed (a size key, the tool, the zoom): drawn again where the pointer is.
    func refreshRing() {
        drawn = nil
        place(at)
    }

    // MARK: the pointer

    @objc private func hover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            place(p)
            hovered(p)
        default:
            place(nil)
            hovered(nil)
        }
    }

    @objc private func press(_ g: MaskPress) {
        switch g.state {
        case .began:
            let p = g.location(in: self)
            start = p
            place(p)
            began(p)
        case .changed:
            let (samples, time) = g.take()
            guard let start, let last = samples.last else { return }
            place(last)
            moved(start, samples, time)
        default:
            if let start {
                let (samples, time) = g.take()
                if !samples.isEmpty { moved(start, samples, time) }
            }
            start = nil
            ended()
        }
    }
}

/// A press and its drag, recognised at the press (no distance to travel first) and holding every sample the drag's
/// events carry (`coalescedTouches`), oldest first.
final class MaskPress: UIGestureRecognizer {
    private var pending: [CGPoint] = []
    private var oldest: TimeInterval?

    /// The samples since the last take, in the view's points, and the oldest one's time (`UITouch.timestamp`).
    func take() -> ([CGPoint], TimeInterval?) {
        defer { pending = []; oldest = nil }
        return (pending, oldest)
    }

    private func add(_ touches: Set<UITouch>, _ event: UIEvent) {
        guard let t = touches.first else { return }
        let all = event.coalescedTouches(for: t) ?? [t]
        pending += all.map { $0.location(in: view) }
        // The oldest sample not yet drawn: the live stroke's time to the screen is counted from it, so a main actor
        // that held the event back counts against the move.
        if oldest == nil { oldest = all.first?.timestamp ?? t.timestamp }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, state == .possible else { state = .failed; return }
        pending = []; oldest = nil
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        add(touches, event)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        add(touches, event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }

    override func reset() {
        super.reset()
        pending = []
    }

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}
