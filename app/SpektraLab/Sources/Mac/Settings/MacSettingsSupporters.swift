//  MacSettingsSupporters.swift — Settings › General › About › Supporters: the thanks, then each supporter.
//
//  Opened by the About group's *Supporters* row (`MacSettingsGeneral`), over the General section's place
//  on the page with a way back (`SettingsWindowRoot`). The list and its rules are `SupportersPage`
//  (Model/Supporters.swift): a name and a note are drawn as they were written, never looked up in the
//  catalogue, and a note wraps in full however long it is (the page's scroll view holds a long list).
//  With nobody listed the page is the thanks alone, with nothing drawn to say the list is empty.

import SwiftUI

struct MacSettingsSupporters: View {
    var page: SupportersPage = .shipped

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            Text(page.thanks).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                .lineSpacing(MacMetric.pt(2))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !page.entries.isEmpty {
                MacSettingsGroup(title: nil) {
                    ForEach(page.entries) { entry in
                        row(entry, last: entry.id == page.entries.last?.id)
                    }
                }
            }
        }
    }

    private func row(_ entry: SupportersPage.Entry, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(3)) {
            Text(verbatim: entry.name).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let note = entry.note {
                // Wrapped in full, every line end kept: the supporter's own words.
                Text(verbatim: note).font(MacMetric.font(12)).foregroundStyle(Theme.secondaryText)
                    .lineSpacing(MacMetric.pt(2))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
        .padding(.vertical, MacMetric.pt(8))
        .overlay(alignment: .bottom) {
            if !last { MacSettingsHairline().padding(.leading, MacMetric.pt(MacSettingsMetric.inset)) }
        }
        .accessibilityElement(children: .combine)
    }
}
