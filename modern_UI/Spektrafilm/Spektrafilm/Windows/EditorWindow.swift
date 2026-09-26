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
//  puts a **1 pt hairline** (`Hairline`, `#b5b6b6`).
//
//  **v3 (2026-09-18) changed two things in this file.**
//
//  The rail dividers run the **full window height** — v3 draws them at
//  x 254.41 and x 1631.93 from the top edge to the bottom, canvas included.
//  The older rule said a line was needed only beside the filmstrip, where
//  rail and strip are the same colour, and that between rail and canvas the
//  ground colour was itself the separator. v3 overrules it, and the reason is
//  visible in the drawing: with the tool bar now `card`-coloured and flush,
//  the top row is one surface across all three columns, so without a divider
//  the rails have no edge at all for their first 38 pt. Both lines are
//  **overlays** on the rails, not siblings in the `HStack` — a sibling would
//  push the canvas 1 pt and make every recorded column width wrong.
//
//  And **the bar stopped floating**. It is a plain 38 pt rectangle filling
//  the centre column's top, flush with both rails and with the window's top
//  edge — `barTop`, `barInset` and `barRadius` are all 0 — and its height is
//  the rail header's, so the three regions share one top row. There is no
//  ground strip behind it any more.
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
                    // v3's full-height divider, on the rail's own trailing
                    // edge. Above the grip in the overlay order so the line is
                    // never drawn over by it; the grip still takes the mouse,
                    // because a 1 pt rectangle is not a hit target.
                    .overlay(alignment: .trailing) {
                        PanelResizeHandle(side: .trailingEdge, range: leftWidth.range,
                                          width: $leftWidth.width)
                    }
                    .overlay(alignment: .trailing) { VerticalHairline().allowsHitTesting(false) }
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
                    .overlay(alignment: .leading) { VerticalHairline().allowsHitTesting(false) }
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
    /// **v3: the bar is a row of its own**, closed by a hairline, rather than
    /// a pill floating in a strip of ground. A maximised frame therefore
    /// starts directly under a surface instead of under a pill with ground
    /// showing round it, and the hairline under the bar is the same wall the
    /// rails' sections are separated by — the top row reads as a room, not as
    /// a shelf.
    private var centreColumn: some View {
        VStack(spacing: 0) {
            TopBar(session: session)
                .frame(height: Theme.Metric.topBarHeight)
                // `barInset` and `barTop` are 0 in v3, so these two are
                // no-ops — kept so that a drawing which floats the bar again
                // is three token values rather than a re-plumbing of this
                // stack. The background is the bar's own `card`, not the
                // ground: there is nothing behind it to show through.
                .padding(.horizontal, Theme.Metric.barInset)
                .padding(.vertical, Theme.Metric.barTop)
            Hairline()
            CanvasArea(session: session)
            if !session.filmstripCollapsed {
                Hairline()
                // **No vertical hairlines here any more.** They used to be
                // the filmstrip's own, drawn only where rail and strip share
                // a colour; v3's dividers run the whole window height and are
                // drawn once by each rail, so a second pair here would be a
                // 1 pt line drawn twice at the same x — visible as a slightly
                // heavier segment beside the strip, which is exactly the kind
                // of seam a full-height divider exists to remove.
                Filmstrip(session: session)
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
            // The finished picture's histogram heads the stack: it describes
            // the pixels on this canvas, as the tier badge under it does, so
            // it moved here from the right rail. No ground and no grid -- it
            // sits on the surround like the text below it. Not a hit target.
            VStack(alignment: .trailing, spacing: CanvasBadges.spacing) {
                if session.selection != nil {
                    HistogramPlot(bins: session.histogram, channels: [.rgb],
                                  showGrid: false, showGround: false)
                        .frame(width: CanvasBadges.histogram.width,
                               height: CanvasBadges.histogram.height)
                        // A soft black haze, not a plate: blurred past its
                        // own edge so there is no outline to read, and dark
                        // enough that the lines hold over a white print.
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.45))
                                .padding(-6)
                                .blur(radius: 10)
                        }
                }
                ForEach(session.canvasBadges, id: \.self) { badge($0) }
            }
            .padding(CanvasBadges.inset)
            .allowsHitTesting(false)
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

    /// Plain text, no capsule. The shadow is not a plate: it is what keeps a
    /// white word readable where the picture under the corner is white too.
    private func badge(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text)
            .frame(height: CanvasBadges.height)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
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
