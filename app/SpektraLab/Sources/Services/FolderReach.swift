//  FolderReach.swift — whether a linked folder answers, where it really is, and its frames' states.
//
//  The owner, 2026-10-21: "also for window, we also show in source, that where the linked folder
//  actually is, and manage the offline / online folder status. we do not yet do a full-scale
//  folder management system". So a folder is asked for again through its security-scoped bookmark
//  (`check`) at launch, when the app comes back to the front, every 30 s while a Sources list is on
//  the screen (the operating system says nothing when a disk is plugged in or out), and at *Check Again*; its place
//  is named as the Files app names it (`place`); and its frames are looked for where the folder now
//  is (`survey`). Nothing here writes to the folder.
//
//  | what the check finds                          | the folder                   | its frames                 |
//  |-----------------------------------------------|------------------------------|----------------------------|
//  | the bookmark answers and the folder reads      | connected                    | there, or *Original missing* |
//  | it answers under another name or place on its  | connected, renamed: its name | found again by their path  |
//  |   volume (a bookmark follows a move)           |   and its frames' follow     |   under it                 |
//  | a disk's bookmark leads nowhere, its volume    | not connected                | away: previews still edit  |
//  |   not mounted                                  |                              |                            |
//  | it leads nowhere, and the volume is there (or  | not found                    | away                       |
//  |   it was on this device or in iCloud Drive)    |                              |                            |
//  | it is there and may not be read                | access lost                  | away                       |

import Foundation

enum FolderReach {
    /// Where a folder is, as Files names it.
    struct Place: Equatable, Sendable {
        /// "SANDISK SSD", "iCloud Drive", "On My window".
        var volume: String
        var kind: LinkedFolder.Kind
        /// A server's share (SMB): kept as a disk, which is how it comes and goes.
        var isNetwork = false
        /// Every folder from the volume down to the folder itself.
        var folders: [String]

        var location: [String] { [volume] + folders }
    }

    /// What asking a folder found.
    struct Check: Sendable {
        var id: LinkedFolder.ID
        /// Where it answered; nil when it did not.
        var url: URL? = nil
        /// Whether this check began a scoped access, which its caller now holds.
        var startedAccess = false
        var lost: LinkedFolder.Lost? = nil
        /// A renewed bookmark, when the operating system said the old one had gone stale.
        var fresh: Data? = nil
        var place: Place? = nil
    }

    /// The device's own place, as Files says it.
    @MainActor static var thisDevice: String {
        "This Mac"
    }

    // MARK: asking

    /// The folder asked for through its bookmark. `holding` is the URL whose access this session
    /// already holds for it: the same URL is not started again.
    nonisolated static func check(_ folder: LinkedFolder, holding: URL?, device: String) -> Check {
        var check = Check(id: folder.id)
        guard let bookmark = folder.bookmark else { return check }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        } catch {
            let e = error as NSError
            check.lost = e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError ? .accessLost
                : gone(folder, bookmark)
            return check
        }
        let held = holding.map { same($0, url) } ?? false
        let started = held ? false : url.startAccessingSecurityScopedResource()
        func letGo() { if started { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.checkResourceIsReachable()) == true else {
            letGo()
            check.lost = gone(folder, bookmark)
            return check
        }
        // There: may it be read? The sandbox says so at the opening of the folder, not before.
        if let dir = opendir(url.path) {
            closedir(dir)
        } else {
            let code = errno
            letGo()
            check.lost = code == EPERM || code == EACCES ? .accessLost : gone(folder, bookmark)
            return check
        }
        check.url = url
        check.startedAccess = started
        if stale { check.fresh = try? url.bookmarkData() }
        check.place = place(of: url, device: device)
        return check
    }

    /// Why a folder that does not answer is away: a disk whose volume is not mounted is simply not
    /// connected; anything else is not found (the bookmark's own record of its volume says which).
    nonisolated private static func gone(_ folder: LinkedFolder, _ bookmark: Data) -> LinkedFolder.Lost? {
        guard folder.kind == .disk else { return .notFound }
        let values = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmark)
        guard let volume = values?.volume, volume.pathComponents.count > 1 else { return nil }
        return FileManager.default.fileExists(atPath: volume.path) ? .notFound : nil
    }

    nonisolated static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: naming

    /// The folder's place as the Files app shows it: "iCloud Drive › Photos › Scans",
    /// "SANDISK SSD › DCIM › 100RICOH", "On My window › Scans".
    nonisolated static func place(of url: URL, device: String) -> Place {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                         .volumeIsEjectableKey, .volumeIsLocalKey, .volumeURLKey, .isUbiquitousItemKey]
        let values = try? url.resourceValues(forKeys: keys)
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        // iCloud Drive: …/reference Documents/com~apple~CloudDocs/<folders>, or an app's own folder
        // there (…/reference Documents/iCloud~com~apple~Pages/Documents/<folders>, shown as "Pages").
        if let i = parts.firstIndex(of: "Mobile Documents"), i + 1 < parts.count {
            var below = Array(parts[(i + 2)...])
            let container = parts[i + 1]
            if container != "com~apple~CloudDocs" {
                if below.first == "Documents" { below.removeFirst() }
                below.insert(container.components(separatedBy: "~").last ?? container, at: 0)
            }
            return Place(volume: "iCloud Drive", kind: .iCloud, folders: below.isEmpty ? [url.lastPathComponent] : below)
        }
        if values?.isUbiquitousItem == true {
            return Place(volume: "iCloud Drive", kind: .iCloud, folders: [url.lastPathComponent])
        }
        let network = values?.volumeIsLocal == false || parts.contains { $0.contains("smbclientd") }
        let external = network || values?.volumeIsInternal == false || values?.volumeIsRemovable == true
            || values?.volumeIsEjectable == true
        if external {
            let name = values?.volumeLocalizedName ?? url.deletingLastPathComponent().lastPathComponent
            var below: [String] = []
            if let volume = values?.volume?.resolvingSymlinksInPath().standardizedFileURL.pathComponents,
               volume.count > 1, parts.starts(with: volume) {
                below = Array(parts.dropFirst(volume.count))
            } else if let i = parts.lastIndex(of: name) {
                below = Array(parts.dropFirst(i + 1))
            }
            return Place(volume: name, kind: .disk, isNetwork: network, folders: below.isEmpty ? [url.lastPathComponent] : below)
        }
        // The Mac's own disk, named as Finder's sidebar names it: a folder in the home folder under
        // the home folder's name ("hanze › Pictures › Scans"), anything else under the disk's
        // ("Macintosh HD › Shared › Scans").
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if parts.count > home.count, parts.starts(with: home) {
            return Place(volume: home.last ?? device, kind: .onDevice, folders: Array(parts.dropFirst(home.count)))
        }
        return Place(volume: values?.volumeLocalizedName ?? device, kind: .onDevice,
                     folders: parts.count > 1 ? Array(parts.dropFirst()) : [url.lastPathComponent])
    }

    // MARK: the frames

    /// A frame of a folder, as the survey needs it.
    struct FrameLook: Sendable {
        var id: LibraryFrame.ID
        /// "DCIM › 100RICOH": the folder linked, then the folders down to the file's.
        var sourcePath: String
        var fileName: String
        var file: URL?
    }

    struct Finding: Sendable, Equatable {
        var id: LibraryFrame.ID
        var original: OriginalState
        /// Where its file now is, when that is not where the frame reads it.
        var moved: URL? = nil
        /// Found under the folder as it now stands (not at an old place outside it).
        var inFolder = false
        /// Its file is in iCloud and not downloaded.
        var cloudOnly = false
    }

    /// Where each frame's file is, with the folder at `url` (nil: the folder is away). A frame's file
    /// is looked for at its path under the folder first — the folder may have been renamed or moved
    /// — then where the frame last read it. Headers are not opened: only whether the file is there.
    nonisolated static func survey(_ frames: [FrameLook], at url: URL?, volume: String) -> [Finding] {
        let files = FileManager.default
        return frames.map { look in
            guard let url else { return Finding(id: look.id, original: .offline(disk: volume)) }
            let name = look.file?.lastPathComponent ?? look.fileName
            let below = look.sourcePath.components(separatedBy: " › ").dropFirst()
            let candidate = (below + [name]).reduce(url) { $0.appendingPathComponent($1) }
            if files.fileExists(atPath: candidate.path) {
                let moved = look.file.map { same($0, candidate) } == true ? nil : candidate
                return Finding(id: look.id, original: .available, moved: moved, inFolder: true,
                               cloudOnly: isCloudOnly(candidate))
            }
            // An iCloud file not downloaded, kept the old way: ".<name>.icloud" beside where it would be.
            let placeholder = candidate.deletingLastPathComponent().appendingPathComponent("." + name + ".icloud")
            if files.fileExists(atPath: placeholder.path) {
                return Finding(id: look.id, original: .available, inFolder: true, cloudOnly: true)
            }
            if let file = look.file, files.fileExists(atPath: file.path) {
                return Finding(id: look.id, original: .available)
            }
            return Finding(id: look.id, original: .missing)
        }
    }

    nonisolated private static func isCloudOnly(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus else { return false }
        return status != .current
    }
}
