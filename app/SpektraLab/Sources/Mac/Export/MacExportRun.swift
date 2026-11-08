//  MacExportRun.swift — a Mac export batch: one picture at a time, each into the folder chosen once.
//
//  The owner, 2026-10-24: "sequential batch export should also be there" (on the one Mac export page,
//  `MacExportPage`). The batch is the window's own `ExportService` batch — one scheduler job per frame,
//  each developed again from its original at the recipe's size, the next not begun until the one before
//  has ended (`ExportService.run` awaits each job's outcome) — so nothing here is a second way to make
//  a file. What the Mac adds is where the files go and what is said of each:
//
//  - **Save to Files is a folder, chosen once for the batch** (Finder's open panel, on the page). On the
//    window the files wait in the batch's folder until the system's "save to" browser is handed them all
//    at the end; on the Mac each file is put into the chosen folder **as its picture finishes**, so a
//    batch stopped half way leaves the pictures it finished, each one whole.
//  - **A file never lands under its name half written, and never over another.** It is copied in under
//    a hidden name (`.<uuid>.spkpart`) and renamed to its own with `RENAME_EXCL`: a name the folder has
//    already is "-2", "-3", as the batch names two frames of one name (`ExportService.free`).
//  - **One picture that fails is said, and the rest go on**: a picture that could not be made a frame
//    (its disk away, its file gone) is a line of its own from the start; a frame whose original cannot
//    be read, or whose file could not be put in the folder, is said on its line.
//  - **Share** keeps the window's way: the batch's files, all of them, to the system's share sheet when the
//    batch has ended.
//
//  It outlives the page: closing the page during a batch leaves the batch running, as closing the window's
//  Exporting sheet does, and its files still reach the folder.

import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class MacExportRun {
    static let shared = MacExportRun()

    struct Line: Identifiable, Equatable {
        enum State: Equatable {
            /// Not begun; why it waits, in the page's words ("" in the queue).
            case waiting(String)
            case running(RenderProgress)
            /// Its file: in the chosen folder (Files), or the batch's own (Share).
            case saved(URL)
            case stopped
            /// It went, and no file came of it: why.
            case failed(String)
            /// It never went: why (its disk is away, its file is gone).
            case leftOut(String)
        }
        let id: Int
        /// Its frame; nil for a picture that never became one.
        let frameID: LibraryFrame.ID?
        /// The file's name (the batch's, unique in it), or the picture's own for one left out.
        var name: String
        var state: State
        /// When it was first seen under way, and when it ended (for the check: one after another).
        var began: Date?
        var ended: Date?

        var isEnded: Bool {
            switch state {
            case .waiting, .running: false
            default: true
            }
        }
        var problem: String? {
            switch state {
            case .failed(let why), .leftOut(let why): why
            default: nil
            }
        }
    }

    /// A picture the page could not make a frame of, and why.
    struct LeftOut: Equatable {
        var name: String
        var why: String
    }

    private(set) var lines: [Line] = []
    private(set) var recipe: ExportRecipe?
    /// Where Files puts each picture; nil for Share.
    private(set) var folder: URL?
    private(set) var isRunning = false
    /// Stop was asked: what is under way is cancelled and nothing more is begun.
    private(set) var stopping = false
    /// The batch's files once it has ended, for Share's sheet.
    private(set) var shareFiles: [URL] = []
    /// How many of the batch's jobs the scheduler held under way at once, at the most (the check's).
    private(set) var mostAtOnce = 0

    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private weak var exporter: ExportService?

    /// The batch's pictures (those with a frame), in order: the first lines.
    private var batchCount: Int { lines.filter { $0.frameID != nil }.count }
    var saved: Int { lines.filter { if case .saved = $0.state { true } else { false } }.count }
    var problems: [Line] { lines.filter { $0.problem != nil } }
    var wasStopped: Bool { lines.contains { $0.state == .stopped } }
    var isFinished: Bool { !isRunning && !lines.isEmpty }
    /// The line under way, else the first not begun.
    var current: Line? {
        lines.first { if case .running = $0.state { true } else { false } } ?? lines.first { !$0.isEnded }
    }
    /// The batch so far, 0…1: the pictures ended and the share of the one under way.
    var fraction: Double {
        let n = batchCount
        guard n > 0 else { return 0 }
        let ended = lines.filter { $0.frameID != nil && $0.isEnded }.count
        var now = 0.0
        if case .running(let p)? = current?.state { now = p.fraction }
        return min(1, (Double(ended) + now) / Double(n))
    }
    /// "3 of 12": the picture under way, of the batch's.
    var countText: String {
        let n = batchCount
        let at = lines.prefix(n).firstIndex { !$0.isEnded } ?? n - 1
        return L("\(min(at + 1, n)) of \(n)")
    }

    func line(for frame: LibraryFrame.ID) -> Line? { lines.first { $0.frameID == frame } }

    // MARK: running

    /// Begins a batch of `frames`, in order. Files needs `folder`. False when nothing was begun: a batch
    /// under way already, no folder for Files, or the service refused it (`ExportService.start`).
    @discardableResult
    func start(_ frames: [LibraryFrame.ID], leftOut: [LeftOut] = [], recipe: ExportRecipe, folder: URL?,
               exporter: ExportService) -> Bool {
        guard !isRunning, !exporter.isExporting, !frames.isEmpty else { return false }
        if recipe.destination == .files, folder == nil { return false }
        exporter.start(frames, recipe: recipe)
        // A refused batch leaves nothing under way: the service says so in its log, the page by its button.
        guard exporter.isExporting, let batch = exporter.batch else { return false }
        self.exporter = exporter
        self.recipe = recipe
        self.folder = recipe.destination == .files ? folder : nil
        shareFiles = []
        stopping = false
        mostAtOnce = 0
        var made = batch.items.enumerated().map { i, item in
            Line(id: i, frameID: item.id, name: item.fileName, state: .waiting(""))
        }
        for (k, l) in leftOut.enumerated() {
            made.append(Line(id: batch.items.count + k, frameID: nil, name: l.name, state: .leftOut(l.why)))
        }
        lines = made
        isRunning = true
        let token = batch.folder
        watcher?.cancel()
        watcher = Task { [weak self] in await self?.watch(exporter, token: token) }
        Log.note(.export, "mac batch", ["pictures": batch.items.count, "left_out": leftOut.count,
                                        "format": recipe.format.rawValue, "colour": recipe.colour.rawValue,
                                        "size": recipe.size.title, "destination": recipe.destination.rawValue])
        return true
    }

    /// Stop: the picture under way is cancelled (its file is never put in the folder), the rest are not
    /// begun, and those already in the folder stay.
    func stop() {
        guard isRunning else { return }
        stopping = true
        exporter?.stop()
    }

    /// The page is done with a finished batch's lines.
    func reset() {
        guard !isRunning else { return }
        lines = []
        recipe = nil
        folder = nil
        shareFiles = []
    }

    /// Follows the service's batch until it has ended and every finished file is in the folder.
    private func watch(_ exporter: ExportService, token: URL?) async {
        guard let recipe else { return }
        var placing = false
        while !Task.isCancelled {
            // Another batch in the service's hands (not this page's: a harness's): this one is over.
            guard let batch = exporter.batch, batch.folder == token else {
                for i in lines.indices where !lines[i].isEnded { lines[i].state = .stopped; lines[i].ended = Date() }
                break
            }
            let atOnce = exporter.batch?.items.filter { if case .running = $0.state { true } else { false } }.count ?? 0
            mostAtOnce = max(mostAtOnce, atOnce)
            for (i, item) in batch.items.enumerated() where i < lines.count {
                var line = lines[i]
                if case .saved = line.state { continue }
                if case .failed = line.state, line.ended != nil { continue }
                let now = Date()
                switch item.state {
                case .waiting(let why):
                    line.state = .waiting(why == .queued ? "" : L(shown: why.text))
                case .running(let p):
                    if line.began == nil { line.began = now }
                    line.state = .running(p)
                case .done:
                    if line.began == nil { line.began = now }
                    if line.ended == nil { line.ended = now }
                    guard let file = item.file else {
                        line.state = .failed(L("The file was not written"))
                        break
                    }
                    if let folder = self.folder {
                        // Into the folder now, as this picture finishes: the next is under way meanwhile.
                        placing = true
                        lines[i] = line
                        let name = item.fileName
                        let placed = await Task.detached(priority: .userInitiated) {
                            Result { try MacExportRun.place(file, named: name, in: folder) }
                        }.value
                        placing = false
                        line = lines[i]
                        switch placed {
                        case .success(let url): line.state = .saved(url)
                        case .failure(let error):
                            line.state = .failed(L("The file could not be written") + Fmt.dot + error.localizedDescription)
                            Log.note(.export, "mac batch: not placed", ["file": name, "error": error.localizedDescription], level: .warn)
                        }
                    } else {
                        line.state = .saved(file)
                    }
                case .stopped:
                    line.state = .stopped
                    if line.ended == nil { line.ended = now }
                case .failed:
                    line.state = .failed(L("Could not develop"))
                    if line.ended == nil { line.ended = now }
                case .notSaved(let why):
                    line.state = .failed(L("Not saved") + (why.isEmpty ? "" : Fmt.dot + L(shown: why)))
                    if line.ended == nil { line.ended = now }
                }
                if line != lines[i] { lines[i] = line }
            }
            if batch.finished, !placing, lines.prefix(batch.items.count).allSatisfy(\.isEnded) {
                if recipe.destination == .share { shareFiles = batch.files }
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        isRunning = false
        stopping = false
        // Files: every finished picture is in the folder, so the batch's own copies go.
        if recipe.destination == .files, exporter.batch?.folder == token { exporter.clear() }
        Log.note(.export, "mac batch ended", ["saved": saved, "problems": problems.count, "stopped": wasStopped])
    }

    // MARK: the folder

    /// `file` into `folder` as `name`, or "-2", "-3" where the folder has the name already: copied in under
    /// a hidden name first and renamed only when whole, so no file in the folder is ever half written or
    /// written over.
    nonisolated static func place(_ file: URL, named name: String, in folder: URL) throws -> URL {
        let fm = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(".\(UUID().uuidString).spkpart")
        try fm.copyItem(at: file, to: part)
        defer { try? fm.removeItem(at: part) }
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...9_999 {
            let candidate = n == 1 ? name : "\(stem)-\(n)" + (ext.isEmpty ? "" : "." + ext)
            let target = folder.appendingPathComponent(candidate)
            if renamex_np(part.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            switch errno {
            case EEXIST: continue
            case ENOTSUP, EINVAL:
                // A disk that cannot rename exclusively (some network and FAT volumes): looked at first.
                if fm.fileExists(atPath: target.path) { continue }
                try fm.moveItem(at: part, to: target)
                return target
            default:
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}

/// The folder Save to Files puts a Mac batch in: chosen once (Finder's open panel), kept for the next.
enum MacExportFolder {
    private static let key = "mac.export.folder"

    static func saved(in defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func remember(_ url: URL, in defaults: UserDefaults = .standard) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData() { defaults.set(data, forKey: key) }
    }

    /// "hanze › Pictures › Export", as Finder's sidebar names the place.
    @MainActor static func place(_ url: URL) -> String {
        FolderReach.place(of: url, device: FolderReach.thisDevice).location.joined(separator: " › ")
    }
}
