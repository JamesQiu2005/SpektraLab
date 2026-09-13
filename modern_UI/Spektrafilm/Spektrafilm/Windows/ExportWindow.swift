//  ExportWindow.swift — the export page as its own window.
//
//  It used to be a `.sheet` over the editor. RFC-018 §6 makes it a window for
//  a reason that is in the RFC rather than in this file: the page exists to
//  show a recipe's *own* picture, and the canvas behind it is now a Display P3
//  proof of a different thing — so the two are worth looking at side by side,
//  which a modal sheet forbids. Its chrome is a window's, too
//  (`reference_layout/Export_Page/Reference_Screenshot.jpg` draws traffic
//  lights on the bar and no way back to an editor), so a window is what it is.
//
//  Two things differ from `EditorWindow`, both measured off that reference:
//  the cards are **flush to the window's edges** (it insets them below the bar
//  and not at all at the sides), and the window buttons therefore sit
//  `topBarHeight / 2` from the top rather than below an outer margin. The
//  buttons are AppKit's own and this moves them onto the bar's centreline the
//  same way the editor does — `Windows/TrafficLights.swift` is the mechanism
//  and the comment there is the reasoning.

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
                TrafficLightAlignment(centreY: Theme.Metric.topBarHeight / 2,
                                      leading: Theme.Metric.trafficLightLeading)
                    .frame(width: 0, height: 0)
            )
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }

    /// Enough for the two side cards and a picture between them, at the
    /// reference's own proportions: 404 + 286 of panel plus a centre that is
    /// still wider than either panel.
    private var minWidth: CGFloat {
        Theme.Metric.Export.leftWidth + Theme.Metric.Export.rightWidth + 380
    }
}
