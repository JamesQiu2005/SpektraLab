//  ImportService.swift — bringing pictures in: Photos, a linked folder, and files
//  copied in.
//
//  design/flow, "Where the photos live". Three sources, one result: each file
//  becomes a `LibraryFrame` with what the file says about itself (name,
//  capture time, camera, exposure, pixel size, read with ImageIO from the
//  header alone), joins the library, and is queued in the one develop queue
//  (`AppServices.develop`) — so its tile carries the ring and the `Developing n`
//  chip counts it, as a shot does.
//
//  | source            | the original                 | what the frame's picture is          |
//  |-------------------|------------------------------|--------------------------------------|
//  | Photos, where the | stays in Photos; brought     | a preview copy, made here            |
//  |   app may read it |   into the working copies    |                                      |
//  |                   |   while it is worked on      |                                      |
//  |                   |   (`Originals`)              |                                      |
//  | Photos, where it  | copied in (the system picker | the copy                             |
//  |   may not         |   hands over the file, A6)   |                                      |
//  | a linked folder   | stays in the folder, read in | the file, read in place              |
//  |                   |   place, never written to    |                                      |
//  | Copy files in     | copied into the app          | the copy                             |
//  | a shot            | written into the app         | the DNG                              |
//
//  **What this build does not do.** There is no engine, so a frame that is not
//  a bundled demo picture is never developed: its picture is its camera's own
//  preview, decoded at display size by `ThumbnailStore`, and the pages say so.
//  On a host the library — its frames and its linked folders — is kept on
//  disk (`LibraryPersistence`); a shot or a copied-in original is the only
//  copy of itself, and is removed only when its frame is removed.
//
//  File work — copying, reading headers, making preview copies — is done off
//  the main thread, one file at a time inside its own autorelease pool, so a
//  card of four hundred RAWs neither blocks the page nor piles up buffers.

import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ImportService {
    let model: AppServices
    private var library: FrameCatalog { model.library }
    private var settings: AppSettings { model.settings }

    // MARK: where the app keeps files

    /// `Application Support/SpektraLab`, not Caches or tmp, which the operating system may
    /// empty when storage is low (design/flow).
    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The Mac app is not sandboxed, and `Application Support/SpektraLab` is the desktop 1.x
        // app's (Sidecars/, Libraries/): this one keeps its own, by its bundle id.
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.spektralab.mac", isDirectory: true)
    }
    /// The only copy of what was copied in, and of the shots. Kept in backups.
    nonisolated static var originals: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    /// Preview copies: rebuildable from the original, so left out of backups.
    nonisolated static var previews: URL { root.appendingPathComponent("Previews", isDirectory: true) }

    /// Security-scoped places this session reads in place: linked folders and
    /// originals found again. Held open for the session; a linked folder's
    /// bookmark is also kept with the library (`LinkedFolder.bookmark`), and
    /// the next session asks again through it (`FrameCatalog.load`).
    private static var scoped: [URL: Data] = [:]

    // MARK: what a file says about itself

    struct Probe: Sendable {
        var url: URL
        var fileName: String
        var captureDate: Date
        var camera: String?
        var exposure: String?
        var size: PixelSize
        var isRAW: Bool
        /// A new frame's Develop crop, as the file's header gives it (`CameraCrop.newFrameGeometry`): the
        /// crop a camera wrote into a DNG (DefaultUserCrop: a Leica Q3's digital zoom or aspect setting),
        /// in the picture as `size` has it — turned as the file says. No crop for any other file.
        var geometry: Geometry = .default
    }

    /// The header only: no pixel is decoded.
    ///
    /// **A RAW's size is asked of its decoder** (`rawSize`), not read off the
    /// file's first image. On the operating system that image is the camera's embedded preview
    /// in a Sony ARW (1,616 × 1,080 of a 61 MP file) and in a Fuji RAF — both
    /// seen in the simulator, where macOS gives the RAW's own size for the
    /// same files — and, by the testers' logs, in a Panasonic RW2 and in the
    /// DNGs the Indigo camera app writes (252 × 189: a thumbnail). A frame
    /// taken for that size was developed from it, soft, and exported at it;
    /// and its export still decoded the whole file, planned as the small one
    /// (the beta's first day, 2026-10-12: nine of twenty-two RAW photos picked
    /// from Photos, and one reference device ended four times for it). `rawFromDecoder`
    /// false reads the first image's size as before, at a twentieth of the
    /// cost: for a shot of the app's own camera, whose DNG has the RAW first,
    /// and for a search through a folder, which looks at the size last.
    nonisolated static func probe(_ url: URL, name: String? = nil, rawFromDecoder: Bool = true) -> Probe? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard w > 0, h > 0 else { return nil }
            // A portrait frame is stored on its side with an orientation tag.
            if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) { swap(&w, &h) }
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
                ?? UTType(filenameExtension: url.pathExtension)
            let isRAW = type?.conforms(to: .rawImage) ?? false
            var size = PixelSize(width: w, height: h)
            // Where the decoder will not open the file at all, the first image's size stands:
            // the frame arrives, and its develop says that it could not be decoded.
            if isRAW, rawFromDecoder, let own = rawSize(url) { size = own }
            let date = captureDate(exif) ?? ((try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate) ?? Date()
            return Probe(url: url, fileName: name ?? url.lastPathComponent, captureDate: date, camera: camera(tiff),
                         exposure: exposure(exif), size: size, isRAW: isRAW,
                         geometry: CameraCrop.newFrameGeometry(properties: props, size: size))
        }
    }

    /// A RAW file's size as its decoder opens it: the extent of the picture
    /// Core Image's RAW filter hands over, which is the one `FrameDecoder`
    /// scales and renders — turned as the file says, in whole pixels. No pixel
    /// is decoded: 35 to 70 ms a file in the simulator on this Mac against 2
    /// to 5 for the first image's properties, and no memory to speak of. Nil
    /// for a file that decoder does not open.
    ///
    /// (The filter's own `nativeSize`, turned by its `orientation`, is the
    /// same number for every file tried — Sony, Fuji, Ricoh, Nikon, an
    /// reference device's DNG upright and on its side — and is what `PhotosHarness`
    /// holds this against.)
    nonisolated static func rawSize(_ url: URL) -> PixelSize? {
        guard let extent = CIRAWFilter(imageURL: url)?.outputImage?.extent.integral,
              !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        return PixelSize(width: Int(extent.width), height: Int(extent.height))
    }

    /// EXIF's `DateTimeOriginal`, in the offset the camera wrote, or local time.
    nonisolated private static func captureDate(_ exif: [CFString: Any]) -> Date? {
        guard let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: s + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: s)
    }

    /// "NIKON Z 7_2", as the file names its camera; the maker is added when
    /// the model alone does not say it ("SONY ILCE-7RM5").
    nonisolated private static func camera(_ tiff: [CFString: Any]) -> String? {
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model, !model.isEmpty else { return make }
        guard let first = make?.split(separator: " ").first, !model.localizedCaseInsensitiveContains(first) else { return model }
        return "\(first) \(model)"
    }

    /// "1/250 s · f/5.6 · ISO 100".
    nonisolated private static func exposure(_ exif: [CFString: Any]) -> String? {
        var parts: [String] = []
        if let t = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue, t > 0 {
            parts.append(t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%g s", (t * 10).rounded() / 10))
        }
        if let f = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue, f > 0 {
            parts.append(String(format: "f/%g", (f * 10).rounded() / 10))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue {
            parts.append("ISO \(iso)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: arriving

    /// A frame for a file, starting with the pair new frames develop with.
    private func frame(_ p: Probe, source: FrameOrigin, picture: PictureRef) -> LibraryFrame {
        var edit = FrameEdit.default
        let stocks = settings.newFrameStocks
        // The paper, then the film: a slide film is scanned, whatever paper
        // the last frame was printed on (`FilmParams.load`).
        edit.params.printStock = stocks.paper
        edit.params.load(film: stocks.film, recommendingPaper: false)
        // The film's long edge as this photograph makes it: 32 mm on 135 for
        // a host's 4:3, not the defaults' 36.
        edit.params = edit.params.heldToItsPhoto(p.size)
        // The advance and the scan: one per photograph (RFC-032 §26.1).
        edit.frameSeed = Int.random(in: 1...Int(Int32.max))
        // A RAW's lens correction is Settings' (`AppSettings.lensCorrection`); a picture its camera
        // has developed is never corrected again, and keeps the decode's default.
        if p.isRAW { edit.decode.lensCorrection = settings.lensCorrection }
        // The frame the photographer saw (`CameraCrop`, 2026-11-05): a DNG whose camera cropped it — a
        // Leica Q3's 35/50/75 mm frame lines — starts with that crop, as though it had been drawn here.
        // Every new frame of this repository's app is made here (an import, a picture of the Mac's library
        // opened, carried or exported, a shot); a frame made before 2026-11-05 is caught up once, at
        // launch, while its crops are as they were made (`AppServices.holdCameraCrops`).
        // tools/crop_selftest.swift reads this line, and `probe`'s `CameraCrop.newFrameGeometry(…)`, out of
        // this file (the hook's own check): reword either and the check goes red.
        edit.geometry = p.geometry
        // `edit:` — until 2026-10-09 the frame was made without it, so every
        // frame that arrived had the defaults: Porta 400 on Supera Enduro
        // whatever film was loaded, and one seed for all of them.
        var made = LibraryFrame(id: UUID(), fileName: p.fileName, captureDate: p.captureDate, camera: p.camera,
                                exposure: p.exposure, originalSize: p.size,
                                previewSize: p.size.scaled(toLongEdge: settings.previewLongEdge), isRAW: p.isRAW,
                                source: source, picture: picture, edit: edit, importedAt: Date())
        // Its header was read just now (`probe`): nothing is owed it.
        made.cameraCropRead = true
        return made
    }

    /// Frames join the library and the one develop queue; the library says once
    /// what arrived (B3) — not for a photo of the gallery made a frame by its first edit (`banner` false).
    /// On the Mac an arrival develops nothing (`DevelopCause.arrival`, the owner, 2026-10-24): the frames
    /// the Mac's library makes for an export, a carry or the Light Table are developed when opened.
    private func arrive(_ frames: [LibraryFrame], banner: Bool = true) {
        guard !frames.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            library.add(frames)
            if banner { library.importBanner = .init(imported: frames.count, developed: 0, frameIDs: frames.map(\.id)) }
        }
        for f in frames { model.develop(f.id, cause: .arrival) }
    }

    // MARK: Copy files in

    /// The picked files are copied into the app; the originals are left where
    /// they were. Returns how many arrived.
    @discardableResult
    func copyIn(_ urls: [URL]) async -> Int {
        let probes = await Task.detached(priority: .userInitiated) { () -> [Probe] in
            urls.compactMap { url in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let copy = try? Self.copyIntoOriginals(url) else { return nil }
                guard let p = Self.probe(copy) else { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()); return nil }
                return p
            }
        }.value
        let frames = probes.map { frame($0, source: .copiedIn, picture: .file($0.url)) }
        arrive(frames)
        Log.imported(from: "files, copied in", asked: urls.count, frames)
        return probes.count
    }

    /// `Originals/<id>/<the file's own name>`: the name is kept, the folder
    /// keeps two files of one name apart.
    nonisolated private static func copyIntoOriginals(_ url: URL) throws -> URL {
        let folder = originals.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    /// A working copy, copied to `Originals/<id>/<its name>` (a clone on APFS: no space until one of the
    /// two changes), where it is the frame's own and kept in backups; the working copy stays for the job
    /// that holds its path.
    nonisolated static func cloneIntoOriginals(_ url: URL) throws -> URL {
        let folder = originals.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return dest
    }

    /// A file of the app's own — a Photos original just fetched into the
    /// working copies — moved to `Originals/<id>/<its name>`, where it is the
    /// only copy and kept in backups (the working copies' folder is not).
    nonisolated static func moveIntoOriginals(_ url: URL) throws -> URL {
        let folder = originals.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var dest = folder.appendingPathComponent(url.lastPathComponent)
        do { try FileManager.default.moveItem(at: url, to: dest) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try? dest.setResourceValues(values)
        return dest
    }

    // MARK: Link a folder

    /// The folder and everything under it is read where it is: each picture in
    /// it becomes a frame, and the folder is listed in Sources. Returns how
    /// many arrived.
    @discardableResult
    func link(folder picked: URL) async -> Int {
        // The Mac: a Capture One catalog or session comes in through this door too (CaptureOneSource).
        let captureOne = CaptureOneSource.kind(of: picked)
        let url = picked.pathExtension.lowercased() == "cosessiondb" ? picked.deletingLastPathComponent() : picked
        _ = url.startAccessingSecurityScopedResource()
        let bookmark = try? url.bookmarkData()
        Self.scoped[url] = bookmark
        // Its volume as Files names it, and where on it the folder is (`FolderReach.place`, 2026-10-21:
        // "On My window" on a window, where every folder was "On My reference device" before).
        var place = FolderReach.place(of: url, device: FolderReach.thisDevice)
        var name = url.lastPathComponent
        var listed: [URL: String]? = nil         // a Capture One catalog's files, by their Capture One folder
        var skips: Set<String> = []
        if let captureOne {
            name = CaptureOneSource.name(of: url, captureOne)
            place = FolderReach.Place(volume: "Capture One", kind: .disk, folders: [name])
            if captureOne == .session { skips = CaptureOneSource.sessionSkips }
            if captureOne == .catalog {
                do {
                    let pictures = try await CaptureOneSource.pictures(ofCatalog: url)
                    listed = Dictionary(pictures.map { ($0.file, $0.folder) }, uniquingKeysWith: { a, _ in a })
                } catch {
                    Log.warn(.library, "capture one catalog refused", ["error": error.localizedDescription])
                    return 0
                }
            }
        }
        let volume = place.volume, kind = place.kind
        let probes = await Task.detached(priority: .userInitiated) { [listed, skips] () -> [Probe] in
            let files = listed.map { $0.keys.sorted { $0.path < $1.path } } ?? Self.pictures(in: url, skipping: skips)
            return files.compactMap { Self.probe($0) }
        }.value
        let frames = probes.map { p -> LibraryFrame in
            // "DCIM › 100RICOH": the folder linked, down to the file's own folder. A Capture One
            // catalog's frame: the catalog, then the Capture One folder its file is in.
            let below = listed.map { [$0[p.url] ?? p.url.deletingLastPathComponent().lastPathComponent] }
                ?? Array(p.url.deletingLastPathComponent().pathComponents.dropFirst(url.pathComponents.count))
            let path = ([name] + below).joined(separator: " › ")
            return frame(p, source: .linkedFolder(disk: volume, path: path), picture: .file(p.url))
        }
        library.addFolder(LinkedFolder(id: UUID(), volume: volume, path: name, kind: kind,
                                       frameCount: frames.count, isConnected: true, bookmark: bookmark,
                                       location: place.location), at: url)
        arrive(frames)
        Log.imported(from: "a linked folder", asked: frames.count, frames, ["place": kind == .iCloud ? "iCloud Drive" : kind == .onDevice ? "this Mac" : "a disk"])
        return frames.count
    }

    /// Every picture under a folder, subfolders included, in name order.
    nonisolated private static func pictures(in folder: URL, depth: Int = 8, skipping: Set<String> = []) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk {
            if walk.level > depth { walk.skipDescendants(); continue }
            // A Capture One session's own folders (its cache, its trash): never pictures of the user's.
            if walk.level == 1, skipping.contains(url.lastPathComponent) { walk.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let type = v.contentType ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true || type?.conforms(to: .rawImage) == true { found.append(url) }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: a linked folder reached again (2026-10-21)

    enum Reconnected: Equatable {
        /// `found` of the folder's `of` frames have their file in it.
        case done(found: Int, of: Int)
        /// None of the folder's frames is in what was picked.
        case notThisFolder
    }

    /// *Reconnect…*: the folder picked again, where it now is — the same folder, access granted
    /// again, or a copy of it moved elsewhere. It is taken when at least one of the folder's frames
    /// is in it by its path under the folder (or, for a folder with no frames, when its name is the
    /// same); then the bookmark is renewed and every frame reads its file there. A frame not in it is
    /// *Original missing*, and Locate finds it one by one. Nothing in the folder is written.
    func reconnect(_ id: LinkedFolder.ID, to url: URL) async -> Reconnected {
        guard let folder = library.linkedFolders.first(where: { $0.id == id }) else { return .notThisFolder }
        let started = url.startAccessingSecurityScopedResource()
        let looks = library.frames(of: folder).compactMap { f -> FolderReach.FrameLook? in
            guard case .linkedFolder(_, let path) = f.source else { return nil }
            return FolderReach.FrameLook(id: f.id, sourcePath: path, fileName: f.fileName, file: f.picture.fileURL)
        }
        let volume = folder.volume
        let findings = await Task.detached(priority: .userInitiated) {
            FolderReach.survey(looks, at: url, volume: volume)
        }.value
        let found = findings.filter(\.inFolder).count
        guard found > 0 || (looks.isEmpty && url.lastPathComponent == folder.path) else {
            if started { url.stopAccessingSecurityScopedResource() }
            Log.note(.library, "folder reconnect refused", ["frames": looks.count])
            return .notThisFolder
        }
        let bookmark = try? url.bookmarkData()
        Self.scoped[url] = bookmark
        // A frame not in the folder picked is missing there, wherever it was read before.
        let taken = findings.map { f -> FolderReach.Finding in
            f.inFolder ? f : FolderReach.Finding(id: f.id, original: .missing)
        }
        library.reconnect(id, at: url, bookmark: bookmark, place: FolderReach.place(of: url, device: FolderReach.thisDevice),
                          findings: taken)
        Log.note(.library, "folder reconnected", ["frames": looks.count, "found": found])
        return .done(found: found, of: looks.count)
    }

    /// A folder's scoped access let go, where this session holds it (*Unlink*).
    static func letGo(_ url: URL) {
        guard let key = scoped.keys.first(where: { FolderReach.same($0, url) }) else { return }
        scoped[key] = nil
        key.stopAccessingSecurityScopedResource()
    }

    /// A JPEG of the picture at the preview size: the picture of a frame whose
    /// original stays in Photos, until its develop lands and whenever the
    /// original cannot be read.
    ///
    /// **The picture itself, made small — not the file's embedded thumbnail.**
    /// ImageIO's "create the thumbnail if the file has none" hands back the
    /// one a HEIC or a JPEG carries, which is 320 pixels or so whatever size
    /// is asked for; so a picture that is not a RAW is always decoded and
    /// reduced (`…FromImageAlways`: the full bitmap is not held, ImageIO
    /// reduces as it decodes — `FrameDecoder` measured 140-195 MB from 48 MP).
    /// A RAW is the other way round: its embedded preview is the camera's own
    /// picture of it, at full size in an Apple ProRAW, and decoding the RAW
    /// here to replace it would be a second, large decode of every imported
    /// frame for a picture its develop replaces within the second. So a RAW's
    /// preview copy is its embedded preview **where that is as large as the
    /// preview**. One that is smaller — an Indigo DNG's is 252 × 189, a Sony
    /// ARW's 1,616 × 1,080 — is replaced by the RAW decoded at the preview size
    /// (`rawDecoded`): until 2026-10-15 it stood as the frame's picture, scaled
    /// up, until its develop landed, and for good where its develop could not
    /// be made (the tester, 2026-10-15: "选择手机相册的照片，分辨率极低").
    /// `ownLongEdge` is the picture's own long edge (`probe`), so that a small
    /// photograph is not decoded again for being small.
    nonisolated static func previewCopy(of url: URL, isRAW: Bool, longEdge: Int, ownLongEdge: Int? = nil) -> URL? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return nil }
            func reduced(_ how: CFString) -> CGImage? {
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    how: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: longEdge,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            }
            var made = isRAW ? reduced(kCGImageSourceCreateThumbnailFromImageIfAbsent) ?? reduced(kCGImageSourceCreateThumbnailFromImageAlways)
                             : reduced(kCGImageSourceCreateThumbnailFromImageAlways)
            // …or a grey one of a colour RAW: the camera's black-and-white style, not the photo (`RawPreviewColour`).
            if isRAW, (made.map { max($0.width, $0.height) } ?? 0) < Self.previewWanted(longEdge: longEdge, own: ownLongEdge) * 9 / 10
                || (made.map { RawPreviewColour.lost($0, in: source) } ?? false),
               let decoded = rawDecoded(url, longEdge: longEdge) {
                made = decoded
            }
            // A JPEG is 8 bits a channel: a 10-bit HEIF's picture (a Fujifilm's, a Sony's, one sips makes from
            // a ProRAW) comes out of ImageIO at 10, and was not written at all — the photo was then not read
            // in place, and arrived only where the picker's own file could be copied in (the simulator,
            // 2026-10-15: two of six picked photos did not arrive).
            guard let image = made.flatMap(eightBit) else { return nil }
            try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
            var dir = previews
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            let out = previews.appendingPathComponent(UUID().uuidString + ".jpg")
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out : nil
        }
    }

    /// The picture at 8 bits a channel, in its own colour space where that is
    /// RGB (Display P3 otherwise): what a JPEG can hold. An 8-bit picture is
    /// handed back as it is.
    nonisolated static func eightBit(_ image: CGImage) -> CGImage? {
        guard image.bitsPerComponent != 8 || image.bitsPerPixel != 32 else { return image }
        let spaces = [image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }, CGColorSpace(name: CGColorSpace.displayP3)].compactMap { $0 }
        guard let context = spaces.lazy.compactMap({
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: $0, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }).first else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The long edge a preview copy is made at: the preview's, or the
    /// picture's own where that is smaller.
    nonisolated static func previewWanted(longEdge: Int, own: Int?) -> Int {
        min(longEdge, own.map { $0 > 0 ? $0 : longEdge } ?? longEdge)
    }

    /// A RAW decoded at `longEdge` by the decoder its develop uses (Core
    /// Image's RAW filter, with its own look: this is a picture to look at
    /// until the develop lands, not the engine's input), scaled after the
    /// decode — never by the filter's `scaleFactor`, which RAW 9 got wrong
    /// (`FrameDecoder`) — and rendered to 8 bits in sRGB. Nil where the
    /// filter does not open the file.
    ///
    /// **What it costs is not measured on a host.** In the the operating system 27 simulator
    /// on the owner's Mac mini, 217 ms for a 12 MP ProRAW whose embedded
    /// preview was cut to 252 px (`tools/photos_check.sh`, 2026-10-15); its
    /// memory was not read. It runs once per frame, off the main thread, only
    /// for a RAW whose embedded preview is under the preview size, and its
    /// context's caches go with it.
    nonisolated static func rawDecoded(_ url: URL, longEdge: Int) -> CGImage? {
        autoreleasepool {
            guard let filter = CIRAWFilter(imageURL: url), let picture = filter.outputImage else { return nil }
            let extent = picture.extent
            guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
            let scale = min(1, CGFloat(longEdge) / max(extent.width, extent.height))
            let scaled = picture.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let out = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(.down), height: (extent.height * scale).rounded(.down))
            guard out.width >= 1, out.height >= 1 else { return nil }
            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            return context.createCGImage(scaled, from: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
    }

    // MARK: the Mac's library (Mac change, 2026-10-23: CatalogSourcesStore, MAC-LIBRARY-DATA.md)

    /// A picture of the Mac's library — a SpektraLab catalog or session, a Capture One catalog or
    /// session, a linked folder — becomes a frame the first time it is opened in Develop: read where it
    /// is, never copied, never written. `disk › path` is what Info's *Original* row says. The frame that
    /// already reads that file is handed back instead. Nil when the file's header cannot be read. Nothing
    /// is queued for it (`arrive`): its tiles show the file's own preview until it is developed.
    func adoptLibraryFile(_ url: URL, disk: String, path: String) async -> LibraryFrame.ID? {
        await adoptLibraryFiles([(url, disk, path)])[url]
    }

    /// `adoptLibraryFile` for many (a selection carried into Develop): the files probed off the main
    /// thread together, and the new frames arriving in one go. Each file's frame, by its URL; a file that
    /// cannot be read has none.
    func adoptLibraryFiles(_ files: [(url: URL, disk: String, path: String)]) async -> [URL: LibraryFrame.ID] {
        var out: [URL: LibraryFrame.ID] = [:]
        var unknown: [(url: URL, disk: String, path: String)] = []
        for file in files {
            if let known = library.frames.first(where: { f in f.picture.fileURL.map { FolderReach.same($0, file.url) } ?? false }) {
                out[file.url] = known.id
            } else {
                unknown.append(file)
            }
        }
        guard !unknown.isEmpty else { return out }
        let urls = unknown.map(\.url)
        let probes = await Task.detached(priority: .userInitiated, operation: { urls.map { Self.probe($0) } }).value
        var made: [LibraryFrame] = []
        for (file, p) in zip(unknown, probes) {
            guard let p else { continue }
            let f = frame(p, source: .linkedFolder(disk: file.disk, path: file.path), picture: .file(file.url))
            made.append(f)
            out[file.url] = f.id
        }
        guard !made.isEmpty else { return out }
        arrive(made, banner: false)
        Log.imported(from: "the Mac's library", asked: unknown.count, made)
        return out
    }

    // MARK: files the app already holds

    /// Files under `Originals` that no frame names — shots and copies made by
    /// a build before the library was kept on disk — become frames, as they
    /// were: developed by their camera, in the order they were taken.
    func adoptOrphans() {
        let named = Set(library.frames.compactMap { f -> String? in
            if case .file(let url) = f.picture { return url.standardizedFileURL.path }
            return nil
        })
        let files = Self.pictures(in: Self.originals, depth: 2).filter { !named.contains($0.standardizedFileURL.path) }
        guard !files.isEmpty else { return }
        let probes = files.compactMap { Self.probe($0) }.sorted { $0.captureDate < $1.captureDate }
        let frames = probes.map { p -> LibraryFrame in
            var f = frame(p, source: .copiedIn, picture: .file(p.url))
            f.importedAt = p.captureDate
            return f
        }
        library.add(frames)
    }

    // MARK: an original found again (F3)

    /// Whether a file is this frame's original: by name, or by size and
    /// capture time when it was renamed.
    func matches(_ url: URL, _ frame: LibraryFrame) -> Bool {
        if url.lastPathComponent.caseInsensitiveCompare(frame.fileName) == .orderedSame { return true }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return Self.isSame(url, size: frame.originalSize, date: frame.captureDate)
    }

    /// Whether a file is the picture of this size taken at this moment. The
    /// moment first, from the header; then the size — the first image's, which
    /// is what a RAW frame made before 2026-10-12 has for its own, or the
    /// decoder's, which is what one has since (`probe`).
    nonisolated private static func isSame(_ url: URL, size: PixelSize, date: Date) -> Bool {
        guard let p = probe(url, rawFromDecoder: false), abs(p.captureDate.timeIntervalSince(date)) < 2 else { return false }
        return p.size == size || (p.isRAW && rawSize(url) == size)
    }

    /// The frame's original inside a folder, subfolders included.
    func search(folder: URL, for frame: LibraryFrame) async -> URL? {
        _ = folder.startAccessingSecurityScopedResource()
        Self.scoped[folder] = try? folder.bookmarkData()
        let name = frame.fileName, size = frame.originalSize, date = frame.captureDate
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let all = Self.pictures(in: folder)
            if let byName = all.first(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }) {
                return byName
            }
            // Renamed: the same pixels at the same moment. Headers only.
            return all.lazy.prefix(2000).first { Self.isSame($0, size: size, date: date) }
        }.value
    }

    /// The frame reads its original from where it was found. A demo frame
    /// keeps its bundled picture, which is what SpektraLab developed.
    func relink(_ id: LibraryFrame.ID, to url: URL) {
        if Self.scoped[url] == nil, url.startAccessingSecurityScopedResource() {
            Self.scoped[url] = try? url.bookmarkData()
        }
        let volume = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        let was = library.frame(id)
        library.update(id) { f in
            f.original = .available
            if case .linkedFolder(let disk, _) = f.source {
                f.source = .linkedFolder(disk: volume ?? disk, path: url.deletingLastPathComponent().lastPathComponent)
            }
            // A photo that was read in place from Photos and is gone from there
            // is, from here on, the file that was found: read where that is,
            // with no way back to Photos to ask.
            if f.readsFromPhotos {
                f.source = .linkedFolder(disk: volume ?? "Files", path: url.deletingLastPathComponent().lastPathComponent)
                f.assetIdentifier = nil
            }
            if !f.isDemo { f.picture = .file(url) }
        }
        // Found, it is read by the decoder that will open it: a RAW frame made before 2026-10-12
        // may have its embedded preview's size, and its file was away when the library's frames
        // were held to theirs (`Originals.holdToItsFile`).
        Task { [model] in await model.originals.holdToItsFile(id) }
        // The preview copy and the working copy it had as a photo in Photos go,
        // once the library that no longer names them is written.
        if let was, was.readsFromPhotos {
            library.flush()
            model.originals.copies.remove([id])
            Task.detached(priority: .utility) { Self.discard(picture: was.picture) }
        }
    }

    // MARK: removing

    /// What goes with frames removed from the library: a copied-in original
    /// (the app's own copy), a preview copy, and the frame's kept develop.
    /// Never a file outside the app's own folders — Photos and linked folders
    /// are not written to. (A working copy is the book's to take:
    /// `AppServices.remove`, `WorkingCopies.remove`.)
    ///
    /// Until 2026-10-10 the kept develop stayed behind: every frame ever
    /// removed left its `dev-…` file under `Previews` for good.
    nonisolated static func discard(_ frames: [LibraryFrame]) {
        for frame in frames {
            discard(picture: frame.picture)
            discard(frame.developed)
        }
    }

    /// A frame's own picture, where that is a file of the app's: a copied-in
    /// original with its folder, or a file under `Previews`.
    nonisolated static func discard(picture: PictureRef) {
        guard case .file(let url) = picture else { return }
        let path = url.standardizedFileURL.path
        if path.hasPrefix(originals.standardizedFileURL.path + "/") {
            // a copied-in original is a catalog's
            // picture on the Mac (the library's move references `Originals/` in place, MacLibraryMove), and
            // it may be the only copy: removing a frame takes the frame and what the app made of it, never
            // the original. A catalog that no longer wants the picture says so itself.
            return
        } else if path.hasPrefix(previews.standardizedFileURL.path + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: keeping the app's own folders to the library

    /// The files under `Previews` that no frame of the library names go
    /// (`StorageTidy.sweep`): `keeping` is the name of every file the
    /// library's frames name, as the library was read.
    @discardableResult
    nonisolated static func sweepPreviews(keeping: Set<String>) -> (files: Int, bytes: Int64) {
        StorageTidy.sweep(previews, keeping: keeping)
    }

    /// A file as a word in a develop's stamp: its place under the app's own
    /// folder, which moves with an install of the app (`StorageTidy.stampWord`).
    nonisolated static func stampWord(_ url: URL) -> String { StorageTidy.stampWord(url, under: root) }
}
