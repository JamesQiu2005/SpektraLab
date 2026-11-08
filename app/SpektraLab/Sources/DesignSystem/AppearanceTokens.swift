//  AppearanceTokens.swift — the window's own tokens (PAGES.md §2).

import SwiftUI

extension Theme {
    /// The one line where the picture side meets the column, and over the filmstrip: on the blue-grey a
    /// darker line (`Theme.tone`), following a chosen ground (`Theme.ground`).
    static let wall = ground(dark: 0x0E1013, light: 0xBDC1C7)
}

/// The app's appearance — System (following macOS), Light or Dark — chosen in Settings › Appearance and
/// kept (`ui.appearance`). The pages ask the system for it (`appColorScheme`), and the tokens follow
/// (`Theme.tone`, `Theme.ground`).
enum AppAppearance: String, CaseIterable {
    case system = "system", light = "light", dark = "dark"
    static let key = "ui.appearance"
    static let standard: AppAppearance = .dark

    /// The scheme the app's pages ask for, for the kept choice `raw`; nil follows the system.
    @MainActor static func scheme(_ raw: String) -> ColorScheme? {
        switch AppAppearance(rawValue: raw) ?? standard {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var title: String {
        switch self {
        case .system: L("System", as: "appearance")
        case .dark: L("Dark", as: "appearance")
        case .light: L("Light", as: "appearance")
        }
    }
}

private struct AppColorScheme: ViewModifier {
    @AppStorage(AppAppearance.key) private var raw = AppAppearance.standard.rawValue
    func body(content: Content) -> some View { content.preferredColorScheme(AppAppearance.scheme(raw)) }
}

extension View {
    /// The app's appearance, in place of `.preferredColorScheme(.dark)` on a page tree, a cover or a sheet.
    func appColorScheme() -> some View { modifier(AppColorScheme()) }
}
