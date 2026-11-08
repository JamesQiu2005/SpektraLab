//  SettingsWindowRoot.swift — the Mac's Settings: a page over the whole window, as Import and Export are.
//
//  The owner, 2026-10-24: "The current settings menu is still the window code, and we need to bring the
//  v1.3.3 type of information density back (it does not mean it has to look the same as v1.3.3), and we
//  do a full redo on the settings, most ideally a separate page just like import / export."
//
//  - **Every way in is this page.** `CoverRoute.settings` shows it on the Mac (`CoverContent`): ⌘,
//    (`AppMenuCommands`), the Mac library's "+" › Settings and › Sources (`MacLibrarySidebar`), Develop's
//    actions menu, a disk banner's Sources. `SettingsRequest` names the window page asked for; it opens the
//    section that holds it. The window's and the reference device's Settings (`SettingsScreen`) are as they were.
//  - **A preferences window's shape, in v2's language**: the title bar (Done at its trailing edge, and
//    Escape), the sections in a column at the left (the import page's column, the library sidebar's
//    rows and its white selection), the chosen section's groups at the right, every setting of it on
//    one page at macOS sizes — no drill-down pages, no 44-pt rows. The one page a row opens is General's
//    *Supporters* (`MacSettingsSupporters`), which holds no setting: it takes General's place, under a
//    way back.
//  - **Seven sections**, from what the settings are: General (language, about and licences),
//    Appearance (the mode, the background, the interface scale: AppearancePage.swift, 2026-10-24), Develop (what new frames develop with, the preview size, lens correction, the film edge's body),
//    Export (the recipes, edited in place), Sources (the Mac library's catalogs, sessions and folders),
//    Storage (what the app keeps, the three budgets and their usage), Diagnostics (the log, what it
//    holds, this build).
//  - **What the Mac leaves out of the window's Settings** is `MacSettingsCoverage`'s table, each with its
//    reason; `--settings-check` reads the window's Settings sources and fails on an item the table does
//    not account for.

import SwiftUI

enum MacSettingsSection: String, CaseIterable, Hashable {
    case general, appearance, develop, export, sources, storage, diagnostics

    var title: String {
        switch self {
        case .general: L("General")
        case .appearance: L("Appearance")
        case .develop: L("Develop")
        case .export: L("Export")
        case .sources: L("Sources")
        case .storage: L("Storage")
        case .diagnostics: L("Diagnostics")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .develop: "camera.filters"
        case .export: "square.and.arrow.up"
        case .sources: "books.vertical"
        case .storage: "internaldrive"
        case .diagnostics: "stethoscope"
        }
    }

    /// The section that holds a window page a way in asked for (`SettingsRequest`).
    init(_ page: SettingsPage?) {
        switch page {
        case .sources?: self = .sources
        case .storage?, .workingLimit?, .previewLimit?: self = .storage
        case .newFrames?, .previewSize?: self = .develop
        case .recipe?, .recipeEdit?: self = .export
        case .diagnostics?: self = .diagnostics
        case .appearance?: self = .appearance
        case .language?, .credits?, nil: self = .general
        }
    }
}

struct SettingsWindowRoot: View {
    @Environment(AppRouter.self) private var router
    @State private var section: MacSettingsSection
    /// General › About › Supporters is shown in the General section's place.
    @State private var supporters: Bool

    init() {
        _section = State(initialValue: MacSettingsSection(SettingsRequest.take()))
        var supporters = false
        #if DEBUG
        supporters = Self.supportersAsked
        Self.supportersAsked = false
        #endif
        _supporters = State(initialValue: supporters)
    }

    #if DEBUG
    /// `MacDriver`'s way to a section, or to Supporters, while the page is up (`userInfo`: "section", a
    /// section's raw value, and "supporters", a Bool).
    static let drive = Notification.Name("com.spektralab.mac.settings.drive")
    /// Supporters asked for before the page is up: the page opens on it.
    static var supportersAsked = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Theme.wall).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                    .frame(width: MacMetric.pt(MacSettingsMetric.sidebar))
                    .background(Theme.panel)
                Rectangle().fill(Theme.wall).frame(width: 1)
                content
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .appColorScheme()
        .macPageActions(confirm: { router.dismissCover() }, cancel: { router.dismissCover() })
        .onAppear {
            #if DEBUG
            MacSettingsCheck.attach(section: section) { section = $0 }
            #endif
        }
        .onChange(of: section) { _, now in
            #if DEBUG
            MacSettingsCheck.attach(section: now) { section = $0 }
            #endif
        }
        .onDisappear {
            #if DEBUG
            MacSettingsCheck.detach()
            #endif
        }
        .macSettingsDriven { asked, shows in
            section = asked
            supporters = shows
        }
    }

    // MARK: the bars

    private var titleBar: some View {
        ZStack {
            Text(L("Settings")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
                .macSettingsItem("Settings")
            HStack {
                Spacer(minLength: 0)
                Button(L("Done")) { router.dismissCover() }
                    .buttonStyle(MacSettingsButtonStyle(kind: .primary))
                    .accessibilityIdentifier("mac.settings.done")
                    .macSettingsItem("Done")
            }
            .padding(.horizontal, MacMetric.pt(10))
        }
        .frame(maxWidth: .infinity)
        .frame(height: MacMetric.pt(MacMetric.gridHeader))
        .background(Theme.panel)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacMetric.pt(2)) {
                ForEach(MacSettingsSection.allCases, id: \.self) { s in
                    let on = s == section
                    Button { section = s; supporters = false } label: {
                        HStack(spacing: MacMetric.pt(6)) {
                            Image(systemName: s.symbol).font(MacMetric.font(13))
                                .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                                .frame(width: MacMetric.pt(18))
                            Text(s.title).font(MacMetric.font(13, on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.onSelection : Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, MacMetric.pt(8))
                        .frame(minHeight: MacMetric.pt(26))
                        .background {
                            if on { RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous).fill(Theme.selection) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("mac.settings.section.\(s.rawValue)")
                }
            }
            .padding(.horizontal, MacMetric.pt(6))
            .padding(.vertical, MacMetric.pt(8))
        }
        .scrollIndicators(.automatic)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
                // Appearance draws its own large title (ChatGPT's page, AppearancePage.swift).
                if section == .general && supporters {
                    supportersTitle
                } else if section != .appearance {
                    Text(section.title).font(MacMetric.font(17, .semibold)).foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                }
                switch section {
                case .general where supporters: MacSettingsSupporters()
                case .general: MacSettingsGeneral(openSupporters: { supporters = true })
                case .appearance: AppearanceSettings(style: .mac)
                case .develop: MacSettingsDevelop()
                case .export: MacSettingsRecipes()
                case .sources: MacSettingsSources(close: { router.dismissCover() })
                case .storage: MacSettingsStorage()
                case .diagnostics: MacSettingsDiagnostics()
                }
            }
            .padding(.horizontal, MacMetric.pt(20))
            .padding(.top, MacMetric.pt(16))
            .padding(.bottom, MacMetric.pt(28))
            .frame(maxWidth: MacMetric.pt(MacSettingsMetric.readable), alignment: .leading)
            .frame(maxWidth: .infinity)
            .id(supporters && section == .general ? "supporters" : section.rawValue)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// Supporters' title, under the way back to General.
    private var supportersTitle: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
            Button { supporters = false } label: {
                HStack(spacing: MacMetric.pt(3)) {
                    Image(systemName: "chevron.left").font(MacMetric.font(11, .semibold))
                    Text(MacSettingsSection.general.title).font(MacMetric.font(12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mac.settings.supporters.back")
            Text(L("Supporters")).font(MacMetric.font(17, .semibold)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension View {
    /// The window Settings items this view stands for (`MacSettingsCoverage`): a debug build notes them as
    /// they appear, for `--settings-check` to find each one on its section.
    func macSettingsItem(_ keys: String...) -> some View { macSettingsItem(keys) }

    func macSettingsItem(_ keys: [String]) -> some View {
        #if DEBUG
        onAppear { MacSettingsCheck.saw(keys) }
        #else
        self
        #endif
    }

    /// A debug build's: `MacDriver` moving the page that is up to a section, or to Supporters.
    func macSettingsDriven(_ perform: @escaping (MacSettingsSection, Bool) -> Void) -> some View {
        #if DEBUG
        onReceive(NotificationCenter.default.publisher(for: SettingsWindowRoot.drive)) { note in
            guard let raw = note.userInfo?["section"] as? String, let section = MacSettingsSection(rawValue: raw) else { return }
            SettingsRequest.next = nil
            SettingsWindowRoot.supportersAsked = false
            perform(section, note.userInfo?["supporters"] as? Bool ?? false)
        }
        #else
        self
        #endif
    }
}
