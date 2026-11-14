//  layers_keep_check.swift — PRD-E's keeping (RFC-052 §8.1, §10.8 in part): an edit with mask layers survives a
//  2.3.x build that opens the library and writes it back. This tree's side of `tools/layers_keep_check.sh`.
//
//      layers_keep_check write  <dir>   a library of three frames, two with layers, as this build writes it
//                                       (`LayerShelf`: library.json without them, layers.json beside it), and the
//                                       red case beside it: library-inline.json, the same frames with the layers
//                                       left inside each edit
//      layers_keep_check verify <dir>   after 2.3.1's coder has written both back (`layers_keep_old`): this build reads
//                                       the library and finds every layer as written and 2.3.1's own change kept;
//                                       the inline copy has lost them (the check can fail)
//
//  The frames are a stand-in for `StoredFrame` (an id, a name, the edit): the split and the join are `LayerShelf`'s,
//  the functions `LibraryPersistence` calls, and what 2.3.x would drop is the edit's `FrameEdit` coder's — the
//  frame's other keys are untouched by this work.
//
//  Also, the model's own checks: an edit with no layer encodes to the bytes it did before the field existed (and
//  `persisted_check` holds those against 2.1.4's files); a record round-trips; a stroke packs to 16 bits and back
//  within half a step; a later build's entry this build cannot read is kept as it was and written back.

import Foundation

struct Item: Codable, Equatable {
    var id: UUID
    var fileName: String
    var edit: FrameEdit
}

struct Library: Codable { var frames: [Item] }

@main struct LayersKeepCheck {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("ok    \(what)") } else { failed += 1; print("FAIL  \(what)") }
    }

    static let ids = [UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
                      UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!]

    /// Every kind of part, both stages.
    static func sampleLayers() -> LocalLayers {
        let stroke = BrushStroke(radius: 0.03, hardness: 0.8, flow: 0.6, points: (0..<40).map { MaskPoint(0.2 + Double($0) * 0.01, 0.5) })
        var scene = LocalLayer(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!, name: "Sky", stage: .scene, parts: [
            .linear(MaskLinear(a: MaskPoint(0.5, 0.0), b: MaskPoint(0.5, 0.45))),
            .radial(MaskRadial(centre: MaskPoint(0.6, 0.3), rx: 0.1, ry: 0.05, angle: 15, feather: 0.6), join: .subtract),
        ])
        scene.scene = SceneDeltas(exposure: -1.5, temperature: 20, tint: -10)
        scene.feather = 0.004
        var finished = LocalLayer(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, name: "Brush 1", stage: .finished, parts: [
            .brush(BrushStrokes(strokes: [stroke])),
            .found(FoundMask(what: .subject, invert: true, width: 512, height: 341, detector: "GenerateForegroundInstanceMaskRequest",
                             revision: 1, system: "26.0", fingerprint: "f00d", decodeGeometry: "lens=0"), asset: "cafe", join: .intersect),
        ])
        finished.finished?.contrast = 12
        finished.opacity = 0.7
        // Fixed ids, so the verify step's sample is the write step's.
        for (n, i) in scene.parts.indices.enumerated() { scene.parts[i].id = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000\(n)")! }
        for (n, i) in finished.parts.indices.enumerated() { finished.parts[i].id = UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000\(n)")! }
        return LocalLayers(items: [scene, finished])
    }

    static func library() -> (Library, layers: [UUID: LocalLayers]) {
        var frames = ids.enumerated().map { i, id in Item(id: id, fileName: "F\(i).ARW", edit: FrameEdit()) }
        frames[0].edit.layers = sampleLayers()
        var other = sampleLayers()
        other.items.removeLast()
        frames[2].edit.layers = other
        let layers = Dictionary(uniqueKeysWithValues: frames.compactMap { f in f.edit.layers.map { (f.id, $0) } })
        return (Library(frames: frames), layers)
    }

    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }

    static func write(_ dir: URL) throws {
        let (lib, _) = library()
        // This build's write: the layers out of every edit, into their own record, first.
        let (bare, record, made) = LayerShelf.split(lib.frames, unread: [:], id: \.id, edit: \.edit)
        let layersURL = LayerShelf.url(beside: dir.appendingPathComponent("library.json"))
        expect(made == 2 && LayerShelf.writes(entries: record.frames.count, made: made, fileExists: false, unreadable: false),
               "two frames' layers go to layers.json (\(made))")
        try LayerShelf.encode(record)!.write(to: layersURL)
        try encoder().encode(Library(frames: bare)).write(to: dir.appendingPathComponent("library.json"))
        // The red case: the same library with the layers left inside each edit.
        try encoder().encode(lib).write(to: dir.appendingPathComponent("library-inline.json"))
        let text = try String(contentsOf: dir.appendingPathComponent("library.json"), encoding: .utf8)
        expect(!text.contains("\"layers\""), "library.json holds no layers key")
        let inline = try String(contentsOf: dir.appendingPathComponent("library-inline.json"), encoding: .utf8)
        expect(inline.contains("\"layers\""), "the inline copy does hold them (what the red case starts from)")
    }

    static func verify(_ dir: URL) throws {
        let (_, expected) = library()
        let libURL = dir.appendingPathComponent("library.json")
        let read = LayerShelf.read(try? Data(contentsOf: LayerShelf.url(beside: libURL)))
        let lib = try JSONDecoder().decode(Library.self, from: Data(contentsOf: libURL))
        let joined = LayerShelf.joined(lib.frames, read, id: \.id, edit: \.edit)
        expect(joined.count == 3, "the library still has its three frames")
        for f in joined {
            expect(f.edit.layers == expected[f.id], "\(f.fileName): its layers after 2.3.1 wrote the library back (\(f.edit.layers?.items.count ?? 0))")
            expect(abs(f.edit.params.exposureCompensationEV - 0.5) < 1e-12, "\(f.fileName): 2.3.1's own change kept (Film Exposure \(f.edit.params.exposureCompensationEV))")
        }
        let inline = try JSONDecoder().decode(Library.self, from: Data(contentsOf: dir.appendingPathComponent("library-inline.json")))
        let lost = inline.frames.filter { expected[$0.id] != nil && $0.edit.layers == nil }.count
        expect(lost == 2, "red: layers kept inside the edit are dropped by 2.3.1's coder (\(lost) of 2 lost)")
        print("measured: layers.json \(try Data(contentsOf: LayerShelf.url(beside: libURL)).count) bytes for 2 frames, 3 layers, a 40-point stroke")
    }

    /// The model's own: neutral bytes, a round trip, packing, a later build's entry.
    static func model() throws {
        let plain = try encoder().encode(FrameEdit())
        var empty = FrameEdit()
        empty.layers = LocalLayers()
        expect(try encoder().encode(empty) == plain, "an edit with an empty layer set is the same bytes as one with none")
        var with = FrameEdit()
        with.layers = sampleLayers()
        let back = try JSONDecoder().decode(FrameEdit.self, from: encoder().encode(with))
        expect(back == with, "an edit with layers round-trips through FrameEdit")
        let pts = (0..<1000).map { MaskPoint(Double($0) / 999, 1 - Double($0) / 999 * 0.37) }
        let unpacked = BrushStroke.unpack(BrushStroke.pack(pts))
        let err = zip(pts, unpacked).map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }.max() ?? 1
        expect(unpacked.count == 1000 && err <= 0.5 / 65535 + 1e-12, String(format: "a stroke packs to 16 bits: max error %.2e (half a step %.2e)", err, 0.5 / 65535))
        // A later build's entry: a stage this build has no case for. Kept as it was, written back.
        let later = Data(#"{"version":1,"frames":{"AAAAAAAA-0000-0000-0000-000000000001":{"version":2,"items":[{"id":"BBBBBBBB-0000-0000-0000-000000000009","stage":"darkroom","parts":[]}]},"AAAAAAAA-0000-0000-0000-000000000002":{"version":1,"items":[]}}}"#.utf8)
        let r = LayerShelf.read(later)
        expect(r.unread.count == 1 && r.layers.isEmpty && !r.unreadable, "a later build's entry is kept unread (\(r.unread.count)), the empty one dropped")
        let frames = ids.map { Item(id: $0, fileName: "x", edit: FrameEdit()) }
        let (_, record, made) = LayerShelf.split(frames, unread: r.unread, id: \.id, edit: \.edit)
        let rewritten = String(data: LayerShelf.encode(record)!, encoding: .utf8)!
        expect(made == 0 && rewritten.contains("darkroom") && LayerShelf.writes(entries: record.frames.count, made: made, fileExists: true, unreadable: false),
               "it is written back as it was")
        let r2 = LayerShelf.read(Data("not json".utf8))
        expect(r2.unreadable && !LayerShelf.writes(entries: 0, made: 0, fileExists: true, unreadable: true), "a file that does not read is not written over")
        expect(!LayerShelf.writes(entries: 0, made: 0, fileExists: false, unreadable: false), "a library with no layers makes no layers.json")
        // A frame removed: its entry goes at the next write.
        let (_, rec2, _) = LayerShelf.split(Array(frames.dropFirst()), unread: r.unread, id: \.id, edit: \.edit)
        expect(rec2.frames.isEmpty, "an unread entry whose frame was removed is dropped")
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: layers_keep_check write|verify <dir> | --bytes <edit.json|-> <out>"); exit(2) }
        let dir = URL(fileURLWithPath: args[2])
        if args[1] == "--bytes" {
            // The same as `layers_keep_old --bytes`, by this tree's coder.
            let src = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
            let edit = try src.map { try JSONDecoder().decode(FrameEdit.self, from: Data(contentsOf: $0)) } ?? FrameEdit()
            try encoder().encode(edit).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            exit(0)
        }
        if args[1] == "write" { try model(); try write(dir) } else { try verify(dir) }
        print("layers keep (\(args[1])): \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
