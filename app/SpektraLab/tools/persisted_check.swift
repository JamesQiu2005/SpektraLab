//  persisted_check.swift — a 2.1.4 library's files, read by this tree's own types, written back the same.
//
//      tools/selftest.sh                                # with the other checks
//      build/tools/persisted_check tools/persisted_2.1.4  # alone, once built
//
//  The files a person's work lives in are named by Swift: a key is a property's name or a CodingKeys
//  literal, a value a case's raw value. Every one of them is spelled out as a literal (2026-11-08), so a
//  rename of a type, a property or a case cannot move a byte on disk; this check is what holds that. For
//  each file of `tools/persisted_2.1.4/` (written by the 2.1.4 release's own types, see its README) it
//  decodes the file with this tree's types — through the app's own reader where the app has one
//  (`PresetStore(url:)`, `ExportRecipeStore(url:)`, `LightTableStore(url:).load()`) — encodes it again as
//  the app writes it, and compares the two documents value for value. It names root types and readers
//  only, never a stored property or a key, so a rename of those leaves this file compiling and the check
//  meaningful.
//
//  A renamed key fails one of two ways, both red here:
//  - **a required key**: the decode throws (in the app, `library.json` would be set aside unread and the
//    library would start empty, `KeptFileAside`);
//  - **an optional key** (`decodeIfPresent ?? default`): it is read as its default. Every leaf of the
//    fixture was moved off its default when it was written, so the re-encoded document differs.
//  A renamed String case: `enums.json` holds every raw value of every enum that reaches a file, and the
//  old word no longer decodes.
//
//  Two more things, which a person's file depends on and no round trip shows:
//  - **retired words** (`retired` below): a value 2.1 could write that names nothing now is read as the
//    value it stands for, and the check expects exactly that, not the old word back;
//  - **a file that does not read is set aside, once** — the Light Table's and the recipes', the two
//    readers this check can compile (the library's own reader calls the same `KeptFileAside`).
//
//  The fixture is copied to a scratch folder first: a reader that sets a file aside writes beside it, and
//  a check never writes into the tree (AGENTS.md trap 24: a test owns its inputs). Arrays of strings are
//  compared as sets (`Set<ClipboardGroup>` encodes in per-process hash order); every other array keeps its
//  order. **Never regenerate the fixture to make this check pass**: the fixture is what 2.1.4 wrote, and a
//  red here is a 2.1.4 file this tree would read differently.

import Foundation

enum Persisted {
    struct Failure: Error, CustomStringConvertible { var description: String }

    /// Words a 2.1.4 file may hold that this build reads as another: (key, kept, read as). Each one is a
    /// decision of the type that owns the key (`ExportRecipe.Destination.retired`), repeated here so the
    /// check says what it expects rather than learning it from the code it checks.
    static let retired: [(key: String, kept: String, readAs: String)] = [
        ("destination", "Photos", "Files"),
    ]

    static func canonical(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.mapValues(canonical) }
        if let a = v as? [Any] {
            if let s = a as? [String] { return s.sorted() }
            return a.map(canonical)
        }
        return v
    }

    /// The document as this build should read it: every retired word replaced by the one it stands for.
    static func retiring(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, x) in d {
                if let s = x as? String, let r = retired.first(where: { $0.key == k && $0.kept == s }) {
                    out[k] = r.readAs
                } else {
                    out[k] = retiring(x)
                }
            }
            return out
        }
        if let a = v as? [Any] { return a.map(retiring) }
        return v
    }

    /// The first place two JSON documents differ, as a path, or nil when they agree.
    static func diff(_ a: Any, _ b: Any, _ path: String = "$") -> String? {
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            for k in Set(x.keys).union(y.keys).sorted() {
                guard let xv = x[k] else { return "\(path).\(k): only after the round trip" }
                guard let yv = y[k] else { return "\(path).\(k): lost in the round trip (a renamed key?)" }
                if let d = diff(xv, yv, "\(path).\(k)") { return d }
            }
            return nil
        case let (x as [Any], y as [Any]):
            guard x.count == y.count else { return "\(path): \(x.count) items became \(y.count)" }
            for (i, (xv, yv)) in zip(x, y).enumerated() { if let d = diff(xv, yv, "\(path)[\(i)]") { return d } }
            return nil
        case let (x as NSNumber, y as NSNumber):
            return x == y ? nil : "\(path): \(x) became \(y)"
        case let (x as String, y as String):
            return x == y ? nil : "\(path): \"\(x)\" became \"\(y)\""
        case (is NSNull, is NSNull):
            return nil
        default:
            return "\(path): \(type(of: a)) became \(type(of: b))"
        }
    }

    static func json(_ data: Data) throws -> Any {
        canonical(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// The kept file as this build should read it back.
    static func expected(_ data: Data) throws -> Any { retiring(try json(data)) }

    static func coders() -> (JSONDecoder, JSONEncoder) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (JSONDecoder(), e)
    }

    /// Decode with this tree's type, encode as the app does, compare.
    static func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> String? {
        let (d, e) = coders()
        let value: T
        do { value = try d.decode(T.self, from: data) } catch { return "decode threw: \(error)" }
        return diff(try expected(data), try json(try e.encode(value)))
    }

    static func read(_ dir: URL, _ name: String) throws -> Data {
        do { return try Data(contentsOf: dir.appendingPathComponent(name)) }
        catch { throw Failure(description: "\(name): the fixture is missing") }
    }

    /// Every check: (fixture file, what reads it). Root types and readers only.
    @MainActor
    static func checks(_ dir: URL) -> [(String, () throws -> String?)] {
        [
            ("frame-edit.json", { try roundTrip(FrameEdit.self, try read(dir, "frame-edit.json")) }),
            ("frame-edit-default.json", { try roundTrip(FrameEdit.self, try read(dir, "frame-edit-default.json")) }),
            ("pair.spektrapair", { try roundTrip(HalfFramePair.self, try read(dir, "pair.spektrapair")) }),
            ("settings-clip.json", { try roundTrip(SettingsClip.self, try read(dir, "settings-clip.json")) }),
            ("export-recipes.json", {
                // Through the app's own reader: what the recipes sheet shows.
                let store = ExportRecipeStore(url: dir.appendingPathComponent("export-recipes.json"))
                if let p = store.problem { return "ExportRecipeStore refused the file: \(p)" }
                return diff(try expected(try read(dir, "export-recipes.json")), try json(try coders().1.encode(store.recipes)))
            }),
            ("look-presets.json", {
                let store = PresetStore(url: dir.appendingPathComponent("look-presets.json"))
                if let e = store.error { return "PresetStore refused the file: \(e)" }
                guard let kept = try expected(try read(dir, "look-presets.json")) as? [String: Any],
                      let presetsKept = kept["presets"] else { return "no presets array" }
                return diff(presetsKept, try json(try coders().1.encode(store.presets)), "$.presets")
            }),
            ("lighttable.json", {
                let store = LightTableStore(url: dir.appendingPathComponent("lighttable.json"))
                guard let table = store.load() else { return "LightTableStore could not read the file" }
                return diff(try expected(try read(dir, "lighttable.json")), try json(try coders().1.encode(table)))
            }),
            ("enums.json", { try enums(try read(dir, "enums.json")) }),
            ("unreadable files", { try setAside(dir) }),
        ]
    }

    /// Every raw value 2.1.4 had for every String enum that reaches a file must still decode — to itself,
    /// or, for a retired word, to the value it stands for.
    static func enums(_ data: Data) throws -> String? {
        guard let kept = try JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return "not a table" }
        func one<E: RawRepresentable & Decodable>(_ name: String, _: E.Type) -> String? where E.RawValue == String {
            guard let words = kept[name] else { return "\(name): not in the fixture" }
            var bad: [String] = []
            for word in words {
                let readAs = retired.first { $0.kept == word }?.readAs ?? word
                guard let value = try? JSONDecoder().decode(E.self, from: Data("\"\(word)\"".utf8)),
                      value.rawValue == readAs else { bad.append(word); continue }
            }
            return bad.isEmpty ? nil : "\(name): \(bad) no longer decode as kept (a renamed case?)"
        }
        let all: [String?] = [
            one("CropAspect", CropAspect.self), one("FilmEdgeFormat", FilmEdgeFormat.self),
            one("FilmEdgeView", FilmEdgeView.self), one("FilmEdgeGate", FilmEdgeGate.self),
            one("FilmEdgeHoles", FilmEdgeHoles.self), one("DateBackFace", DateBackFace.self),
            one("DateBackPlacement", DateBackPlacement.self), one("DateBackCorner", DateBackCorner.self),
            one("DateBackOrder", DateBackOrder.self), one("DecodeSettings.WhiteBalance", DecodeSettings.WhiteBalance.self),
            one("ClipboardGroup", ClipboardGroup.self), one("ExportRecipe.Format", ExportRecipe.Format.self),
            one("ExportRecipe.Colour", ExportRecipe.Colour.self), one("ExportRecipe.Destination", ExportRecipe.Destination.self),
            one("LightTablePaper", LightTablePaper.self), one("HalfFramePair.Scope", HalfFramePair.Scope.self),
            one("CurveChannel", CurveChannel.self), one("ParametricCurve.Region", ParametricCurve.Region.self),
        ]
        let bad = all.compactMap { $0 }
        return bad.isEmpty ? nil : bad.joined(separator: "; ")
    }

    /// A Light Table and a recipes file that do not decode: each is read as "nothing kept" as before, and
    /// copied beside itself, byte for byte, once however often it is read.
    @MainActor
    static func setAside(_ dir: URL) throws -> String? {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent("unreadable", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let junk = Data("{\"places\": \"a key this build reads, holding what it cannot\"}".utf8)
        func asides(_ stem: String) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(stem + ".unreadable-") }
        }
        let table = folder.appendingPathComponent("lighttable.json")
        try junk.write(to: table)
        let store = LightTableStore(url: table)
        if store.load() != nil { return "an unreadable lighttable.json read as a table" }
        _ = store.load()
        let tableAside = asides("lighttable")
        guard tableAside.count == 1 else { return "lighttable.json: \(tableAside.count) copies set aside, not 1" }
        guard (try? Data(contentsOf: tableAside[0])) == junk else { return "lighttable.json: the copy is not the file" }

        let recipes = folder.appendingPathComponent("export-recipes.json")
        try junk.write(to: recipes)
        let recipeStore = ExportRecipeStore(url: recipes)
        if recipeStore.problem == nil { return "an unreadable export-recipes.json read without a problem" }
        guard recipeStore.recipes == ExportRecipe.builtIn else { return "an unreadable export-recipes.json did not leave the built-ins" }
        _ = ExportRecipeStore(url: recipes)
        let recipeAside = asides("export-recipes")
        guard recipeAside.count == 1 else { return "export-recipes.json: \(recipeAside.count) copies set aside, not 1" }
        guard (try? Data(contentsOf: recipeAside[0])) == junk else { return "export-recipes.json: the copy is not the file" }
        return nil
    }
}

@main
struct PersistedCheck {
    @MainActor
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        #if PERSISTED_FIXTURE_WRITER
        if args.first == "--write", args.count == 2 {
            let dir = URL(fileURLWithPath: args[1], isDirectory: true)
            try PersistedFixtureWriter.write(to: dir)
            print("persisted: fixture written to \(dir.path)")
            return
        }
        #endif
        guard let path = args.first else { print("usage: persisted_check <fixture dir>"); exit(2) }
        // A scratch copy: a reader may write beside the file it reads, and the fixture is the tree's.
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("persisted-check-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: URL(fileURLWithPath: path, isDirectory: true), to: scratch)
        defer { try? fm.removeItem(at: scratch) }
        var failed = 0
        for (name, check) in Persisted.checks(scratch) {
            do {
                if let d = try check() { print("FAIL  \(name): \(d)"); failed += 1 } else { print("ok    \(name)") }
            } catch { print("FAIL  \(name): \(error)"); failed += 1 }
        }
        print("persisted check: \(failed == 0 ? "green" : "RED"), \(failed) failing")
        exit(failed == 0 ? 0 : 1)
    }
}
