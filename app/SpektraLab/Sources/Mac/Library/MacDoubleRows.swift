//  MacDoubleRows.swift — a double exposure is a row of the Mac library, as a pair is (2026-11-11).
//
//  `MacPairRows.swift` for the pair's sibling (`DoubleExposure`, RFC-047), on the owner's rule for the pair
//  (2026-10-25): "database side this is treated as a separate image, but it must point to the storage place
//  within the app", and "the library edit must just point to the file on how the pair is formed and the
//  storage of edit, instead of the could-be-deleted cached file". So, as for a pair (`MAC-LIBRARY-DATA.md` §2k):
//
//  - **its file is its recipe**, `<app root>/Doubles/<the double's name>.spektradouble` beside `library.json`:
//    `DoubleExposure`'s own JSON (each exposure's photograph by id, its decode and cut, its placement and flip,
//    its own stops and meter, the readings), and under `spektralab` the double's id, its two photographs
//    (id, file, name) and where its look is kept (`library.json`'s sibling `doubles.json`, by that id; never
//    copied here to go stale). Written on every keep and every change that moves the piece (`doubleKept`);
//  - **its row is added by reference** (`images.add`, never copied) into the library holding its **bottom**
//    photograph (the one that sets the frame), with the double's capture time, size and camera. spklib 0.3.1
//    has no kind for it: the row's kind is `other` until the SDK names `.spektradouble` (a one-line change in
//    `kind_for_extension`, `SpektraLab_library`, not made here). The grid and Develop find the double by the
//    file's path, as a pair's (`refreshFrameIndex`);
//  - **removing the double removes both** (`doublesRemoved`); **doubles made before** get files and rows at
//    the store's start (`placeDoubles`), where a row whose double has gone is cleaned up too.
//
//  Where each double's row went is `MacLibrary/doubles.json` (double id → source, image, path), the pair's
//  record's shape (`PairRecord`).

import Foundation

extension CatalogSourcesStore {
    /// Where the app keeps its double exposures' files.
    nonisolated static var doublesFolder: URL { root.appending(path: "Doubles", directoryHint: .isDirectory) }

    /// A double's file: its name in the library ("Double Exposure 3", kept unique by `keepDouble`).
    nonisolated static func doubleFile(_ f: LibraryFrame) -> URL {
        let name = f.fileName.replacingOccurrences(of: "/", with: "-")
        return doublesFolder.appending(path: name + "." + DoubleExposure.fileExtension)
    }

    /// The double kept or changed (`AppServices.keepDouble`, `changeDouble`): its file written again, and its
    /// row added if it has none yet. A library kept nowhere (the snapshot harness, the drawings') has no files.
    func doubleKept(_ id: LibraryFrame.ID) {
        guard let model, model.library.persistence != nil, let f = model.library.frame(id), let double = f.double else { return }
        do {
            try Self.writeRecipe(f, double: double, library: model.library)
        } catch {
            Log.warn(.library, "mac library: double file not written", ["double": id.uuidString, "error": error.localizedDescription])
            return
        }
        guard Self.readDoubleRecord().placed[id.uuidString] == nil else { return }
        Task { await placeDouble(id) }
    }

    /// Double exposures gone from the app library (`AppServices.remove`): their files deleted, their rows forgotten.
    func doublesRemoved(_ frames: [LibraryFrame]) {
        let doubles = frames.filter(\.isDouble)
        guard !doubles.isEmpty else { return }
        var record = Self.readDoubleRecord()
        var drop: [PairRecord.Placed] = []
        for f in doubles {
            let placed = record.placed.removeValue(forKey: f.id.uuidString)
            try? FileManager.default.removeItem(at: placed.map { URL(fileURLWithPath: $0.path) } ?? Self.doubleFile(f))
            if let placed { drop.append(placed) }
        }
        Self.writeDoubleRecord(record)
        guard !drop.isEmpty else { return }
        Task { await forgetRows(drop) }
    }

    /// Every double of the app library with its file and its row, and a row whose double has gone forgotten.
    /// Called at the store's start, after the pairs (`placePairs`).
    func placeDoubles() async {
        guard let model, model.library.persistence != nil else { return }
        let doubles = model.library.frames.filter(\.isDouble)
        var record = Self.readDoubleRecord()
        let ids = Set(doubles.map(\.id.uuidString))
        let orphans = record.placed.filter { !ids.contains($0.key) }
        if !orphans.isEmpty {
            for (key, placed) in orphans {
                try? FileManager.default.removeItem(atPath: placed.path)
                record.placed[key] = nil
            }
            Self.writeDoubleRecord(record)
            await forgetRows(Array(orphans.values))
        }
        for f in doubles {
            if !FileManager.default.fileExists(atPath: Self.doubleFile(f).path), let double = f.double {
                try? Self.writeRecipe(f, double: double, library: model.library)
            }
            if record.placed[f.id.uuidString] == nil { await placeDouble(f.id) }
        }
    }

    /// The double's row, in the library that holds its bottom photograph (the top's with the bottom empty).
    private func placeDouble(_ id: LibraryFrame.ID) async {
        guard let model, !pairPlacing.contains(id) else { return }
        pairPlacing.insert(id)
        defer { pairPlacing.remove(id) }
        guard let f = model.library.frame(id), let double = f.double, Self.readDoubleRecord().placed[id.uuidString] == nil else { return }
        let url = Self.doubleFile(f)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let bottom = (double[.bottom] ?? double[.top]).flatMap { model.library.frame($0.frame) }
        guard let (s, h) = await pairHome(bottom?.picture.fileURL) else {
            Log.note(.library, "mac library: double has no library to be a row of yet", ["double": id.uuidString])
            return
        }
        let item = LibraryClient.AddItem(url: url, capturedLocal: Self.wallClockString(f.captureDate),
                                         width: f.originalSize.width, height: f.originalSize.height, cameraModel: f.camera)
        do {
            let r = try await client.add(h, [item], copy: false, recentImport: false)
            guard let image = r.results.first?.image else {
                Log.warn(.library, "mac library: double row not added", ["double": id.uuidString, "error": r.results.first?.error ?? "-"])
                return
            }
            var record = Self.readDoubleRecord()
            record.placed[id.uuidString] = .init(source: s.id, image: image, path: url.path)
            Self.writeDoubleRecord(record)
            Log.note(.library, "mac library: double row", ["double": id.uuidString, "source": s.name])
            refreshDevelopInfo()
            if s.id == selectedSourceID {
                await refreshTree()
                await reload()
            }
        } catch {
            Log.warn(.library, "mac library: double row not added", ["double": id.uuidString, "error": error.localizedDescription])
        }
    }

    // MARK: - the recipe

    /// The double's file: how it is formed, and where its look is kept (see the header).
    static func writeRecipe(_ f: LibraryFrame, double: DoubleExposure, library: FrameCatalog) throws {
        var photos: [String: Any] = [:]
        for position in DoubleExposure.Position.allCases {
            guard let e = double[position], let frame = library.frame(e.frame) else { continue }
            photos[position == .bottom ? "bottom" : "top"] = ["frame": e.frame.uuidString,
                                                              "path": frame.picture.fileURL?.path ?? "", "name": frame.fileName]
        }
        guard var json = try JSONSerialization.jsonObject(with: double.encoded()) as? [String: Any] else { return }
        json["spektralab"] = [
            "kind": "double_exposure", "version": 1, "double": f.id.uuidString, "name": f.fileName, "exposures": photos,
            // The look is the app library's, by the double's id: one place, never a second copy that goes stale.
            "edit": ["kept_in": library.persistence?.doublesURL.path ?? "", "frame": f.id.uuidString],
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let url = doubleFile(f)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - the record (`MacLibrary/doubles.json`, the pair's record's shape)

    nonisolated static var doubleRecordURL: URL { root.appending(path: "MacLibrary/doubles.json") }

    nonisolated static func readDoubleRecord() -> PairRecord {
        guard let data = try? Data(contentsOf: doubleRecordURL) else { return PairRecord() }
        do {
            return try JSONDecoder().decode(PairRecord.self, from: data)
        } catch {
            KeptFileAside.setAside(doubleRecordURL, error: error)
            return PairRecord()
        }
    }

    private nonisolated static func writeDoubleRecord(_ r: PairRecord) {
        do {
            try FileManager.default.createDirectory(at: doubleRecordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(r).write(to: doubleRecordURL, options: .atomic)
        } catch {
            Log.warn(.library, "mac library: double record not kept", ["error": error.localizedDescription])
        }
    }
}
