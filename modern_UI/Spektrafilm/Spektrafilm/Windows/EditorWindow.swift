//  EditorWindow.swift — the window's three regions, exactly as the
//  2026-09-17 drawing has them:
//
//     ┌─────────┬──────────────────────────┬─────────┐
//     │ header  │      ▁▁▁▁ bar ▁▁▁▁       │ header  │
//     ├─────────┤                          ├─────────┤
//     │  left   │          canvas          │  right  │
//     │  rail   │                          │  rail   │
//     │  254    ├──────────────────────────┤   288   │
//     │         │        filmstrip         │         │
//     └─────────┴──────────────────────────┴─────────┘
//
//  Flush: no outer margin, no gutter, no corner radius. Where the previous
//  design left a 6 pt trench of ground between four floating cards, this one
//  puts a **1 pt hairline** (`Hairline`, `#b5b5b6`) — and only where two
//  surfaces of the *same* colour meet. Between a rail and the canvas the
//  ground colour is the separator, so the drawing draws no line there; beside
//  the filmstrip, where rail and strip are both `Theme.card`, it draws two
//  (`line x1="508.8"` and `x1="3263.6"`, y 1895…2160).
//
//  The bar no longer spans the window. It is a rounded pill floating on the
//  ground over the canvas (`Theme.Metric.barStrip`), so it belongs to the
//  centre column and grows with it.
//
//  **The window buttons did not move.** They sit at `y 19`, which is the
//  centre of a rail header *and* very nearly the centre of the bar — one row,
//  two occupants. So folding the left rail does not relocate them; it only
//  changes which view reserves the space (`Theme.Metric.trafficLightClearance`
//  in the header, `barLeadingWithButtons` on the bar).
//
//  Folding is the two `sidebar.left` / `sidebar.right` buttons now, not the
//  hover tabs on the canvas edge (PRD: "moved to become sidebar.left and
//  sidebar.right … these two buttons must also remain on the screen at any
//  given time"). Each lives at the far end of its own rail's header and moves
//  onto the bar when that rail is folded, which is the only place left that is
//  always on screen. The **bottom** tab is untouched — "except the bottom
//  gallery view remains unchanged".

import SwiftUI
import UniformTypeIdentifiers

struct EditorWindow: View {
    @Bindable var session: Session
    /// Opening the export page's scene. A `Window` scene is addressed by its
    /// id from anywhere with the environment, which is how this window hands
    /// the request on without either of them owning the other.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // One layout. The window used to switch to a `BrowseView` worklist
        // whenever a folder was open and no frame chosen; that page is gone
        // and the filmstrip is the only list. Opening a folder still develops
        // nothing until a frame is picked — see `Session.unloadSelection()`.
        printLayout
        .background(Theme.ground)
        // Above the browse/print switch, so the buttons are re-placed in
        // either state and the observer outlives every card that can fold.
        // See `TrafficLightAlignment` for why that matters.
        .background(
            TrafficLightAlignment(centreY: Theme.Metric.trafficLightCentreY,
                                  leading: Theme.Metric.trafficLightLeading)
                .frame(width: 0, height: 0)
        )
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers {
                    if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
                }
                if !urls.isEmpty { session.open(urls: urls) }
            }
            return true
        }
        // The export page is a window of its own (RFC-018 §6): with a
        // per-destination transform the canvas is a Display P3 proof of a
        // different thing, so the two are worth looking at side by side, which
        // a modal sheet over the editor forbids. `showExport` is unchanged and
        // still means "an export was asked for" — it is now consumed here
        // rather than presented, so ⌘E, the editor's menu item and the
        // toolbar's button all keep working without knowing the page moved.
        .onChange(of: session.showExport) { _, wanted in
            guard wanted else { return }
            session.showExport = false
            openWindow(id: ExportWindowID.scene)
        }
    }

    /// The Print state: the four cards, exactly as drawn.
    ///
    /// `session.topCollapsed` is deliberately not read here. The bar is not a
    /// card that folds any more (PRD §1): it is the row that hosts the window
    /// buttons, so it has to be present for the window to have a corner. The
    /// stored property stays for the session's state and for a launch that
    /// reads it back, but no view consults it.
    /// The panels' widths, which are the user's now (PRD: "the collapse tabs
    /// should be non-fixed, and there should be one narrowest and widest for
    /// both").
    ///
    /// `@State` and not on `Session`: a panel width is chrome, and `Session` is
    /// the document — its `uiKey` namespace is for state that has to come back
    /// with a frame. `PanelWidthStore` writes its own keys, so the lifetime
    /// here only has to be the window's, which is what `@State` is.
    @State private var leftWidth = PanelWidthStore(name: "editor.left",
                                                   range: Theme.Metric.leftPanelRange)
    @State private var rightWidth = PanelWidthStore(name: "editor.right",
                                                    range: Theme.Metric.rightPanelRange)

    private var printLayout: some View {
        HStack(spacing: 0) {
            if !session.leftCollapsed {
                LeftPanel(session: session)
                    .frame(width: session.snapshotPanelWidths ? leftWidth.range.standard
                                                              : leftWidth.width)
                    // The grip is an **overlay**, not a sibling: a 6 pt view
                    // in the HStack would push the canvas 6 pt right on a
                    // fresh install and move every snapshot. It sits on the
                    // rail's own trailing edge, where the drawing has nothing
                    // but the colour change.
                    .overlay(alignment: .trailing) {
                        PanelResizeHandle(side: .trailingEdge, range: leftWidth.range,
                                          width: $leftWidth.width)
                    }
                    .transition(.move(edge: .leading))
            }
            centreColumn
            if !session.rightCollapsed {
                RightPanel(session: session)
                    .frame(width: session.snapshotPanelWidths ? rightWidth.range.standard
                                                              : rightWidth.width)
                    .overlay(alignment: .leading) {
                        PanelResizeHandle(side: .leadingEdge, range: rightWidth.range,
                                          width: $rightWidth.width)
                    }
                    // The colour balance triangle sizes its wheels from the
                    // rail, and the rail is the user's.
                    .environment(\.colorBalanceWidth,
                                 ColorBalanceLayout.interior(panelWidth: rightWidth.width))
                    .transition(.move(edge: .trailing))
            }
        }
        .transition(.opacity)
    }

    /// Bar strip, canvas, filmstrip — the column between the two rails.
    ///
    /// The strip at the top is ground with the bar floating in it, rather than
    /// the bar being a row of its own: that is what the drawing shows (its
    /// `.st13` ground rectangle runs from y 0 and the bar is drawn on top of
    /// it) and it is the only arrangement in which a maximised frame is never
    /// partly under a toolbar.
    private var centreColumn: some View {
        VStack(spacing: 0) {
            TopBar(session: session)
                .frame(height: Theme.Metric.topBarHeight)
                .padding(.horizontal, Theme.Metric.barInset)
                .padding(.vertical, Theme.Metric.barTop)
                .background(Theme.ground)
            CanvasArea(session: session)
            if !session.filmstripCollapsed {
                HStack(spacing: 0) {
                    // Only against a rail that is there. With one folded, the
                    // strip runs to the window's edge and a line at the edge
                    // is a line with nothing on the other side of it.
                    if !session.leftCollapsed { VerticalHairline() }
                    Filmstrip(session: session)
                    if !session.rightCollapsed { VerticalHairline() }
                }
                .frame(height: Theme.Metric.filmstripHeight)
                .transition(.move(edge: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The centre: the Metal view (or, in snapshot mode, an offscreen render of
/// it) with the four collapse tabs on its edges.
struct CanvasArea: View {
    @Bindable var session: Session
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        ZStack {
            if snapshotMode {
                SnapshotCanvas(session: session)
            } else {
                MetalCanvasView(host: session)
            }
            // Handles, thirds grid and the straighten line. The shader does
            // the dimming; this does the lines, which want to stay crisp.
            if session.tool == .crop && !snapshotMode {
                CropOverlay(session: session)
            } else if FeatureFlags.masks && !snapshotMode && session.selectedMask != nil {
                MaskOverlay(session: session)
            }
            // Above both: the split's handle is a control, and it is the only
            // overlay that takes the mouse.
            //
            // Drawn in snapshot mode too, unlike the other two. The shader
            // puts the split at `ouv.x`, this puts the line at a view point,
            // and the two arithmetics are written in different files — so a
            // capture where the line does not sit on the seam is the only
            // thing that catches them disagreeing.
            CompareOverlay(session: session)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Everything in this stack is positioned in **view coordinates**, and
        // a view coordinate at high zoom is off the canvas: the crop frame's
        // corners, its grips and the mask handles all ran past the canvas edge
        // and were painted over the side panels and the toolbar. SwiftUI does
        // not clip by default; the canvas is the one place that must.
        //
        // Not the Metal view's problem — a `CAMetalLayer` cannot draw outside
        // itself (which is why a zoomed picture looks *cut off* at the canvas
        // edge rather than spilling, and why the crop tool's view is fitted to
        // the picture: `Renderer.fitRotatedPhoto`). This is the overlay half.
        .clipped()
        // **One edge, not three.** The left and right tabs are gone: the
        // drawing folds a rail with the `sidebar.left` / `sidebar.right`
        // button in that rail's own header, and a second control that does
        // the same thing is a control that will disagree with the first about
        // being there. The bottom one is untouched — "except the bottom
        // gallery view remains unchanged" — and is still the pill that
        // appears when the pointer comes near the canvas's lower edge.
        .overlay(alignment: .bottom) { HoverEdgeTab(edge: .bottom, collapsed: $session.filmstripCollapsed) }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: CanvasBadges.spacing) {
                ForEach(session.canvasBadges, id: \.self) { badge($0) }
            }
            .padding(CanvasBadges.inset)
        }
        // Contract §2's "a visible error rather than a blank canvas". Centred
        // and opaque, not a corner badge: the app is not going to render, and
        // a caption the user has to go looking for would leave them staring at
        // an empty canvas deciding the app is broken — which it is, but not in
        // a way they can act on without being told.
        .overlay {
            if let why = session.serviceBlocked {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Theme.accent)
                    Text("The render service cannot be used")
                        .font(Theme.Font.sectionTitle).foregroundStyle(Theme.text)
                    Text(why)
                        .font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Restart the render service") { session.restartService() }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                .padding(20)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let w = session.stockWarning {
                Text(w).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(2)
                    .padding(6).background(Theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(8)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.card.opacity(0.8), in: Capsule())
    }
}

/// Snapshot stand-in: the renderer draws offscreen into an image at the
/// canvas's real size, so a capture shows the real render path.
///
/// It takes over `Renderer.needsDraw`, which in the running app is the
/// `MTKView`'s `scheduleDraw`. That is the whole point: the previous version
/// re-rendered on a hand-written list of properties — `previewSoft`,
/// `histogram`, `zoomPercent`, `detailTier`, `detailPending` — and so was
/// blind to every state that invalidates the canvas without touching one of
/// them. Masks were the case that found it: `--mask` captured an image with
/// no mask in it, and the feature was fine. Anything the renderer considers a
/// reason to redraw is now a reason to re-capture, with no list to maintain.
struct SnapshotCanvas: View {
    @Bindable var session: Session
    @State private var image: CGImage?
    @State private var revision = 0
    @State private var rendering = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image { Image(decorative: image, scale: 2).resizable() } else { Theme.ground }
            }
            .onAppear { session.renderer.needsDraw = { revision &+= 1 } }
            .onChange(of: geo.size, initial: true) { _, size in render(size) }
            .onChange(of: revision) { _, _ in render(geo.size) }
        }
    }

    private func render(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        // A render can invalidate the canvas again (the detail tier swaps a
        // texture in), and that arrives here as another revision. One level
        // is enough; re-entering would be a loop.
        guard !rendering else { return }
        rendering = true
        defer { rendering = false }
        session.renderer.viewport.backingScale = 2
        session.renderer.viewport.resize(viewport: size)
        session.viewportChanged()
        image = session.renderer.renderOffscreen(size: size, backingScale: 2)?.makeCGImage()
    }
}

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotMode: Bool { get { self[SnapshotModeKey.self] } set { self[SnapshotModeKey.self] = newValue } }
}

/// The window's drag handle. `.windowStyle(.hiddenTitleBar)` removes the
/// titlebar a window is normally dragged by, and the strip reserved for the
/// traffic lights is SwiftUI content, which would otherwise eat the gesture.
/// `performDrag` hands it to the window server the way the real titlebar does.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
