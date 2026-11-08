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
        ZStack {
            Theme.background.ignoresSafeArea()
            if let session, let frame = session.frame {
                DevelopWorkspace(session: session, frame: frame, back: back, opening: opening, stockStrip: stockStrip)
            }
        }
        // One session per page: it holds what the controls want against what
        // the picture shows, and it leaves nothing queued when the page goes.
        .onAppear {
            if session == nil {
                stockStrip = model.stockPreviews.strip(for: frameID)
                session = model.session(for: frameID)
                session?.enter()
                // A snapshot's own: the pair's darkroom on the layer its drawing shows.
                if let layer = opening.layer { session?.pick(layer) }
            }
            // With an engine that makes pictures the canvas develops once as the
            // page opens, so the next edit is a reprint from its negative.
            session?.open()
        }
        .onChange(of: session?.developed?.stamp) { _, stamp in
            // Photos recovery/open may have left cards waiting for the page's decode.
            if stamp != nil { stockStrip?.refresh() }
        }
        .onChange(of: session?.frame?.original) { _, _ in stockStrip?.refresh() }
        .onChange(of: session?.frame?.picture) { _, _ in stockStrip?.refresh() }
        .onChange(of: session?.frame?.pair) { _, _ in stockStrip?.refresh() }
        // The page is gone (a cover over it is not a disappearance): it lets
        // go of the session, which closes when nothing else holds it.
        .onDisappear {
            stockStrip?.leave(); stockStrip = nil
            session?.leave()
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
