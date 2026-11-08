//  MacSettingsGeneral.swift — Settings › General on the Mac: the language, agents, and about.
//
//  - **Language**: the app's four, each in itself (`AppLanguage.ownName`), changed at once
//    (`Language.choose`), as the window's page does.
//  - **About**: this build's version, and the licences and credits in full: first the engine's, the
//    notice GPL-3.0 §5(a) asks of a modified version (that it is derived from spektrafilm), then the
//    film and paper profiles'. Under them *Supporters*, which opens its own page (`MacSettingsSupporters`)
//    in the General section's place (`SettingsWindowRoot`).
//  - **Agents** (ARCHITECTURE.md §7.16): the switch that lets a program on this Mac use SpektraLab through
//    its command line and MCP server (`AppSettings.agentAccess`, off by default), and the commands.

import SwiftUI
import UIKit

struct MacSettingsGeneral: View {
    @Environment(Diagnostics.self) private var diagnostics
    @Environment(AppSettings.self) private var settings
    /// The Supporters row's: the page shows Supporters in this section's place.
    var openSupporters: () -> Void = {}
    /// The MCP configuration was copied (the button says so until the page goes).
    @State private var copied = false

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
            agents
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

    // MARK: agents

    /// The switch, and the two ways in it opens: the command, and the MCP server with a configuration to
    /// copy. The paths are this running copy's own, so what is shown is what works.
    private var agents: some View {
        MacSettingsGroup(title: L("Agents")) {
            MacSettingsRow(label: L("Allow agents to use SpektraLab"),
                           caption: L("A program on this Mac, such as an AI agent, can then list, rate, label, import, develop and export your pictures through SpektraLab while it is open, and opens it when it is not. It can move pictures to a library's Trash and back, and never deletes a file. Off, every call is refused.")) {
                MacSettingsCheckbox(label: L("Allow agents to use SpektraLab"),
                                    on: Binding(get: { settings.agentAccess }, set: { settings.agentAccess = $0 }))
            }
            .macSettingsItem("Agents", "Allow agents to use SpektraLab")
            VStack(alignment: .leading, spacing: MacMetric.pt(4)) {
                Text(L("Command line")).font(MacMetric.font(12, .semibold)).foregroundStyle(Theme.secondaryText)
                command(Self.quoted(Self.executable) + " cli tools")
                Text(L("MCP server")).font(MacMetric.font(12, .semibold)).foregroundStyle(Theme.secondaryText)
                    .padding(.top, MacMetric.pt(4))
                command(Self.quoted(Self.executable) + " mcp")
                Button(copied ? L("Copied") : L("Copy MCP Configuration")) {
                    UIPasteboard.general.string = Self.mcpConfiguration
                    copied = true
                }
                .buttonStyle(MacSettingsButtonStyle())
                .padding(.top, MacMetric.pt(4))
                .macSettingsItem("Copy MCP Configuration")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
            .padding(.vertical, MacMetric.pt(8))
            .macSettingsItem("Command line", "MCP server")
        }
    }

    /// A command as it is typed: selectable, wrapping at any width (a path is long).
    private func command(_ text: String) -> some View {
        Text(verbatim: text).font(.system(size: MacMetric.pt(11), design: .monospaced)).foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// This copy's executable: the command line and the MCP server are it, run with `cli` or `mcp`.
    static var executable: String { Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "SpektraLab" }

    static func quoted(_ path: String) -> String {
        path.contains(where: { $0 == " " || $0 == "'" }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }

    /// The `mcpServers` entry an MCP client's configuration takes (Claude Desktop's and Claude Code's shape).
    static var mcpConfiguration: String {
        let v: JSONValue = ["mcpServers": ["spektralab": ["command": .string(executable), "args": ["mcp"]]]]
        return v.text(pretty: true)
    }
}
