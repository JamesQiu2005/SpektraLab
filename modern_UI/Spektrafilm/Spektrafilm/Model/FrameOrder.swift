//  FrameOrder.swift — the order a folder's frames were dragged into.
//
//  The filmstrip lists a folder by name. A photographer puts the frames in
//  the order of the story (or the two halves of a pair next to each other),
//  and that order is theirs: it is kept next to the sidecars, one small file
//  per folder, and laid over the listing the next time the folder is opened.
//  Frames it does not name — added to the folder since, or a pair made since
//  — stay where the listing has them, after their own neighbour.

import CryptoKit
import Foundation

enum FrameOrder {
    nonisolated static var storeDirectory: URL { Sidecar.storeDirectory.appending(path: "Order") }

    /// The one folder a set of frames is from, or nil for a set drawn from
    /// several (an order is a folder's). A pair is a file in the store and is
    /// not asked: it belongs to the folder of the frames beside it.
    nonisolated static func folder(of frames: [URL]) -> URL? {
        let parents = Set(frames.filter { !HalfFramePair.isPair($0) }
            .map { $0.deletingLastPathComponent().standardizedFileURL.path })
        return parents.count == 1 ? URL(fileURLWithPath: parents.first!) : nil
    }

    nonisolated static func url(for folder: URL) -> URL {
        let path = folder.standardizedFileURL.path
        let hex = SHA256.hash(data: Data(path.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return storeDirectory.appending(path: "\(folder.lastPathComponent)-\(hex).order.json")
    }

    /// Keep `frames` as their folder's order. A failure is not reported: the
    /// order is a convenience, and the frames are where they were.
    nonisolated static func save(_ frames: [URL]) {
        guard let folder = folder(of: frames) else { return }
        let names = frames.map(\.lastPathComponent)
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try? data.write(to: url(for: folder), options: .atomic)
    }

    /// `listed` in the order kept for its folder.
    nonisolated static func applied(to listed: [Frame]) -> [Frame] {
        guard let folder = folder(of: listed.map(\.id)),
              let data = try? Data(contentsOf: url(for: folder)),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return listed }
        return ordered(listed, by: names)
    }

    /// The named frames in the order named; each of the others after the
    /// frame it follows in `listed` (or first, when it follows none).
    nonisolated static func ordered(_ listed: [Frame], by names: [String]) -> [Frame] {
        var rank: [String: Int] = [:]
        for (i, n) in names.enumerated() where rank[n] == nil { rank[n] = i }
        var out = listed.filter { rank[$0.id.lastPathComponent] != nil }
            .sorted { rank[$0.id.lastPathComponent]! < rank[$1.id.lastPathComponent]! }
        for (i, frame) in listed.enumerated() where rank[frame.id.lastPathComponent] == nil {
            let before = i > 0 ? out.firstIndex { $0.id == listed[i - 1].id } : nil
            out.insert(frame, at: before.map { $0 + 1 } ?? 0)
        }
        return out
    }
}
