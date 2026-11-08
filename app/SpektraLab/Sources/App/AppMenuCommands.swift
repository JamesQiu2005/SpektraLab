//  AppMenuCommands.swift — the app's places in the operating system's menu bar, and their keys.
//
//  PAGES.md §6: in the operating system 26's menu bar, the desktop's keys where it has them. These are the
//  app-wide ones — places, not edits; a page's own keys (Develop's ⌘Z, ⌘B, ← →) are the page's.
//  ⌘1 and ⌘2 are the Library's own (Icons, List: Finder's keys), so the Go menu's places are ⌥⌘1, ⌥⌘2.
//  A host has no menu bar, and a hardware keyboard on one lists these under ⌘ held, which is
//  harmless.

import SwiftUI

struct AppMenuCommands: Commands {
    let model: AppServices

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Import")) {
                guard model.router.cover == nil, model.router.sheets.isEmpty else { return }
                guard !MacLibraryBrowser.shared.modal, MacShellPath.split(model.router.path).stacked.isEmpty else { return }
                MacLibraryBrowser.shared.importAsked = true
            }
                .keyboardShortcut(MacShortcut.importKey, modifiers: MacShortcut.importModifiers)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("Settings")) { SettingsRequest.openFromMenu(model.router) }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(L("Go")) {
            Button(L("Library")) {
                model.router.dismissAllSheets()
                model.router.dismissCover()
                model.router.home()
            }
            Button(L("Light Table")) {
                guard model.router.path.last != .lightTable, model.router.cover == nil else { return }
                model.router.open(.lightTable)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button(L("Back")) { if model.router.cover == nil, model.router.sheets.isEmpty { model.router.back() } }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}
