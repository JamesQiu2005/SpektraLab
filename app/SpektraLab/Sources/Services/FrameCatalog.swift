//  FrameCatalog.swift — the hub: every frame, and what the library page needs of it.
//
//  The Library is home (design/flow, B). Imports land here, and
//  join one develop queue — the same ring on the tile, the same
//  `Developing n` chip. The store holds the frames and their states; the
//  scheduler tells it when a frame's job moves (`apply`).
//
//  On a host the frames are kept on disk (`LibraryPersistence`): read at
//  launch, written a moment after a change. The simulator, the snapshot
//  harness and `--demo` hold the demo library (`DemoLibrary`) in memory.

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class FrameCatalog {
    enum Filter: Hashable, Sendable { case all, developing, favourites, film(String) }

    /// What an import did, said once on the library page (B3), with the stock
    /// it developed with — which can still change.
    struct ImportBanner: Equatable, Sendable {
        var imported: Int
        var developed: Int
        var frameIDs: [LibraryFrame.ID]
        var done: Bool { developed >= imported }
    }

    private(set) var frames: [LibraryFrame]
    /// The frame shown large at the top of the library.
    var selectedID: LibraryFrame.ID?
    var filter: Filter = .all

    // Select (B4)
    var isSelecting = false
    var picked: Set<LibraryFrame.ID> = []
    /// What Copy Settings took (C7), pasted from Select.
    var clipboard: SettingsClip?

    // Sources (F1) and storage (F5)
    var linkedFolders: [LinkedFolder]
    var storage: StorageReport
    var importBanner: ImportBanner?
    /// Where the lists of the library's frames keep their sort, oldest first or not (a preference
    /// kept on the device).
    static let oldestFirstKey = "library.oldestFirst"

    /// "Now", for the grid's day names. The snapshot harness pins it.
    var now: () -> Date = Date.init
    /// The library on disk, where there is one.
    @ObservationIgnored var persistence: LibraryPersistence?
    /// What the app keeps on the device has just been measured (`measureStorage`).
    @ObservationIgnored var onMeasured: (() -> Void)?

    init(_ seed: DemoLibrary.Seed) {
        frames = seed.frames
        selectedID = seed.selectedID
        linkedFolders = seed.linkedFolders
        storage = seed.storage
        importBanner = seed.importBanner
        now = seed.now
    }

    // MARK: reading

    func frame(_ id: LibraryFrame.ID?) -> LibraryFrame? {
        guard let id, let i = position(of: id) else { return nil }
        return frames[i]
    }

    /// Where each frame was last found in `frames`. Checked on every read (the frame at that place must
    /// be the one asked), and made again on a miss, so it is never wrong and never slower than the walk it
    /// replaces (2026-11-05: the Mac's grid looks every row's frame up on each render, and every develop's
    /// state change renders it; 500 queued previews made each render ~500 × 1,000 comparisons, and the
    /// window lagged ~0.6 s).
    @ObservationIgnored private var positions: [LibraryFrame.ID: Int] = [:]

    private func position(of id: LibraryFrame.ID) -> Int? {
        if let i = positions[id], i < frames.count, frames[i].id == id { return i }
        positions = Dictionary(frames.indices.map { (frames[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        return positions[id]
    }

    var selected: LibraryFrame? { frame(selectedID) ?? frames.first }

    var isEmpty: Bool { frames.isEmpty }

    /// Frames in the one queue: the `Developing n` chip.
    var developingCount: Int { frames.filter(\.develop.isBusy).count }

    var visible: [LibraryFrame] {
        switch filter {
        case .all: frames
        case .developing: frames.filter(\.develop.isBusy)
        case .favourites: frames.filter(\.isFavourite)
        case .film(let id): frames.filter { $0.edit.params.filmStock == id }
        }
    }

    /// Linked disks that are not connected, with how many frames each holds:
    /// the library says it once, above their frames (F2).
    var disconnected: [(disk: String, frames: Int)] {
        var count: [String: Int] = [:]
        for f in frames { if case .offline(let disk) = f.original { count[disk, default: 0] += 1 } }
        // The folder's own count is the truth where the demo shows only a few of its frames.
        return count.keys.sorted().map { disk in
            (disk, linkedFolders.first { $0.volume == disk }?.frameCount ?? count[disk]!)
        }
    }

    // MARK: the library on disk

    /// Reads the frames kept on disk into the library, and what the device
    /// holds. Called once, at launch, on a host.
    func load(from persistence: LibraryPersistence) {
        self.persistence = persistence
        if let stored = persistence.load() {
            frames = stored.frames.map(\.frame)
            selectedID = stored.selectedID ?? frames.last?.id
            // A library kept by a build from before 2026-10-09 may hold a
            // slide film still set to print on a paper: it is scanned from
            // here on (`Stock.swift`, "the film decides"). Its kept develop
            // was a print, so its stamp no longer matches and it is developed
            // again at launch (`AppServices.developStale`).
            var held = false
            for i in frames.indices {
                let edit = frames[i].edit.heldToItsFilm()
                if edit != frames[i].edit { frames[i].edit = edit; held = true }
            }
            // The folders linked before, each asked for again through its
            // bookmark: connected when it answers, and its frames away when
            // it does not (the unplugged disk of F2). Since 2026-10-21 by
            // the check *Check Again* runs too (`FolderReach`): where each
            // is, why one is away, and a frame found again by its path under
            // a folder that was renamed.
            linkedFolders = (stored.folders ?? []).map(\.folder)
            let device = FolderReach.thisDevice
            let checks = linkedFolders.map { FolderReach.check($0, holding: nil, device: device) }
            var renewed = take(checks)
            for folder in linkedFolders where folder.bookmark != nil {
                let looks = looks(of: folder)
                renewed = apply(FolderReach.survey(looks, at: reached[folder.id]?.url, volume: folder.volume), to: folder.id)
                    || renewed
            }
            // on the Mac such a frame is the Mac
            // library's (`ImportService.adoptLibraryFiles`), and its file says where it is.
            if recheckLooseFiles() { renewed = true }
            if renewed || held { changed() }
            watchFolders()
        }
        measureStorage()
    }

    /// A frame or a folder changed, came or went: written a moment later. Inside `batch`, once at its end.
    private func changed() {
        if batching > 0 { changedInBatch = true; return }
        persistence?.save(frames, folders: linkedFolders, selectedID: selectedID)
    }

    @ObservationIgnored private var batching = 0
    @ObservationIgnored private var changedInBatch = false

    /// Many changes, one save (2026-11-05): `save` maps every frame to its stored form on the main thread
    /// before it debounces, so a launch's catch-up over N frames, one `update` each, did N² of that.
    func batch(_ body: () -> Void) {
        batching += 1
        body()
        batching -= 1
        if batching == 0, changedInBatch { changedInBatch = false; changed() }
    }

    /// The library as it stands, written now: before files that a change has
    /// left behind are deleted (`AppServices.remove`), so that the library on
    /// disk never names a file that is gone.
    func flush() {
        persistence?.saveNow(frames, folders: linkedFolders, selectedID: selectedID)
    }

    /// A folder just linked, with its bookmark, joins the list — and the disk.
    /// `url`: where it was picked, whose access `ImportService` holds.
    func addFolder(_ folder: LinkedFolder, at url: URL? = nil) {
        linkedFolders.append(folder)
        if let url { reached[folder.id] = (url, false) }
        changed()
    }

    /// The list replaced whole (the first run, the demo restored): written too.
    func replaceFolders(_ folders: [LinkedFolder]) {
        linkedFolders = folders
        changed()
    }

    func setKeepsLocalCopy(_ id: LinkedFolder.ID, _ on: Bool) {
        guard let i = linkedFolders.firstIndex(where: { $0.id == id }), linkedFolders[i].keepsLocalCopy != on else { return }
        linkedFolders[i].keepsLocalCopy = on
        changed()
    }

    // MARK: the linked folders, checked (2026-10-21)

    /// Where each folder answered last, and whether the scoped access to it is this store's to let go
    /// (false: `ImportService` holds it, for a folder linked or reconnected in this session).
    @ObservationIgnored private var reached: [LinkedFolder.ID: (url: URL, mine: Bool)] = [:]
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var checkAgain = false
    @ObservationIgnored private var watchers: [NSObjectProtocol] = []

    /// Where a connected folder is in this session: *Show in Files*.
    func url(of folder: LinkedFolder.ID) -> URL? { reached[folder]?.url }

    /// The library's frames from a folder.
    func frames(of folder: LinkedFolder) -> [LibraryFrame] { frames.filter { folder.holds($0.source) } }

    /// Every folder asked for again now, as at launch: connected or not, and why; where it is; and,
    /// `full`, where each of its frames' files is. A light check (`full` false: the poll while a
    /// Sources list is shown) looks at the frames only of a folder whose answer changed. A check
    /// asked for while one runs runs once more after it.
    func recheckFolders(full: Bool = true) async {
        if recheckLooseFiles() { changed() }
        guard !checking else { if full { checkAgain = true }; return }
        let folders = linkedFolders.filter { $0.bookmark != nil }
        guard !folders.isEmpty else { return }
        checking = true
        defer { checking = false }
        let holding = reached.mapValues(\.url)
        let device = FolderReach.thisDevice
        let began = ContinuousClock.now
        let checks = await Task.detached(priority: .utility) {
            folders.map { FolderReach.check($0, holding: holding[$0.id], device: device) }
        }.value
        let before = Dictionary(uniqueKeysWithValues: linkedFolders.map { ($0.id, ($0.status, reached[$0.id]?.url)) })
        var write = take(checks)
        for folder in linkedFolders where folder.bookmark != nil {
            let answered = reached[folder.id]?.url
            let was = before[folder.id]
            let sameURL = switch (was?.1, answered) {
            case (nil, nil): true
            case (let a?, let b?): FolderReach.same(a, b)
            default: false
            }
            guard full || was?.0 != folder.status || !sameURL else { continue }
            let looks = looks(of: folder), volume = folder.volume
            let findings = await Task.detached(priority: .utility) {
                FolderReach.survey(looks, at: answered, volume: volume)
            }.value
            write = apply(findings, to: folder.id) || write
        }
        if write { changed() }
        let took = ContinuousClock.now - began
        // The poll's checks that found nothing new are not written: two a minute would fill the log.
        if full || write { Log.note(.library, "folders checked",["folders": folders.count, "full": full,
                                               "connected": linkedFolders.filter(\.isConnected).count,
                                               "ms": (took / .milliseconds(1) * 10).rounded() / 10]) }
        #if DEBUG
        NSLog("[folders] %@ check of %d folders in %.2f ms", full ? "full" : "light", folders.count, took / .milliseconds(1))
        #endif
        if checkAgain {
            checkAgain = false
            checking = false
            await recheckFolders(full: true)
        }
    }

    /// Asks again every 30 s while the calling page is on the screen (its `.task`): the operating system tells an app
    /// nothing when a disk is plugged in or out. Each check resolves a bookmark and opens nothing.
    func pollFolders() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await recheckFolders(full: false)
        }
    }

    /// The folder reached again where the user picked it (*Reconnect…*): its bookmark renewed, its
    /// name and volume those of where it now is — its frames' with it — and each frame reading its
    /// file there (`findings`, by its path under the folder).
    func reconnect(_ id: LinkedFolder.ID, at url: URL, bookmark: Data?, place: FolderReach.Place,
                   findings: [FolderReach.Finding]) {
        guard let i = linkedFolders.firstIndex(where: { $0.id == id }) else { return }
        if let held = reached[id], held.mine, !FolderReach.same(held.url, url) { held.url.stopAccessingSecurityScopedResource() }
        reached[id] = (url, false)
        retarget(i, volume: place.volume, path: url.lastPathComponent)
        linkedFolders[i].kind = place.kind
        if let bookmark { linkedFolders[i].bookmark = bookmark }
        linkedFolders[i].isConnected = true
        linkedFolders[i].lost = nil
        linkedFolders[i].location = place.location
        _ = apply(findings, to: id)
        changed()
    }

    /// The folder leaves Sources (*Unlink*); its frames are `AppServices.remove`'s to take, and no file
    /// in it is touched.
    func removeFolder(_ id: LinkedFolder.ID) {
        if let held = reached.removeValue(forKey: id) {
            if held.mine { held.url.stopAccessingSecurityScopedResource() } else { ImportService.letGo(held.url) }
        }
        linkedFolders.removeAll { $0.id == id }
        changed()
    }

    /// The checks taken into the folders: whether each answered, why not, where it is, its bookmark
    /// renewed, and its new name where it was renamed on its volume. Returns whether anything kept
    /// on disk changed.
    private func take(_ checks: [FolderReach.Check]) -> Bool {
        var write = false
        for check in checks {
            guard let i = linkedFolders.firstIndex(where: { $0.id == check.id }), linkedFolders[i].bookmark != nil else {
                if check.startedAccess { check.url?.stopAccessingSecurityScopedResource() }
                continue
            }
            // The access held: the one this check began, or the one held before when it is the same place.
            if let held = reached[check.id], check.url.map({ FolderReach.same(held.url, $0) }) != true {
                if held.mine { held.url.stopAccessingSecurityScopedResource() }
                reached[check.id] = nil
            }
            if let url = check.url, check.startedAccess { reached[check.id] = (url, true) }
            else if let url = check.url, reached[check.id] == nil { reached[check.id] = (url, false) }
            let before = linkedFolders[i]
            linkedFolders[i].isConnected = check.url != nil
            linkedFolders[i].lost = check.lost
            if let fresh = check.fresh { linkedFolders[i].bookmark = fresh }
            if let place = check.place { linkedFolders[i].location = place.location }
            // Renamed where it is (a bookmark follows a rename and a move on its volume): its name
            // and its frames' follow, so the rows say what Files says.
            if let url = check.url, url.lastPathComponent != linkedFolders[i].path, !url.lastPathComponent.isEmpty {
                retarget(i, volume: linkedFolders[i].volume, path: url.lastPathComponent)
            }
            let after = linkedFolders[i]
            if after.bookmark != before.bookmark || after.location != before.location || after.path != before.path { write = true }
        }
        return write
    }

    /// A folder's frames, for the survey: those whose original the folder decides.
    private func looks(of folder: LinkedFolder) -> [FolderReach.FrameLook] {
        frames.compactMap { f in
            guard case .linkedFolder(_, let path) = f.source, folder.holds(f.source) else { return nil }
            switch f.original {
            case .available, .offline, .missing:
                return FolderReach.FrameLook(id: f.id, sourcePath: path, fileName: f.fileName, file: f.picture.fileURL)
            case .inCloud: return nil
            }
        }
    }

    /// What the survey found, in the frames and in the folder's counts. A frame whose state moved
    /// meanwhile from the three the survey looks at is left as it is. Returns whether anything kept
    /// on disk changed.
    @discardableResult
    func apply(_ findings: [FolderReach.Finding], to folderID: LinkedFolder.ID) -> Bool {
        var write = false
        for finding in findings {
            guard let i = frames.firstIndex(where: { $0.id == finding.id }) else { continue }
            switch frames[i].original {
            case .available, .offline, .missing: break
            case .inCloud: continue
            }
            if frames[i].original != finding.original { frames[i].original = finding.original; write = true }
            if let moved = finding.moved, !frames[i].isDemo { frames[i].picture = .file(moved); write = true }
        }
        if let j = linkedFolders.firstIndex(where: { $0.id == folderID }) {
            let cloud = findings.filter(\.cloudOnly).count
            let count = frames.filter { linkedFolders[j].holds($0.source) }.count
            if linkedFolders[j].isConnected, linkedFolders[j].stillInCloud != cloud { linkedFolders[j].stillInCloud = cloud; write = true }
            if linkedFolders[j].frameCount != count { linkedFolders[j].frameCount = count; write = true }
        }
        return write
    }

    /// The folder's name and volume changed, and every one of its frames' with it ("DCIM › 100RICOH"
    /// becomes "Card › 100RICOH").
    private func retarget(_ i: Int, volume: String, path: String) {
        let old = linkedFolders[i]
        guard old.volume != volume || old.path != path else { return }
        for j in frames.indices where old.holds(frames[j].source) {
            guard case .linkedFolder(_, let p) = frames[j].source else { continue }
            frames[j].source = .linkedFolder(disk: volume, path: path + p.dropFirst(old.path.count))
        }
        linkedFolders[i].volume = volume
        linkedFolders[i].path = path
    }

    /// Mac change . A frame the Mac library made
    /// (`ImportService.adoptLibraryFiles`: a picture of a catalog, a session or a folder opened in
    /// Develop, exported or carried) has a linked folder's kind of source and no linked folder. The
    /// launch used to mark every such frame away ("linked by a build that kept no folder") and nothing
    /// ever brought it back, so a whole library of pictures on a connected disk read *Not connected*
    /// (the owner, 2026-10-24). Its file is asked instead: there, available; gone from a disk that is
    /// here, missing; on a disk that is not mounted, away. Asked at launch and with every folder check
    /// (activation, *Check Again*, a disk mounting or ejecting). Returns whether a frame changed.
    @discardableResult
    func recheckLooseFiles() -> Bool {
        let fm = FileManager.default
        var moved = false
        for i in frames.indices {
            guard case .linkedFolder(let disk, _) = frames[i].source,
                  !linkedFolders.contains(where: { $0.holds(frames[i].source) }),
                  let url = frames[i].picture.fileURL else { continue }
            if case .inCloud = frames[i].original { continue }
            let state: OriginalState
            if fm.fileExists(atPath: url.path) {
                state = .available
            } else {
                let parts = url.standardizedFileURL.pathComponents
                let volume = parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : "/"
                state = fm.fileExists(atPath: volume) ? .missing : .offline(disk: disk)
            }
            if frames[i].original != state { frames[i].original = state; moved = true }
        }
        return moved
    }

    /// Checks again when the app comes back to the front (a disk may have been plugged in, a folder
    /// moved in Files meanwhile) and when the iCloud account changes.
    private func watchFolders() {
        guard watchers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.didBecomeActiveNotification, .NSUbiquityIdentityDidChange] {
            watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.recheckFolders() }
            })
        }
    }

    func measureStorage() {
        guard persistence != nil else { return }
        let previous = storage
        Task.detached(priority: .utility) { [weak self] in
            let report = LibraryPersistence.storageReport(previous: previous)
            await self?.measured(report)
        }
    }

    private func measured(_ report: StorageReport) {
        // The limits are the page's to set meanwhile: only the figures are the measurement's.
        var measured = report
        measured.workingCopiesLimit = storage.workingCopiesLimit
        measured.previewCopiesLimit = storage.previewCopiesLimit
        storage = measured
        onMeasured?()
    }

    // MARK: changing

    func update(_ id: LibraryFrame.ID, _ change: (inout LibraryFrame) -> Void) {
        guard let i = position(of: id) else { return }
        let before = frames[i]
        change(&frames[i])
        // The develop state is not kept; anything else is.
        var after = frames[i]
        after.develop = before.develop
        if after != before { changed() }
    }

    func add(_ new: [LibraryFrame]) {
        frames.append(contentsOf: new)
        if selectedID == nil { selectedID = new.first?.id }
        changed()
        measureStorage()
    }

    func toggleFavourite(_ id: LibraryFrame.ID) { update(id) { $0.isFavourite.toggle() } }

    /// Removes frames from the library, and no file: what the app kept of them
    /// goes with them in `AppServices.remove`. Never an original in Photos or in
    /// a linked folder; a copied-in original goes with its frame.
    func remove(_ ids: Set<LibraryFrame.ID>) {
        frames.removeAll { ids.contains($0.id) }
        picked.subtract(ids)
        if let s = selectedID, ids.contains(s) { selectedID = frames.first?.id }
        changed()
        measureStorage()
    }

    func togglePick(_ id: LibraryFrame.ID) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    func endSelecting() { isSelecting = false; picked = [] }

    /// Paste the clipboard onto frames: settings, not solved numbers. Returns
    /// the frames that changed, which must develop again. A frame whose
    /// paste changed Edit's layer alone (Light, Curve, Colour) is not one of
    /// them: its picture is the same develop, and its edited copy follows
    /// (`Layer2Copies`).
    @discardableResult
    /// `clip`: the clip a paste took at its press, where it lands later (the Mac's, after its frames are
    /// made); the clipboard as it is now otherwise.
    func paste(onto ids: Set<LibraryFrame.ID>, clip held: SettingsClip? = nil) -> [LibraryFrame.ID] {
        guard let clip = held ?? clipboard else { return [] }
        var changed: [LibraryFrame.ID] = []
        var any = false
        for id in ids {
            guard let i = frames.firstIndex(where: { $0.id == id }) else { continue }
            // A film pasted without its scan, or a paper pasted under a slide:
            // the film still decides whether there is a print. And a film's
            // size pasted from a picture of another shape is this picture's
            // length on that film, not the other's; a film edge lies along this picture.
            var pasted = clip.applied(to: frames[i].edit, picture: frames[i].originalSize).held(to: frames[i].originalSize)
            // Onto a half-frame pair: its look has no cut and no film edge of a frame's own.
            if frames[i].isPair { pasted = pasted.asPairLook }
            guard pasted != frames[i].edit else { continue }
            var beside = pasted
            beside.adjustments = frames[i].edit.adjustments
            if beside != frames[i].edit { changed.append(id) }
            frames[i].edit = pasted
            any = true
        }
        if any { self.changed() }
        return changed
    }

    // MARK: the scheduler's news

    /// A job moved. Canvas jobs belong to the develop page and do not put a
    /// ring on the tile; everything else is the frame's own develop. Not the Mac's
    /// full-size prefetch of Develop's neighbour (an `importDevelop` at the full tier,
    /// `MacRenderCache`): it is the page's, not the frame's picture, and its ring,
    /// or its cancel read as `.developed`, would stand for a develop that is not there.
    func apply(_ snapshot: JobSnapshot) {
        let job = snapshot.job
        guard job.kind == .shot || (job.kind == .importDevelop && job.tier != .full) else { return }
        update(job.frameID) { frame in
            switch snapshot.state {
            case .queued: frame.develop = .queued
            case .waiting(let why): frame.develop = .waiting(why)
            case .running(let p): frame.develop = .developing(progress: p.fraction)
            case .done: frame.develop = .developed
            case .cancelled: frame.develop = .developed
            case .failed(let message): frame.develop = .failed(message)
            }
        }
        if case .done = snapshot.state, var banner = importBanner, banner.frameIDs.contains(job.frameID) {
            banner.developed = banner.frameIDs.filter { frame($0)?.develop == .developed }.count
            importBanner = banner
        }
    }
}
