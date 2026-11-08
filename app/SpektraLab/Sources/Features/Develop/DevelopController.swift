//  DevelopController.swift — the photo and develop routes: one page with a filmstrip.
//
//  PAGES.md §3 (2026-10-20): the photo viewer *is* the editor's page with the column put away, and
//  Develop brings the column in on the same frame and the same filmstrip. So both routes — `.photo`
//  and `.develop` — open this host, which keeps:
//
//  - **the frames** of the Library as it was showing them (its collection and sort), and the open one;
//  - **whether the column is in** (`developing`) and, on the column layout, whether it is put away (⌘B);
//  - **the page's state across a change of frame**: the step, the tool, the open tile, the darkroom
//    page go with the person to the next frame (`opening`).
//
//  What it shows: viewing, `ViewerPane` — picture, filmstrip, the viewer's bar; developing, the
//  develop page in the column.
//
//  **One session per page** (`DevelopPane`): a frame changed from the filmstrip or the arrow keys is a
//  new `DevelopPane` (`.id(frame)`), so the last frame's session leaves and the next one's enters.
//  Viewing holds no session and asks for no render: the picture is the frame's kept develop.

import SwiftUI

/// `.photo(id)`: the host in its viewing state.
struct PhotoRoute: View {
    let id: LibraryFrame.ID
    let back: BackWay

    var body: some View {
        DevelopWindowContent(id: id, developing: false, opening: { var o = DevelopOpening(); o.back = back; return o }())
    }
}

/// `.develop(id)`: the host developing.
struct DevelopRoute: View {
    let id: LibraryFrame.ID
    let opening: DevelopOpening

    var body: some View {
        DevelopWindowContent(id: id, developing: true, opening: opening)
    }
}

/// What the window's photo and develop pages share across a change of frame or of window.
@MainActor @Observable
final class DevelopController {
    /// The frames the filmstrip shows, in the Library's order, and the open one.
    private(set) var browser: LibraryBrowser
    /// The column is in: the develop page, with its session. Viewing holds none.
    var developing: Bool
    /// The column is put away on the column layout (⌘B); the picture takes the window.
    var columnHidden = false
    /// The filmstrip is collapsed (its button on the picture side's bar); the picture takes its room.
    var stripHidden = false
    /// How the next develop page opens: where ‹ goes, and the state carried from the last frame.
    private(set) var opening: DevelopOpening
    /// the
    /// frames chosen in the filmstrip beside the open one — ⌘-click, ⇧-click, a drag across it, as Capture
    /// One's filmstrip — which Export takes as one batch (`exportIDs`). Empty: the open frame alone. A plain
    /// click, or any other change of the open frame, lets it go. Nothing sets it on a reference device or a window.
    var chosen: Set<LibraryFrame.ID> = [] {
        didSet {
            #if DEBUG
            if !chosen.isEmpty { Self.front = self }   // the strip last chosen in is the one in front
            #endif
        }
    }
    /// Where a ⇧-click's run begins: the last frame clicked.
    var anchor: LibraryFrame.ID?

    #if DEBUG
    /// The host on screen, for the debug driver's `export.strip` (`MacDriver`): the picture bar's Export.
    static weak var front: DevelopController?
    #endif

    init(id: LibraryFrame.ID, developing: Bool, opening: DevelopOpening) {
        browser = LibraryBrowser(selectedID: id)
        self.developing = developing
        self.opening = opening
    }

    var current: LibraryFrame.ID? { browser.selectedID }
    var ids: [LibraryFrame.ID] { browser.ids }
    /// "3 of 14": the open frame's place in the strip.
    var place: (index: Int, count: Int)? {
        guard let id = current, let i = browser.ids.firstIndex(of: id) else { return nil }
        return (i, browser.ids.count)
    }

    func start(_ ids: [LibraryFrame.ID]) {
        // A frame the Library is not showing (a filter changed under it) is still the one opened.
        if let id = current, !ids.contains(id) { browser.start([id]) } else { browser.start(ids) }
    }

    /// The strip has its frames: the window has been wide since the host opened (`joinStrip`).
    var started: Bool { browser.started }

    func reconcile(_ remaining: Set<LibraryFrame.ID>) { browser.reconcile(remaining) }

    /// The frame `id` opens; on the develop page, with `carrying` the page's state as it stands.
    ///
    /// `strip`: the frames the visit walks, when the caller knows them better than the strip it started
    /// with — the Mac's page, whose browser is the window's (`MainWindowLayout`) and whose strip was the
    /// carry of whatever was chosen when a mode was pressed. A frame the strip does not hold would
    /// otherwise be silently refused by `LibraryBrowser.select`, leaving the browser showing one picture
    /// and the canvas another (the owner, 2026-10-26: "it selects it but the canvas keeps showing the old
    /// picture" — the strip held the one carried frame, `ids=1`).
    func select(_ id: LibraryFrame.ID, carrying: DevelopOpening? = nil, strip: [LibraryFrame.ID]? = nil) {
        chosen = []
        anchor = id
        guard id != current else { return }
        if let carrying {
            var o = carrying
            o.back = opening.back
            opening = o
        }
        if let strip, !browser.ids.contains(id) { browser.restart(strip, selecting: id) }
        browser.select(id)
    }

    /// What Export takes: the frames chosen, in the strip's order; with fewer than two, the open frame
    /// (one chosen is no batch: the strip draws it as it draws none).
    func exportIDs(_ open: LibraryFrame.ID) -> [LibraryFrame.ID] {
        chosen.count < 2 ? [open] : browser.ids.filter { chosen.contains($0) }
    }

    /// ⌘-click: the frame added to the chosen or taken from them (the open one is among them from the first).
    func toggle(_ id: LibraryFrame.ID) {
        if chosen.isEmpty, let current { chosen = [current] }
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
        anchor = id
    }

    /// ⇧-click: the run from the anchor (or the open frame) to this one; with ⌘ too, added to what is chosen.
    func extend(to id: LibraryFrame.ID, adding: Bool) {
        let ids = browser.ids
        guard let from = anchor ?? current, let i = ids.firstIndex(of: from), let j = ids.firstIndex(of: id) else {
            toggle(id); return
        }
        let run = Set(ids[min(i, j)...max(i, j)])
        chosen = adding ? chosen.union(run) : run
    }

    /// The frame `step` places along the strip from the open one; nil past either end.
    func neighbour(_ step: Int) -> LibraryFrame.ID? {
        guard let (i, n) = place, i + step >= 0, i + step < n else { return nil }
        return browser.ids[i + step]
    }

    /// Viewing → developing, on the same frame (the viewer's Develop).
    func develop() {
        var o = DevelopOpening()
        o.back = opening.back
        opening = o
        columnHidden = false
        developing = true
    }
}

/// The window's photo and develop page (see the top of this file).
struct DevelopWindowContent: View {
    @State private var pad: DevelopController
    #if SPK_ENGINE
    @Environment(AppServices.self) private var model
    @State private var host = UUID()
    #endif
    @Environment(WindowShape.self) private var window
    @Environment(FrameCatalog.self) private var library
    @Environment(AppRouter.self) private var router
    @AppStorage(FrameCatalog.oldestFirstKey) private var oldestFirst = false

    init(id: LibraryFrame.ID, developing: Bool, opening: DevelopOpening) {
        _pad = State(initialValue: DevelopController(id: id, developing: developing, opening: opening))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let id = pad.current {
                if pad.developing {
                    // A new frame is a new page: its own session, the last one's left.
                    DevelopPane(frameID: id, opening: pad.opening).id(id)
                } else {
                    ViewerPane(frameID: id)
                }
            }
        }
        .environment(pad)
        .onAppear {
            joinStrip()
            #if DEBUG
            DevelopController.front = pad
            #endif
        }
        #if SPK_ENGINE
        // the frame on the develop page and its strip,
        // for its neighbours' full renders made ahead while it is inspected (`MacRenderCache`).
        .onChange(of: pad.developing ? pad.current : nil, initial: true) { [pad] _, id in
            if !model.isSnapshot { model.renderCache.developing(id, strip: { pad.ids }, host: host) }
        }
        .onChange(of: pad.ids) { [pad] _, _ in
            if !model.isSnapshot, pad.developing { model.renderCache.developing(pad.current, strip: { pad.ids }, host: host) }
        }
        .onDisappear { if !model.isSnapshot { model.renderCache.developing(nil, strip: { [] }, host: host) } }
        #endif
        #if SPK_ENGINE && DEBUG
        // `--render-check` (Sources/Mac/Render/MacRenderCheck.swift): a step along the strip, as ← → do.
        .onReceive(NotificationCenter.default.publisher(for: .spkCheckStep)) { note in
            if let step = note.object as? Int, let id = pad.neighbour(step) { pad.select(id) }
        }
        #endif
        .onChange(of: pad.current) { _, id in if let id, pad.started { library.selectedID = id } }
        // The Library's selection moved while viewing: the strip follows it. A strip never started
        // follows nothing.
        .onChange(of: pad.started ? library.selectedID : nil) { _, id in
            guard let id, !pad.developing, pad.ids.contains(id) else { return }
            pad.select(id)
        }
        .onChange(of: pad.started ? library.frames.map(\.id) : []) { _, ids in
            guard pad.started else { return }
            pad.reconcile(Set(ids))
            // The page goes back by itself when its last frame goes.
            if pad.current == nil { router.back() }
        }
    }

    /// The strip takes the Library's frames in its order, once, and the frame in front becomes the
    /// Library's selection.
    private func joinStrip() {
        // a carry from the Mac library (its selection,
        // a collection) is the strip, not the whole app library.
        if !pad.started, let carried = MacDevelopCarry.shared.strip(opening: pad.current) { pad.start(carried) }
        if !pad.started { pad.start(library.grid(oldestFirst: oldestFirst).flatMap(\.frames).map(\.id)) }
        if !pad.developing, let id = library.selectedID, id != pad.current, pad.ids.contains(id) { pad.select(id) }
        if let id = pad.current { library.selectedID = id }
    }
}

// MARK: - the filmstrip

/// The Library's frames along the foot of the picture side (PAGES.md §3, the desktop's): the open
/// frame in the white frame, a developing frame with its ring, the open frame kept in view. Its
/// tiles are the Library's own (`LibraryTile`): thumbnails, never the engine.
struct BrowserFilmstrip: View {
    let ids: [LibraryFrame.ID]
    let current: LibraryFrame.ID
    /// the strip as tall as it was dragged
    /// (`PaneDividers`), its tiles growing with it, the margins round them kept; nil is today's height.
    var height: CGFloat? = nil
    let select: (LibraryFrame.ID) -> Void
    @Environment(FrameCatalog.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The host's, for the Mac's multi-selection (`DevelopController.chosen`).
    @Environment(DevelopController.self) fileprivate var pad: DevelopController?
    /// A drag across the strip: where it began and is now (content space), and what was chosen before it.
    @State private var sweep: (start: CGFloat, now: CGFloat, base: Set<LibraryFrame.ID>, flags: UIKeyModifierFlags)?
    /// The strip's visible width: the empty space after the last tile is the strip's too.
    @State private var width: CGFloat = 0

    static let height: CGFloat = 96
    static let tile: CGFloat = 64

    private var stripHeight: CGFloat { height ?? Self.height }
    private var tileSide: CGFloat { Self.tile + stripHeight - Self.height }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.spacing) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        if let frame = library.frame(id) {
                            tile(frame, index: index)
                        }
                    }
                }
                .padding(.horizontal, Self.margin)
                .frame(height: stripHeight, alignment: .center)
                .modifier(MacStripChoosing(strip: self, sweep: $sweep, width: width))
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, id in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
            // A window resized under it: the open frame is brought back into view.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                width = w
                proxy.scrollTo(current, anchor: .center)
            }
        }
        .frame(height: stripHeight)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.wall).frame(height: 1) }
        .accessibilityIdentifier("pad.filmstrip")
    }
}

extension BrowserFilmstrip {
    static let spacing: CGFloat = 6
    static let margin: CGFloat = 16

    /// The chosen, when there are several, each in the white frame (the owner, 2026-10-25: no tick, "the
    /// white frame around a selected tile is enough"); else the open frame in it, as it always was.
    fileprivate func mark(_ id: LibraryFrame.ID) -> LibraryTile.Mark {
        let chosen = pad?.chosen ?? []
        if chosen.count > 1 { return chosen.contains(id) ? .selected : .none }
        return id == current ? .selected : .none
    }

    /// The Mac's marks, as thin as the Mac library grid's selection frame (`MacGridCell`: 1.5 pt; the owner,
    /// 2026-10-25: "the white frame, and the bottom accent line can all be narrower, similar to the white
    /// frame width in library and the left panel"); the tile's own 3 pt frame is the window's. Among several
    /// chosen, the open frame — the picture above — has a line of the accent under its tile, so it is told
    /// from the rest of the batch.
    @ViewBuilder private func macMark(_ id: LibraryFrame.ID) -> some View {
        if mark(id) == .selected {
            Rectangle().strokeBorder(Theme.selectionFrame, lineWidth: Self.macStroke).allowsHitTesting(false)
        }
        if (pad?.chosen.count ?? 0) > 1, id == current {
            Rectangle().fill(Theme.accent).frame(height: Self.macStroke)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .offset(y: 4).allowsHitTesting(false)
        }
    }

    static let macStroke: CGFloat = 1.5

    @ViewBuilder fileprivate func tile(_ frame: LibraryFrame, index: Int) -> some View {
        let id = frame.id
        let picked = (pad?.chosen.count ?? 0) > 1 && pad?.chosen.contains(id) == true
        // Capture One's filmstrip: a click opens the frame and the choice goes back to it; ⌘ and ⇧ choose.
        LibraryTile(frame: frame, mark: .none)
            .frame(width: tileSide, height: tileSide)
            .overlay { macMark(id) }
            .modifier(MacClick { flags in click(id, flags) })
            .id(id)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(frame.fileName)
            .accessibilityAddTraits(id == current || picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(id) }
            .accessibilityIdentifier("pad.filmstrip.\(index)")
    }

    private func click(_ id: LibraryFrame.ID, _ flags: UIKeyModifierFlags) {
        guard let pad else { select(id); return }
        if flags.contains(.shift) { pad.extend(to: id, adding: flags.contains(.command)) }
        else if flags.contains(.command) { pad.toggle(id) }
        else {
            pad.chosen = []
            pad.anchor = id
            select(id)
        }
    }

    /// The tile under `x` (content space), if `x` is on one.
    fileprivate func index(at x: CGFloat) -> Int? {
        let pitch = tileSide + Self.spacing
        let i = Int(((x - Self.margin) / pitch).rounded(.down))
        guard i >= 0, i < ids.count, x - Self.margin - CGFloat(i) * pitch <= tileSide else { return nil }
        return i
    }

    /// The tiles a sweep from `a` to `b` (content space) passes over.
    fileprivate func ids(from a: CGFloat, to b: CGFloat) -> [LibraryFrame.ID] {
        let pitch = tileSide + Self.spacing
        let lo = min(a, b), hi = max(a, b)
        let i0 = max(0, Int(((lo - Self.margin) / pitch).rounded(.down)))
        let i1 = min(ids.count - 1, Int(((hi - Self.margin) / pitch).rounded(.down)))
        guard i0 <= i1 else { return [] }
        return (i0...i1).filter { i in
            let left = Self.margin + CGFloat(i) * pitch
            return hi >= left && lo <= left + tileSide
        }.map { ids[$0] }
    }

    /// The tile's band, top to bottom, in the strip's height.
    fileprivate var band: ClosedRange<CGFloat> {
        let top = (stripHeight - tileSide) / 2
        return top...(top + tileSide)
    }
}

/// The Mac filmstrip's choosing beyond a click (the owner, 2026-10-25): a drag across the strip chooses
/// the frames it passes over (⌘ toggles them, ⇧ adds them, neither replaces: Finder's marquee, as the
/// library's grid has it); a click on the strip's empty space — between tiles, after the last — lets the
/// choice go back to the open frame. A tile's own click is its own (`MacClick`); a drag begun on a tile is
/// a sweep too, the tiles filling the strip's height.
private struct MacStripChoosing: ViewModifier {
    let strip: BrowserFilmstrip
    @Binding var sweep: (start: CGFloat, now: CGFloat, base: Set<LibraryFrame.ID>, flags: UIKeyModifierFlags)?
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(minWidth: width, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(MacPointClickRecognizer { p in
                guard let pad = strip.pad else { return }
                if strip.index(at: p.x) == nil || !strip.band.contains(p.y) { pad.chosen = [] }
            })
            .gesture(MacMarqueeRecognizer { state, point, flags in drive(state, point, flags) })
            .overlay(alignment: .topLeading) {
                if let s = sweep {
                    let lo = min(s.start, s.now), hi = max(s.start, s.now), b = strip.band
                    Rectangle().fill(Theme.accent.opacity(0.12))
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1))
                        .frame(width: max(hi - lo, 1), height: b.upperBound - b.lowerBound)
                        .offset(x: lo, y: b.lowerBound)
                        .allowsHitTesting(false)
                }
            }
    }

    private func drive(_ state: UIGestureRecognizer.State, _ point: (now: CGPoint, start: CGPoint), _ flags: UIKeyModifierFlags) {
        guard let pad = strip.pad else { return }
        switch state {
        case .began:
            sweep = (point.start.x, point.now.x, flags.isEmpty ? [] : pad.chosen, flags)
        case .changed:
            guard var s = sweep else { return }
            s.now = point.now.x
            sweep = s
            let swept = Set(strip.ids(from: s.start, to: s.now))
            var base = s.base
            if base.isEmpty, !s.flags.isEmpty, let current = pad.current { base = [current] }
            pad.chosen = s.flags.contains(.command) ? base.symmetricDifference(swept)
                : s.flags.contains(.shift) ? base.union(swept) : swept
            if let last = strip.ids(from: s.start, to: s.now).last { pad.anchor = last }
        default:
            sweep = nil
        }
    }
}

// MARK: - keys

/// The keys of PAGES.md §6 that both window pages answer: ← → for the frame, and what the page adds.
/// Buttons drawn nowhere, so a hardware keyboard reaches them and a finger never does.
struct HiddenKeyEquivalent: View {
    let title: String
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    var enabled = true
    let action: () -> Void

    var body: some View {
        // The Mac's keys share one registration and menu path, including shifted and modified keys.
        // A plain key is the window's own command (`MacKeyAnchor`, the Mac's shell): Catalyst drops a
        // `keyboardShortcut` without a modifier — measured 2026-10-26, ← → and the digits arrived at
        // `.onKeyPress` and never reached their buttons, while ⌘-shortcuts fired. Registered on every
        // pass rather than on first appearance, because what the key acts on (the rows, the choice) is
        // the page's state as it stands.
        MacKeyRegistration(specs: [MacKeySpec(key, modifiers: modifiers)], title: title, enabled: enabled, action: action)
            .frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
