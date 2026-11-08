//  MacImportSession.swift — the import page's state and the import itself (2026-10-24).
//
//  The owner: "keep them on the external disk, let our own .spkcatalog be created, and import in batches
//  … choose either to keep them in their original place or copy them to a selectable folder location —
//  the same behaviour as Capture One's." One session is one pass of the flow: what was picked in Finder,
//  what the scan found (`MacImportScan`), the choices of Capture One's Import Images window (Import From,
//  Import To, Filters), the selection (its own `MacLibraryBrowser`, never `.shared`), and the run.
//
//  The run, in chunks of `chunkSize` files:
//  - **Add to Catalog** (Capture One's "Current Location"): the files are referenced where they are.
//  - **Copy to Folder**: the app copies each file under the chosen folder itself, keeping the path below
//    the picked folder ("_prints/x.tif"), never overwriting ("_1", "_2" as the helper does), then adds the
//    copies by reference. The originals are only read.
//  - **Copy into the Catalog** (or the session's Capture folder): the helper copies (`mode: copy`).
//  The first chunk that adds anything makes the import's one Recent Imports album; the others go into it
//  (`MacLibraryData.importChunk`). Then the library shows the destination and that album.
//
//  Not a watched folder: `folders.add` is a sync, this is an import (the lead, 2026-10-24).

import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MacImportSession {
    /// The rows' source id in the page's grid: not a source of the store's.
    static let gridSource = UUID(uuidString: "5B4C1A00-0000-4000-8000-0000000000F1")!
    /// Files per `images.add`.
    static let chunkSize = 200

    enum Placement: String, CaseIterable, Hashable {
        /// Referenced where they are (Capture One's "Add to Catalog — your files stay where they are").
        case inPlace
        /// Copied by the app under a chosen folder, then referenced there.
        case copyToFolder
        /// Copied by the helper into the catalog's `Originals/yyyy/mm/dd`, or a session's `Capture`.
        case intoLibrary
    }

    enum Destination: Hashable {
        case source(MacSource.ID)
        /// A `.spkcatalog` made when the import starts (`newCatalogName` in `newCatalogFolder`).
        case newCatalog
    }

    struct Progress: Equatable {
        enum Phase: Equatable { case creating, copying, adding, finishing }
        var phase: Phase
        var done: Int
        var total: Int
    }

    struct Result: Equatable {
        var destination: MacSource.ID
        var added = 0
        var existing = 0
        var copied = 0
        var failed: [String: String] = [:]
        var album: String?
        var chunks = 0
        var seconds: Double = 0
        /// Where each picked file landed (itself, or its copy), in the order imported.
        var files: [URL] = []
    }

    let store: any MacLibraryData
    /// The page's selection, marquee and keys: its own, so the library's selection is left as it was.
    let browser = MacLibraryBrowser()

    // Import From
    private(set) var picked: [URL] = []
    /// Some picks are copies the system handed over for a drop from another app (`MacImportDrop`), in a
    /// temporary folder: they are copied into the catalog or to a folder, never referenced there.
    private(set) var picksAreCopies = false
    var includeSubfolders = true { didSet { if includeSubfolders != oldValue { rescan() } } }
    var excludeDuplicates = true { didSet { refreshRows() } }

    // What was found
    private(set) var files: [MacFoundFile] = []
    private(set) var tally = MacImportScan.Tally()
    private(set) var scanning = false
    private(set) var readingHeaders = false
    /// The visible rows (filters applied), in name order, as the grid's `MacImage`s.
    private(set) var rows: [MacImage] = []
    private var byPath: [String: Int] = [:]

    // Filters (Capture One's: format, date). Empty is "all".
    var formats: Set<String> = [] { didSet { refreshRows() } }
    var days: Set<String> = [] { didSet { refreshRows() } }

    // Import To
    var destination: Destination? { didSet { if destination != oldValue { destinationChanged() } } }
    var placement: Placement = .inPlace
    var copyFolder: URL?
    var newCatalogName = "SpektraLab Catalog"
    var newCatalogFolder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures")
    private(set) var existing: MacImportExisting?
    private(set) var loadingExisting = false

    // The run
    private(set) var progress: Progress?
    private(set) var result: Result?
    private(set) var problem: String?
    /// Asked to stop: the run ends after the chunk in hand.
    var stopAsked = false
    /// The page's Finder panel is up (`MacImportPage.ask`): a drop then is refused, never wiped by the
    /// panel's answer (`MacImportDrop.accepts`).
    var finderUp = false
    /// `close()` has run (Cancel, an import done): the page is going and takes no more drops.
    @ObservationIgnored private(set) var closed = false
    #if DEBUG
    /// The page's Cancel, for the driver and the checks (`MacImportFlow.finish`; it holds no view).
    @ObservationIgnored var debugCancel: (() -> Void)?
    #endif

    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var existingTask: Task<Void, Never>?
    @ObservationIgnored private var scoped: [URL] = []
    @ObservationIgnored private var scanStarted = ContinuousClock.now
    /// How long the last scan's listing and headers took, seconds.
    private(set) var listedIn: Double?
    private(set) var scannedIn: Double?

    init(store: any MacLibraryData) {
        self.store = store
        destination = Self.defaultDestination(store)
        placement = defaultPlacement
        destinationChanged()
    }

    /// A word for the page's status line from outside it (a drop that held nothing to import).
    func say(_ words: String) { problem = words }

    /// Ends the session: the scan stopped, security-scoped access given back, a drop's temporary copies
    /// removed (an import has copied them by then: `picksAreCopies` never lets them be referenced).
    func close() {
        closed = true
        scan?.cancel()
        existingTask?.cancel()
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = []
        MacImportDrop.discard(picked)
    }

    // MARK: - Import From

    /// Import's picker also opens library documents. A catalog is a source, never a folder to crawl
    /// for previews and Originals. In a mixed pick, photo files go into the last writable source opened.
    /// True means only libraries were picked and the import page can close.
    /// `adding`: a drop on the open page — the pictures join what was picked. `copies`: they are a drop's
    /// temporary copies (`picksAreCopies`).
    func receivePicks(_ urls: [URL], adding: Bool = false, copies: Bool = false) async -> Bool {
        problem = nil
        let documents = urls.filter { MacLibraryDocuments.kind(of: $0) != nil }
        let photos = urls.filter { MacLibraryDocuments.kind(of: $0) == nil }
        for url in documents {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try await store.open(url)
                if source.kind == .catalog || source.kind == .session { destination = .source(source.id) }
            } catch {
                problem = error.localizedDescription
                return false
            }
        }
        if photos.isEmpty { return !documents.isEmpty && !adding }
        let known = Set(picked.map(\.standardizedFileURL))
        let all = adding ? picked + photos.filter { !known.contains($0.standardizedFileURL) } : photos
        // Picks replaced (the Finder panel's Choose…): a drop's temporary copies among them go with them.
        if !adding {
            let kept = Set(all.map(\.standardizedFileURL))
            MacImportDrop.discard(picked.filter { !kept.contains($0.standardizedFileURL) })
        }
        picksAreCopies = (adding && picksAreCopies) || copies
        if picksAreCopies, placement == .inPlace { placement = .intoLibrary }
        pick(all)
        return false
    }

    /// What Finder gave: folders and pictures. Replaces what was picked before.
    func pick(_ urls: [URL]) {
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        picked = urls
        rescan()
    }

    /// "115NZ7_2", "3 folders, 2 files".
    var pickedTitle: String {
        if picked.count == 1, let one = picked.first { return one.lastPathComponent }
        let folders = picked.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.count
        let loose = picked.count - folders
        switch (folders, loose) {
        case (_, 0): return L("\(folders) folders")
        case (0, _): return L("\(loose) files")
        default: return L("\(folders) folders, \(loose) files")
        }
    }

    func rescan() {
        scan?.cancel()
        files = []
        byPath = [:]
        tally = .init()
        browser.collectionChanged()
        listedIn = nil
        scannedIn = nil
        formats = []
        days = []
        refreshRows()
        guard !picked.isEmpty else { return }
        scanning = true
        readingHeaders = true
        scanStarted = .now
        let stream = MacImportScan.run(picked, subfolders: includeSubfolders)
        scan = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.take(event)
            }
        }
    }

    /// Waits for the scan in hand to finish (the check's; the page just watches `scanning`).
    func scanFinished() async {
        await scan?.value
    }

    private func take(_ event: MacImportScan.Event) {
        switch event {
        case .found(let batch):
            files += batch
            files.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
            reindex()
            refreshRows()
        case .headers(let read):
            var dropped = false
            for (path, header) in read {
                guard let i = byPath[path] else { continue }
                if let header {
                    files[i].header = header
                    files[i].headerRead = true
                } else {
                    files[i].headerRead = true
                    files[i].header = nil
                    dropped = true
                }
            }
            if dropped {
                files.removeAll { $0.headerRead && $0.header == nil }
                reindex()
            }
            refreshRows()
        case .listed(let t):
            tally = t
            scanning = false
            listedIn = seconds(since: scanStarted)
        case .done(let t):
            tally = t
            scanning = false
            readingHeaders = false
            scannedIn = seconds(since: scanStarted)
        }
    }

    private func reindex() {
        byPath = Dictionary(files.enumerated().map { ($1.url.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - rows, filters, duplicates

    /// The formats found, with counts: "NEF 628", "JPG 1".
    var formatCounts: [(format: String, count: Int)] {
        Dictionary(grouping: files, by: \.format).map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }
    }

    /// The capture days found ("2026-10-03"), newest first, with counts; "" is undated.
    var dayCounts: [(day: String, count: Int)] {
        Dictionary(grouping: files, by: Self.day).map { ($0.key, $0.value.count) }.sorted { $0.day > $1.day }
    }

    nonisolated static func day(_ f: MacFoundFile) -> String { String((f.header?.capturedLocal ?? "").prefix(10)) }

    func isDuplicate(_ f: MacFoundFile) -> Bool {
        existing?.holds(path: f.url.path, name: f.name, size: f.size) ?? false
    }

    /// Duplicates of the visible rows (`isDuplicate`), whether or not they are excluded.
    var duplicateCount: Int { files.filter(isDuplicate).count }

    func isExcluded(_ id: MacImage.ID) -> Bool {
        guard excludeDuplicates, let i = byPath[id.image] else { return false }
        return isDuplicate(files[i])
    }

    func file(_ id: MacImage.ID) -> MacFoundFile? { byPath[id.image].map { files[$0] } }

    func refreshRows() {
        rows = files.filter { f in
            (formats.isEmpty || formats.contains(f.format)) && (days.isEmpty || days.contains(Self.day(f)))
        }.map(row)
        browser.selection.formIntersection(Set(rows.map(\.id)))
    }

    private func row(_ f: MacFoundFile) -> MacImage {
        let d = f.header
        let exposure = Self.exposureText(d)
        return MacImage(
            id: .init(source: Self.gridSource, image: f.url.path), url: f.url, fileName: f.name, kind: f.kind,
            capturedLocal: d?.capturedLocal, captureDate: CatalogSourcesStore.wallClock(d?.capturedLocal), rating: 0, colorLabel: nil,
            cameraMake: d?.cameraMake, cameraModel: d?.cameraModel, lens: d?.lens, exposure: exposure,
            pixelSize: d?.width.flatMap { w in d?.height.map { PixelSize(width: w, height: $0) } },
            isOffline: false, isTrashed: false, isRemoved: false, fromCaptureOne: false, primaryVariant: nil,
            variantCount: 1, develop: nil)
    }

    /// "1/250 s · f/5.6 · ISO 100", as the library's rows say it (`CatalogSourcesStore.exposureText`).
    nonisolated static func exposureText(_ d: LibraryDescription?) -> String? {
        guard let d else { return nil }
        var parts: [String] = []
        if let t = d.shutter, t > 0 { parts.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%g s", (t * 10).rounded() / 10)) }
        if let f = d.aperture, f > 0 { parts.append(String(format: "f/%g", (f * 10).rounded() / 10)) }
        if let iso = d.iso, iso > 0 { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the primary button imports: the chosen rows, or with none chosen every visible row; never an
    /// excluded duplicate.
    var toImport: [MacImage] {
        let chosen = browser.selection
        let base = chosen.isEmpty ? rows : rows.filter { chosen.contains($0.id) }
        return base.filter { !isExcluded($0.id) }
    }

    /// "Import All (629)" with nothing chosen, "Import 12 Selected" with a selection.
    var importTitle: String {
        let n = toImport.count
        return browser.selection.isEmpty ? L("Import All (\(n.formatted()))") : L("Import \(n.formatted()) Selected")
    }

    // MARK: - Import To

    /// The catalogs and sessions an import may go to: SpektraLab's and a Capture One catalog (into its
    /// mirror, 2026-10-24), never the app library.
    var destinations: [MacSource] { store.sources.filter(\.acceptsImports) }

    /// The selected source if it takes imports; else the most recently opened one; else a new catalog.
    static func defaultDestination(_ store: any MacLibraryData) -> Destination {
        if let s = store.selectedSource, s.acceptsImports { return .source(s.id) }
        let recent = store.sources.filter(\.acceptsImports).max { ($0.openedAt ?? $0.addedAt) < ($1.openedAt ?? $1.addedAt) }
        return recent.map { .source($0.id) } ?? .newCatalog
    }

    var destinationSource: MacSource? {
        guard case .source(let id)? = destination else { return nil }
        return store.sources.first { $0.id == id }
    }

    /// A catalog's word, or a session's.
    var intoLibraryTitle: String {
        destinationSource?.kind == .session ? L("Copy into the Session's Capture Folder") : L("Copy into the Catalog")
    }

    /// Capture One's defaults: a catalog references the files where they are; a session copies them into
    /// its Capture folder (MAC-LIBRARY-DATA §6.1).
    var defaultPlacement: Placement {
        picksAreCopies || destinationSource?.defaultImport == .copy ? .intoLibrary : .inPlace
    }

    private func destinationChanged() {
        existingTask?.cancel()
        existing = nil
        // A chosen Copy to Folder is kept; otherwise the new destination's own default.
        if placement != .copyToFolder { placement = defaultPlacement }
        guard case .source(let id)? = destination else { loadingExisting = false; refreshRows(); return }
        loadingExisting = true
        existingTask = Task { [weak self] in
            guard let self else { return }
            let found = try? await self.store.existingFiles(in: id)
            guard !Task.isCancelled, self.destination == .source(id) else { return }
            self.existing = found ?? MacImportExisting()
            self.loadingExisting = false
            self.refreshRows()
        }
    }

    /// Waits for the destination's files to be read (the check's).
    func existingRead() async { await existingTask?.value }

    /// A name for the new catalog that is not taken in its folder: "SpektraLab Catalog", "… 2", ….
    static func freeName(_ name: String, in folder: URL) -> String {
        let fm = FileManager.default
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "SpektraLab Catalog" : name
        var candidate = base, n = 1
        while fm.fileExists(atPath: folder.appending(path: candidate + ".spkcatalog").path)
                || fm.fileExists(atPath: folder.appending(path: candidate).path) {
            n += 1
            candidate = "\(base) \(n)"
        }
        return candidate
    }

    /// Why the import cannot start yet, or nil.
    var notReady: String? {
        if picked.isEmpty { return L("Choose a folder or pictures to import.") }
        if destination == nil { return L("Choose where to import to.") }
        if placement == .copyToFolder, copyFolder == nil { return L("Choose the folder to copy to.") }
        if placement == .inPlace, picksAreCopies {
            return destinationSource?.kind == .session
                ? L("These pictures came from another app: copy them into the session's Capture folder or to a folder.")
                : L("These pictures came from another app: copy them into the catalog or to a folder.")
        }
        if toImport.isEmpty { return files.isEmpty && !scanning ? L("No pictures were found.") : nil }
        return nil
    }

    var canImport: Bool { notReady == nil && !toImport.isEmpty && progress == nil && !scanning && !readingHeaders }

    // MARK: - the run

    /// Imports `images` (the button's `toImport`, or any rows of the grid). Returns the result, also kept
    /// in `result`; a failure is kept in `problem`.
    @discardableResult
    func run(_ images: [MacImage]? = nil) async -> Result? {
        let asked: [MacImage] = images ?? toImport
        let chosen = asked.compactMap { self.file($0.id) }
        guard !chosen.isEmpty, let destination, progress == nil else { return nil }
        let t0 = ContinuousClock.now
        // Fixed for the run: the new catalog's `destination` below would otherwise reset it to that
        // catalog's default (caught by the check, 2026-10-24: a copy into a new catalog became a reference).
        let placement = self.placement
        problem = nil
        stopAsked = false
        do {
            let target: MacSource
            switch destination {
            case .source(let id):
                guard let s = store.sources.first(where: { $0.id == id }) else { throw MacLibraryError.noSource }
                target = s
            case .newCatalog:
                progress = .init(phase: .creating, done: 0, total: chosen.count)
                try FileManager.default.createDirectory(at: newCatalogFolder, withIntermediateDirectories: true)
                target = try await store.newCatalog(named: Self.freeName(newCatalogName, in: newCatalogFolder), in: newCatalogFolder)
                self.destination = .source(target.id)
                self.placement = placement
            }
            var out = Result(destination: target.id)
            let copyTo = placement == .copyToFolder ? copyFolder : nil
            if placement == .copyToFolder, copyTo == nil { throw MacLibraryError.notSupported("Choose the folder to copy to.") }
            var done = 0
            progress = .init(phase: copyTo == nil ? .adding : .copying, done: 0, total: chosen.count)
            for start in stride(from: 0, to: chosen.count, by: Self.chunkSize) {
                if stopAsked { break }
                let chunk = Array(chosen[start..<min(start + Self.chunkSize, chosen.count)])
                var items: [MacImportFile]
                if let copyTo {
                    progress = .init(phase: .copying, done: done, total: chosen.count)
                    let copied = await Self.copy(chunk, under: copyTo) { [weak self] n in
                        self?.progress = .init(phase: .copying, done: done + n, total: chosen.count)
                    }
                    for (path, why) in copied.failed { out.failed[path] = why }
                    out.copied += copied.files.count
                    items = copied.files
                } else {
                    items = chunk.map { MacImportFile(url: $0.url, header: $0.header) }
                }
                progress = .init(phase: .adding, done: done, total: chosen.count)
                let r = try await store.importChunk(items, into: target.id, copyIntoLibrary: placement == .intoLibrary, album: out.album)
                out.chunks += 1
                out.added += r.added
                out.existing += r.existing
                out.album = out.album ?? r.album
                for (path, why) in r.failed { out.failed[path] = why }
                out.files += items.map(\.url)
                done += chunk.count
                progress = .init(phase: .adding, done: done, total: chosen.count)
            }
            progress = .init(phase: .finishing, done: done, total: chosen.count)
            await store.showImport(in: target.id, album: out.album)
            out.seconds = seconds(since: t0)
            result = out
            progress = nil
            Log.note(.library, "mac import: done", ["added": out.added, "existing": out.existing, "copied": out.copied,
                                                    "failed": out.failed.count, "chunks": out.chunks, "seconds": out.seconds])
            return out
        } catch {
            progress = nil
            problem = error.localizedDescription
            Log.warn(.library, "mac import: stopped", ["error": error.localizedDescription])
            return nil
        }
    }

    /// The chunk's files copied under `folder`, each at its path below the folder it was picked from, off
    /// the main thread. A name that is taken is never overwritten: "_1", "_2" are tried, as the helper does.
    nonisolated static func copy(_ chunk: [MacFoundFile], under folder: URL,
                                 progress: @escaping @MainActor (Int) -> Void) async -> (files: [MacImportFile], failed: [String: String]) {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var files: [MacImportFile] = []
            var failed: [String: String] = [:]
            for (n, f) in chunk.enumerated() {
                if Task.isCancelled { break }
                var target = folder.appending(path: f.relative)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let stem = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
                    var i = 0
                    while fm.fileExists(atPath: target.path) {
                        i += 1
                        target = target.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)")
                    }
                    try fm.copyItem(at: f.url, to: target)
                    files.append(MacImportFile(url: target, header: f.header))
                } catch {
                    failed[f.url.path] = error.localizedDescription
                }
                if n % 4 == 3 || n == chunk.count - 1 { let k = n + 1; await progress(k) }
            }
            return (files, failed)
        }.value
    }

    private func seconds(since t: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
