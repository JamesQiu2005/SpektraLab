//  LibraryPanels.swift — the system panels that create and open libraries,
//  and the menu items that use them.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum LibraryPanels {
    /// Where a new catalog goes: `<Name>.spkcatalog`, a package.
    static func newCatalog() -> URL? {
        let panel = NSSavePanel()
        panel.title = L("New Catalog", zh: "新建目录")
        panel.message = L("A SpektraLab catalog keeps photos from anywhere, with their edits, ratings and albums.",
                          zh: "SpektraLab 目录保存来自任何位置的照片，及其调整、评级与相册。")
        panel.nameFieldStringValue = L("SpektraLab Catalog", zh: "SpektraLab 目录")
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "spkcatalog") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        if url.pathExtension != "spkcatalog" { url = url.appendingPathExtension("spkcatalog") }
        return url
    }

    /// Where a new session goes: a folder named for it, which will hold
    /// `<Name>.spksession` and `Capture/ Selects/ Output/ Trash/`.
    static func newSession() -> URL? {
        let panel = NSSavePanel()
        panel.title = L("New Session", zh: "新建会话")
        panel.message = L("A session is one shoot in one folder: Capture, Selects, Output and Trash.",
                          zh: "会话是一个文件夹中的一次拍摄：采集、精选、输出与废纸篓。")
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = L("Session", zh: "会话") + " " + day
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A `.spkcatalog`, a session folder, or the `.spksession` inside one.
    static func openLibrary() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Open Library", zh: "打开图库")
        panel.message = L("Choose a SpektraLab catalog or session.", zh: "选择 SpektraLab 目录或会话。")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A `.cocatalog`, or a Capture One session folder. Read one way: the
    /// panel says so, because it is the promise the feature rests on.
    static func openCaptureOne() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Open Capture One Catalog", zh: "打开 Capture One 目录")
        panel.message = L("SpektraLab reads a copy of the catalog and never writes to it.",
                          zh: "SpektraLab 读取目录的副本，从不写入。")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Photos to add to a SpektraLab library.
    static func addPhotos() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L("Add Photos", zh: "添加照片")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image, .rawImage, .tiff, .png, .jpeg, .heic]
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func locateFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Locate Folder", zh: "查找文件夹")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// What a dropped or double-clicked file is, for the app delegate:
    /// a library to open in the Library, or anything else (a photo, a
    /// folder of photos) for the editor, as ever.
    enum Opened { case library(URL), captureOne(URL), editor }

    nonisolated static func classify(_ url: URL) -> Opened {
        switch url.pathExtension.lowercased() {
        case "spkcatalog", "spksession": return .library(url)
        case "cocatalog", "cocatalogdb", "cosessiondb": return .captureOne(url)
        default: break
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return .editor }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        if names.contains(where: { $0.hasSuffix(".spksession") }) { return .library(url) }
        if names.contains(where: { $0.hasSuffix(".cosessiondb") }) { return .captureOne(url) }
        return .editor
    }
}

/// File ▸ the four ways into a library, and Window ▸ Library and Edit. A
/// panel first, then the Library, so a cancelled panel changes nothing.
struct LibraryCommands: Commands {
    let library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    /// The window, forward (or back, if it was closed), on `workspace`.
    private func show(_ workspace: Workspace) {
        library.session.workspace = workspace
        openWindow(id: "editor")
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button(L("New Catalog…", zh: "新建目录…")) {
                guard let url = LibraryPanels.newCatalog() else { return }
                show(.library)
                Task { await library.create(.catalog, at: url) }
            }
            Button(L("New Session…", zh: "新建会话…")) {
                guard let url = LibraryPanels.newSession() else { return }
                show(.library)
                Task { await library.create(.session, at: url) }
            }
            Button(L("Open Library…", zh: "打开图库…")) {
                guard let url = LibraryPanels.openLibrary() else { return }
                show(.library)
                Task { await library.open(at: url) }
            }
            Button(L("Open Capture One Catalog…", zh: "打开 Capture One 目录…")) {
                guard let url = LibraryPanels.openCaptureOne() else { return }
                show(.library)
                Task { await library.openCaptureOne(at: url) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            if !library.recents.isEmpty {
                Menu(L("Open Recent Library", zh: "打开最近的图库")) {
                    ForEach(library.recents) { r in
                        Button(r.name) {
                            show(.library)
                            Task { await library.open(r) }
                        }
                    }
                }
            }
        }
        CommandGroup(before: .windowList) {
            // The switch's two sides, numbered in its order, so a third
            // surface is ⌘3 rather than a letter to find.
            Button(Workspace.library.title) { show(.library) }
                .keyboardShortcut("1", modifiers: .command)
            Button(Workspace.edit.title) { show(.edit) }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
        }
    }
}
