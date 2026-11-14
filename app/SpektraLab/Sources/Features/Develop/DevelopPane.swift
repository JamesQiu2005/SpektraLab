//  DevelopPane.swift — the develop page's host: one `OpenFrameSession` per page, and how it opens.
//
//  **There is no live render** (RFC-036 §4). Every control goes through the
//  frame's `OpenFrameSession`: `began` when a finger lands, `change` as the
//  value moves (the number beside the control is live), `ended` when it lifts.
//  The session decides when a render is asked for — print-side edits as
//  coalesced reprints while the finger moves, film-side ones when it rests or
//  lifts. The picture is always the last finished develop, and the line under
//  it says what is catching up. The page is `DevelopWorkspace`, placed in the
//  column (`PadDevelopPage.swift`).

import QuartzCore
import SwiftUI

/// How the page opens. A running app opens it on Film with nothing folded;
/// the snapshot harness draws each drawing's page in its own state.
struct DevelopOpening {
    var surface: DevelopSurface = .develop
    var step: DevelopStep = .filmAndPaper
    var editTool: EditTool = .adjust
    /// Adjust's tile open in place of its strip, and what it shows (the snapshot harness's).
    var adjustTool: AdjustTool? = nil
    var adjustState: AdjustState? = nil
    var darkroom: DarkroomPage? = nil
    /// Where the top bar's ‹ goes and what it says: the page under this one
    /// as the router had it when the page was pushed (`Routes.swift`). The
    /// drawings' pages are over the Library.
    var back = BackWay.library
    var tab: DevelopTab = .film
    /// Print's tool and Effects' page under pro-control; Scene's tool.
    var enlargerTool = EnlargerTool.colour
    var effectsPage = EffectsPage.grain
    var sceneTool = SceneTool.whiteBalance
    /// Film & Paper's Decode: the part its chips show.
    var decodeTool = DecodeTool.exposure
    /// Basic Effects opened on Scene Placement's own page.
    var placementOpen = false
    var compare = false
    /// The panel folded away; the Latitude card folded to its head.
    var panelFolded = false
    var latitudeFolded = false
    var zoom: CGFloat = 1
    /// The film or the paper its tab's row of cards opens on, where that is
    /// not the chosen card's place: the cards a row keeps past its fourth,
    /// for a snapshot to draw.
    var cardsOpenOn: String? = nil
    /// The line under the picture, fixed: the drawings show a develop at a
    /// particular moment (58 %), which a running page only passes through.
    var status: DevelopStatus? = nil

    /// A half-frame pair's darkroom opened on a layer (design/pair v2): nil
    /// leaves the one the pair's session starts on.
    var layer: HalfFramePair.Layer? = nil

    static func tab(_ tab: DevelopTab, status: DevelopStatus? = nil) -> DevelopOpening {
        DevelopOpening(tab: tab, status: status)
    }

    /// A pair's darkroom, on `layer` and `tab`.
    static func pair(_ layer: HalfFramePair.Layer, tab: DevelopTab) -> DevelopOpening {
        var opening = DevelopOpening(tab: tab)
        opening.layer = layer
        return opening
    }
}

struct DevelopPane: View {
    let frameID: LibraryFrame.ID
    var opening = DevelopOpening()

    @Environment(AppServices.self) private var model
    @State private var session: OpenFrameSession?
    @State private var stockStrip: StockStrip?
    /// Where ‹ goes, as it was when the page was pushed: kept, since the path
    /// no longer holds this page while it is being popped.
    @State private var back: BackWay

    init(frameID: LibraryFrame.ID, opening: DevelopOpening = DevelopOpening()) {
        self.frameID = frameID
        self.opening = opening
        _back = State(initialValue: opening.back)
    }

    var body: some View {
        #if DEBUG && SPK_ENGINE
        let _ = TransitionMarks.mark("pane.body")
        #endif
        ZStack {
            Theme.background.ignoresSafeArea()
            if let session, let frame = session.frame {
                DevelopWorkspace(session: session, frame: frame, back: back, opening: opening, stockStrip: stockStrip)
            }
        }
        // One session per frame: it holds what the controls want against what the picture shows, and it leaves
        // nothing queued when the page goes or moves to another frame.
        .onAppear {
            #if DEBUG && SPK_ENGINE
            TransitionMarks.mark("pane.appear>")
            defer { TransitionMarks.mark("pane.appear<") }
            #endif
            if session == nil { take(frameID) }
            // With an engine that makes pictures the canvas develops once as the
            // page opens, so the next edit is a reprint from its negative.
            session?.open()
            // 主体 · 背景 · 人's finder on this frame, a clone's found masks adopted, the missing ones marked (M1c).
            if let session { MaskFinding.shared.pageOpened(session) }
        }
        // The session's edit, develop and frame watched in a view of their own (`OwnReads`): read in this body, every
        // step and every develop re-made the page under it, its canvas and column (2.4.0 A2).
        .background { OwnReads { watches } }
        // Another frame on the same page (2.4.0 A2b, `DevelopController.made`): the next frame's session taken, then
        // the last one's let go — the order a page made again had (the next page appeared before the last one went),
        // the letting go and the next develop once the next frame is on the screen.
        .onChange(of: frameID) { _, next in switchSession(to: next) }
        // The page is gone (a cover over it is not a disappearance): it lets
        // go of the session, which closes when nothing else holds it.
        .onDisappear {
            #if DEBUG && SPK_ENGINE
            TransitionMarks.mark("pane.gone>")
            defer { TransitionMarks.mark("pane.gone<") }
            #endif
            Self.release(session, stockStrip, model: model)
            stockStrip = nil
            session = nil
        }
        // The frame's own picture, small and off the main thread, before
        // anything asks for it: the Film Edge flow's guide and Original draw
        // the undeveloped picture, which no page has decoded while the library
        // was showing the frame's develop. Until its own size is decoded the
        // guide then has this one to draw (`ThumbnailStore.cachedAny`), not
        // its ground.
        .task(id: frameID) {
            guard let picture = model.library.frame(frameID)?.picture else { return }
            _ = await ThumbnailStore.shared.image(picture, maxPixel: 768)
        }
    }

    /// The frame's session and its stock strip taken up: the page holds them while it shows the frame.
    private func take(_ id: LibraryFrame.ID) {
        stockStrip = model.stockPreviews.strip(for: id)
        session = model.session(for: id)
        session?.enter()
        // A snapshot's own: the pair's darkroom on the layer its drawing shows.
        if let layer = opening.layer { session?.pick(layer) }
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("pane.taken")
        #endif
    }

    /// A frame's session and strip let go: the strip's cards, the finder's focus (its found masks' folder adopted and
    /// swept, `FoundMaskKeeping`), the session (it closes when nothing else holds it).
    private static func release(_ session: OpenFrameSession?, _ strip: StockStrip?, model: AppServices) {
        strip?.leave()
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("release.strip")
        #endif
        if let session { MaskFinding.shared.pageClosed(session, model: model) }
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("release.finder")
        #endif
        session?.leave()
    }

    /// Another frame on this page: its session in at once — the page draws the frame's kept picture with it — and the
    /// finder on it; once that frame is on the screen, its develop asked and the last frame's session let go.
    ///
    /// Asked in the same turn, the develop's submission wrote the queue the page's status line reads, inside SwiftUI's
    /// update (this `onChange`), and the graph was flushed again under it before the first frame of the next picture
    /// could be committed: ~30 ms of the switch's main thread, by `sample` (2.4.0 A2b). A frame later it costs the
    /// picture nothing, and the develop, hundreds of ms on a RAW, starts ~10 ms later.
    private func switchSession(to id: LibraryFrame.ID) {
        #if DEBUG && SPK_ENGINE
        TransitionMarks.mark("pane.switch>")
        defer { TransitionMarks.mark("pane.switch<") }
        #endif
        guard session?.frameID != id else { return }
        let last = session, lastStrip = stockStrip
        // Drawn as it is, not animated to (`switchFrame`'s transaction).
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { take(id) }
        let next = session, model = model
        // The finder on the next frame at once (it only starts a task), so the last one's close finds it moved on.
        if let next { MaskFinding.shared.pageOpened(next) }
        // Two frames: the display link's first callback after the commit may come before the frame is on the screen.
        AfterFrame.run(after: 2) {
            // Still this page's (not left since, which `leave` says by letting go of it): its develop asked.
            if let next, next.isHeld { next.open() }
            Self.release(last, lastStrip, model: model)
            #if DEBUG && SPK_ENGINE
            TransitionMarks.mark("pane.followed")
            #endif
        }
    }

    /// What follows the session's edit, its develop and its frame: the finder's focus, the found masks, the stock cards.
    private var watches: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            // The decode's geometry moved under the masks (镜头校正 switched, another corrector or distortion,
            // `OpenFrameSession.lensWord`): a find under way is dropped and the next looks again. Another frame on the
            // same page (A2b) is not that: its finder was focused as its session was taken (`switchSession`).
            .onChange(of: session.map { LensGeometry(frame: $0.frameID, word: "\($0.edit.decode.lensCorrection)" + $0.lensWord) }) { was, now in
                if was?.frame == now?.frame, let session { MaskFinding.shared.refocus(session) }
            }
            // An act or an Undo: which found masks have no file now.
            .onChange(of: session?.edit.layers) { _, _ in if let session { MaskFinding.shared.layersChanged(session) } }
            .onChange(of: session?.developed?.stamp) { _, stamp in
                // Photos recovery/open may have left cards waiting for the page's decode.
                if stamp != nil { stockStrip?.refresh() }
            }
            .onChange(of: session?.frame?.original) { _, _ in stockStrip?.refresh() }
            .onChange(of: session?.frame?.picture) { _, _ in stockStrip?.refresh() }
            .onChange(of: session?.frame?.pair) { _, _ in stockStrip?.refresh() }
    }
}

/// What the masks' geometry hangs on, for one frame: 镜头校正 and who corrects (`DevelopPane.watches`).
private struct LensGeometry: Equatable {
    let frame: LibraryFrame.ID?
    let word: String
}

extension OpenFrameSession {
    /// A control's binding: it reads the session's edit and writes through
    /// `change`, so the session sees every value the finger passes.
    func binding<T: Equatable>(_ path: WritableKeyPath<FrameEdit, T>) -> Binding<T> {
        Binding(get: { self.edit[keyPath: path] }, set: { v in self.change { $0[keyPath: path] = v } })
    }

    /// A ruler's `onEditingChanged`: the finger landing on a control of
    /// `layer`, and lifting.
    func editing(_ layer: ParamLayer) -> (Bool) -> Void {
        { [weak self] down in
            guard let self else { return }
            if down { self.began(layer) } else { self.ended() }
        }
    }
}

/// Work that waits for the next display frame: run at the display link's next callback, after the commit of the
/// turn that asked (the frame it carries is the render server's to show from then on).
@MainActor
enum AfterFrame {
    private final class Tick: NSObject {
        private var work: (() -> Void)?
        private var link: CADisplayLink?
        private var me: Tick?
        init(_ work: @escaping () -> Void) { self.work = work }
        func start() {
            me = self
            let l = CADisplayLink(target: self, selector: #selector(fired(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        @objc func fired(_ l: CADisplayLink) {
            link?.invalidate(); link = nil
            let w = work
            work = nil; me = nil
            MainActor.assumeIsolated { w?() }
        }
    }

    /// `work` after `frames` display frames: the first frame of a change on the screen before it starts.
    static func run(after frames: Int = 1, _ work: @escaping () -> Void) {
        guard frames > 1 else { Tick(work).start(); return }
        Tick { run(after: frames - 1, work) }.start()
    }
}
