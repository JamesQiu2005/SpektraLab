//  UpdateAnnounce.swift — the launch's Check for Updates, and what the window says when it finds one (2.2.1).

import SwiftUI

/// The launch's own check, and what the window says when it finds a newer release: once, with Download
/// (the manifest's link, opened in the browser), the release's notes where there are some, and Later.
struct UpdateAnnounce: ViewModifier {
    @Environment(AppServices.self) private var model
    @Environment(\.openURL) private var openURL
    private var check: UpdateCheck { .shared }

    func body(content: Content) -> some View {
        content
            .task { check.checkAtLaunch(enabled: model.settings.checksForUpdates) }
            .alert(L("A New Version Is Available"),
                   isPresented: Binding(get: { check.announced != nil }, set: { if !$0 { check.announced = nil } })) {
                Button(L("Download")) {
                    if let r = check.announced { openURL(r.url) }
                    check.announced = nil
                }
                if let notes = check.announced?.notes {
                    Button(L("Release Notes")) { openURL(notes); check.announced = nil }
                }
                Button(L("Later"), role: .cancel) { check.announced = nil }
            } message: {
                Text(L("SpektraLab \(check.announced?.version ?? "") is available. You have \(UpdateCheck.runningVersion)."))
            }
    }
}
