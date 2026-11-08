//  Originals.swift — an original that stayed in Photos, and the frames' files held to their size.
//
//  The window read photos in place from the Photos library: the library kept the way back to the asset
//  (`assetIdentifier`), its edit and a preview copy, and the original was only ever here as a working
//  copy (`WorkingCopies`). This app has no Photos library (the Mac's, since 2026-10-23, and the only
//  build now): nothing asks Photos for anything. A frame read in place there whose working copy is here
//  still develops from it, and can be kept in the app (*Copy into Spek*); one whose copy is not here is
//  missing (F3), as Photos' answer was on the Mac.

import Foundation
import os

@MainActor
final class Originals {
    /// What a fetch came to.
    enum Brought: Equatable, Sendable {
        /// The copy is here to read.
        case here
        /// Photos no longer has it for this app: the frame's original is missing.
        case gone
        /// In iCloud, and not downloaded now.
        case inCloud
        /// There, and not read now.
        case unreadable

        /// For a page, where it has to say why a picture was not made.
        var words: String {
            switch self {
            case .here: ""
            case .gone: "The original is no longer in Photos"
            case .inCloud: "The original is in iCloud and could not be downloaded"
            case .unreadable: "The original could not be read from Photos"
            }
        }
    }

    /// The copies and their book.
    let copies: WorkingCopies
    /// The long edge a new frame's preview is given (`AppSettings.previewLongEdge`): what a frame
    /// whose size is corrected is given too. The app's model sets it.
    var previewLongEdge: () -> Int = { 2400 }
    /// A frame's size was corrected from its file (`take`): the app's model lays out again what
    /// was laid out from the old one, and develops the frame again where nobody is about to.
    var onResized: (LibraryFrame.ID) -> Void = { _ in }
    private let library: FrameCatalog
    /// RAW frames whose size has been read from their file in this run of the app, and the
    /// readings under way (`holdToItsFile`).
    private var sized: Set<LibraryFrame.ID> = []
    private var sizing: [LibraryFrame.ID: Task<Bool, Never>] = [:]
    private let log = Logger(subsystem: "com.spektralab.mac", category: "originals")

    /// `folder` nil keeps no copies: the drawings' own library, and wherever
    /// the library is not kept on disk.
    init(library: FrameCatalog, folder: URL?, limit: Int64) {
        self.library = library
        copies = WorkingCopies(folder: folder, limit: limit)
    }

    /// Whether the frame's original has to be brought before it can be read:
    /// it stays in Photos, and its copy is not here.
    func isAway(_ frame: LibraryFrame) -> Bool {
        frame.readsFromPhotos && frame.original.isAvailable && !copies.has(frame.id, named: frame.fileName)
    }

    /// The frame's original, here to read: at once when its copy is. One that stayed in Photos whose
    /// copy is not here cannot be brought (nothing asks Photos): its frame is marked missing.
    /// `asked` is true where the user asked for what needs it.
    func bring(_ frame: LibraryFrame, asked: Bool) async -> Brought {
        guard frame.readsFromPhotos else { return .here }
        guard frame.original.isAvailable else { return .gone }
        if copies.has(frame.id, named: frame.fileName) {
            copies.touch(frame.id)
            return .here
        }
        log.info("an original that stayed in Photos is not here: its frame is marked missing")
        Log.original("gone", asked: asked)
        library.update(frame.id) { $0.original = .missing }
        return .gone
    }

    // MARK: a frame taken for another size than its file's

    /// The frame's size becomes its file's, where it was another: its preview
    /// is as large as a new frame's would be (`previewLongEdge`), its film's
    /// long edge is as this photograph's shape makes it
    /// (`FilmParams.heldToItsPhoto`), and whoever laid something out from the
    /// old size hears of it (`onResized`). Whether it moved.
    ///
    /// Two ways a frame came to have another size. A build before 2026-10-10
    /// took a Photos photo's from the file the picker handed over, which for
    /// one edited in Photos was the edit. A build before 2026-10-12 took a
    /// RAW's from the file's first image, which in a Sony ARW, a Fuji RAF and
    /// an Adobe-laid DNG is its embedded preview or thumbnail
    /// (`ImportService.probe`): such a frame was developed, soft, from 1,616
    /// or 252 pixels, and exported at that.
    @discardableResult
    private func take(_ size: PixelSize, for id: LibraryFrame.ID) -> Bool {
        guard let frame = library.frame(id), size.width > 0, size.height > 0, size != frame.originalSize else { return false }
        log.info("\(frame.fileName, privacy: .public): its file is \(size.width) x \(size.height), not the \(frame.originalSize.width) x \(frame.originalSize.height) it was imported as")
        let edge = previewLongEdge()
        library.update(id) { f in
            f.originalSize = size
            f.previewSize = size.scaled(toLongEdge: edge)
            f.edit.params = f.edit.params.heldToItsPhoto(size)
        }
        onResized(id)
        return true
    }

    /// A RAW frame is held to its file: its size read again from the file,
    /// by the decoder that will open it, where the file is here to read — a
    /// frame's own in the app, a linked folder's, or a working copy that is
    /// in. Once for a frame in a run of the app, and one reading at a time for
    /// it. Whether its size moved.
    ///
    /// Asked at launch of every RAW frame, once for a library, and again at
    /// each later launch of one whose file was away then
    /// (`AppServices.holdRAWsToTheirFiles`); of a frame whose original has just
    /// been found again (`ImportService.relink`); and of a frame before its
    /// export is planned (`ExportService`): an export planned from a preview's
    /// size writes a file of that size and decodes the whole RAW unplanned. A
    /// frame whose working copy is away is held when it is next fetched
    /// (`fetch`).
    @discardableResult
    func holdToItsFile(_ id: LibraryFrame.ID) async -> Bool {
        if let running = sizing[id] { return await running.value }
        guard let frame = library.frame(id), frame.isRAW, !frame.isPair, !sized.contains(id),
              let file = frame.developSource, FileManager.default.fileExists(atPath: file.path) else { return false }
        let task = Task { [weak self] () -> Bool in
            let size = await Task.detached(priority: .userInitiated) { ImportService.rawSize(file) }.value
            guard let self, let size else { return false }
            self.sized.insert(id)
            return self.take(size, for: id)
        }
        sizing[id] = task
        let moved = await task.value
        sizing[id] = nil
        return moved
    }

    /// Whether the frame's size has been read from its file in this run of
    /// the app: false for one whose file was not here to read.
    func isHeld(_ id: LibraryFrame.ID) -> Bool { sized.contains(id) }

    /// At launch: a frame read in place from Photos is one whose original is missing (F3) — nothing
    /// asks Photos what it still has. Its working copy, where it is here, is still read and can be kept.
    func reconcile() {
        for frame in library.frames where frame.readsFromPhotos && frame.original == .available {
            library.update(frame.id) { $0.original = .missing }
        }
    }

    // MARK: an original kept in the app

    /// A frame read in place from Photos keeps its original in the app from
    /// here on (Settings › Sources › *Keep Originals in Spek*; the owner,
    /// 2026-10-21, of a tester who wanted to delete the photo from Photos once
    /// it was in Spek: the app's own file is the frame's "digital origin",
    /// never touched, every edit recomputed from it). Its working copy, where
    /// it is here, moves into `Originals`, and the frame is the app's own: one
    /// that was missing — deleted from Photos while its copy was still here —
    /// is whole again. Nothing is fetched for it: a frame whose copy is away
    /// moves the next time it is brought. Never a frame being read now (its
    /// file's path is in a job's hands), nor one being fetched. Whether it moved.
    @discardableResult
    func keepInApp(_ id: LibraryFrame.ID) -> Bool {
        keepInApp([id]) == 1
    }

    /// The same, for many frames, with one write of the library. How many moved.
    ///
    /// `evenInUse` (*Copy into Spek*, asked by the person): a frame being read is kept too — its working
    /// copy is copied (a clone on APFS, which costs no space until one of them changes) rather than moved,
    /// and stays in the book for the job that holds its path; the limit clears it later as any other.
    @discardableResult
    func keepInApp(_ ids: [LibraryFrame.ID], evenInUse: Bool = false) -> Int {
        let busy = copies.inUse()
        var replaced: [PictureRef] = []
        for id in ids {
            guard let frame = library.frame(id), frame.readsFromPhotos,
                  copies.has(id, named: frame.fileName), let copy = copies.copies[id]?.url else { continue }
            let reading = busy.contains(id)
            guard !reading || evenInUse else { continue }
            guard let kept = try? (reading ? ImportService.cloneIntoOriginals(copy) : ImportService.moveIntoOriginals(copy)) else { continue }
            if !reading { copies.forget(id) }
            library.update(id) { f in
                f.source = .copiedIn
                f.original = .available
                if !f.isDemo { f.picture = .file(kept) }
            }
            replaced.append(frame.picture)
            log.info("\(frame.fileName, privacy: .public): its original is kept in the app from now on")
        }
        guard !replaced.isEmpty else { return 0 }
        // The library that names the kept files is written before the preview copies go.
        library.flush()
        Task.detached(priority: .utility) { for picture in replaced { ImportService.discard(picture: picture) } }
        Log.note(.library, "originals kept in the app", ["frames": replaced.count])
        return replaced.count
    }
}

extension ImportService {
    /// Originals brought here from Photos while they are worked on
    /// (`WorkingCopies`): rebuildable, so left out of backups.
    nonisolated static var workingCopies: URL { root.appendingPathComponent("WorkingCopies", isDirectory: true) }
}

extension LibraryFrame {
    /// Read in place from Photos: the original stays there, and the app has
    /// the way back to it. Its develops read a working copy (`Originals`).
    var readsFromPhotos: Bool { source == .photos && assetIdentifier != nil && !isDemo }

    /// Where this frame's original is while it is here.
    var workingCopy: URL { WorkingCopies.url(in: ImportService.workingCopies, for: id, name: fileName) }
}
