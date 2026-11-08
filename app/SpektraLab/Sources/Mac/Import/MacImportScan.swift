//  MacImportScan.swift — what the import page finds in the folders and files picked in Finder (2026-10-24).
//
//  The owner: "Detect the readable RAW / JPG in the folder (and its subfolders)". Off the main thread, in
//  two passes, so that a folder of 600 NEFs on a USB disk is a grid at once and fills in after:
//
//  1. **The listing.** Each folder is walked (its subfolders too unless *Include Subfolders* is off),
//     hidden files and packages never entered, a `CaptureOne/` folder (a session's caches) never walked.
//     A file is a picture when its type conforms to `.rawImage` or `.image` *and* ImageIO reads that type
//     (`CGImageSourceCopyTypeIdentifiers`, no file opened). Sidecars (`.xmp`, `.spektra.json`, Capture
//     One's `.cos`…), movies and anything else are counted and left out. Rows go to the page in batches.
//  2. **The headers.** Each picture's header is read (`MacHeaders.readIfReadable`: ImageIO's properties,
//     no pixel decoded) four at a time: the date, the camera, the size for the grid and the filters, and
//     the metadata the import hands the helper. A file ImageIO cannot open after all is dropped then.

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture the scan found.
struct MacFoundFile: Identifiable, Sendable, Equatable {
    let url: URL
    /// The picked folder it was found under, nil for a picked file.
    let root: URL?
    /// Its path below that folder ("_prints/x.tif"), or its name for a picked file: what a copy keeps.
    let relative: String
    let size: Int?
    let kind: MacImage.FileKind
    /// "NEF", "JPG": its extension, upper case, for the Format filter.
    let format: String
    /// Read in the second pass; nil until then.
    var header: LibraryDescription?
    var headerRead = false

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum MacImportScan {
    /// What a scan saw, besides the pictures.
    struct Tally: Sendable, Equatable {
        var pictures = 0
        var sidecars = 0
        var movies = 0
        /// Image types ImageIO cannot read, and files whose header it could not open.
        var unreadable = 0
        var other = 0
        var folders = 0
        /// Folders never walked: `CaptureOne/`.
        var skippedFolders = 0

        var dictionary: [String: Int] {
            ["pictures": pictures, "sidecars": sidecars, "movies": movies, "unreadable": unreadable, "other": other,
             "folders": folders, "skipped_folders": skippedFolders]
        }
    }

    enum Event: Sendable {
        /// Pictures listed (no header yet).
        case found([MacFoundFile])
        /// Headers read, by path; nil: ImageIO could not open the file after all.
        case headers([String: LibraryDescription?])
        /// The listing is done; the headers go on.
        case listed(Tally)
        /// Everything is done.
        case done(Tally)
    }

    /// Sidecars, by extension: Adobe's and Capture One's settings, SpektraLab 1.x's `.spektra.json`
    /// (matched by name), RawTherapee's, DxO's, Canon's thumbnails.
    static let sidecarExtensions: Set<String> = ["xmp", "cos", "cot", "cof", "comask", "pp3", "dop", "arp", "thm", "on1"]
    /// Folder names never walked, at any depth.
    static let skippedFolderNames: Set<String> = ["CaptureOne"]

    /// The types ImageIO reads on this Mac, asked once.
    static let imageIOTypes: [UTType] = {
        ((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []).compactMap { UTType($0) }
    }()

    enum Kind: Equatable { case picture(MacImage.FileKind), sidecar, movie, unreadable, other }

    /// What a file is, by its name and type alone (no file opened).
    static func classify(_ url: URL, type: UTType?) -> Kind {
        let name = url.lastPathComponent.lowercased()
        if sidecarExtensions.contains(url.pathExtension.lowercased()) || name.hasSuffix(".spektra.json") { return .sidecar }
        guard let type = type ?? UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
        let raw = type.conforms(to: .rawImage)
        guard raw || type.conforms(to: .image) else { return .other }
        guard imageIOTypes.contains(where: { type.conforms(to: $0) }) else { return .unreadable }
        return .picture(raw ? .raw : .raster)
    }

    /// A folder's entries in the enumerator's order, `body` given each one and the enumerator (to skip a
    /// folder's descendants); it returns false to stop. Synchronous: an enumerator is not iterated in an
    /// async context.
    private static func walk(_ folder: URL, keys: [URLResourceKey], options: FileManager.DirectoryEnumerationOptions,
                             _ body: (URL, FileManager.DirectoryEnumerator) -> Bool) {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: options) else { return }
        for case let url as URL in walk {
            if !body(url, walk) { return }
        }
    }

    /// The scan of `picked` (folders and files, as Finder gave them), as a stream of events. Ending the
    /// stream (the page closed, the picks changed) stops the scan.
    static func run(_ picked: [URL], subfolders: Bool) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var tally = Tally()
                var listed: [MacFoundFile] = []
                var batch: [MacFoundFile] = []
                var seen = Set<String>()
                var lastSent = ContinuousClock.now
                func flush(_ force: Bool = false) {
                    guard !batch.isEmpty, force || batch.count >= 200 || ContinuousClock.now - lastSent > .milliseconds(150) else { return }
                    continuation.yield(.found(batch))
                    batch = []
                    lastSent = ContinuousClock.now
                }
                func take(_ url: URL, root: URL?, type: UTType?, size: Int?) {
                    let key = CatalogSourcesStore.key(url.path)
                    guard seen.insert(key).inserted else { return }
                    switch classify(url, type: type) {
                    case .picture(let kind):
                        let relative: String
                        if let root {
                            let base = root.standardizedFileURL.pathComponents, mine = url.standardizedFileURL.pathComponents
                            relative = mine.count > base.count ? mine.dropFirst(base.count).joined(separator: "/") : url.lastPathComponent
                        } else {
                            relative = url.lastPathComponent
                        }
                        let f = MacFoundFile(url: url, root: root, relative: relative, size: size, kind: kind,
                                             format: url.pathExtension.uppercased())
                        listed.append(f)
                        batch.append(f)
                        flush()
                    case .sidecar: tally.sidecars += 1
                    case .movie: tally.movies += 1
                    case .unreadable: tally.unreadable += 1
                    case .other: tally.other += 1
                    }
                }

                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey]
                for pick in picked {
                    if Task.isCancelled { break }
                    let v = try? pick.resourceValues(forKeys: Set(keys))
                    guard v?.isDirectory == true, v?.isPackage != true else {
                        if v?.isRegularFile == true { take(pick, root: nil, type: v?.contentType, size: v?.fileSize) }
                        continue
                    }
                    tally.folders += 1
                    var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                    if !subfolders { options.insert(.skipsSubdirectoryDescendants) }
                    walk(pick, keys: keys, options: options) { url, walk in
                        if Task.isCancelled { return false }
                        guard let r = try? url.resourceValues(forKeys: Set(keys)) else { return true }
                        if r.isDirectory == true {
                            if r.isPackage == true { return true }
                            if skippedFolderNames.contains(url.lastPathComponent) {
                                walk.skipDescendants()
                                if subfolders { tally.skippedFolders += 1 }
                            } else if subfolders {
                                tally.folders += 1
                            }
                            return true
                        }
                        if r.isRegularFile == true { take(url, root: pick, type: r.contentType, size: r.fileSize) }
                        return true
                    }
                }
                flush(true)
                tally.pictures = listed.count
                continuation.yield(.listed(tally))

                // The headers, four at a time (a USB disk gives more to a few readers than to one).
                var headers: [String: LibraryDescription?] = [:]
                lastSent = ContinuousClock.now
                await withTaskGroup(of: (String, LibraryDescription?).self) { group in
                    var next = 0
                    func add() {
                        guard next < listed.count else { return }
                        let url = listed[next].url
                        next += 1
                        group.addTask { (url.path, Task.isCancelled ? nil : MacHeaders.readIfReadable(url)) }
                    }
                    for _ in 0..<4 { add() }
                    while let (path, header) = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        headers[path] = .some(header)
                        if header == nil { tally.unreadable += 1; tally.pictures -= 1 }
                        if headers.count >= 64 || ContinuousClock.now - lastSent > .milliseconds(200) {
                            continuation.yield(.headers(headers))
                            headers = [:]
                            lastSent = ContinuousClock.now
                        }
                        add()
                    }
                }
                if !headers.isEmpty { continuation.yield(.headers(headers)) }
                if !Task.isCancelled { continuation.yield(.done(tally)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
