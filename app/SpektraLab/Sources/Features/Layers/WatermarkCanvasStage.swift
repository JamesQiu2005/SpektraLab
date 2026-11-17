//  WatermarkCanvasStage.swift — the canvas while a watermark's row is picked: the marks drawn live over the picture, and the
//  place to move them, for a pointer (PRD-8 §4.2; RFC-067 §5).
//
//  - **Drawn live, at the display's rate, with no develop**: each mark that is on, its pixels laid through its frame
//    (`WatermarkGeometry.frame`, the composite's one arithmetic) on the canvas — the cut picture as shown, in points.
//    The page's picture is laid without them meanwhile (`OpenFrameSession.watermarkOverlayLive`), so nothing is drawn
//    twice; at rest, the row unpicked, the picture carries the composite again.
//  - **The pointer, by where it begins**: the overlay takes the pointer only over a mark and the
//    picked mark's handles (its hit shape); a drag that begins anywhere else is the canvas's own pan and zoom, and a
//    click there puts the picked mark's handles away (the row stays picked: `watermarkSelected`).
//    · inside a mark: drag moves it (and picks its row);
//    · a corner handle: drag sizes it about the opposite corner, aspect kept;
//    · the turn handle above its top edge, or just outside a corner: drag turns it about its centre, following the
//      pointer's angle from the centre as Photoshop's does; ⇧ holds it to 15° steps. The pointer is UIKit's
//      (`WatermarkPointer`): SwiftUI's drag lost the press to the Develop page's own gestures with a real pointer.
//      Preview's Markup has none for a picture, and Keynote's other way (⌘ on a corner) needs the pointer's modifier
//      flags, which the pointer's own press does not carry (⇧ is read from the keyboard's state, `MacModifiers`). A trackpad's pinch and rotate are left out: the canvas's
//      own zoom is a simultaneous gesture of the whole page, so a pinch over a mark would zoom the picture too.
//  - **Snapping**: the centre to the canvas's centre lines and the turned box's edges to the 4 % safe
//    margin within 8 points, drawn as a dashed accent line while held; the turn to a right angle within 3°. No haptic.
//  - **One Undo step a gesture** (`beganWatermark` … `endedWatermark`); its end keeps the whole mark on the canvas
//    and measures it from its nearest corner (`WatermarkGeometry.settled`).
//  - **VoiceOver**: each mark an element, adjustable (its size ±5 %), with actions that move it 1 % of the short side
//    and turn it 5°.
//  - **A 底片 mark** (the film on) is measured on the 底片 canvas — the picture the engine is handed, inside the film
//    edge, through Edit's crop (`WatermarkCanvases`) — and drawn through that canvas's place on this one, so overlay and
//    develop agree in place and size. It is in the developed picture, so the overlay draws it **only while the picture
//    on the page is not of it** (`drawsLive`): under the pointer, and after the lift until its develop lands; at rest
//    the picture carries the developed mark — grain, halation, the film's colour — and the overlay draws its handles
//    alone. They cannot agree in tone: that is the point. **Under a gesture** the page's picture is developed without
//    the 底片 marks (`OpenFrameSession.developTarget`), so the old place of a dragged mark is not left in it (the owner's
//    hand test, 2026-11-16); the lift develops them where they went.

import SwiftUI
import UIKit

/// The marks' pixels the overlay lays: the library's, at a width the canvas can show sharp, made off the main actor
/// once a mark and width.
@MainActor @Observable
final class WatermarkOverlayPixels {
    static let shared = WatermarkOverlayPixels()
    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var asked: Set<String> = []

    func image(_ mark: UUID, width: Int, store: WatermarkStore, fill: String? = nil) -> UIImage? {
        let w = max(64, Int((Double(width) / 128).rounded(.up)) * 128)
        let key = "\(mark)|\(fill ?? "")|\(w)|\(store.info(mark)?.sha256 ?? "")"
        if let hit = images[key] { return hit }
        // A smaller one already made stands in until this one lands (of the same fill: never another colour's).
        let standIn = images.first { $0.key.hasPrefix("\(mark)|\(fill ?? "")|") }?.value
        guard !asked.contains(key) else { return standIn }
        asked.insert(key)
        Task.detached(priority: .userInitiated) {
            // 填充 as the composite draws it (`WatermarkFill.filled`): the same pixels on the canvas and in the file.
            let made = store.bitmap(mark, width: w).map { b in UIImage(cgImage: WatermarkFill.filled(b, fill) ?? b) }
            await MainActor.run {
                if let made { self.images[key] = made }
                if self.images.count > 16 { self.images.removeAll(); self.asked.removeAll() }
            }
        }
        return standIn
    }
}

struct WatermarkCanvasStage: View {
    let session: OpenFrameSession
    /// The picture as shown, in the canvas's view (the cut finished picture): the marks' canvas.
    let shown: CGRect
    /// Where the 底片 canvas is on it (nil: unknown, every mark measured on `shown`).
    var canvases: WatermarkCanvases? = nil
    @Environment(AppServices.self) private var model
    @Environment(\.displayScale) private var scale
    @State private var drag: (touch: WatermarkTouch, start: WatermarkPlacement, at: CGPoint)?
    @State private var guides: WatermarkGuides = []
    static let handle: CGFloat = 9
    static let handleReach: Double = 9
    static let rotateDistance: Double = 26
    /// Just outside a corner, off the mark, a press turns it (Photoshop's free transform).
    static let cornerTurnReach: Double = 22
    /// How far past the canvas's edge the pointer's view reaches: a mark at the top edge has its turn handle out there.
    static let pointerMargin: CGFloat = 48
    static let snapTolerance: Double = 8

    private var canvas: CGSize { shown.size }
    private var store: WatermarkStore { model.watermarks }

    private func aspect(_ mark: UUID) -> Double {
        guard let i = store.info(mark), i.w > 0, i.h > 0 else { return 1 }
        return Double(i.w) / Double(i.h)
    }

    /// The canvas `p` is measured on, and its map onto this view's (`shown`'s, top-left origin).
    private func space(_ p: WatermarkPlacement) -> WatermarkStageHit.Space {
        WatermarkStageHit.space(p, shown: shown.size, canvases: canvases, appliesFilm: session.edit.appliesFilm)
    }

    /// `p` as drawn on this view.
    private func local(_ p: WatermarkPlacement) -> WatermarkFrame {
        let sp = space(p)
        return WatermarkGeometry.frame(of: p, canvas: sp.canvas, aspect: aspect(p.mark)).through(sp.toLocal)
    }

    /// Whether the overlay draws `p`'s pixels: a 成片 mark always; a 底片 one only while the page's picture is not of it.
    private func drawsLive(_ p: WatermarkPlacement) -> Bool {
        guard space(p).isBase else { return true }
        return !session.developedBaseMarks.contains(p)
    }

    var body: some View {
        let marks = session.shownMarks
        let picked = session.watermarkSelected ? session.pickedMark : nil
        ZStack(alignment: .topLeading) {
            ForEach(marks.filter { $0.on && drawsLive($0) }) { p in markView(p) }
            ForEach(WatermarkGeometry.lines(for: guides, canvas: canvas), id: \.from.x) { line in
                Path { $0.move(to: line.from); $0.addLine(to: line.to) }
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let picked { handles(picked) }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .overlay { pointer(marks).padding(-Self.pointerMargin) }
        .onDisappear { finish() }
        .position(x: shown.midX, y: shown.midY)
        .onAppear { session.watermarkCanvas = canvas; session.watermarkCanvases = canvases }
        .onChange(of: canvas) { _, now in session.watermarkCanvas = now }
        .onChange(of: canvases) { _, now in session.watermarkCanvases = now }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watermark.stage")
    }

    // MARK: drawing

    @ViewBuilder private func markView(_ p: WatermarkPlacement) -> some View {
        let f = local(p)
        Group {
            if let image = WatermarkOverlayPixels.shared.image(p.mark, width: Int((f.size.width * scale).rounded()), store: store, fill: p.fill) {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: max(f.size.width, 1), height: max(f.size.height, 1))
        .rotationEffect(.radians(f.rotation))
        .opacity(f.opacity)
        .position(f.center)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(store.mark(p.mark)?.name ?? L("Watermark"))
        .accessibilityValue("\(Int((p.size * 100).rounded())) %, \(Int(WatermarkGeometry.degrees(p.rotation).rounded()))°")
        .accessibilityHint(L("Swipe up or down to resize it. Its actions move and rotate it."))
        .accessibilityAdjustableAction { direction in
            nudge(p.id) { WatermarkGeometry.scaled($0, by: direction == .increment ? 1.05 : 1 / 1.05, canvas: space(p).canvas, aspect: aspect(p.mark)) }
        }
        .accessibilityAction(named: L("Move Up")) { nudge(p.id) { move($0, 0, -0.01) } }
        .accessibilityAction(named: L("Move Down")) { nudge(p.id) { move($0, 0, 0.01) } }
        .accessibilityAction(named: L("Move Left")) { nudge(p.id) { move($0, -0.01, 0) } }
        .accessibilityAction(named: L("Move Right")) { nudge(p.id) { move($0, 0.01, 0) } }
        .accessibilityAction(named: L("Rotate Left")) { nudge(p.id) { WatermarkGeometry.rotated($0, by: -5 * .pi / 180) } }
        .accessibilityAction(named: L("Rotate Right")) { nudge(p.id) { WatermarkGeometry.rotated($0, by: 5 * .pi / 180) } }
    }

    private func move(_ p: WatermarkPlacement, _ fx: Double, _ fy: Double) -> WatermarkPlacement {
        let c = space(p).canvas, s = WatermarkGeometry.shortSide(c)
        return WatermarkGeometry.moved(p, by: CGSize(width: fx * s, height: fy * s), canvas: c)
    }

    /// One step: `mutate` on the placement, kept on the canvas and measured from its nearest corner.
    private func nudge(_ id: UUID, _ mutate: @escaping (WatermarkPlacement) -> WatermarkPlacement) {
        guard let p = session.shownMarks.first(where: { $0.id == id }) else { return }
        let next = WatermarkGeometry.settled(mutate(p), canvas: space(p).canvas, aspect: aspect(p.mark))
        session.changeWatermark(id) { $0 = next }
    }

    @ViewBuilder private func handles(_ p: WatermarkPlacement) -> some View {
        let f = local(p)
        let c = f.corners
        let knob = WatermarkGeometry.rotateHandle(of: f, distance: Self.rotateDistance)
        let top = CGPoint(x: (c[0].x + c[1].x) / 2, y: (c[0].y + c[1].y) / 2)
        Path { path in path.addLines(c); path.closeSubpath() }
            .stroke(Theme.accent, lineWidth: 1)
            .allowsHitTesting(false)
        Path { $0.move(to: top); $0.addLine(to: knob) }.stroke(Theme.accent, lineWidth: 1).allowsHitTesting(false)
        ForEach(0..<4, id: \.self) { i in
            Circle().fill(Color.white).overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                .frame(width: Self.handle, height: Self.handle).position(c[i]).allowsHitTesting(false)
        }
        Circle().fill(Theme.accent).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .frame(width: Self.handle + 1, height: Self.handle + 1).position(knob).allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: the pointer

    /// What a press at `p` (this view's points) lands on: the picked mark's handles first, then the marks.
    private func touch(at p: CGPoint, _ marks: [WatermarkPlacement]) -> WatermarkTouch? {
        let selected = session.watermarkSelected ? session.watermarkPick : nil
        return WatermarkStageHit.hit(p, in: marks, selected: selected, shown: canvas, canvases: canvases,
                                     appliesFilm: session.edit.appliesFilm, aspect: aspect)
    }

    /// The pointer, in UIKit (`WatermarkPointer`): the press takes only where `touch` finds a mark or a handle, and no
    /// ancestor's gesture can take it from the stage (the Develop page's own drag, pinch and hold are SwiftUI's, which
    /// on the 26 SDK are no longer simultaneous with a descendant's — `CoexistingDrag`'s header).
    private func pointer(_ marks: [WatermarkPlacement]) -> some View {
        WatermarkPointer(inset: Self.pointerMargin,
                         takes: { p in touch(at: p, marks) != nil },
                         began: { p in
                             guard drag == nil, let touch = touch(at: p, marks),
                                   let start = marks.first(where: { $0.id == touch.placement }) else { return }
                             session.pick(row: .watermark(touch.placement))
                             session.watermarkSelected = true
                             session.beganWatermark()
                             drag = (touch, start, p)
                         },
                         moved: { startLocation, location in dragged(to: location, from: startLocation) },
                         ended: { finish() })
    }

    private func dragged(to point: CGPoint, from startLocation: CGPoint) {
        guard let drag else { return }
        let value = (location: point, startLocation: startLocation,
                     translation: CGSize(width: point.x - startLocation.x, height: point.y - startLocation.y))
        do {
                let a = aspect(drag.start.mark)
                // The gesture in the placement's own canvas: this view's points taken back through its place here.
                let sp = space(drag.start)
                let canvas = sp.canvas, back = sp.toLocal.inverted()
                let location = value.location.applying(back), at = drag.at.applying(back)
                let by = CGSize(width: value.translation.width * back.a + value.translation.height * back.c,
                                height: value.translation.width * back.b + value.translation.height * back.d)
                let tolerance = Self.snapTolerance * Double(sqrt(abs(back.a * back.d - back.b * back.c)))
                var next: WatermarkPlacement
                var held: WatermarkGuides = []
                switch drag.touch.part {
                case .body:
                    next = WatermarkGeometry.moved(drag.start, by: by, canvas: canvas)
                    let s = WatermarkGeometry.snapped(next, canvas: canvas, aspect: a, tolerance: tolerance)
                    next = WatermarkGeometry.kept(s.placement, canvas: canvas, aspect: a)
                    held = s.guides.subtracting(.rightAngle)
                case .handle(let corner):
                    next = WatermarkGeometry.kept(WatermarkGeometry.resized(drag.start, handle: corner, to: location, canvas: canvas, aspect: a),
                                                  canvas: canvas, aspect: a)
                case .rotate:
                    // About the centre, which stays: Shift to 15°, else a right angle held within 3°.
                    let shift = MacModifiers.shift
                    next = WatermarkGeometry.turned(drag.start, canvas: canvas, aspect: a, from: at, to: location, shift: shift)
                    if !shift {
                        let s = WatermarkGeometry.snapped(next, canvas: canvas, aspect: a, tolerance: 0)
                        next.rotation = s.placement.rotation
                    }
                }
                // A guide is drawn on this view: only a 成片 mark's canvas is it.
                if sp.isBase { held = [] }
                if held != guides { guides = held }
                let settled = next
                session.moveWatermark(drag.start.id) { $0 = settled }
        }
    }

    /// The gesture's end — its lift, or its cancellation (`WatermarkPointer` ends on either): the mark kept on its canvas and measured from its
    /// nearest corner, one step.
    private func finish() {
        guards()
        guard let drag else { return }
        self.drag = nil
        if let p = session.shownMarks.first(where: { $0.id == drag.start.id }) {
            let end = WatermarkGeometry.settled(p, canvas: space(p).canvas, aspect: aspect(p.mark))
            session.moveWatermark(p.id) { $0 = end }
        }
        session.endedWatermark()
    }

    private func guards() { if !guides.isEmpty { guides = [] } }
}

/// What a point of the canvas's view lands on among the picked photograph's marks (the stage's own hit-test, for the
/// canvas's click that puts the handles away), and the canvas each mark is measured on.
@MainActor
enum WatermarkStageHit {
    /// A placement's canvas and its map onto the view's (the cut finished picture as shown, top-left origin).
    struct Space {
        var canvas: CGSize
        var toLocal: CGAffineTransform
        var isBase: Bool
    }

    /// 成片 (or 底片 with the film off, N9): the view's own canvas. 底片: the 底片 canvas, through its place.
    static func space(_ p: WatermarkPlacement, shown: CGSize, canvases: WatermarkCanvases?, appliesFilm: Bool) -> Space {
        guard !WatermarkRules.drawnAsFull(p, appliesFilm: appliesFilm), let c = canvases, c.base.width > 0, c.full.width > 0 else {
            return Space(canvas: shown, toLocal: .identity, isBase: false)
        }
        return Space(canvas: c.base, toLocal: c.baseToShown(shown), isBase: true)
    }

    /// The picked mark's handles first, then the marks from the top of the list down; a mark switched off is not there.
    static func hit(_ point: CGPoint, in placements: [WatermarkPlacement], selected: UUID?, shown: CGSize,
                    canvases: WatermarkCanvases?, appliesFilm: Bool, aspect: (UUID) -> Double) -> WatermarkTouch? {
        func local(_ p: WatermarkPlacement) -> WatermarkFrame {
            let sp = space(p, shown: shown, canvases: canvases, appliesFilm: appliesFilm)
            return WatermarkGeometry.frame(of: p, canvas: sp.canvas, aspect: aspect(p.mark)).through(sp.toLocal)
        }
        if let selected, let p = placements.first(where: { $0.id == selected }),
           let part = WatermarkGeometry.hit(point, frame: local(p), handles: true, handleRadius: WatermarkCanvasStage.handleReach,
                                            rotateDistance: WatermarkCanvasStage.rotateDistance,
                                            cornerTurnReach: WatermarkCanvasStage.cornerTurnReach), part != .body {
            return WatermarkTouch(placement: p.id, part: part)
        }
        for p in placements.reversed() where p.on {
            if WatermarkGeometry.hit(point, frame: local(p), handles: false, handleRadius: 0) != nil {
                return WatermarkTouch(placement: p.id, part: .body)
            }
        }
        return nil
    }

    static func hit(_ point: CGPoint, session: OpenFrameSession, shown: CGRect, store: WatermarkStore) -> WatermarkTouch? {
        let local = CGPoint(x: point.x - shown.minX, y: point.y - shown.minY)
        return hit(local, in: session.shownMarks, selected: session.watermarkPick, shown: shown.size,
                   canvases: session.watermarkCanvases, appliesFilm: session.edit.appliesFilm,
                   aspect: { id in store.info(id).map { Double($0.w) / Double(max($0.h, 1)) } ?? 1 })
    }
}


/// The stage's pointer in UIKit: a press that begins on a mark or a handle (`takes`), its drag from where it began, and its
/// end or cancellation — `MaskPress`, which no other recogniser can prevent. A view of SwiftUI's own `DragGesture` under the
/// Develop page's simultaneous ones lost the press to them with a real pointer (the owner, 2026-11-16: the turn handle's
/// dot would not turn). It reaches `inset` points past the stage on every side, and `takes` and the callbacks are in the
/// stage's own points.
struct WatermarkPointer: UIViewRepresentable {
    var inset: CGFloat
    var takes: (CGPoint) -> Bool
    var began: (CGPoint) -> Void
    var moved: (CGPoint, CGPoint) -> Void
    var ended: () -> Void

    func makeUIView(context: Context) -> WatermarkPointerView { WatermarkPointerView() }

    func updateUIView(_ v: WatermarkPointerView, context: Context) {
        v.inset = inset; v.takes = takes; v.began = began; v.moved = moved; v.ended = ended
    }
}

final class WatermarkPointerView: UIView {
    var inset: CGFloat = 0
    var takes: (CGPoint) -> Bool = { _ in false }
    var began: (CGPoint) -> Void = { _ in }
    var moved: (CGPoint, CGPoint) -> Void = { _, _ in }
    var ended: () -> Void = {}
    private var start: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "watermark.pointer"
        isAccessibilityElement = false
        addGestureRecognizer(MaskPress(target: self, action: #selector(press(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func stage(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - inset, y: p.y - inset) }

    /// Only a mark and its handles: any other press is the canvas's own pan and zoom. Decided at the press's own point
    /// (`PressPoint`): the turn dot is 9 points across, and the pointer's area hit-test gave its press to the canvas
    /// round it — the owner's "cannot be rotated by dragging on the canvas" (round 4, 2026-11-16).
    private var pressPoint = PressPoint()
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.insetBy(dx: -pressPoint.reach, dy: -pressPoint.reach).contains(point) else { return false }
        return pressPoint.inside(point, with: event) { [unowned self] p in bounds.contains(p) && takes(stage(p)) }
    }

    @objc private func press(_ g: MaskPress) {
        switch g.state {
        case .began:
            let p = stage(g.location(in: self))
            start = p
            began(p)
        case .changed:
            let (samples, _) = g.take()
            guard let start, let last = samples.last else { return }
            moved(start, stage(last))
        default:
            if let start {
                let (samples, _) = g.take()
                if let last = samples.last { moved(start, stage(last)) }
            }
            start = nil
            ended()
        }
    }
}
