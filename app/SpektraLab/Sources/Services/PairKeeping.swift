//  PairKeeping.swift — a half-frame pair, as the library keeps it.
//
//  On the desktop a pair is a file whose URL is a filmstrip item. Here it is
//  a library item (`LibraryFrame.pair`): a piece of film with two of the
//  library's frames on it, whose `edit` is the pair's own look. It sits after
//  its left frame, is developed in the one queue like an import, opens on the
//  develop page like a frame and is exported like one — the engine's host
//  composes the piece from the two frames' own files (`PairDevelop.swift`).
//
//  **A pair references its frames and does not own them** (the desktop's
//  answer B7): removing a pair removes the pair; removing a frame leaves its
//  hole empty in every pair it was in.
//
//  **Until the engine has developed it, a pair shows a guide**: the two
//  frames' own previews laid under their holes, the film between them dark
//  (`PairGuide`, the desktop's `PairComposer.thumbnail`). It is a file of the
//  pair's own under `Previews`, and goes with the pair. In a library that
//  keeps nothing on disk — the drawings' own, the snapshot harness — it is a
//  temporary file, made from the bundled pictures.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

extension AppServices {
    /// Keep what the pair's page made: a new library item — or, with
    /// `existing`, over the pair it was opened from. The decode and cut of
    /// each hole are read again from its frame; the pair's film edge becomes
    /// the pair's own switch and its look wears none (`FrameEdit.asPairLook`).
    /// Returns the item's id, or nil for a pair with no frame the library has:
    /// an empty piece is not kept.
    @discardableResult
    func keepPair(_ made: HalfFramePair, look: FrameEdit, as existing: LibraryFrame.ID? = nil) -> LibraryFrame.ID? {
        var pair = made
        pair.onStrip = pair.onStrip || look.filmEdge.active
        let look = look.heldToItsFilm().asPairLook
        let frames = darkroom.held(by: pair)
        pair = pair.mirrored(frames)
        guard let first = frames[.left] ?? frames[.right] else { return nil }
        let own = pair.pieceSize(frames, longEdge: nil)
        let preview = own.scaled(toLongEdge: settings.previewLongEdge)

        // A library kept on disk keeps the guide beside its preview copies.
        let folder = library.persistence != nil ? ImportService.previews
                                                : FileManager.default.temporaryDirectory.appendingPathComponent("PairGuides", isDirectory: true)
        if let existing, let was = library.frame(existing), was.isPair {
            let session = openSession(existing)
            let before = session?.historySnapshot()
            let guide = PairGuide.write(pair, frames: frames, id: existing, in: folder)
            library.update(existing) { f in
                f.pair = pair
                f.originalSize = own
                f.previewSize = preview
                f.captureDate = first.captureDate
                f.camera = first.camera
                f.exposure = first.exposure
                if let guide { f.picture = .file(guide) }
            }
            if guide != nil { Task.detached(priority: .utility) { PairGuide.discard(was.picture) } }
            // One develop for the look and the piece together: on the page that has
            // the pair open, or in the queue.
            if let session {
                session.pieceChanged(look: look)
                if let before { session.recordHistory(from: before) }
            } else {
                library.update(existing) { $0.edit = look }
                queue(existing)
            }
            // On the Mac a pair is a row of the library, pointing at its file in the app's storage (`MacPairRows.swift`).
            macLibrary.pairKept(existing)
            return existing
        }

        // New holes keep their source's exposure choice, including a mixed
        // Source/Balanced pair. Existing pairs above retain their saved gate.
        let fresh = pair.startingLook(look)
        let id = UUID()
        // Never another frame's own file: a pair's picture goes with the pair (`ImportService.discard`).
        guard let guide = PairGuide.write(pair, frames: frames, id: id, in: folder) else { return nil }
        let picture = PictureRef.file(guide)
        var n = 1
        while library.frames.contains(where: { $0.isPair && $0.fileName == "Half-Frame Pair \(n)" }) { n += 1 }
        let item = LibraryFrame(id: id, fileName: "Half-Frame Pair \(n)", captureDate: first.captureDate, camera: first.camera,
                                exposure: first.exposure, originalSize: own, previewSize: preview, isRAW: false, source: .copiedIn,
                                picture: picture, edit: fresh,
                                // After its left frame, in the grid's own order (the desktop's answer B8).
                                importedAt: first.importedAt.addingTimeInterval(0.001), pair: pair)
        library.add([item])
        queue(id)
        // On the Mac a pair is a row of the library, pointing at its file in the app's storage (`MacPairRows.swift`).
        macLibrary.pairKept(id)
        return id
    }

    /// **A pair's pictures are the caches'; the pair is its recipe** (the owner, 2026-10-25: "cache system
    /// can be deleted, so the library edit must just point to the file on how the pair is formed and the
    /// storage of edit … and let the scheduler and cache system do the re-render job"). A pair whose guide
    /// or develop file has gone with `Previews` (Storage, the system, a person) has its guide drawn again
    /// from its frames' own files and its develop asked of the one queue, from the pair and its look.
    /// The Mac's library calls it at its start (`MacPairRows.placePairs`).
    func repairPairPictures() {
        guard library.persistence != nil else { return }
        let gone = { (ref: PictureRef?) -> Bool in ref?.fileURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false }
        for f in library.frames where f.isPair {
            guard let pair = f.pair else { continue }
            if gone(f.picture), let guide = PairGuide.write(pair, frames: darkroom.held(by: pair), id: f.id, in: ImportService.previews) {
                library.update(f.id) { $0.picture = .file(guide) }
            }
            // A develop kept in a catalog's or a session's previews (`LibraryPreviews`, 2026-11-05) whose disk is
            // not mounted is away, not gone: made again now it would land in the app's `Previews` and leave the
            // library's copy nobody's when the disk is back. Found under its name in the library the pair was
            // last carried from (the library moved), it is the pair's again. Gone from a disk that is here, it
            // is made again, as before.
            if let file = f.developed?.picture.fileURL, gone(f.developed?.picture) {
                switch LibraryPreviews.locate(file, carriedFrom: LibraryPreviews.home(of: f.id)) {
                case .there, .away:
                    continue
                case .at(let now):
                    library.update(f.id) { $0.developed?.picture = .file(now) }
                case .gone:
                    library.update(f.id) { $0.developed = nil }
                    queue(f.id)
                }
            }
        }
    }

    /// A pair's own develop, in the one queue. The snapshot harness draws a
    /// page still: nothing is queued there, and the pair shows its guide.
    private func queue(_ id: LibraryFrame.ID) {
        if !isSnapshot { develop(id) }
    }

    /// **Make a pair of one or two of the library's frames, and keep it**: the
    /// way in from the Library's *Pair* and from Select (design/pair v2) — no
    /// page stands between the frames and the pair's darkroom. The frames
    /// fill the holes in the library's own order, the look is the first
    /// frame's (`PairStart.make`), and a frame given alone is the first hole.
    /// Returns the pair's id, or nil where neither is a photograph of the library.
    ///
    /// `beginsWithFirst`: the pair began with `first` alone and was then asked
    /// for its second frame (the sheet, H2) — `first` is what the pair is of,
    /// and stays in it (`HalfFramePair.origin`). Two frames picked together
    /// in Select begin it together, and neither is held.
    @discardableResult
    func makePair(_ first: LibraryFrame.ID?, _ second: LibraryFrame.ID?, keepFilmEdge: Bool = false,
                  beginsWithFirst: Bool = false) -> LibraryFrame.ID? {
        var made: PairStart
        if keepFilmEdge, let first {
            // From a half frame's Film Edge: the first hole is the half frame, as it was
            // framed, with its film edge; the second frame fills the other.
            made = PairStart.make(.halfFrame(first), library: library)
            if let second, let frame = library.frame(second), !frame.isPair { made.pair.right = PairStart.hole(for: frame) }
        } else if beginsWithFirst, let first {
            // The frame the pair began with is its first, whichever comes first in the library.
            made = PairStart.make(.new(first: first, second: nil), library: library)
            if let second, let frame = library.frame(second), !frame.isPair { made.pair.right = PairStart.hole(for: frame) }
        } else {
            made = PairStart.make(.new(first: first, second: second), library: library)
        }
        if keepFilmEdge || beginsWithFirst || second == nil { made.pair.origin = made.pair.left?.frame ?? made.pair.right?.frame }
        guard let id = keepPair(made.pair, look: made.look) else { return nil }
        library.selectedID = id
        return id
    }

    /// **An edit of a kept pair's piece**, from its darkroom: a frame's
    /// exposure, its meter, its picture under the hole, its own print, whether
    /// the back printed on it, another frame in a hole, the two changed over,
    /// the camera turned, the spacing. `mutate` is handed the piece and its
    /// look together, because some edits are of both (a frame's exposure that
    /// applies to the film moves the film's print; a swap takes each frame's
    /// Scene Placement with it).
    ///
    /// The one place the library's piece is written between a pair's making
    /// and its removal. Each hole's decode and cut are read again from its
    /// frame, the piece's size is the layout's, and its guide — what the tile
    /// and *Original* show — is drawn again when what a guide shows has moved.
    /// The develop is the open page's (`OpenFrameSession.pieceChanged`: asked
    /// for when the finger rests, as for any control), or the queue's.
    func changePair(_ id: LibraryFrame.ID, _ mutate: (inout HalfFramePair, inout FrameEdit) -> Void) {
        guard let item = library.frame(id), let was = item.pair else { return }
        let session = openSession(id)
        let historyBefore = session?.historySnapshot()
        var pair = was
        var look = session?.edit ?? item.edit
        mutate(&pair, &look)
        let frames = darkroom.held(by: pair)
        pair = pair.mirrored(frames)
        pair.hold(&look.params)
        look = look.heldToItsFilm().asPairLook
        let moved = pair.changes(from: was)
        guard pair != was || look != (session?.edit ?? item.edit) else { return }
        let own = pair.pieceSize(frames, longEdge: nil)
        // What a guide shows: which frames, where each picture sits, how the piece lies.
        let redraw = moved.contains(.pixels) && pair.guideKey != was.guideKey
        let folder = library.persistence != nil ? ImportService.previews
                                                : FileManager.default.temporaryDirectory.appendingPathComponent("PairGuides", isDirectory: true)
        let guide = redraw ? PairGuide.write(pair, frames: frames, id: id, in: folder) : nil
        let first = frames[.left] ?? frames[.right]
        library.update(id) { f in
            f.pair = pair
            f.originalSize = own
            f.previewSize = own.scaled(toLongEdge: settings.previewLongEdge)
            if let first {
                f.captureDate = first.captureDate
                f.camera = first.camera
                f.exposure = first.exposure
            }
            if let guide { f.picture = .file(guide) }
        }
        if guide != nil { Task.detached(priority: .utility) { PairGuide.discard(item.picture) } }
        if let session {
            session.pieceChanged(look: look)
            if let historyBefore { session.recordHistory(from: historyBefore) }
        } else {
            library.update(id) { $0.edit = look }
            queue(id)
        }
        if pair != was { macLibrary.pairKept(id) }
    }

    /// A frame of a pair's own decode — its white balance, its lens correction
    /// — changed from the pair's darkroom (pro-control's Scene tab).
    ///
    /// **Written to the frame itself** (the desktop's `Session.setFocusDecode`:
    /// "the shot stays the frame's — it is the same shot in every pair and by
    /// itself"). A hole's decode is read from its frame every time the piece
    /// is written (`HalfFramePair.mirrored`), so the piece takes it from
    /// there and is composed again when the finger rests. The photograph's own
    /// kept picture is made again by `keepDecode` when the finger lifts.
    func changeDecode(of side: HalfFramePair.Side, in pairID: LibraryFrame.ID, _ mutate: (inout DecodeSettings) -> Void) {
        guard let hole = library.frame(pairID)?.pair?[side], let held = library.frame(hole.frame), !held.isPair else { return }
        var decode = held.edit.decode
        mutate(&decode)
        guard decode != held.edit.decode else { return }
        let session = openSession(pairID)
        let ownsHistory = session?.beginHistoryTransaction() ?? false
        defer { if ownsHistory { session?.endHistoryTransaction() } }
        library.update(held.id) { $0.edit.decode = decode }
        changePair(pairID) { _, _ in }
    }

    /// The finger has left a control of `changeDecode`: the frame's own kept
    /// develop — what the library shows of the photograph by itself — is made
    /// again, in the one queue. It reads the camera's own white balance again
    /// too, for a frame put back to As Shot (`readAsShot`).
    func keepDecode(of side: HalfFramePair.Side, in pairID: LibraryFrame.ID) {
        guard let hole = library.frame(pairID)?.pair?[side], let held = library.frame(hole.frame), !held.isPair else { return }
        queue(held.id)
    }

    /// A pair's own switch for its film edge (`HalfFramePair.onStrip`). On a
    /// strip the camera decides the gap, so the piece is laid out again; the
    /// picture is asked for again either way — the wire is another.
    func setPairFilmEdge(_ on: Bool, of id: LibraryFrame.ID) {
        changePair(id) { pair, _ in pair.onStrip = on }
    }
}

/// A pair before the engine has developed it: its two frames' own previews
/// under their holes.
enum PairGuide {
    /// Write the guide for `pair` into `folder`, and say where. Nil when
    /// neither frame has a picture to read.
    static func write(_ pair: HalfFramePair, frames: HalfFramePair.Frames, id: UUID, in folder: URL, longEdge: Int = 1280) -> URL? {
        let layout = pair.layout(frames, longEdge: longEdge)
        let size = layout.size
        guard size.width > 0, size.height > 0 else { return nil }
        // Unexposed film, as the pair's page draws it: dark, not black.
        var canvas = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.06)).cropped(to: CGRect(origin: .zero, size: size))
        var any = false
        for side in HalfFramePair.Side.allCases {
            // A frame's own file, or — in the drawings' own library — its bundled picture.
            guard let hole = pair[side], let frame = frames[side], let url = ThumbnailStore.url(for: frame.picture),
                  let shown = preview(url, maxPixel: longEdge * 2) else { continue }
            let own = frame.developSize
            let framed = HalfFramePair.turned(hole.geometry.outputSize(for: CGSize(width: own.width, height: own.height)), by: hole.placement)
            guard framed.width > 0, framed.height > 0 else { continue }
            let rect = layout.rect(side)
            let placed = PiecePlacer.place(shown, cut: hole.geometry, quarterTurns: hole.placement.quarterTurns,
                                           window: pair.window(hole, of: framed), size: rect.size)
            // Core Image's y runs upward; the layout's downward.
            canvas = placed.transformed(by: .init(translationX: rect.minX, y: size.height - rect.maxY)).composited(over: canvas)
            any = true
        }
        guard any, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A new name each time: the pages' picture cache keys by path.
        let url = folder.appendingPathComponent("pair-\(id.uuidString)-\(UUID().uuidString.prefix(8)).jpg")
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        do {
            try context.writeJPEGRepresentation(of: canvas, to: url, colorSpace: space, options: [:])
            return url
        } catch {
            return nil
        }
    }

    /// A guide that has been replaced. Only a guide: a file of a pair's own,
    /// under `Previews` or the temporary files.
    nonisolated static func discard(_ picture: PictureRef?) {
        guard let url = picture?.fileURL, url.lastPathComponent.hasPrefix("pair-") else { return }
        let path = url.standardizedFileURL.path
        let mine = [ImportService.previews, FileManager.default.temporaryDirectory].map { $0.standardizedFileURL.path }
        guard mine.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The file's own small picture, turned as the file says: a RAW's embedded
    /// preview, a HEIF or a JPEG reduced by ImageIO. Nothing is demosaiced.
    private static func preview(_ url: URL, maxPixel: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        return CIImage(cgImage: image)
    }
}
