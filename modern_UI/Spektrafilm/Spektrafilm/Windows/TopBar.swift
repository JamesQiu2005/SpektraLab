//  TopBar.swift — the commands and tools at the left, zoom at the right,
//  exactly the design's glyphs: import · export · select · hand · crop  ……
//  before/after · zoom-in · [100 %] · zoom-out · expand.
//
//  The bar spans the window and is the first row of it, so the three window
//  buttons are on its centreline (`Windows/TrafficLights.swift`) and its
//  leading inset clears them (`Theme.Metric.topBarLeading`). It cannot be
//  collapsed: it is the row that keeps the corner of the window (PRD §1).
//
//  **Selection is orange, not grey.** A selected control tints the glyph
//  itself (`Theme.accent`) instead of putting a darker plate behind it. That
//  is Capture One's convention and it is the better one here for a specific
//  reason: this interface is almost entirely greys, so a grey-on-grey plate
//  reads as a rendering artefact at a glance and has to be looked *for*. The
//  one accent colour in the palette exists to be found without looking.

import SwiftUI

struct TopBar: View {
    @Bindable var session: Session

    /// Whether the window is in fullscreen, so the one expand button can show
    /// which way it goes. Read off the window rather than kept as a flag of
    /// our own: fullscreen is also left with ⌃⌘F and by the green button, and
    /// a second copy of that state would be wrong exactly when it mattered.
    @State private var fullScreen = false

    var body: some View {
        HStack(spacing: 0) {
            // Import and export lead the cluster, which is where the drawing
            // puts them and where the user asked for them. They were in the
            // left panel's header until the bar became the row that hosts
            // everything: two always-visible homes for one command is worse
            // than none, so they left the header when they arrived here.
            iconButton("square.and.arrow.down", "Open a folder or image (⌘O)") { session.openPanel() }
                .padding(.leading, Theme.Metric.topBarLeading)
            iconButton("square.and.arrow.up", "Export (⌘E)", disabled: session.selection == nil) {
                session.showExport = true
            }
            .padding(.leading, 22)
            toolButton("cursorarrow", .select, "Select (V)").padding(.leading, 22)
            toolButton("hand.point.up.left", .hand, "Pan (H)").padding(.leading, 22)
            toolButton("crop", .crop, "Crop (C)").padding(.leading, 22)
            if session.working {
                ProgressView().controlSize(.small).scaleEffect(0.7).padding(.leading, 18)
            }
            Text(statusText).font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
                .padding(.leading, 12)
            if !session.serviceReady, session.selection != nil {
                Button("Restart") { session.restartService() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    .padding(.leading, 8)
                    .help("The render service is not running. Start it again.")
            }
            // The empty middle of the bar is the window's drag surface: the
            // titlebar is hidden, and this is where a toolbar would be.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            // "full" once the frame is on the canvas at its own resolution,
            // accented while that render is still on its way. Nothing here is
            // about zoom any more: the canvas settles at the frame's own size
            // after every edit, whatever the zoom.
            if session.fullPending || session.renderer.showsFullRender {
                Text(session.renderer.showsFullRender ? "full" : "full…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(session.fullPending ? Theme.accent : Theme.dim)
                    .help(session.renderer.showsFullRender
                          ? "The canvas is showing this frame at its own resolution."
                          : "Rendering this frame at its own resolution…")
            }
            // Before/after, immediately left of the zoom controls — the
            // reference layout's position
            // (`reference_layout/before_and_after/`). It belongs with zoom
            // rather than with the tools because it changes how the canvas is
            // *displayed*, not what a click on it does.
            Button { session.comparing.toggle() } label: {
                BeforeAfterIcon(color: session.comparing ? Theme.accent : Theme.text)
                    .frame(width: 20, height: 16)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canCompare)
            .opacity(session.canCompare ? 1 : 0.4)
            .help("Before / after split — drag the line on the canvas (⌥\\)")
            .padding(.trailing, 6)
            iconButton("plus.magnifyingglass", "Zoom in (⌘+)", disabled: session.zoomLocked) { session.zoomStep(1) }
            zoomPill.padding(.horizontal, 12)
                .disabled(session.zoomLocked)
                .opacity(session.zoomLocked ? 0.4 : 1)
            iconButton("minus.magnifyingglass", "Zoom out (⌘−)", disabled: session.zoomLocked) { session.zoomStep(-1) }
            // One button, both ways (PRD §1). Fit and fullscreen were only
            // ever two buttons because fullscreen had nowhere else to be —
            // they are not two halves of one idea. Fit keeps its ⌘0, its View
            // menu item and its entry in the pill's own menu, which is what
            // the drawing's single diagonal-arrows glyph assumes.
            iconButton(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                       fullScreen ? "Leave full screen (⌃⌘F)" : "Full screen (⌃⌘F)") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
        }
        .frame(height: Theme.Metric.topBarHeight)
        .panelCard()
        .onAppear { fullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            fullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            fullScreen = false
        }
    }

    private var statusText: String {
        // The service cannot report real progress: a render call does not
        // return until it is finished and the transport is single-flight, so
        // there is nothing to poll. Elapsed time is what is actually known.
        guard session.working else { return session.status }
        return String(format: "%@ · %.1f s", session.status, session.workSeconds)
    }

    private func toolButton(_ name: String, _ tool: CanvasTool, _ help: String) -> some View {
        Button { session.tool = tool } label: {
            Image(systemName: name)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(session.tool == tool ? Theme.accent : Theme.text.opacity(0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// `disabled` is for the controls the crop tool locks: greyed out, so the
    /// toolbar says *why* nothing happens, rather than a live-looking button
    /// that quietly does nothing (`Theme.text` at 0.4 is the same weight the
    /// before/after button uses when it has nothing to compare).
    private func iconButton(_ name: String, _ help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: Theme.Metric.toolIcon, weight: .regular))
                .foregroundStyle(disabled ? Theme.text.opacity(0.4) : Theme.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var zoomPill: some View {
        Menu {
            Button("Fit") { session.zoomToFit() }
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { session.zoomTo(fraction: f) }
            }
        } label: {
            // zoomPercent is 0 until an image is on the canvas.
            Text(session.zoomPercent == 0 ? "—"
                 : session.isFit ? "Fit · \(session.zoomPercent) %" : "\(session.zoomPercent) %")
                .font(Theme.Font.pill)
                .foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.zoomPill.width, height: Theme.Metric.zoomPill.height)
                .background(Theme.well, in: Capsule())
                .overlay(Capsule().stroke(Theme.text, lineWidth: 1))
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
