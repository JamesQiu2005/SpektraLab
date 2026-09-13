//  EditorWindow.swift — the four cards on the ground, exactly as drawn:
//
//     ┌─────────────────── top bar ───────────────────────┐
//     │ ┌left┐  ┌──────── canvas ────────┐  ┌right┐        │
//     │ │328 │  │                       │  │ 286 │        │
//     │ │    │  └───── filmstrip ───────┘  │     │        │
//     │ └────┘                            └─────┘        │
//     └──────────────────────────────────────────────────┘
//
//  The top bar is the window's first row and spans all of it — it is not the
//  canvas column's first row any more. That is what gives the three window
//  buttons a home that never folds (`Windows/TrafficLights.swift`), and it is
//  the drawing's own arrangement (`PRD/new_frontend_top_layout.png`).
//
//  Outer margins 9/7 pt, gutters 6 pt, radius 15 pt. The side panels are
//  fixed width (the drawing's), so a wider window gives the canvas the extra
//  room and a narrower one takes it from the canvas — never from a panel.
//  Collapsing a card removes it from the HStack/VStack, so the canvas grows
//  into its place; the small tabs on the canvas edges bring it back. The top
//  bar is the one card that does not collapse at all.

import SwiftUI
import UniformTypeIdentifiers

struct EditorWindow: View {
    @Bindable var session: Session
    /// Opening the export page's scene. A `Window` scene is addressed by its
    /// id from anywhere with the environment, which is how this window hands
    /// the request on without either of them owning the other.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if session.browsing && !session.frames.isEmpty {
                BrowseView(session: session)
                    .padding(.horizontal, Theme.Metric.outerX)
                    .padding(.vertical, Theme.Metric.outerY)
                    .transition(.opacity)
            } else {
                printLayout
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.browsing)
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
        VStack(spacing: Theme.Metric.gutter) {
            TopBar(session: session)
            HStack(spacing: Theme.Metric.gutter) {
                if !session.leftCollapsed {
                    LeftPanel(session: session)
                        .frame(width: leftWidth.width)
                        // The grip is an **overlay**, not a sibling, and that
                        // is what keeps the standard width pixel-identical to
                        // the drawing: a 6 pt view in the HStack would push the
                        // canvas 6 pt right on a fresh install and move every
                        // snapshot. It sits inside the panel's own outer margin
                        // — the 9 pt of card before the first well — so it
                        // covers nothing that was drawn.
                        .overlay(alignment: .trailing) {
                            PanelResizeHandle(side: .trailingEdge, range: leftWidth.range,
                                              width: $leftWidth.width)
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                VStack(spacing: Theme.Metric.gutter) {
                    CanvasArea(session: session)
                    if !session.filmstripCollapsed {
                        Filmstrip(session: session)
                            .frame(height: Theme.Metric.filmstripHeight)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !session.rightCollapsed {
                    RightPanel(session: session)
                        .frame(width: rightWidth.width)
                        .overlay(alignment: .leading) {
                            PanelResizeHandle(side: .leadingEdge, range: rightWidth.range,
                                              width: $rightWidth.width)
                        }
                        // The colour balance triangle sizes its wheels from the
                        // well it is in, and the well comes from the panel —
                        // `ColorBalanceLayout.assumedWidth` is only what it
                        // falls back to when nobody says.
                        .environment(\.colorBalanceWidth,
                                     ColorBalanceLayout.interior(panelWidth: rightWidth.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, Theme.Metric.outerX)
        .padding(.vertical, Theme.Metric.outerY)
        .transition(.opacity)
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
        // Three edges, not four: the top bar is not a card that folds, so
        // there is no top tab to bring it back (PRD §1).
        .overlay(alignment: .leading) { HoverEdgeTab(edge: .leading, collapsed: $session.leftCollapsed) }
        .overlay(alignment: .trailing) { HoverEdgeTab(edge: .trailing, collapsed: $session.rightCollapsed) }
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
