//  SettingsScreen.swift — what Settings is opened on (`SettingsPage`, `SettingsRequest`), and the
//  header a pushed page draws (`SettingsPageHeader`: the Export page's Size page). Settings itself
//  is the Mac's page, `Sources/Mac/Settings/SettingsWindowRoot.swift`.

import SwiftUI

/// A page Settings pushes.
enum SettingsPage: Hashable {
    case sources, storage, newFrames, previewSize, recipe, credits, workingLimit, previewLimit, diagnostics, language
    /// the mode, the background and the interface scale (AppearancePage.swift).
    case appearance
    /// One recipe's page; nil makes a new one.
    case recipeEdit(ExportRecipe.ID?)
}

/// Settings opened on one of its pages: the Library's `···` asks for Sources.
/// The cover's route carries no page, so the request is left here just before
/// the cover is shown, and taken once.
@MainActor
enum SettingsRequest {
    static var next: SettingsPage?
    static func take() -> SettingsPage? {
        defer { next = nil }
        return next
    }

    /// The menu bar's Settings (⌘,, `AppMenuCommands`): Settings on its first page, over whatever is shown,
    /// unless a cover is up. One place, so the Mac's `--settings-check` presses what the menu presses.
    static func openFromMenu(_ router: AppRouter) {
        guard router.cover == nil else { return }
        router.dismissAllSheets()
        next = nil
        router.show(.settings)
    }
}

// MARK: - the parts the pushed pages share

/// A pushed page's top: `‹ Settings`, then the page's own large title.
struct SettingsPageHeader: View {
    let title: String
    var back = L("Settings")
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { dismiss() } label: {
                // nav_page(): the chevron's centre at 22, the word from 34.
                HStack(spacing: 8) {
                    Icon(.back).frame(width: 8)
                    Text(back).font(Theme.Font.ui(15)).foregroundStyle(Theme.text)
                }
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .padding(.top, -2)
            Text(title).font(Theme.Font.pageTitle).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
