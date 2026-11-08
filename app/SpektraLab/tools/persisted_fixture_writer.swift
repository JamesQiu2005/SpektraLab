//  persisted_fixture_writer.swift — how `tools/persisted_2.1.4/` was made. Not part of `tools/selftest.sh`.
//
//      swiftc -O -parse-as-library -D PERSISTED_FIXTURE_WRITER <the check's sources> \
//          tools/persisted_fixture_writer.swift -o build/tools/persisted_writer
//      build/tools/persisted_writer --write <empty folder>
//
//  The fixture was written by the 2.1.4 release's own types through this writer (its recipes' destinations
//  then set to the Mac's, as below), and on 2026-11-08, before any rename, this file compiled against the
//  tree wrote the same bytes but for a Set's order and a new preset id. Unlike the check, it names stored
//  properties, so a later rename stops it compiling — which is right: the fixture is 2.1.4's and is
//  **never regenerated to make the check pass**. Keep it for what it shows, and for a new file the check
//  should cover: write that one file, look at it, add it to the folder.
//
//  Every value is synthetic (paths under /Volumes/Fixture, fixed UUIDs, fixed dates): nothing of anyone's
//  library. After the seed values are encoded, every Bool and number leaf is moved off its default
//  (flipped, or +1 / +0.125), and the move is kept only where the document still round-trips through the
//  types unchanged (a clamp or a derived value refuses it): so a key a later tree reads as its default is a
//  key it no longer reads, and the check sees it.
//
//  The recipes go to Files (the Mac's default), one to Share, and one carries the retired word "Photos",
//  which a 2.1 file may hold (`ExportRecipe.Destination.retired`) and which no type can write any more:
//  it is put into the JSON after the types have written it.

#if PERSISTED_FIXTURE_WRITER
import CoreGraphics
import Foundation

@MainActor
enum PersistedFixtureWriter {
    static let skip: Set<String> = ["schemaVersion", "version"]   // readers refuse other versions

    static func perturbed(_ doc: Any, roundTrips: (Any) -> Bool) -> Any {
        var doc = doc
        func leaves(_ v: Any, _ path: [Any]) -> [[Any]] {
            if let d = v as? [String: Any] {
                return d.keys.sorted().flatMap { k in skip.contains(k) ? [] : leaves(d[k]!, path + [k]) }
            }
            if let a = v as? [Any] { return a.indices.flatMap { leaves(a[$0], path + [$0]) } }
            return v is NSNumber ? [path] : []
        }
        func get(_ v: Any, _ p: ArraySlice<Any>) -> Any {
            guard let h = p.first else { return v }
            if let k = h as? String { return get((v as! [String: Any])[k]!, p.dropFirst()) }
            return get((v as! [Any])[h as! Int], p.dropFirst())
        }
        func set(_ v: Any, _ p: ArraySlice<Any>, _ new: Any) -> Any {
            guard let h = p.first else { return new }
            if let k = h as? String { var d = v as! [String: Any]; d[k] = set(d[k]!, p.dropFirst(), new); return d }
            var a = v as! [Any]; let i = h as! Int; a[i] = set(a[i], p.dropFirst(), new); return a
        }
        for path in leaves(doc, []) {
            let n = get(doc, path[...]) as! NSNumber
            let moved: Any
            if CFGetTypeID(n) == CFBooleanGetTypeID() { moved = !n.boolValue }
            else if n.doubleValue == n.doubleValue.rounded() && !"\(n)".contains(".") { moved = n.intValue + 1 }
            else { moved = n.doubleValue + 0.125 }
            let trial = set(doc, path[...], moved)
            if roundTrips(trial) { doc = trial }
        }
        return doc
    }

    static func document<T: Codable>(_ value: T, perturb: Bool = true) throws -> Any {
        let (dec, enc) = Persisted.coders()
        let seed = try JSONSerialization.jsonObject(with: try enc.encode(value))
        func trips(_ doc: Any) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: doc),
                  let v = try? dec.decode(T.self, from: data), let again = try? enc.encode(v),
                  let back = try? Persisted.json(again) else { return false }
            return Persisted.diff(Persisted.canonical(doc), back) == nil
        }
        let doc = perturb ? perturbed(seed, roundTrips: trips) : seed
        precondition(trips(doc), "the fixture does not round-trip through the types")
        return doc
    }

    static func save(_ doc: Any, _ name: String, to dir: URL) throws {
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent(name))
    }

    static func write<T: Codable>(_ value: T, _ name: String, to dir: URL, perturb: Bool = true) throws {
        try save(try document(value, perturb: perturb), name, to: dir)
    }

    static let frameID = UUID(uuidString: "D13D13D1-0000-4000-8000-000000000001")!
    static let otherID = UUID(uuidString: "D13D13D1-0000-4000-8000-000000000002")!

    /// Every optional set, every sub-struct present.
    static func richEdit() -> FrameEdit {
        var e = FrameEdit()
        e.solvedEV = 0.25
        e.placementNeedsFit = true
        e.frameSeed = 7
        e.rawExposureFacts = RawExposureFacts(
            sourcePath: "/Volumes/Fixture/DSC0001.ARW", treatment: .sourceReference, decoderVersion: "RAW 9",
            baselineExposureEV: 0.5, initialExposureEV: 0.25, initialShadowBias: 0.125, appliedExposureEV: 0.375,
            appliedShadowBias: 0.0625, captureBiasEV: -0.375, captureISO: 400, captureSeconds: 0.0078125, captureFNumber: 2.5)
        e.filmOff = .init(filmEdgeActive: true, dateBackActive: false)
        e.geometry.crop = CropRect(x: 0.125, y: 0.0625, width: 0.75, height: 0.8125)
        e.geometry.quarterTurns = 1
        e.printCrop.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        e.params.autoExposureMethod = "protect_highlights"
        e.adjustments.exposure = 0.25
        return e
    }

    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let edit = richEdit()
        try write(edit, "frame-edit.json", to: dir)
        // The defaults, unmoved: what a new frame writes (no facts, no film-off, printCrop left out).
        try write(FrameEdit(), "frame-edit-default.json", to: dir, perturb: false)

        var pair = HalfFramePair(folder: "/Volumes/Fixture/Roll 7")
        var left = HalfFramePair.Hole(path: "/Volumes/Fixture/Roll 7/01.dng", frame: frameID, sourceEdit: edit,
                                      sourceGeometry: edit.geometry)
        left.meteredEV = 0.5; left.meteredFor = "fixture"; left.print = HalfFramePair.PrintTrim(edit.params)
        var right = HalfFramePair.Hole(path: "/Volumes/Fixture/Roll 7/02.dng", frame: otherID)
        right.meteredEV = -0.5; right.meteredFor = "fixture"; right.meterMethod = "balanced"
        pair.left = left; pair.right = right; pair.origin = otherID
        try write(pair, "pair.spektrapair", to: dir)

        var clip = SettingsClip(groups: [.filmAndPaper, .light], settings: edit, sourceName: "DSC0001.ARW")
        clip.sourceAspect = 1.5
        try write(clip, "settings-clip.json", to: dir)

        // Through the app's own writer, then every leaf moved as above (version/schemaVersion kept).
        let presetsURL = dir.appendingPathComponent("look-presets.json")
        try? FileManager.default.removeItem(at: presetsURL)
        _ = PresetStore(url: presetsURL).save(name: "Fixture look", clip: clip)
        let presetsDoc = try JSONSerialization.jsonObject(with: try Data(contentsOf: presetsURL))
        let (dec, enc) = Persisted.coders()
        let moved = perturbed(presetsDoc) { doc in
            guard let d = doc as? [String: Any], let p = d["presets"],
                  let data = try? JSONSerialization.data(withJSONObject: p),
                  let v = try? dec.decode([LookPreset].self, from: data), let again = try? enc.encode(v),
                  let back = try? Persisted.json(again) else { return false }
            return Persisted.diff(Persisted.canonical(p), back) == nil
        }
        try save(moved, "look-presets.json", to: dir)

        var recipes = ExportRecipe.builtIn
        for (i, size) in [ExportRecipe.Size.megapixels(24), .longEdge(4096), .shortEdge(2048)].enumerated() {
            var r = ExportRecipe()
            r.id = UUID(uuidString: "D13D13D1-0000-4000-8000-00000000010\(i)")!
            r.title = "Fixture \(i)"; r.size = size; r.format = .tiff; r.colour = ExportRecipe.Colour.allCases.last!
            if i == 1 { r.destination = .share }
            recipes.append(r)
        }
        var recipesDoc = try document(recipes) as! [Any]
        var first = recipesDoc[ExportRecipe.builtIn.count] as! [String: Any]
        first["destination"] = "Photos"   // the retired word, which no type writes now
        recipesDoc[ExportRecipe.builtIn.count] = first
        try save(recipesDoc, "export-recipes.json", to: dir)

        var table = LightTableModel()
        table.relayout(paper: .a5, portrait: false)
        _ = table.place(frameID, size: CGSize(width: 3000, height: 2000))
        _ = table.place(otherID, size: CGSize(width: 2000, height: 3000))
        table.takeOff(otherID)
        try write(StoredTable(table), "lighttable.json", to: dir, perturb: false)

        func cases<E: CaseIterable & RawRepresentable>(_: E.Type) -> [String] where E.RawValue == String {
            E.allCases.map(\.rawValue)
        }
        var destinations = cases(ExportRecipe.Destination.self)
        destinations.insert("Photos", at: 0)   // 2.1.4 had it as a case; see `retired`
        let enums: [String: [String]] = [
            "CropAspect": cases(CropAspect.self), "FilmEdgeFormat": cases(FilmEdgeFormat.self),
            "FilmEdgeView": cases(FilmEdgeView.self), "FilmEdgeGate": cases(FilmEdgeGate.self),
            "FilmEdgeHoles": cases(FilmEdgeHoles.self), "DateBackFace": cases(DateBackFace.self),
            "DateBackPlacement": cases(DateBackPlacement.self), "DateBackCorner": cases(DateBackCorner.self),
            "DateBackOrder": cases(DateBackOrder.self), "DecodeSettings.WhiteBalance": cases(DecodeSettings.WhiteBalance.self),
            "ClipboardGroup": cases(ClipboardGroup.self), "ExportRecipe.Format": cases(ExportRecipe.Format.self),
            "ExportRecipe.Colour": cases(ExportRecipe.Colour.self), "ExportRecipe.Destination": destinations,
            "LightTablePaper": cases(LightTablePaper.self), "HalfFramePair.Scope": cases(HalfFramePair.Scope.self),
            "CurveChannel": cases(CurveChannel.self), "ParametricCurve.Region": cases(ParametricCurve.Region.self),
        ]
        try save(enums, "enums.json", to: dir)
    }
}
#endif
