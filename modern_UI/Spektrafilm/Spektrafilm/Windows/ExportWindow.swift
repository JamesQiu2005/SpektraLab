//  ExportWindow.swift — the export page as its own window.
//
//  It used to be a `.sheet` over the editor. RFC-018 §6 makes it a window for
//  a reason that is in the RFC rather than in this file: the page exists to
//  show a recipe's *own* picture, and the canvas behind it is a proof of the
//  *working* space rather than of this recipe's — so the two are worth looking
//  at side by side,
//  which a modal sheet forbids. Its chrome is a window's, too
//  (`reference_layout/Export_Page/export_page.svg` draws traffic lights on the
//  bar and no way back to an editor), so a window is what it is.
//
//  Two things differ from `EditorWindow`, both from that drawing: the cards
//  are **flush to the window's edges** (they start at x 0 of a 2981.27-unit
//  window, so there is no outer margin at all), and the window buttons
//  therefore sit `topBarHeight / 2` from the top rather than below one. The
//  buttons are AppKit's own and this moves them onto the bar's centreline the
//  same way the editor does — `Windows/TrafficLights.swift` is the mechanism
//  and the comment there is the reasoning.
//
//  **The buttons are placed, not drawn, and that is settled rather than
//  unresolved.** The drawing embeds a screenshot of them (an `<image>` whose
//  href points at the designer's own Desktop) instead of drawing the three
//  circles, so there is nothing in it to reproduce; the user's answer is that
//  AppKit's real buttons at the drawing's leading inset are what belong there.
//  They are the only part of this window the window server draws, which is why
//  no offscreen capture can see them — `Tools/capture-live.sh` is the check,
//  and `Theme.Metric.Export.trafficLightLeading` is the inset.

import SwiftUI

/// The scene's id, in one place: the editor opens the window by it
/// (`EditorWindow.consumeExportRequest`) and the app declares it.
enum ExportWindowID {
    static let scene = "export"
}

struct ExportWindow: View {
    @Bindable var session: Session
    /// See `ExportPage.startIn` — the snapshot harness is the only caller that
    /// passes anything but the default.
    var startIn: ExportPage.Mode = .viewer

    var body: some View {
        ExportPage(session: session, startIn: startIn)
            .frame(minWidth: minWidth, minHeight: Theme.Metric.minWindow.height)
            .background(Theme.ground)
            // Above the page, so the buttons are re-placed whatever the page
            // does and the observer outlives it. See `TrafficLightAlignment`
            // for why the attachment point matters.
            .background(
                TrafficLightAlignment(centreY: Theme.Metric.Export.topBarHeight / 2,
                                      leading: Theme.Metric.Export.trafficLightLeading)
                    .frame(width: 0, height: 0)
            )
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }

    /// The drawing's own window. Its centre pane is the part that gives, so
    /// this is the size at which the capture can be laid over the drawing.
    /// The side cards move inside it now (`Controls/PanelResize.swift`), which
    /// does not change this: a narrower window is a narrower proof, and the
    /// cards have their own bounds.
    private var minWidth: CGFloat { Theme.Metric.Export.width }
}
