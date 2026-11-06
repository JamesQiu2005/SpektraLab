//  SettingsPresets.swift — named, saved settings-clipboard clips (1.3.6).
//
//  RFC-027 listed "named presets (a saved clip)" as its next step. A preset is
//  exactly that: the groups that were ticked when it was saved and the
//  settings those groups own. Applying one is a paste of that clip, through
//  the paste path (`Session.applyPreset`): settings, not solved numbers.
//
//  **Only the owned fields are kept.** A preset's settings are the clip
//  applied to a default `Sidecar`, so the file never carries the source
//  photograph's path, crop or fingerprint, and `applied(to:)` — which reads
//  only the groups' fields — gives the same result as the original clip.
//
//  The store follows `ExportRecipeStore`: one JSON file the user can open,
//  written atomically, injectable for tests, and never fatal. One difference:
//  a file that cannot be read is **not overwritten** — saving is refused until
//  it is fixed or moved, so a typo cannot cost the user every preset.

import Foundation
import Observation

struct SettingsPreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var groups: Set<ClipboardGroup>
    /// The owned fields only (see the file comment).
    var settings: Sidecar

    init(id: UUID = UUID(), name: String, groups: Set<ClipboardGroup>, from source: Sidecar) {
        self.id = id
        self.name = name
        self.groups = groups
        self.settings = SettingsClip(groups: groups, settings: source, sourceName: "")
            .applied(to: Sidecar())
    }

    /// The clip a paste writes.
    var clip: SettingsClip { SettingsClip(groups: groups, settings: settings, sourceName: name) }

    /// Groups in the section's order, for the row's caption.
    var orderedGroups: [ClipboardGroup] { ClipboardGroup.allCases.filter(groups.contains) }

    private enum CodingKeys: String, CodingKey { case id, name, groups, settings }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Preset"
        // A group a later build adds and this one does not know is dropped,
        // not fatal: the rest of the preset still means what it meant.
        let raw = (try? c.decode([String].self, forKey: .groups)) ?? []
        groups = Set(raw.compactMap(ClipboardGroup.init(rawValue:)))
        settings = try c.decode(Sidecar.self, forKey: .settings)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(orderedGroups.map(\.rawValue), forKey: .groups)
        try c.encode(settings, forKey: .settings)
    }
}

@MainActor
@Observable
final class SettingsPresetStore {
    static let shared = SettingsPresetStore()

    private(set) var presets: [SettingsPreset]
    /// Set when the file could not be read or written, for the sheet to show.
    private(set) var problem: String?
    /// The file could not be read; saving would replace it, so it is refused.
    private var readOnly = false

    static let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SpektraLab")
            .appending(path: "settings-presets.json")
    }()

    /// Injectable: a test that used the real path would rewrite the user's
    /// own presets.
    let url: URL

    init(url: URL = SettingsPresetStore.url) {
        self.url = url
        presets = []
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            presets = try JSONDecoder().decode([SettingsPreset].self, from: Data(contentsOf: url))
        } catch {
            readOnly = true
            problem = String(format: L("%@ could not be read (%@). It has not been changed; presets cannot be saved until it is fixed or moved.",
                                       zh: "无法读取 %@（%@）。文件未被改动；修复或移走该文件之前无法保存预设。"),
                             url.lastPathComponent, error.localizedDescription)
        }
    }

    /// A name that is not taken yet: "Preset 1", "Preset 2", …
    func nextName() -> String {
        let base = L("Preset", zh: "预设")
        let taken = Set(presets.map(\.name))
        for n in 1... where !taken.contains("\(base) \(n)") { return "\(base) \(n)" }
        return base
    }

    @discardableResult
    func add(_ preset: SettingsPreset) -> Bool {
        guard !readOnly else { return false }
        presets.append(preset)
        return save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !trimmed.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = trimmed
        save()
    }

    /// Keep the preset's name and place; take the groups and settings anew.
    func replace(_ id: UUID, with preset: SettingsPreset) {
        guard !readOnly, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        var p = preset
        p.id = id
        p.name = presets[i].name
        presets[i] = p
        save()
    }

    func remove(_ id: UUID) {
        guard !readOnly else { return }
        presets.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: url, options: .atomic)
            problem = nil
            return true
        } catch {
            problem = String(format: L("Could not save %@: %@", zh: "无法保存 %@：%@"),
                             url.lastPathComponent, error.localizedDescription)
            return false
        }
    }
}
