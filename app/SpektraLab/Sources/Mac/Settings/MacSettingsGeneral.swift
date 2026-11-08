//  MacSettingsGeneral.swift — Settings › General on the Mac: the language, and about.
//
//  - **Language**: the app's four, each in itself (`AppLanguage.ownName`), changed at once
//    (`Language.choose`), as the window's page does.
//  - **About**: this build's version, and the licences and credits in full: first the engine's, the
//    notice GPL-3.0 §5(a) asks of a modified version (that it is derived from spektrafilm), then the
//    film and paper profiles'. Under them *Supporters*, which opens its own page (`MacSettingsSupporters`)
//    in the General section's place (`SettingsWindowRoot`).

import SwiftUI

struct MacSettingsGeneral: View {
    @Environment(Diagnostics.self) private var diagnostics
    /// The Supporters row's: the page shows Supporters in this section's place.
    var openSupporters: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            MacSettingsGroup(title: L("Language")) {
                MacSettingsRow(label: L("Language"),
                               caption: L("SpektraLab changes at once. What macOS shows of its own, such as a Finder panel, follows the next time the app is opened."),
                               last: true) {
                    MacSettingsPopUp(label: L("Language"), options: AppLanguage.allCases.map { ($0, $0.ownName) },
                                     selection: Binding(get: { Language.shared.current }, set: { Language.shared.choose($0) }))
                }
                .macSettingsItem("Language")
            }
            MacSettingsGroup(title: L("About")) {
                MacSettingsValueRow(label: L("Version"), value: "SpektraLab " + diagnostics.build.text)
                    .macSettingsItem("About", "This app")
                MacSettingsRow(label: L("Licences and credits"), last: true)
                    .macSettingsItem("Licences and credits", "Licences")
                VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
                    // The engine's credit, first and in the page's own type: GPL-3.0 §5(a)'s prominent notice.
                    Text(L("The SpektraLab engine is a C++/Metal implementation derived from spektrafilm by Andrea Volpato "
                           + "(GPL-3.0-or-later)."))
                        .font(MacMetric.font(12)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .macSettingsItem("SpektraLab engine")
                        .padding(.bottom, MacMetric.pt(4))
                    Text(L("Film and paper")).font(MacMetric.font(12, .semibold)).foregroundStyle(Theme.secondaryText)
                        .macSettingsItem("Film and paper")
                    MacSettingsCaption(L("The colour film and paper profiles are from spektrafilm by Andrea Volpato, under CC BY-SA 4.0."),
                                       color: Theme.secondaryText)
                    MacSettingsCaption(L("The black-and-white films and their paper are SpektraLab's own profiles, built from their makers' "
                                         + "published data sheets, under CC BY-SA 4.0 as well."), color: Theme.secondaryText)
                }
                .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
                .padding(.bottom, MacMetric.pt(10))
                MacSettingsHairline()
                Button(action: openSupporters) {
                    MacSettingsRow(label: L("Supporters"), last: true) {
                        Image(systemName: "chevron.right").font(MacMetric.font(11, .semibold)).foregroundStyle(Theme.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mac.settings.supporters")
                .macSettingsItem("Supporters")
            }
        }
    }
}
