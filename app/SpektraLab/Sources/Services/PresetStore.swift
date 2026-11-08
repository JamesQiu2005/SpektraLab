import Foundation
import Observation

struct LookPreset: Codable, Equatable, Identifiable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case id = "id", name = "name", clip = "clip" }
    var id = UUID()
    var name: String
    var clip: SettingsClip
}

/// Version 1 is independent of sidecars. Unknown versions/corruption are read-only;
/// writes are atomic and leave the last good file intact. Extra JSON fields survive edits.
@MainActor @Observable final class PresetStore {
    private(set) var presets: [LookPreset] = []
    private(set) var error: String?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var raw: [String: Any] = [:]
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var deleted: (LookPreset, Int)?
    @ObservationIgnored private var deletedRaw: [String: Any]?
    private struct File: Codable {
        var version = 1; var presets: [LookPreset]
        /// The keys as they are written: renaming a property must not move its key.
        enum CodingKeys: String, CodingKey { case version = "version", presets = "presets" }
    }

    init(url: URL?) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version == 1, file.presets.allSatisfy({ $0.clip.settings.schemaVersion == FrameEdit.currentSchema }),
                  Set(file.presets.map(\.id)).count == file.presets.count else { throw Failure.unsupported }
            presets = file.presets
            raw = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } catch { writable = false; self.error = L("Presets could not be read") }
    }
    var canWrite: Bool { writable }
    var canRestore: Bool { deleted != nil }
    func clearError() { error = nil }
    @discardableResult func save(name: String, clip: SettingsClip) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, !clip.groups.isEmpty else { return false }
        guard !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            error = L("A preset with this name already exists"); return false
        }
        return commit(presets + [LookPreset(name: String(name.prefix(80)), clip: clip.transferable)])
    }
    @discardableResult func rename(_ id: UUID, to name: String) -> Bool {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return false }
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            error = L("A preset with this name already exists"); return false
        }
        var next = presets; next[i].name = name
        return commit(next)
    }
    func delete(_ id: UUID) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        var next = presets; let removed = next.remove(at: i)
        let original = (raw["presets"] as? [[String: Any]])?.first { ($0["id"] as? String) == removed.id.uuidString }
        if commit(next) { deleted = (removed, i); deletedRaw = original }
    }
    func restoreDeleted() {
        guard let (preset, index) = deleted else { return }
        guard !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame }) else {
            error = L("A preset with this name already exists"); return
        }
        var next = presets; next.insert(preset, at: min(index, next.count))
        if commit(next) { deleted = nil; deletedRaw = nil }
    }
    private func commit(_ next: [LookPreset]) -> Bool {
        guard writable else { error = L("Presets could not be read"); return false }
        do {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(File(presets: next))) as! [String: Any]
            var merged = raw
            merged["version"] = 1
            var old = raw["presets"] as? [[String: Any]] ?? []
            if let deletedRaw { old.append(deletedRaw) }
            merged["presets"] = (encoded["presets"] as? [[String: Any]] ?? []).map { fresh in
                Self.merge(old.first(where: { ($0["id"] as? String) == (fresh["id"] as? String) }) ?? [:], fresh)
            }
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]).write(to: url, options: .atomic)
            }
            raw = merged; presets = next; error = nil; return true
        } catch { self.error = L("Preset could not be saved"); return false }
    }
    private static func merge(_ old: [String: Any], _ new: [String: Any]) -> [String: Any] {
        var out = old
        for (key, value) in new {
            if let a = old[key] as? [String: Any], let b = value as? [String: Any] { out[key] = merge(a, b) }
            else { out[key] = value }
        }
        return out
    }
    private enum Failure: Error { case unsupported }
}
