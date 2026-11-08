//  MacPairRows.swift — a half-frame pair is a row of the Mac library (2026-10-25).
//
//  The owner, 2026-10-25: "database side this is treated as a separate image, but it must point to
//  the storage place within the app." A pair is an item of the app's library (`LibraryFrame.pair`,
//  `PairKeeping.swift`) with no file of its own in any catalog, so until now it was nowhere on the
//  Mac's library page. Now:
//
//  - **Its file is the app's, and it is the pair's recipe, never a picture.** The owner, the same day:
//    "cache system can be deleted, so the library edit must just point to the file on how the pair is
//    formed and the storage of edit, instead of the could-be-deleted cached file, and let the scheduler
//    and cache system do the re-render job." So the row points at `<app root>/Pairs/<the pair's
//    name>.spektrapair`, beside `library.json` (durable storage, not `Previews` or a render cache), never
//    in the person's folders, written each time the pair is kept or changed (`pairKept`, `recipe`):
//    `HalfFramePair`'s own JSON with the desktop's keys (each hole's `path` the frame's file, as the
//    desktop means it, and `frame` its id: its placement, exposure, print, the spacing, `onStrip`),
//    and under `spektralab` the pair's id and where its look is kept (`library.json`, by that id: the
//    look stays with the pair in the app library, as a picture's edit does, and is not copied here to
//    go stale). The guide, the develop and every render are the scheduler's and the caches', and are
//    made again from the pair when they are gone.
//  - **Its row is an image like any other**, added by reference (`images.add`, never copied, even into
//    a session) with the pair's capture time, size and camera, of kind `pair` (spklib 0.3.1). It goes
//    into the library that holds the pair's first frame: the one shown first, then any other catalog or
//    session open now or cheap to open (a Capture One catalog that is not shown is not linked for it);
//    with none, the library shown, if it takes imports. A pair with nowhere to go is tried again at the
//    next start and the next change.
//  - **The row finds the pair by that file's path**, as a picture's row finds its frame
//    (`refreshFrameIndex`): its develop state, its grid picture (the pair's develop, or its guide), and
//    Develop opening on the pair's own page instead of making a frame of the file.
//  - **Removing the pair removes both**: the file is deleted, then the row is forgotten
//    (`images.remove`, which refuses while the file is there and never touches a file).
//  - **Pairs made before** (on the window library, or before this) get files and rows at the store's
//    start (`placePairs`), which is also where a row whose pair has gone is cleaned up.
//
//  Where each pair's row went is kept in `MacLibrary/pairs.json` (pair id → source, image, path), so a
//  removal knows which library to ask.

import Foundation

extension CatalogSourcesStore {
    /// Where the app keeps its pairs' files.
    nonisolated static var pairsFolder: URL { root.appending(path: "Pairs", directoryHint: .isDirectory) }

    /// A pair's file: its name in the library ("Half-Frame Pair 3", kept unique by `keepPair`).
    nonisolated static func pairFile(_ f: LibraryFrame) -> URL {
        let name = f.fileName.replacingOccurrences(of: "/", with: "-")
        return pairsFolder.appending(path: name + "." + HalfFramePair.fileExtension)
    }

    /// The pair kept or changed (`AppServices.keepPair`, `changePair`): its file written again, and its row
    /// added if it has none yet. A library kept nowhere (the snapshot harness, the drawings') has no files.
    func pairKept(_ id: LibraryFrame.ID) {
        guard let model, model.library.persistence != nil, let f = model.library.frame(id), let pair = f.pair else { return }
        let url = Self.pairFile(f)
        do {
            try Self.writeRecipe(f, pair: pair, library: model.library)
        } catch {
            Log.warn(.library, "mac library: pair file not written", ["pair": id.uuidString, "error": error.localizedDescription])
            return
        }
        guard Self.readPairRecord().placed[id.uuidString] == nil else { return }
        Task { await placePair(id) }
    }

    /// Pairs gone from the app library (`AppServices.remove`): their files deleted, then their rows forgotten.
    func pairsRemoved(_ frames: [LibraryFrame]) {
        let pairs = frames.filter(\.isPair)
        guard !pairs.isEmpty else { return }
        var record = Self.readPairRecord()
        var drop: [PairRecord.Placed] = []
        for f in pairs {
            let placed = record.placed.removeValue(forKey: f.id.uuidString)
            let url = placed.map { URL(fileURLWithPath: $0.path) } ?? Self.pairFile(f)
            try? FileManager.default.removeItem(at: url)
            if let placed { drop.append(placed) }
        }
        Self.write(record)
        guard !drop.isEmpty else { return }
        Task { await forgetRows(drop) }
    }

    /// Every pair of the app library with its file and its row (the pairs made before rows were), and a
    /// row whose pair has gone forgotten. Called at the store's start, after the sources are read.
    func placePairs() async {
        guard let model, model.library.persistence != nil else { return }
        // Guides and develops gone with a cache: made again from the pairs (the rows point at recipes).
        model.repairPairPictures()
        let pairs = model.library.frames.filter(\.isPair)
        var record = Self.readPairRecord()
        let ids = Set(pairs.map(\.id.uuidString))
        let orphans = record.placed.filter { !ids.contains($0.key) }
        if !orphans.isEmpty {
            for (key, placed) in orphans {
                try? FileManager.default.removeItem(atPath: placed.path)
                record.placed[key] = nil
            }
            Self.write(record)
            await forgetRows(Array(orphans.values))
        }
        for f in pairs {
            let url = Self.pairFile(f)
            if !FileManager.default.fileExists(atPath: url.path), let pair = f.pair {
                try? Self.writeRecipe(f, pair: pair, library: model.library)
            }
            if record.placed[f.id.uuidString] == nil { await placePair(f.id) }
        }
    }

    /// The pair's row, in the library that holds its first frame (see the header).
    private func placePair(_ id: LibraryFrame.ID) async {
        guard let model, !pairPlacing.contains(id) else { return }
        pairPlacing.insert(id)
        defer { pairPlacing.remove(id) }
        guard let f = model.library.frame(id), let pair = f.pair, Self.readPairRecord().placed[id.uuidString] == nil else { return }
        let url = Self.pairFile(f)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let firstFrame = (pair.left ?? pair.right).flatMap { model.library.frame($0.frame) }
        guard let (s, h) = await pairHome(firstFrame?.picture.fileURL) else {
            Log.note(.library, "mac library: pair has no library to be a row of yet", ["pair": id.uuidString])
            return
        }
        let item = LibraryClient.AddItem(url: url, capturedLocal: Self.wallClockString(f.captureDate),
                                         width: f.originalSize.width, height: f.originalSize.height, cameraModel: f.camera)
        do {
            // By reference, whatever the library's own default: the file is the app's and stays where it is.
            let r = try await client.add(h, [item], copy: false, recentImport: false)
            guard let image = r.results.first?.image else {
                Log.warn(.library, "mac library: pair row not added", ["pair": id.uuidString, "error": r.results.first?.error ?? "-"])
                return
            }
            var record = Self.readPairRecord()
            record.placed[id.uuidString] = .init(source: s.id, image: image, path: url.path)
            Self.write(record)
            Log.note(.library, "mac library: pair row", ["pair": id.uuidString, "source": s.name])
            refreshDevelopInfo()
            if s.id == selectedSourceID {
                await refreshTree()
                await reload()
            }
        } catch {
            Log.warn(.library, "mac library: pair row not added", ["pair": id.uuidString, "error": error.localizedDescription])
        }
    }

    /// The library a pair's row goes into: the one shown first, then the other SpektraLab catalogs and
    /// sessions (and a Capture One catalog only if it is the one shown: linking one is a snapshot), the
    /// first that holds `firstFile`; with none, the one shown, if it takes imports.
    private func pairHome(_ firstFile: URL?) async -> (MacSource, String)? {
        var order = sources.filter { $0.acceptsImports && ($0.kind != .captureOneCatalog || $0.id == selectedSourceID) }
        if let i = order.firstIndex(where: { $0.id == selectedSourceID }) { order.insert(order.remove(at: i), at: 0) }
        if let firstFile {
            for s in order {
                guard let h = try? await handle(s),
                      let found = try? await client.lookup(h, paths: [firstFile]), found.results.first?.found == true else { continue }
                return (s, h)
            }
        }
        if let s = selectedSource, s.acceptsImports, let h = try? await handle(s) { return (s, h) }
        return nil
    }

    /// Rows whose pair has gone, each forgotten in its own library (whose file is deleted by now).
    private func forgetRows(_ rows: [PairRecord.Placed]) async {
        for (source, group) in Dictionary(grouping: rows, by: \.source) {
            guard let s = sources.first(where: { $0.id == source }), let h = try? await handle(s) else { continue }
            do {
                _ = try await client.removeImages(h, images: group.map(\.image))
            } catch {
                Log.warn(.library, "mac library: pair rows not forgotten", ["source": s.name, "error": error.localizedDescription])
            }
            if source == selectedSourceID {
                await refreshTree()
                await reload()
            }
        }
    }

    // MARK: - the recipe

    /// The pair's file: how it is formed, and where its look is kept (see the header).
    static func writeRecipe(_ f: LibraryFrame, pair: HalfFramePair, library: FrameCatalog) throws {
        var p = pair
        var frames: [String: Any] = [:]
        for side in HalfFramePair.Side.allCases {
            guard var hole = p[side], let id = hole.frame, let frame = library.frame(id) else { continue }
            let file = frame.picture.fileURL?.path
            // The desktop's meaning of `path`: the frame's file. The host's key, `frame`, stays beside it.
            if let file { hole.path = file }
            p[side] = hole
            frames[side.key] = ["frame": id.uuidString, "path": file ?? hole.path, "name": frame.fileName]
        }
        guard var json = try JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any] else { return }
        json["spektralab"] = [
            "kind": "half_frame_pair", "version": 1, "pair": f.id.uuidString, "name": f.fileName, "frames": frames,
            // The look is the app library's, by the pair's id: one place, never a second copy that goes stale.
            "edit": ["kept_in": library.persistence?.url.path ?? "", "frame": f.id.uuidString],
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let url = pairFile(f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - the record

    /// `MacLibrary/pairs.json`.
    struct PairRecord: Codable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case version = "version", placed = "placed" }
        struct Placed: Codable, Equatable {
            /// The keys as they are written: renaming a property must not move its key.
            enum CodingKeys: String, CodingKey { case source = "source", image = "image", path = "path" }
            var source: MacSource.ID
            /// The helper's image uuid of the row.
            var image: String
            /// The pair's file the row points at.
            var path: String
        }
        var version = 1
        /// By the pair's id.
        var placed: [String: Placed] = [:]
    }

    nonisolated static var pairRecordURL: URL { root.appending(path: "MacLibrary/pairs.json") }

    /// The record; an empty one for none, or for one this build cannot read, which is copied aside
    /// first (`KeptFileAside`) so the record written next does not go over it.
    nonisolated static func readPairRecord() -> PairRecord {
        guard let data = try? Data(contentsOf: pairRecordURL) else { return PairRecord() }
        do {
            return try JSONDecoder().decode(PairRecord.self, from: data)
        } catch {
            KeptFileAside.setAside(pairRecordURL, error: error)
            return PairRecord()
        }
    }

    private nonisolated static func write(_ r: PairRecord) {
        do {
            try FileManager.default.createDirectory(at: pairRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(r).write(to: pairRecordURL, options: .atomic)
        } catch {
            Log.warn(.library, "mac library: pair record not kept", ["error": error.localizedDescription])
        }
    }
}
