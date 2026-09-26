//  TopBar.swift — the canvas's own bar.
//
//  **v4 (2026-09-26):** ◧ · import · export · select · crop · [Process]
//  [Original] …… before/after · [100 %] · zoom-out · zoom-in · ◨. Process and
//  Original came up from the Print section, import and export from the left
//  rail's header, and both sidebar toggles live here permanently, which keeps
//  them on screen whichever rail is folded. The hand and full-screen glyphs are
//  not drawn; H, Space-drag and ⌃⌘F still do both. The notes below are v3's
//  and still describe the bar's geometry.
//
//
//  **v3 (2026-09-18) flattened it and re-ordered it.** It was a rounded pill
//  floating on ground; it is now a plain rectangle filling the centre
//  column's top, flush with both rails and with the window's top edge, 38 pt
//  tall like the rail headers beside it (`Theme.Metric.topBarHeight`, which
//  *is* `panelHeaderHeight`) and closed by a hairline drawn by
//  `EditorWindow`. It still belongs to the centre column and is as wide as
//  the picture is.
//
//  Two orders changed, both from v3's measured glyph centres:
//
//  - **Zoom out before zoom in**, with the percentage plate ahead of both:
//    `… Before/After · 1405.64 % · 1478.38 − · 1541.06 + · 1601.37 ⤢`. The
//    old bar had `+` then the pill then `−`, which reads as a stepper
//    straddling its own readout; v3's reads left-to-right as one cluster with
//    the value at its head.
//  - **The percentage plate is 41 pt, not 105.** It holds `100 %` and nothing
//    else, so `Fit · 100 %` does not fit in it. Fit keeps its ⌘0, its View
//    menu item and its place in this pill's own menu; what it loses is the
//    prefix in the readout, and a 105 pt plate sized for a string that is
//    only sometimes there was 64 pt of permanent air.
//
//  The drawing's three tools are exactly the three that were here — import
//  and export live on the left rail's header, because opening a file is not a
//  thing you do to the picture.
//
//  **Two things the bar hosts only while a rail is folded.** The window
//  buttons sit on the rail header's centreline, which is also the bar's, so
//  when the left rail goes the bar is what has to leave room for them
//  (`barLeadingWithButtons`). And each `sidebar` toggle moves here from its
//  own rail's header for the same reason: the PRD requires both to be on
//  screen at every moment, and a folded rail has no header to hold one.
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

    var body: some View {
        HStack(spacing: 0) {
            // The leading edge is either the bar's own padding or the room the
            // window buttons need — they are on this row whenever the left
            // rail is not (Windows/TrafficLights.swift).
            Spacer()
                .frame(width: session.leftCollapsed ? Theme.Metric.barLeadingWithButtons
                                                    : Theme.Metric.barPadding - 14)
            // v4's order: the rail toggle, the file, the tools, then the one
            // action that prints the frame and the view that compares it.
            SidebarToggle(edge: .leading, collapsed: $session.leftCollapsed)
            iconButton("square.and.arrow.down", L(.helpOpen) + " (⌘O)") { session.openPanel() }
                .padding(.leading, Theme.Metric.barClusterGap)
            iconButton("square.and.arrow.up", L(.helpExport) + " (⌘E)", disabled: session.selection == nil) {
                session.showExport = true
            }
            .padding(.leading, Theme.Metric.barIconGap)
            // **Pan is H and the hand, not a button.** v4 draws two tools;
            // the hand stays one key away (View ▸ Hand, H) and a drag with
            // Space held on the canvas.
            toolButton("cursorarrow", .select, L(.helpSelect) + " (V)")
                .padding(.leading, Theme.Metric.barClusterGap)
            toolButton("crop", .crop, "Crop (C)").padding(.leading, Theme.Metric.barIconGap)
            action(L(.actionSolve),
                   help: "Auto-exposure and the enlarger filter pack for this paper — print this frame.",
                   active: session.canSolve, enabled: session.canSolve) { session.solveNow() }
                .padding(.leading, Theme.Metric.barActionLeading)
            action(L(.actionOriginal),
                   help: session.showingOriginal
                       ? "Showing the original — press to go back to the developed print."
                       : "Show the RAW as Apple's decoder renders it, before any film simulation (⎵ does the same, while held).",
                   active: session.showingOriginal, enabled: session.selection != nil) {
                session.toggledOriginal(!session.showingOriginal)
            }
            .padding(.leading, Theme.Metric.actionGap)
            if session.working {
                ProgressView().controlSize(.small).scaleEffect(0.7).padding(.leading, 18)
            }
            Text(statusText).font(Theme.Font.caption).foregroundStyle(Theme.dim).lineLimit(1)
                .padding(.leading, 12)
            if !session.serviceReady, session.selection != nil {
                Button(L(.actionRestart)) { session.restartService() }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                    .padding(.leading, 8)
                    .help("The render service is not running. Start it again.")
            }
            // The empty middle of the bar is the window's drag surface: the
            // titlebar is hidden, and this is where a toolbar would be.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            // Before/after, immediately left of the zoom controls. It belongs
            // with zoom rather than with the tools because it changes how the
            // canvas is *displayed*, not what a click on it does.
            Button { session.comparing.toggle() } label: {
                BeforeAfterIcon(color: session.comparing ? Theme.accent : Theme.text)
                    .frame(width: Theme.Metric.beforeAfterIcon.width,
                           height: Theme.Metric.beforeAfterIcon.height)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!session.canCompare)
            .opacity(session.canCompare ? 1 : 0.4)
            .help(L(.helpBeforeAfter) + " (⌥\\)")
            .padding(.trailing, Theme.Metric.beforeAfterGap)
            // The value, then out, then in. Full screen is ⌃⌘F and the
            // window's own green button; v4 draws no glyph for it.
            zoomPill.rowEnabled(!session.zoomLocked)
            iconButton("minus.magnifyingglass", L(.helpZoomOut) + " (⌘−)", disabled: session.zoomLocked) { session.zoomStep(-1) }
                .padding(.leading, Theme.Metric.zoomGap)
            iconButton("plus.magnifyingglass", L(.helpZoomIn) + " (⌘+)", disabled: session.zoomLocked) { session.zoomStep(1) }
            SidebarToggle(edge: .trailing, collapsed: $session.rightCollapsed)
                .padding(.leading, Theme.Metric.barClusterGap)
            Spacer().frame(width: Theme.Metric.barPadding - 14)
        }
        .frame(height: Theme.Metric.topBarHeight)
        .barCard()
        // The whole bar is a window drag surface behind its controls: with the
        // titlebar hidden this row *is* where a titlebar would be.
        .background(WindowDragHandle())
    }

    /// Process / Original: v3's two capsules, moved up from the Print section
    /// by v4. **No plate**: Process is an accent outline whenever it can run;
    /// Original is accent while it is showing and muted otherwise. A muted
    /// Original is *not* a disabled one — `rowEnabled` carries that.
    private func action(_ title: String, help: String, active: Bool, enabled: Bool,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(Theme.Font.action)
                .foregroundStyle(active ? Theme.accent : Theme.Ink.tertiary)
                .lineLimit(1)
                .frame(width: Theme.Metric.actionSize.width, height: Theme.Metric.actionSize.height)
                .overlay(RoundedRectangle(cornerRadius: Theme.Metric.actionRadius, style: .continuous)
                    .stroke(active ? Theme.accent : Theme.Ink.tertiary, lineWidth: 1))
                .frame(height: Theme.Metric.actionHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
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
            Button(L(.helpFit)) { session.zoomToFit() }
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { f in
                Button("\(Int(f * 100)) %") { session.zoomTo(fraction: f) }
            }
        } label: {
            // zoomPercent is 0 until an image is on the canvas.
            //
            // **No `Fit ·` prefix.** v3's plate is 41.29 pt and the prefix
            // does not fit in it. Whether the canvas is fitted is still worth
            // knowing, so it is said in the tooltip and by the check mark in
            // this menu rather than by a string that would either truncate
            // the number or size the plate for a case that is usually absent.
            Text(session.zoomPercent == 0 ? "—" : "\(session.zoomPercent) %")
                .font(Theme.Font.zoomValue)
                .foregroundStyle(Theme.text)
                .frame(width: Theme.Metric.zoomPill.width, height: Theme.Metric.zoomPill.height)
                // No outline. The previous drawing stroked this capsule in
                // white; the new one draws it as a plain `.st13` pill, like
                // every other pill in the interface.
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(session.isFit ? "Fitted to the window — \(session.zoomPercent) % (⌘0)"
                            : "Zoom — \(session.zoomPercent) %")
    }
}
