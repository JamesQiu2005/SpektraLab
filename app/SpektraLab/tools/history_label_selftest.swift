import Foundation

// A history step's label (Sources/Model/HistoryFields.swift, HistoryLabel.swift; PRD-F §3.4, §5):
//
//  1. **every field has a name**: a revision with every optional set and every field written (a photograph's edit, a
//     pair's piece, a double's, the members' decodes) is walked field by field — first its Swift shape against its
//     JSON, so a field the sample leaves unwritten fails here and cannot hide from step 2 — then each JSON leaf is
//     changed alone, read back, and the step's label held to the one entry of the table that covers it, or to
//     `observations` / `unnamed`, which name none. A field added later that nothing covers fails, by its path;
//  2. the names are the UI's: Layer 2's against `Layer2Control.title`; every key a label can hold is in the catalog
//     in the three languages (`Resources/Localizable.xcstrings`);
//  3. one field, its name and value; two of one group, the group; two groups, the first and "+1 more"; the text;
//  4. the cost at record time, against PRD-F §5's 1 ms.
//
//   history_label_selftest <Resources/Localizable.xcstrings>

@main struct HistoryLabelSelftest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ name: @autoclosure () -> String) {
        if ok { passed += 1 } else { failed += 1; print("FAIL: \(name())") }
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1, let catalog = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: Any],
              let strings = catalog["strings"] as? [String: Any] else {
            print("usage: history_label_selftest <Localizable.xcstrings>"); exit(2)
        }
        let full = sample()
        shape(full)
        let keys = everyField(full)
        names(strings, keys)
        labels()
        cost(full)
        print("History labels: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: a revision with everything in it

    static let left = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let right = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let bottom = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let top = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    /// Every optional set and every field that is written only once moved, moved: what the walk below can see.
    static func sample() -> DevelopRevision {
        var e = FrameEdit()
        e.solvedEV = 0.3
        e.rawExposureFacts = RawExposureFacts(sourcePath: "a.dng", treatment: .sourceReferencePlusOne, decoderVersion: "1",
                                              baselineExposureEV: 0.1, initialExposureEV: 0.2, initialShadowBias: 0.3,
                                              appliedExposureEV: 0.4, appliedShadowBias: 0.5, captureBiasEV: 0.6, captureISO: 100,
                                              captureSeconds: 0.01, captureFNumber: 2.8)
        e.printCrop.angle = 3
        // Each Geometry's fields written only once set (a perspective, the size a crop was made for).
        func full(_ g: inout Geometry) { g.vertical = 2; g.horizontal = 1; g.intendedSize = CGSize(width: 100, height: 80) }
        full(&e.geometry)
        full(&e.printCrop)
        var framing = Geometry.default
        full(&framing)
        e.filmEdge.framing = framing
        e.filmEdge.perforation = .ks65
        e.dateBack.customText = "x"
        e.filmOff = .init(filmEdgeActive: true, dateBackActive: false)
        e.hdrChoice = true
        e.hdrPeakStops = 3
        e.leak.kind = .allCases.last!
        e.lens.filter = .allCases.first
        e.lens.character = .allCases.first
        e.adjustments.vibrance = 5
        // 镜头校正's fields, written only once moved (2.4.0), on every decode of the revision.
        func lensMoved(_ d: inout DecodeSettings) {
            d.lensProfile = .init(key: "Canon/Canon RF 45mm F1.2 STM", name: "Canon RF 45mm F1.2 STM")
            d.lensDistortion = 50; d.lensLightFalloff = 20; d.lensHideDistortedAreas = false
        }
        lensMoved(&e.decode)
        e.adjustments.hsl.red.saturation = 10
        e.adjustments.channelMixer.red.green = 10
        // PRD-E's mask layers: one layer with every field written, and one part carrying every kind's fields, so the
        // walk sees each of them (a real part carries only its kind's).
        var part = MaskPart(kind: .brush,
                            linear: MaskLinear(a: MaskPoint(0.1, 0.2), b: MaskPoint(0.3, 0.4)),
                            radial: MaskRadial(centre: MaskPoint(0.5, 0.5), rx: 0.2, ry: 0.1, angle: 10, feather: 0.4),
                            brush: BrushStrokes(strokes: [BrushStroke(radius: 0.02, hardness: 0.5, flow: 0.7, erase: true,
                                                                      points: [MaskPoint(0.1, 0.1), MaskPoint(0.2, 0.3)])]),
                            found: FoundMask(what: .person, instance: 1, invert: true, width: 64, height: 48, detector: "d",
                                             revision: 1, system: "s", fingerprint: "f", decodeGeometry: "g"),
                            asset: "abc")
        part.join = .subtract
        var layer = LocalLayer(name: "Subject 1", stage: .scene, parts: [part])
        layer.opacity = 0.8; layer.feather = 0.01; layer.invert = true
        layer.madeOn = MaskMadeOn(lensCorrection: true, lensWord: "|lens=sony-embedded.1")
        layer.scene = SceneDeltas(exposure: 0.5, temperature: 10, tint: -5)
        var fin = FinishedDeltas()
        fin.exposure = 0.1; fin.contrast = 1; fin.brightness = 2; fin.highlights = 3; fin.shadows = 4; fin.blackPoint = 5
        fin.whitePoint = 6; fin.saturation = 7; fin.vibrance = 8; fin.temperature = 9; fin.tint = 10
        layer.finished = fin
        e.layers = LocalLayers(items: [layer])
        var p = HalfFramePair()
        p.origin = UUID()
        for side in HalfFramePair.Side.allCases {
            var h = HalfFramePair.Hole(path: side == .left ? "L.jpg" : "R.jpg", frame: side == .left ? left : right)
            h.meteredEV = 0.4
            h.meteredFor = "key"
            h.meterMethod = "balanced"
            h.print = HalfFramePair.PrintTrim()
            h.adjustments = .object(["exposure": .number(0)])
            h.dated = false
            full(&h.geometry)
            lensMoved(&h.decode)
            p[side] = h
        }
        var b = DoubleExposure.Exposure(frame: bottom), t = DoubleExposure.Exposure(frame: top)
        full(&b.cut)
        full(&t.cut)
        lensMoved(&b.decode); lensMoved(&t.decode)
        b.meterReadings = ["balanced": 0.2]
        t.meterReadings = ["balanced": 0.1]
        let x = DoubleExposure(bottom: b, top: t, origin: UUID())
        var d = DecodeSettings()
        d.whiteBalance = .custom
        lensMoved(&d)
        return DevelopRevision(edit: e, pair: p, sourceDecodes: [left: d], double: x)
    }

    // MARK: 1a. the Swift shape against the JSON

    /// A stored property's key where its JSON key is not its name.
    static let renamed = ["hdrChoice": "hdr", "hdrPeakStops": "hdrPeak", "lensBox": "lens"]

    static func json(_ r: DevelopRevision) -> Any {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try! JSONSerialization.jsonObject(with: try! enc.encode(r))
    }

    /// Every stored property of the sample, held to the JSON at the same place: an optional left nil, or a field the
    /// encoding leaves out (written only once moved), is a field the walk would not see.
    static func shape(_ r: DevelopRevision) {
        var missing: [String] = []
        func walk(_ value: Any, _ object: Any?, _ path: String) {
            if value is UUID || value is String || value is Bool || value is Double || value is Int || value is Date { return }
            let m = Mirror(reflecting: value)
            switch m.displayStyle {
            case .optional:
                guard let some = m.children.first?.value else { missing.append(path + " (nil)"); return }
                walk(some, object, path)
            case .collection:
                guard let first = m.children.first?.value, let array = object as? [Any], let j = array.first else {
                    if (object as? [Any])?.isEmpty != false { missing.append(path + "[] (empty)") }
                    return
                }
                walk(first, j, path + "[]")
            case .dictionary:
                guard let pair = m.children.first?.value, let dict = object as? [String: Any], let j = dict.values.first else {
                    missing.append(path + ".* (empty)"); return
                }
                walk(Mirror(reflecting: pair).children.dropFirst().first!.value, j, path + ".*")
            case .enum:
                return
            case .struct, .class:
                if String(describing: type(of: value)).hasPrefix("Boxed<") {
                    // `FrameEdit.lens`, kept on the heap: its value is the JSON object itself.
                    let storage = m.children.first!.value
                    walk(Mirror(reflecting: storage).children.first!.value, object, path)
                    return
                }
                // A struct written as an array or a number of its own (a curve's point, `[x, y]`) is a leaf here.
                guard let dict = object as? [String: Any] else { return }
                for child in m.children {
                    guard let label = child.label else { continue }
                    let key = renamed[label] ?? label
                    guard let j = dict[key] else { missing.append(path + "." + key + " (not written)"); continue }
                    walk(child.value, j, path + "." + key)
                }
            default:
                return
            }
        }
        walk(r, json(r), "")
        expect(missing.isEmpty, "the sample writes every field (set these so the walk sees them): \(missing)")
    }

    // MARK: 1b. each field alone

    enum Step: CustomStringConvertible {
        case key(String), index(Int)
        var description: String { switch self { case .key(let k): k; case .index(let i): "[\(i)]" } }
    }

    /// Each leaf of the JSON: where it is, its path as the table spells it (`[]`, `*`), its value.
    static func leaves(_ v: Any, _ at: [Step] = [], _ path: String = "", into out: inout [([Step], String, Any)]) {
        if let d = v as? [String: Any] {
            for k in d.keys.sorted() {
                let uuidLike = UUID(uuidString: k) != nil || path.hasSuffix("meterReadings")
                leaves(d[k]!, at + [.key(k)], path.isEmpty ? k : path + "." + (uuidLike ? "*" : k), into: &out)
            }
        } else if let a = v as? [Any] {
            if let first = a.first { leaves(first, at + [.index(0)], path + "[]", into: &out) }
        } else {
            out.append((at, path, v))
        }
    }

    static func setting(_ root: Any, _ at: [Step], _ value: Any) -> Any {
        guard let step = at.first else { return value }
        switch step {
        case .key(let k):
            var d = root as! [String: Any]
            d[k] = setting(d[k]!, Array(at.dropFirst()), value)
            return d
        case .index(let i):
            var a = root as! [Any]
            a[i] = setting(a[i], Array(at.dropFirst()), value)
            return a
        }
    }

    /// Strings a field takes in place of the sample's, where any other string would not read (a raw value).
    static let alternates: [String: [String]] = [
        "edit.filmEdge.format": FilmEdgeFormat.allCases.map(\.rawValue).reversed(),
        "edit.dateBack.style": DateBackFace.allCases.map(\.rawValue).reversed(),
        "edit.dateBack.placement": DateBackPlacement.allCases.map(\.rawValue).reversed(),
        "edit.filmEdge.perforation": ["none"],
        "edit.params.filmStock": ["kodak_gold_200"], "edit.params.printStock": ["kodak_portra_endura"],
        "edit.params.autoExposureMethod": ["highlights", "source", "average"],
        "edit.params.filmFrame": ["120"], "edit.params.filmSide": ["long"],
        "edit.params.sceneLatitude.norm": ["linear"], "edit.params.sceneLatitudeOther.norm": ["linear"],
        "edit.params.contrastMask.scheme": ["box"],
        "edit.decode.whiteBalance": ["Daylight"], "edit.decode.rawExposureTreatment": ["legacy.1"],
        "pair.left.decode.whiteBalance": ["Daylight"], "pair.right.decode.whiteBalance": ["Daylight"],
        "pair.left.decode.rawExposureTreatment": ["legacy.1"], "pair.right.decode.rawExposureTreatment": ["legacy.1"],
        "double.exposures[].decode.whiteBalance": ["Daylight"], "double.exposures[].decode.rawExposureTreatment": ["legacy.1"],
        "sourceDecodes.*.whiteBalance": ["Daylight"], "sourceDecodes.*.rawExposureTreatment": ["legacy.1"],
        "edit.rawExposureFacts.treatment": ["legacy"],
        "pair.left.printScope": ["frame"], "pair.right.printScope": ["frame"],
        "pair.left.exposureScope": ["film"], "pair.right.exposureScope": ["film"],
        "edit.geometry.aspect": ["original", "1:1"], "edit.printCrop.aspect": ["original", "1:1"],
        "pair.left.geometry.aspect": ["original", "1:1"], "pair.right.geometry.aspect": ["original", "1:1"],
        "double.exposures[].cut.aspect": ["original", "1:1"],
        "edit.filmEdge.mode": ["filed"], "edit.filmEdge.gate": ["square", "rounded"],
        "edit.filmEdge.holes": ["black", "clear"],
        "edit.dateBack.order": ["us", "europe", "iso"],
        "edit.dateBack.corner": ["bl", "tl", "tr"],
        "edit.leak.kind": ["edge", "streak", "off"], "edit.lens.filter": ["glimmerglass", "black_pro_mist_2"], "edit.lens.character": ["petzval", "jupiter"],
        "double.exposures[].meterMethod": ["balanced", "highlights"],
        "edit.layers.items[].stage": ["finished", "enlarger"],
        "edit.layers.items[].parts[].join": ["add", "intersect"], "edit.layers.items[].parts[].kind": ["linear", "radial"],
        "edit.layers.items[].parts[].found.what": ["subject", "people"],
        // A stroke's packed points (base64): another valid packing.
        "edit.layers.items[].parts[].brush.strokes[].points": [BrushStroke.pack([MaskPoint(0.5, 0.5)]).base64EncodedString()],
    ]

    static func covers(_ prefix: String, _ path: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + ".") || path.hasPrefix(prefix + "[]")
    }

    /// The other values a leaf is tried with, until one reads back as another revision.
    static func candidates(_ path: String, _ v: Any) -> [Any] {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return [!n.boolValue] }
            let d = n.doubleValue
            return [d + 1, d - 1, d + 0.25, d - 0.25, d * 0.5, d + 7, 2.0, 0.5]
        }
        if let s = v as? String {
            if UUID(uuidString: s) != nil { return [UUID().uuidString] }
            return (alternates[path] ?? []) + [s + "x", "x"]
        }
        return []
    }

    /// Each leaf changed alone, and the label it makes. The keys every label made holds.
    static func everyField(_ full: DevelopRevision) -> Set<String> {
        let base = full
        let object = json(base)
        var all: [([Step], String, Any)] = []
        leaves(object, into: &all)
        var keys = Set<String>()
        var uncovered: [String] = [], unvaried: [String] = [], wrong: [String] = []
        var walked = 0, named = 0
        for (at, path, value) in all {
            walked += 1
            let entries = HistoryFields.table.indices.filter { i in HistoryFields.table[i].paths.contains { covers($0, path) } }
            let observation = HistoryFields.observations.keys.contains { covers($0, path) }
            let unnamed = HistoryFields.unnamed.keys.contains { covers($0, path) }
            let buckets = (entries.isEmpty ? 0 : 1) + (observation ? 1 : 0) + (unnamed ? 1 : 0)
            guard buckets == 1, entries.count <= 1 else {
                if buckets == 0 { uncovered.append(path) }
                else { wrong.append("\(path): covered \(buckets > 1 ? "twice" : "by \(entries.count) entries")") }
                continue
            }
            // The leaf changed, read back as a revision that differs from the sample.
            var changed: DevelopRevision?
            for c in candidates(path, value) {
                guard let data = try? JSONSerialization.data(withJSONObject: setting(object, at, c)),
                      let r = try? JSONDecoder().decode(DevelopRevision.self, from: data), r != base else { continue }
                changed = r
                break
            }
            guard let after = changed else {
                // A field that cannot be told apart from the sample by the JSON alone is no step either.
                if !entries.isEmpty { unvaried.append(path) }
                continue
            }
            let fired = HistoryFields.changed(from: base, to: after).map { f in HistoryFields.table.firstIndex { $0.paths == f.paths }! }
            let label = HistoryLabels.develop(from: base, to: after)
            if let i = entries.first {
                if fired != [i] { wrong.append("\(path): moved alone, the table saw \(fired.map { HistoryFields.table[$0].paths.first! })") }
                else if label == .adjustment || label != HistoryFields.table[i].named(base, after) {
                    wrong.append("\(path): named \(label.key)")
                } else { named += 1 }
                keys.insert(label.key)
                if let k = label.valueKey { keys.insert(k) }
            } else if !fired.isEmpty || label != .adjustment {
                wrong.append("\(path): no control's, but named \(label.key) by \(fired.map { HistoryFields.table[$0].paths.first! })")
            }
        }
        print("history labels: \(walked) fields walked, \(named) named by the table")
        expect(walked > 300, "the sample has the fields of a photograph, a pair and a double (\(walked))")
        expect(uncovered.isEmpty, "every field is the table's, an observation or unnamed; these are none: \(uncovered)")
        expect(unvaried.isEmpty, "every named field can be moved alone (give it an alternate): \(unvaried)")
        expect(wrong.isEmpty, "each field moved alone is named by its own entry: \(wrong)")
        // Every path the table names is a field of the revision: a renamed field cannot leave a dead entry.
        let dead = (HistoryFields.table.flatMap(\.paths) + Array(HistoryFields.observations.keys) + Array(HistoryFields.unnamed.keys))
            .filter { p in !all.contains { covers(p, $0.1) } }
        expect(dead.isEmpty, "every path of the table is a field of a revision: \(dead)")
        return keys
    }

    // MARK: 2. the UI's words, in every language

    static func names(_ strings: [String: Any], _ fieldKeys: Set<String>) {
        // Layer 2's names are `Layer2Control.title`'s (English here: the key itself).
        for control in Layer2Control.allCases {
            var r = DevelopRevision(edit: FrameEdit(), pair: nil, sourceDecodes: [:])
            let was = r
            r.edit.adjustments[control] = control.rest + (control.range.upperBound - control.rest) / 2
            let label = HistoryLabels.develop(from: was, to: r)
            expect(HistoryLabel.shown(label.key) == control.title, "Layer 2's \(control) is named \(label.key), the slider \(control.title)")
        }
        var keys = fieldKeys
        for g in HistoryGroup.allCases { keys.insert(g.label.key) }
        for l in [HistoryLabel.adjustment, .changedElsewhere, .paste(from: ""), .paste(from: "x"), .preset("x"), .crop, .printCrop, .filmEdge,
                  .composite("x"), .lensCorrection, .agent] { keys.insert(l.key) }
        keys.formUnion(["On", "Off", "Scanned", "Printed", "%@: %@", "%@ +%@ more"])
        var lacking: [String] = []
        // Never translated (LOCALIZATION.md): a name the UI writes as it is.
        let never: Set<String> = ["HSL"]
        for k in keys.sorted() where !never.contains(k) {
            guard let entry = strings[k] as? [String: Any], let loc = entry["localizations"] as? [String: Any] else { lacking.append(k); continue }
            for lang in ["zh-Hans", "zh-Hant", "ja"] where ((loc[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] == nil {
                lacking.append("\(k) (\(lang))")
            }
        }
        expect(lacking.isEmpty, "every key a label holds is in the catalog in three languages: \(lacking)")
        expect(keys.count > 40, "the keys counted (\(keys.count))")
    }

    // MARK: 3. names, groups, more

    static func labels() {
        let a = DevelopRevision(edit: FrameEdit(), pair: nil, sourceDecodes: [:])
        var b = a
        b.edit.params.exposureCompensationEV = 0.3
        var l = HistoryLabels.develop(from: a, to: b)
        expect(l == HistoryLabel("Film Exposure", value: "+0.3") && l.text == "Film Exposure +0.3", "one field: its name and value (\(l.text))")
        b = a
        b.edit.params.filmStock = "kodak_gold_200"
        l = HistoryLabels.develop(from: a, to: b)
        expect(l.text == "Film: kodak_gold_200", "a stock after a colon (\(l.text); no catalogue in the self-test: its id)")
        b = a
        b.edit.filmEdge.active = true
        b.edit.filmEdge.fog = 0.3
        l = HistoryLabels.develop(from: a, to: b)
        expect(l == HistoryLabel("Film Edge") && l.more == nil, "two of one group: the group (\(l.text))")
        b = a
        b.edit.adjustments.exposure = 1
        b.edit.params.printBrightnessStops = 0.5
        b.edit.geometry.angle = 2
        l = HistoryLabels.develop(from: a, to: b)
        expect(l.text == "Brightness +0.5 +2 more", "three groups: the first in the column's order and +2 more (\(l.text))")
        b = a
        b.edit.params.grainActive = false
        expect(HistoryLabels.develop(from: a, to: b).text == "Grain: Off", "a switch: its word")
        b = a
        b.edit.adjustments.tint = 20
        l = HistoryLabels.develop(from: a, to: b)
        expect(l.key == "Tint {the colour shift}" && l.text == "Tint +20", "a sense is the key's, not the text's (\(l.text))")
        b = a
        b.edit.solvedEV = 1.2
        b.edit.placementNeedsFit = true
        expect(HistoryLabels.develop(from: a, to: b) == .adjustment, "observations alone name nothing")
        b = a
        b.edit.params.contrastMask.active = true
        expect(HistoryLabels.develop(from: a, to: b) == .adjustment, "a field no control sets reads Adjustment")
        expect(HistoryLabels.develop(from: a, to: a) == .adjustment, "no change, Adjustment")
        // As kept: a label written before `value` and `more` existed reads; the new fields round-trip.
        let old = try! JSONDecoder().decode(HistoryLabel.self, from: Data(#"{"key":"Paste Settings from %@","args":["DSCF1"]}"#.utf8))
        expect(old == .paste(from: "DSCF1") && old.text == "Paste Settings from DSCF1", "a part-1 label reads (\(old.text))")
        let more = HistoryLabel("Film", value: "Portra 400").and(more: 2)
        let back = try! JSONDecoder().decode(HistoryLabel.self, from: JSONEncoder().encode(more))
        expect(back == more && back.text == "Film: Portra 400 +2 more", "value and more round-trip (\(back.text))")
        let newer = try! JSONDecoder().decode(HistoryLabel.self, from: Data(#"{"key":"Masks","args":[],"layer":3}"#.utf8))
        expect(newer.text == "Masks", "a newer build's label: its key, its unknown fields ignored")
        // A pair's and a double's own controls.
        var p = sample()
        p.edit = FrameEdit()
        var q = p
        q.pair?.left?.exposureEV = 0.7
        expect(HistoryLabels.develop(from: p, to: q).key == "Film Exposure", "a pair's hole exposure is Film Exposure")
        q = p
        q.double?.exposures[0]?.placement.flipped.toggle()
        expect(HistoryLabels.develop(from: p, to: q).key == "Arrange", "a double's placement is Arrange (\(HistoryLabels.develop(from: p, to: q).key))")
        q = p
        q.sourceDecodes[left]?.temperature = 4200
        q.pair?.left?.decode.temperature = 4200
        expect(HistoryLabels.develop(from: p, to: q) == HistoryLabel("White Balance"), "a member's decode is White Balance")
    }

    // MARK: 4. the cost

    static func cost(_ full: DevelopRevision) {
        func median(_ pairs: [(DevelopRevision, DevelopRevision)]) -> Double {
            var ms: [Double] = []
            for _ in 0..<200 {
                for (a, b) in pairs {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = HistoryLabels.develop(from: a, to: b)
                    ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
            }
            ms.sort()
            return ms[ms.count / 2]
        }
        var photo = DevelopRevision(edit: FrameEdit(), pair: nil, sourceDecodes: [:])
        photo.edit.adjustments.hsl.red.saturation = 4
        var moved = photo
        moved.edit.params.exposureCompensationEV = 0.3
        var many = photo
        many.edit.params.filmStock = "kodak_gold_200"; many.edit.filmEdge.active = true; many.edit.adjustments.exposure = 1
        var composite = full
        composite.pair?.left?.exposureEV = 0.4
        let photoMs = median([(photo, moved)]), manyMs = median([(photo, many)]), pieceMs = median([(full, composite)])
        print(String(format: "history labels: cost at record time (median, -O): a photograph's one field %.4f ms, three groups %.4f ms, a pair and double's piece %.4f ms",
                     photoMs, manyMs, pieceMs))
        expect(max(photoMs, manyMs, pieceMs) < 0.2, "naming a step takes a fifth of PRD-F's 1 ms or less")
    }
}
