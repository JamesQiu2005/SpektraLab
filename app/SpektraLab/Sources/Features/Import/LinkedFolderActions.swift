//  LinkedFolderActions.swift — what a linked folder's row says of it and offers, in Settings › Sources
//  (reference device and window) and in the window Library sidebar's SOURCES (2026-10-21).
//
//  The owner: "show in source, that where the linked folder actually is, and manage the offline /
//  online folder status … we do not yet do a full-scale folder management system". So a folder
//  says where it is and whether it answers, and offers three things only:
//
//  - **Check Again**: asks every folder again now (`FrameCatalog.recheckFolders`), as the app does
//    by itself at launch, back in front, and every 30 s while a Sources list is on the screen;
//  - **Reconnect…**: the folder picked again in Files, to grant access again or to follow a copy
//    that moved (`ImportService.reconnect`);
//  - **Unlink…**: the folder and its frames leave the library, after a confirmation that says the
//    files in it are not touched (`AppServices.remove`).
//
//  And *Show in Files* while it is connected: the Files app opened on it.

import SwiftUI
import UniformTypeIdentifiers

extension LinkedFolder {
    /// "Connected", "Not connected", "Not found", "Access lost".
    var statusWord: String {
        switch status {
        case .connected: L("Connected")
        case .notConnected: L("Not connected")
        case .notFound: L("Not found")
        case .accessLost: L("Access lost")
        }
    }

    /// What to do about it, for a folder that is away.
    var statusHint: String? {
        switch status {
        case .connected: nil
        case .notConnected: L("Connect it, or Reconnect if it moved. Its frames' previews still edit.")
        case .notFound: L("It was moved, renamed or deleted. Reconnect to find it.")
        case .accessLost: L("SpektraLab may no longer read it. Reconnect to allow it again.")
        }
    }

    /// "Connected · 12 frames · 3 still in iCloud", "Not connected · 48 frames".
    var statusLine: String {
        var parts = [statusWord, L("\(frameCount) frames")]
        if isConnected, stillInCloud > 0 { parts.append(L("\(stillInCloud) still in iCloud")) }
        return parts.joined(separator: Fmt.dot)
    }
}

/// The folder's actions, as menu items: the row's context menu, and its ⋯ button on Settings › Sources.
struct LinkedFolderMenu: View {
    let folder: LinkedFolder
    let reconnect: () -> Void
    let unlink: () -> Void
    @Environment(FrameCatalog.self) private var library
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        // The section's title is where the folder is: the whole of it, which a row may cut.
        Section(folder.place) {
            Button {
                guard !isSnapshot else { return }
                Task { await library.recheckFolders() }
            } label: { Label(L("Check Again"), systemImage: "arrow.clockwise") }
            Button(action: reconnect) { Label(L("Reconnect…"), systemImage: "link") }
            if folder.isConnected, let url = library.url(of: folder.id),
               let files = URL(string: "shareddocuments://" + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)) {
                Button { UIApplication.shared.open(files) } label: { Label(L("Show in Files"), systemImage: "folder") }
            }
        }
        Button(role: .destructive, action: unlink) { Label(L("Unlink…"), systemImage: "minus.circle") }
    }
}

/// The picker *Reconnect…* opens, the confirmation *Unlink…* asks, and what came of a reconnect: put
/// on the view that holds the folder rows. A row asks by setting `reconnecting` or `unlinking`.
struct LinkedFolderActions: ViewModifier {
    @Binding var reconnecting: LinkedFolder.ID?
    @Binding var unlinking: LinkedFolder.ID?
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library

    @State private var picking = false
    @State private var target: LinkedFolder.ID?
    @State private var said: Said?

    struct Said: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: reconnecting) { _, id in
                guard let id else { return }
                target = id
                reconnecting = nil
                picking = true
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: UTType.linkable) { result in
                guard case .success(let url) = result, let id = target,
                      let folder = library.linkedFolders.first(where: { $0.id == id }) else { return }
                Task {
                    switch await ImportService(model: model).reconnect(id, to: url) {
                    case .notThisFolder:
                        said = Said(title: L("Not the same folder"),
                                    message: L("\(url.lastPathComponent) holds none of the frames of \(folder.title)."))
                    case .done(let found, let of) where found < of:
                        said = Said(title: L("Reconnected"),
                                    message: L("\(found) of \(of) frames are in it. The others are marked Original missing."))
                    case .done: break
                    }
                }
            }
            .confirmationDialog(unlinkTitle, isPresented: unlinkAsked, titleVisibility: .visible) {
                Button(L("Unlink"), role: .destructive) { unlink() }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(unlinkMessage)
            }
            .alert(item: $said) { said in
                Alert(title: Text(said.title), message: Text(said.message), dismissButton: .default(Text(L("OK"))))
            }
    }

    private var unlinkFolder: LinkedFolder? { unlinking.flatMap { id in library.linkedFolders.first { $0.id == id } } }

    private var unlinkAsked: Binding<Bool> {
        Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } })
    }

    private var unlinkTitle: String { unlinkFolder.map { L("Unlink \($0.title)?") } ?? "" }

    private var unlinkMessage: String {
        guard let folder = unlinkFolder else { return "" }
        return L("Its \(library.frames(of: folder).count) frames leave the library, with their edits. "
                 + "The files in the folder are not touched.")
    }

    private func unlink() {
        guard let folder = unlinkFolder else { return }
        let ids = Set(library.frames(of: folder).map(\.id))
        library.removeFolder(folder.id)
        if !ids.isEmpty { model.remove(ids) }
        Log.note(.library, "folder unlinked", ["frames": ids.count])
        unlinking = nil
    }
}
