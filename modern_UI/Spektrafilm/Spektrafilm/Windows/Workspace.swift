//  Workspace.swift — Library | Edit: which of the window's surfaces is on
//  screen, and the switch that changes it (2.0).
//
//  The Library was a window of its own, reached only from the menus, and the
//  owner could not find a way between it and the frame being edited
//  (2026-10-19). Capture One's answer is a switch at the head of the tools,
//  and that is what this is: under the left rail's name, above its first
//  section — Navigator in Edit, the source in the Library — drawn as the
//  right rail's Pre-Dev | Post-Dev switch is, so the window's two switches
//  read as one family. The Library now replaces the canvas and both rails,
//  as the 2.0 design drew it (PRD-v2.0.0 §16 Q2: a mode, not a window); the
//  rails keep their widths, so the switch does not move when it is used.
//
//  More surfaces are a case each: the switch lays out whatever `allCases` is.

import SwiftUI

enum Workspace: String, CaseIterable, Identifiable, Sendable {
    /// Where frames come from: the catalog, its collections and filters.
    case library
    /// The open frame: film and print on the left, the parameters on the right.
    case edit

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .library: L("Library", zh: "图库")
        case .edit: L("Edit", zh: "编辑")
        }
    }
}

/// The switch itself. A side that has nothing to show greys, with the reason.
struct WorkspaceSwitch: View {
    @Bindable var session: Session
    /// Whether the window has a Library to switch to (a test's window may not).
    var hasLibrary = true

    static var accessibilityName: String { L("Workspace", zh: "工作区") }

    var body: some View {
        SegmentedSwitch(options: Workspace.allCases,
                        selection: $session.workspace,
                        title: { $0.title },
                        enabled: { $0 != .library || hasLibrary },
                        accessibilityName: Self.accessibilityName)
    }
}

/// The top of a left rail in either surface: the rail's name after the
/// window buttons' clearance, then the switch, then the rule that closes the
/// header. One view in both, so the switch is at the same place in both.
struct WorkspaceRailHeader: View {
    let title: String
    @Bindable var session: Session
    var hasLibrary = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The three window buttons live here (Windows/TrafficLights.swift).
                // They are *placed* in window coordinates, so this is a
                // reservation and not a container.
                Spacer().frame(width: Theme.Metric.trafficLightClearance)
                Text(title)
                    .font(Theme.Font.railTitle)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: Theme.Metric.panelHeaderHeight)
            // The header row is the window's drag surface, as a sidebar header
            // is in Xcode.
            .background(WindowDragHandle())
            // The right rail's switch row: the same insets and the same air
            // under it, so the window's two switches share one row.
            WorkspaceSwitch(session: session, hasLibrary: hasLibrary)
                .padding(.leading, Theme.Metric.rowInset)
                .padding(.trailing, Theme.Metric.panelHeaderTrailing)
                .padding(.bottom, 8)
        }
    }
}
