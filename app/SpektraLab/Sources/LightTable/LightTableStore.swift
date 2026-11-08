//  LightTableStore.swift — the table as it was left: which frames lie on it, where, in what pile.
//
//  The website keeps a copy of every picture and where it lies in the browser (`store.js`,
//  IndexedDB). The host keeps **no picture**: the frames are the library's, so what is written is
//  each frame's id and its place — centre, angle, place in the pile — and the table it lay on: its
//  size (A4, A5, A6) and which way it was turned, beside the library's own file (`Application Support/SpektraLab/lighttable.json`,
//  next to `library.json`, `LibraryPersistence`). A size is never written: it is the frame's, read
//  again from the library at every open (`LightTableSizing`), so a format changed while the table
//  was closed comes back at its new size, kept on the light.
//
//  - **A table kept before it had a size** (schema 1, 2026-10-17 to 10-19: A4 only) has no `paper`
//    and opens as the A4 it was, every film where it lay. Schema 2 writes the size.
//  - **A frame the library let go of drops off the table**: at the open, and whenever the library
//    changes (`LightTableController.sync`).
//  - Written a moment after the last change of a burst (the website's 300 ms), on a background
//    queue, atomically; and at once when the table closes.
//  - The demo library, the snapshot harness and a check keep the table in memory only.

import CoreGraphics
import Foundation

/// The table as it is written.
struct StoredTable: Codable, Equatable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schemaVersion", portrait = "portrait", paper = "paper", places = "places"
    }
    struct Place: Codable, Equatable {
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case frame = "frame", on = "on", x = "x", y = "y", rot = "rot", z = "z" }
        /// The library frame's id.
        var frame: UUID
        var on: Bool
        var x: Double
        var y: Double
        var rot: Double
        /// Its place in the pile, bottom 0; −1 off the table.
        var z: Int
    }

    var schemaVersion = 2
    var portrait: Bool
    /// The table's size; nil in a file kept before there were sizes, which was A4.
    var paper: LightTablePaper?
    var places: [Place]

    /// The table's places, in the pile's order then the ones off it.
    init(_ model: LightTableModel) {
        portrait = model.portrait
        paper = model.paper
        let z = Dictionary(uniqueKeysWithValues: model.order.enumerated().map { ($1, $0) })
        places = model.items.map { Place(frame: $0.id, on: $0.on, x: $0.x, y: $0.y, rot: $0.rot, z: z[$0.id] ?? -1) }
    }

    /// The size it was kept at: A4 for a file from before there were sizes.
    var keptPaper: LightTablePaper { paper ?? .a4 }

    /// The table laid out again from what was written (`restore`): the pile in its order, each film
    /// where it lay — carried in proportion to a table of another size or turned the other way
    /// (`LightTableModel.carried`) — then those off the table, waiting. `size` is the library's for
    /// a frame, nil for one it no longer has, which is left out.
    func model(paper nowPaper: LightTablePaper? = nil, portrait now: Bool, size: (UUID) -> CGSize?) -> LightTableModel {
        var m = LightTableModel()
        m.relayout(paper: nowPaper ?? keptPaper, portrait: now)
        let sorted = places.sorted { a, b in (a.on ? a.z : Int.max) < (b.on ? b.z : Int.max) }
        for p in sorted {
            guard let s = size(p.frame) else { continue }
            if p.on {
                m.place(p.frame, size: s, kept: LightTableModel.Kept(x: p.x, y: p.y, rot: p.rot, portrait: portrait, paper: keptPaper))
            } else {
                m.place(p.frame, size: s)
                m.takeOff(p.frame)
            }
        }
        return m
    }
}

@MainActor
final class LightTableStore {
    static let fileName = "lighttable.json"
    /// Nil: kept in memory only.
    let url: URL?
    private var pending: Task<Void, Never>?

    init(url: URL?) { self.url = url }

    /// Beside the library's own file.
    static var beside: URL { ImportService.root.appendingPathComponent(fileName) }

    /// The table as it was left; nil for none, or none this build can read, which is copied aside
    /// first (`KeptFileAside`) so the fresh table written next does not go over it.
    func load() -> StoredTable? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(StoredTable.self, from: data)
        } catch {
            KeptFileAside.setAside(url, error: error)
            return nil
        }
    }

    /// Written a moment after the last call.
    func save(_ model: LightTableModel) {
        guard let url else { return }
        let stored = StoredTable(model)
        pending?.cancel()
        pending = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            Self.write(stored, to: url)
        }
    }

    /// Written now: the table is closing.
    func saveNow(_ model: LightTableModel) {
        pending?.cancel()
        pending = nil
        guard let url else { return }
        Self.write(StoredTable(model), to: url)
    }

    nonisolated private static func write(_ stored: StoredTable, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
