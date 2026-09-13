//  LeftPanel.swift — the Layer 1 column: import/export, then the five
//  sections in the design's order. To add a section: write a view in
//  Panels/Sections and add one line to `sections`. Nothing else changes.

import SwiftUI

struct LeftPanel: View {
    @Bindable var session: Session

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    FilmProfileSection(session: session)
                    PrintProfileSection(session: session)
                    CameraSection(session: session)
                    CropSection(session: session)
                    FeaturesSection(session: session)
                    EnlargerSection(session: session)
                }
                .padding(.top, 4)
            }
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Import and export are **not** here any more: they lead the tool
            // cluster on the top bar, which is the drawing's arrangement and
            // where the user asked for them. A command in two always-visible
            // places is a command that will disagree with itself about being
            // enabled, so it lives in one. What is left of this row is what it
            // was always for — the window's drag surface, the way a sidebar
            // header is in Xcode, and the card's own menu at the far end.
            //
            // And the window buttons are no longer aligned to this row's
            // centreline either: they sit on the top bar now, which cannot be
            // collapsed (Windows/TrafficLights.swift). `EditorWindow` owns the
            // one `TrafficLightAlignment` in the app.
            Spacer()
            Menu {
                Button("Reset Layer 1 (film, paper, camera, enlarger)") { session.resetParams() }
                Button("Reset Layer 2 (adjustments)") { session.resetAdjustments() }
                Divider()
                Button("Reveal sidecar in Finder") {
                    guard let u = session.selection else { return }
                    // The settings live in the app's store now, not beside the
                    // image, so this can be asked for a frame that has never
                    // been saved and therefore has no file. Show the folder in
                    // that case rather than selecting nothing, which is what
                    // `activateFileViewerSelecting` does with a path that is
                    // not there — a menu item that silently does nothing.
                    let sidecar = Sidecar.url(for: u)
                    if FileManager.default.fileExists(atPath: sidecar.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([sidecar])
                    } else {
                        NSWorkspace.shared.open(Sidecar.storeDirectory)
                    }
                }
            } label: {
                VerticalEllipsis().frame(width: 3, height: 15).padding(10).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .padding(.trailing, 6)
        }
        .frame(height: Theme.Metric.panelHeaderHeight)
        // The header row is the window's drag surface here, as a sidebar
        // header is in Xcode.
        //
        // The traffic lights are **not** aligned from here any more. They now
        // sit on the top bar, which is full width and cannot be collapsed, so
        // `EditorWindow` owns the one `TrafficLightAlignment` in the app. Two
        // aligners would each build their own container and take the buttons
        // from one another on every window notification — nothing would look
        // wrong, and the corner would flicker on resize for no visible reason.
        // One owner, and this is not it.
        .background(WindowDragHandle())
    }
}

struct PanelIconButton: View {
    let systemImage: String
    var help: String = ""
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Metric.panelIcon, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct VerticalEllipsis: View {
    var body: some View {
        VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.text).frame(width: 3, height: 3) } }
    }
}

extension View {
    /// One of the four floating cards.
    func panelCard() -> some View {
        self.background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius, style: .continuous))
    }
}
