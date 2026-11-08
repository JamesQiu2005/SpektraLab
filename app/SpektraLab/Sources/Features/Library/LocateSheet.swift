//  LocateSheet.swift — F3 Original missing. the page layout (`locate_sheet`)
//
//  A frame whose original was moved, renamed or deleted keeps its edit and its
//  preview copy, and still edits; only a full-size export needs the original.
//  So the sheet says where it was, that nothing of the user's work is lost,
//  and offers the two ways to find it — the file itself, or the folder it is
//  now in, matched by name, size and capture time — or to let it go.
//
//  Finding it reads the file where it is (a security-scoped URL, as a linked
//  folder is read); nothing is written to the user's folders.

import SwiftUI
import UniformTypeIdentifiers

struct LocateSheet: View {
    let frameID: LibraryFrame.ID
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library

    private enum Looking { case file, folder }
    @State private var looking: Looking = .file
    @State private var picking = false
    @State private var confirmingRemoval = false
    /// Said under the buttons when what was picked is not this frame.
    @State private var notFound: String?

    var body: some View {
        VStack(spacing: 0) {
            if let frame = library.frame(frameID) {
                SheetHeader(title: L("Original missing"),
                            subtitle: frame.fileName + Fmt.dot + Fmt.stamp(frame.captureDate)) { router.dismissSheet() }
                content(frame)
            } else {
                SheetHeader(title: L("Original missing")) { router.dismissSheet() }
            }
            Spacer(minLength: 0)
        }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: looking == .folder ? [.folder] : [.rawImage, .image, .item]) { result in
            guard case .success(let url) = result, let frame = library.frame(frameID) else { return }
            find(frame, at: url)
        }
        .confirmationDialog(L("Remove this frame?"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(L("Remove from Library"), role: .destructive) { remove() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Its edit and preview copy go with it. If the original turns up, it can be imported again."))
        }
    }

    private func content(_ frame: LibraryFrame) -> some View {
        VStack(spacing: 0) {
            Text(whereItWas(frame))
                .font(Theme.Font.ui(14)).foregroundStyle(Theme.secondaryText)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14.4)
            Note(L("Its edit and its preview copy are safe, and still edit. Find the file to export it at full size."),
                 size: 12)
                .padding(.top, 16.4)
            CapsuleButton(title: L("Find the File"), height: 46) { look(.file) }
                .padding(.top, 26.4)
            CapsuleButton(title: L("Find Its Folder"), primary: false, height: 46) { look(.folder) }
                .padding(.top, 10)
            if let notFound {
                Note(notFound, size: 12, color: Theme.danger, alignment: .center).padding(.top, 10)
            }
            TextButton(title: L("Remove from Library"), color: Theme.danger, font: Theme.Font.ui(15, .semibold)) {
                confirmingRemoval = true
            }
            .padding(.top, notFound == nil ? 10.3 : 0)
            Note(L("Found again by name, size and capture time."), alignment: .center)
                .padding(.top, 4.6)
        }
        .padding(.horizontal, 20)
    }

    /// "It is no longer in SANDISK SSD › DCIM › 100RICOH: it was moved,
    /// renamed or deleted."
    private func whereItWas(_ frame: LibraryFrame) -> String {
        switch frame.source {
        case .linkedFolder(let disk, let path):
            L("It is no longer in \(L(shown: disk)) › \(path): it was moved, renamed or deleted.")
        case .photos:
            L("It is no longer in your Photos library: it was deleted, or access to it was taken away.")
        case .copiedIn:
            L("Its copy in SpektraLab is gone: it was removed from the app's storage.")
        }
    }

    private func look(_ how: Looking) {
        notFound = nil
        looking = how
        picking = true
    }

    private func find(_ frame: LibraryFrame, at url: URL) {
        let service = ImportService(model: model)
        let how = looking
        Task {
            let found = how == .folder ? await service.search(folder: url, for: frame)
                                       : (service.matches(url, frame) ? url : nil)
            if let found {
                service.relink(frame.id, to: found)
                router.dismissSheet()
            } else {
                notFound = how == .folder
                    ? L("\(frame.fileName) is not in \(url.lastPathComponent).")
                    : L("\(url.lastPathComponent) is not this frame: its name, size and capture time differ.")
            }
        }
    }

    private func remove() {
        guard library.frame(frameID) != nil else { return }
        model.remove([frameID])
        router.dismissSheet()
    }
}
