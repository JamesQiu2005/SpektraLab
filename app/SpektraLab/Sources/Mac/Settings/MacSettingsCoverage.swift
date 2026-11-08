//  MacSettingsCoverage.swift — every item of Settings, and the section of the Mac's page it is on.
//
//  The keys are the items' own English words (`L("…")`, an interpolation as `%@`), plus a word for each
//  row drawn by a part with no words of its own (`Size`, `Colour`, `Quality` — the Export rows a recipe
//  reuses — and a linked folder's actions); the page's views note them as they appear (`macSettingsItem`).
//  `--settings-check` fails on a *shown* one the page did not show on its section.

#if DEBUG
import Foundation

@MainActor
enum MacSettingsCoverage {
    enum Fate {
        /// On the page, in this section.
        case shown(MacSettingsSection)
        /// On the page while `when` holds (a build with a log server, a disk folder linked); otherwise
        /// `otherwise` says why not.
        case shownWhen(MacSettingsSection, when: @MainActor (AppServices) -> Bool, otherwise: String)
    }

    static let table: [String: Fate] = [
        // The page and its groups.
        "Settings": .shown(.general),
        "Done": .shown(.general),
        "Library": .shown(.sources),
        "Develop": .shown(.develop),
        "Export": .shown(.export),
        "About": .shown(.general),
        "Diagnostics": .shown(.diagnostics),
        "This build": .shown(.diagnostics),
        // Library: Sources.
        "Sources": .shown(.sources),
        "Linked folders": .shown(.sources),
        "Link a Folder": .shown(.sources),
        "Reading the folder": .shown(.sources),
        "Copied into SpektraLab": .shown(.sources),
        "%@ frames": .shown(.sources),
        "Keep a local copy": .shownWhen(.sources, when: { m in m.library.linkedFolders.contains { $0.kind == .disk } },
                                        otherwise: "beside a linked disk folder only, and none is linked"),
        "Linked folder actions": .shownWhen(.sources, when: { m in !m.library.linkedFolders.isEmpty },
                                            otherwise: "beside a linked folder only, and none is linked"),
        // Library: Storage.
        "Storage": .shown(.storage),
        "%@ on this Mac": .shown(.storage),
        "Copied-in originals": .shown(.storage),
        "Working copies": .shown(.storage),
        "Preview copies": .shown(.storage),
        "Thumbnails and cache": .shown(.storage),
        "Limits": .shown(.storage),
        "Working copies up to": .shown(.storage),
        "Preview copies up to": .shown(.storage),
        "Clear Working Copies": .shown(.storage),
        " of %@ GB": .shown(.storage),
        // Develop.
        "New frames": .shown(.develop),
        "Last used": .shown(.develop),
        "Film": .shown(.develop),
        "Paper": .shown(.develop),
        "Preview size": .shown(.develop),
        "Lens Correction": .shown(.develop),
        "Finish in the background": .shownWhen(.develop, when: { _ in FeatureFlags.backgroundFinish },
                                               otherwise: "not built (FeatureFlags.backgroundFinish is false)"),
        "Body": .shown(.develop),
        "No. %@": .shown(.develop),
        "Another": .shown(.develop),
        // Export: the recipes.
        "Recipes": .shown(.export),
        "Recipe": .shown(.export),
        "New Recipe": .shown(.export),
        "Add Recipe": .shown(.export),
        "Delete Recipe": .shown(.export),
        "Name": .shown(.export),
        "File": .shown(.export),
        "Format": .shown(.export),
        "Size": .shown(.export),
        "Colour": .shown(.export),
        "Quality": .shown(.export),
        "Save to": .shown(.export),
        // About.
        "Language": .shown(.general),
        // Agents (ARCHITECTURE.md §7.16): the switch, the commands, the configuration to copy.
        "Agents": .shown(.general),
        "Allow agents to use SpektraLab": .shown(.general),
        "Command line": .shown(.general),
        "MCP server": .shown(.general),
        "Copy MCP Configuration": .shown(.general),
        // Updates (2.2.1): check at launch or not, and Check Now.
        "Updates": .shown(.general),
        "Check for updates automatically": .shown(.general),
        "Check for Updates": .shown(.general),
        "Check Now": .shown(.general),
        // Appearance (2026-10-24): the window's page, the Mac's section, one view (AppearancePage.swift).
        "Appearance": .shown(.appearance),
        "Visual style": .shown(.appearance),
        "Mode": .shown(.appearance),
        "System": .shown(.appearance),
        "Light": .shown(.appearance),
        "Dark": .shown(.appearance),
        "Background": .shown(.appearance),
        "Interface scale": .shown(.appearance),
        "Licences and credits": .shown(.general),
        "Licences": .shown(.general),
        "SpektraLab engine": .shown(.general),
        "Supporters": .shown(.general),
        "Film and paper": .shown(.general),
        "This app": .shown(.general),
        // Diagnostics.
        "Share the log with SpektraLab": .shownWhen(.diagnostics, when: { m in
            #if SPK_LOG_UPLOAD
            return m.diagnostics.canSend
            #else
            return false
            #endif
        }, otherwise: "this build was given no log server: it sends nothing"),
        "What the log holds": .shown(.diagnostics),
        "Never in it": .shown(.diagnostics),
        "Where it goes": .shown(.diagnostics),
        "Privacy Policy": .shown(.diagnostics),
        "Export Log Zip": .shown(.diagnostics),
        "Making the Zip": .shown(.diagnostics),
        "Engine": .shown(.diagnostics),
        "Memory budget": .shown(.diagnostics),
    ]
}
#endif
