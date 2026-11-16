// watermark_model_selftest.swift -- 水印's model on the Mac (PRD-8, RFC-067 §3, §5, §6): the placements an edit holds,
// their coding, where the library keeps them, the geometry the overlay and the composite draw them by, Copy Settings'
// 水印 group, the history's steps, and the one rule every reader takes the marks by.
//
//     python3 tools/gate.py selftest --only watermark_model_selftest   # the checks, then their own check
//
//   - an edit with marks round-trips with its nine keys; one without has no `watermarks` key; a newer build's word
//     falls back; the row's eye is written only when off; FrameEdit grows by one pointer at most;
//   - **where the library keeps them**: 2.4.0's coder (its key list, 058f0248) drops a `watermarks` key at
//     its next write, so `library.json` never carries it: `WatermarkShelf` splits it out, an older build's rewrite of
//     `library.json` leaves `watermarks.json` as it was, and the join puts the marks back; an entry this build cannot
//     read is written back as it was; a library with no mark makes no file;
//   - paste: a corner mark on a 3:2 landscape lands in the same corner, the same fraction of the short side in, the
//     same width, on a 2:3 portrait; new placement ids; the target's marks replaced; a mark since deleted dropped; at
//     most 4; a preset carries them;
//   - 成片 ↔ 底片: the place kept on screen where both canvases cover it, clamped in outside;
//   - the nearest-corner re-anchor; snapping (centre lines, the 4 % margin, 3° of a right angle); hit-testing a turned
//     mark, its handles and its turn handle; sizing from a handle about the opposite corner; turning about the centre;
//   - **a gesture keeps the whole mark on the canvas** (half a mark could leave it), while drawing keeps the centre's
//     clamp, so an edit already written draws where it always drew;
//   - **a pair or a double draws no mark** (else it could export marks its page never showed);
//   - every reset leaves the marks; the history names add, move, size, turn, opacity, stage, eye and removal.
import CoreGraphics
import Foundation

/// One broken rule at a time, for `--self-test`: each must make a check fail.
struct Rules {
    var name = "the app's"
    var encode: (FrameEdit) -> Data? = { e in let j = JSONEncoder(); j.outputFormatting = [.sortedKeys]; return try? j.encode(e) }
    var paste: (SettingsClip, FrameEdit) -> FrameEdit = { $0.applied(to: $1, picture: PixelSize(width: 3000, height: 2000)) }
    var reanchor: (WatermarkPlacement, CGSize) -> WatermarkPlacement = { WatermarkGeometry.reanchored($0, canvas: $1) }
    var snap: (WatermarkPlacement, CGSize, Double, Double) -> (placement: WatermarkPlacement, guides: WatermarkGuides) = {
        WatermarkGeometry.snapped($0, canvas: $1, aspect: $2, tolerance: $3)
    }
    var convert: (WatermarkPlacement, WatermarkStage, CGRect, CGRect, Double) -> WatermarkPlacement = {
        WatermarkGeometry.switched($0, to: $1, full: $2, base: $3, aspect: $4)
    }
    var hit: (CGPoint, [WatermarkPlacement], UUID?, CGSize) -> WatermarkTouch? = {
        WatermarkGeometry.hit($0, in: $1, selected: $2, canvas: $3, aspect: { _ in 2 }, handleRadius: 12, rotateDistance: 40)
    }
    var reset: (FrameEdit, PageResetScope) -> FrameEdit = { $0.resetting($1) }
    var kept: (WatermarkPlacement, CGSize, Double) -> WatermarkPlacement = { WatermarkGeometry.kept($0, canvas: $1, aspect: $2) }
    var split: ([Frame], [UUID: ShelfJSON]) -> (frames: [Frame], record: WatermarkShelf.Record, made: Int) = {
        WatermarkShelf.split($0, unread: $1, id: \.id, edit: \.edit)
    }
    var finished: (FrameEdit, Bool) -> [WatermarkPlacement] = { WatermarkRules.finished($0, isComposite: $1) }
    var underGesture: (FrameEdit) -> FrameEdit = { WatermarkRules.underGesture($0, isComposite: false) }
    var fillWord: (String?) -> String? = { WatermarkFill.normalised($0) }

    static var broken: [Rules] {
        var a = Rules(name: "the edit always writes its marks' key")
        a.encode = { e in
            let j = JSONEncoder(); j.outputFormatting = [.sortedKeys]
            guard let d = try? j.encode(e), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            if o["watermarks"] == nil { o["watermarks"] = [Any]() }
            return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        }
        var b = Rules(name: "paste keeps the source's placement ids")
        b.paste = { clip, target in
            var out = clip.applied(to: target, picture: PixelSize(width: 3000, height: 2000))
            if clip.groups.contains(.watermark) { out.watermarks = Array(clip.settings.watermarks.prefix(4)) }
            return out
        }
        var c = Rules(name: "paste adds to the target's marks instead of replacing them")
        c.paste = { clip, target in
            var out = clip.applied(to: target, picture: PixelSize(width: 3000, height: 2000))
            if clip.groups.contains(.watermark) { out.watermarks = Array((target.watermarks + out.watermarks).prefix(4)) }
            return out
        }
        var d = Rules(name: "the re-anchor keeps the numbers and moves the mark")
        d.reanchor = { p, canvas in
            var q = p; q.anchor = WatermarkGeometry.nearestCorner(to: WatermarkGeometry.storedCenter(of: p, canvas: canvas), canvas: canvas); return q
        }
        var e = Rules(name: "snapping leaves the turn alone")
        e.snap = { p, canvas, aspect, tol in
            var r = WatermarkGeometry.snapped(p, canvas: canvas, aspect: aspect, tolerance: tol)
            r.placement.rotation = p.rotation; r.guides.remove(.rightAngle); return r
        }
        var f = Rules(name: "a stage's switch keeps the numbers, not the place")
        f.convert = { p, stage, _, _, _ in var q = p; q.stage = stage; return q }
        var g = Rules(name: "hit-testing by the unturned box")
        g.hit = { point, placements, _, canvas in
            for p in placements.reversed() {
                let fr = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: 2)
                let box = CGRect(x: fr.center.x - fr.size.width / 2, y: fr.center.y - fr.size.height / 2,
                                 width: fr.size.width, height: fr.size.height)
                if box.contains(point) { return WatermarkTouch(placement: p.id, part: .body) }
            }
            return nil
        }
        var h = Rules(name: "the effects reset takes the marks")
        h.reset = { e, scope in var out = e.resetting(scope); if scope == .effects { out.watermarks = [] }; return out }
        var i = Rules(name: "a gesture keeps only the centre on the canvas (the drawing clamp)")
        i.kept = { p, canvas, aspect in WatermarkGeometry.clamped(p, canvas: canvas, aspect: aspect) }
        var j = Rules(name: "the library writes the marks inside the edit")
        j.split = { frames, _ in (frames, WatermarkShelf.Record(), 0) }
        var k = Rules(name: "a pair or a double draws its edit's marks")
        k.finished = { e, _ in WatermarkRules.finished(e, isComposite: false) }
        var l = Rules(name: "a mark's eye is not read")
        l.finished = { e, composite in WatermarkRules.placements(e, isComposite: composite).map { var p = $0; p.stage = .full; return p } }
        var m = Rules(name: "under a gesture the page develops the edit as it is (the old place stays in the picture)")
        m.underGesture = { $0 }
        var n = Rules(name: "under a gesture every mark is taken out, 成片 ones too")
        n.underGesture = { e in var out = e; out.watermarks = []; return out }
        var o = Rules(name: "a fill is kept as written, whatever it says")
        o.fillWord = { $0 }
        var q = Rules(name: "原样 writes a fill key")
        q.encode = { e in
            let j = JSONEncoder(); j.outputFormatting = [.sortedKeys]
            guard let d = try? j.encode(e), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  var list = o["watermarks"] as? [[String: Any]] else { return try? j.encode(e) }
            for i in list.indices where list[i]["fill"] == nil { list[i]["fill"] = "" }
            o["watermarks"] = list
            return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        }
        return [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, q]
    }
}

/// A library frame as the shelf sees one: an id and an edit.
struct Frame: Equatable {
    var id: UUID
    var edit: FrameEdit
}

struct Checker {
    var passed = 0
    var failed = 0
    var quiet = false
    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else {
            failed += 1
            if !quiet { print("  FAILED: \(what())") }
        }
    }
}

func close(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }
func close(_ a: CGPoint, _ b: CGPoint, _ eps: Double = 1e-6) -> Bool { close(Double(a.x), Double(b.x), eps) && close(Double(a.y), Double(b.y), eps) }

let signature = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
let logo = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
let gone = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!

func corner(_ c: DateBackCorner, dx: Double = 0.1, dy: Double = 0.08, size: Double = 0.3, mark: UUID = signature) -> WatermarkPlacement {
    WatermarkPlacement(mark: mark, anchor: c, dx: dx, dy: dy, size: size)
}

/// 2.4.0's `FrameEdit.CodingKeys` (058f0248): the keys its coder reads and the only ones it writes back.
let keysOf240: Set<String> = ["schemaVersion", "decoder", "decode", "params", "geometry", "filmEdge", "dateBack", "solvedEV",
                              "placementNeedsFit", "frameSeed", "adjustments", "rawExposureFacts", "printCrop", "filmOff", "hdr",
                              "hdrPeak", "leak", "lens", "layers"]

/// An edit's JSON as 2.4.0's coder writes it back after reading it: its keys only.
func through240(_ data: Data) -> [String: Any]? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return o.filter { keysOf240.contains($0.key) }
}

// MARK: - coding

func codingChecks(_ c: inout Checker, _ r: Rules) {
    var e = FrameEdit()
    e.watermarks = [corner(.br), WatermarkPlacement(mark: logo, stage: .base, anchor: .tl, dx: 0.2, dy: 0.15, size: 0.12,
                                                     rotation: 0.6, opacity: 0.4)]
    let data = r.encode(e)
    let back = data.flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
    c.expect(back == e, "an edit with two marks round-trips")
    let json = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(json.contains("\"watermarks\":[") && json.contains("\"stage\":\"base\"") && json.contains("\"anchor\":\"tl\""),
             "the marks are written under `watermarks`, with their stage and corner")
    // The nine keys, every one written (a synthesised coder's shape), and no tenth while the eye is on.
    if let o = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
       let first = (o["watermarks"] as? [[String: Any]])?.first {
        c.expect(Set(first.keys) == ["id", "mark", "stage", "anchor", "dx", "dy", "size", "rotation", "opacity"],
                 "a placement is the nine keys (\(first.keys.sorted()))")
    } else { c.expect(false, "the placement is an object") }
    var hidden = e; hidden.watermarks[0].on = false
    let hiddenJSON = r.encode(hidden).map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(hiddenJSON.contains("\"on\":false") && (r.encode(hidden).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) })?.watermarks[0].on == false,
             "the row's eye is written only when off, and read back")

    let plain = r.encode(FrameEdit()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(!plain.contains("watermarks"), "an edit with no mark has no `watermarks` key")
    let read = (r.encode(FrameEdit())).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
    c.expect(read?.watermarks == [], "an edit without the key reads with no marks")
    c.expect(FrameEdit.currentSchema == 5, "no schema bump (5)")
    // A 2.4.0 edit (every key it writes, the layers and the leak among them) is the same JSON with or without the field.
    var rich = FrameEdit(); rich.leak.kind = .band; rich.printCrop.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    rich.layers = LocalLayers(items: [LocalLayer(name: "主体 1", stage: .finished)])
    if let bytes = r.encode(rich), let again = try? JSONDecoder().decode(FrameEdit.self, from: bytes) {
        c.expect(r.encode(again) == bytes && !String(decoding: bytes, as: UTF8.self).contains("watermarks"),
                 "an edit without marks re-encodes byte for byte, with no `watermarks` key")
        c.expect(Set((try? JSONSerialization.jsonObject(with: bytes) as? [String: Any])?.keys.map { $0 } ?? []).isSubset(of: keysOf240),
                 "and writes only keys 2.4.0 knows")
    } else { c.expect(false, "a 2.4.0-shaped edit round-trips") }

    // A newer build's word for a stage or a corner falls back; a broken list never fails the edit.
    if var o = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
        var list = o["watermarks"] as! [[String: Any]]
        list[0]["stage"] = "hologram"; list[0]["anchor"] = "middle"
        o["watermarks"] = list
        let newer = (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
        c.expect(newer?.watermarks.first?.stage == .full && newer?.watermarks.first?.anchor == .br,
                 "an unknown stage or corner falls back to 成片, bottom right")
        o["watermarks"] = "not a list"
        let broken = (try? JSONSerialization.data(withJSONObject: o)).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
        c.expect(broken != nil && broken?.watermarks == [], "a broken `watermarks` value reads as none, and the edit opens")
    }
    // An edit written without `on` (the nine keys alone) reads with the mark shown.
    let nineKeys = #"{"id":"00000000-0000-0000-0000-0000000000B1","mark":"00000000-0000-0000-0000-00000000A001","stage":"full","anchor":"tr","dx":0.1,"dy":0.1,"size":0.2,"rotation":0,"opacity":1}"#
    let fromNine = try? JSONDecoder().decode(WatermarkPlacement.self, from: Data(nineKeys.utf8))
    c.expect(fromNine?.on == true && fromNine?.anchor == .tr, "a placement without `on` reads, shown")

    c.expect(MemoryLayout<[WatermarkPlacement]>.size == 8, "the marks are one pointer in the edit")

    // 填充 (2026-11-16): 原样 writes nothing; a colour is written as "#RRGGBB" and read back; a word this build
    // cannot read as a colour reads as 原样.
    if let o = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
       let list = o["watermarks"] as? [[String: Any]] {
        c.expect(list.allSatisfy { $0["fill"] == nil }, "原样: no `fill` key")
    }
    var tinted = e; tinted.watermarks[0].fill = r.fillWord("#d0342c")
    let tintedData = r.encode(tinted)
    let tintedJSON = tintedData.map { String(decoding: $0, as: UTF8.self) } ?? ""
    c.expect(tintedJSON.contains("\"fill\":\"#D0342C\""), "a fill is written as \"#RRGGBB\", upper case")
    c.expect(tintedData.flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }?.watermarks[0].fill == "#D0342C", "and read back")
    for bad in ["red", "#12345", "#GG0000", "", "#1234567"] {
        c.expect(r.fillWord(bad) == nil, "a fill of \"\(bad)\" is no fill")
    }
    let odd = #"{"id":"00000000-0000-0000-0000-0000000000B2","mark":"00000000-0000-0000-0000-00000000A001","dx":0.1,"dy":0.1,"size":0.2,"fill":"chartreuse"}"#
    let oddRead = try? JSONDecoder().decode(WatermarkPlacement.self, from: Data(odd.utf8))
    c.expect(oddRead != nil && oddRead?.fill == nil, "a fill this build cannot read opens as 原样")
    c.expect(WatermarkFill.rgb("#2F6FDE").map { [$0.r, $0.g, $0.b] } == [0x2F, 0x6F, 0xDE], "a fill's components")
    c.expect(WatermarkFill.word(r: 1, g: 0.5, b: 0) == "#FF8000", "a colour's word")
}

/// Under a gesture the page develops the edit without its 底片 marks (`WatermarkRules.underGesture`): the 成片 ones and
/// every other field stay; with the film off (a 底片 mark works as 成片) or none, the edit as it is.
func gestureChecks(_ c: inout Checker, _ r: Rules) {
    var e = FrameEdit()
    let full = corner(.br), base = WatermarkPlacement(mark: logo, stage: .base, anchor: .tl, dx: 0.2, dy: 0.2, size: 0.1)
    var hiddenBase = base; hiddenBase.id = UUID(); hiddenBase.on = false
    e.watermarks = [full, base, hiddenBase]
    let clean = r.underGesture(e)
    c.expect(clean.watermarks == [full, hiddenBase], "under a gesture: the 底片 mark out, the 成片 one and the hidden one kept")
    c.expect(WatermarkRules.base(clean, isComposite: false).isEmpty, "and nothing laid in the source")
    var other = clean; other.watermarks = e.watermarks
    c.expect(other == e, "nothing else of the edit moves")
    var only = FrameEdit(); only.watermarks = [full]
    c.expect(r.underGesture(only) == only, "a 成片 mark's gesture develops nothing new")
    var off = e; off.filmOff = FrameEdit.FilmOff(filmEdgeActive: false, dateBackActive: false)
    c.expect(!off.appliesFilm && r.underGesture(off) == off, "with the film off a 底片 mark is drawn as 成片: the edit as it is")
}

// MARK: - where the library keeps them

func shelfChecks(_ c: inout Checker, _ r: Rules) {
    var marked = FrameEdit(); marked.watermarks = [corner(.br), corner(.tl, mark: logo)]
    let a = Frame(id: UUID(), edit: marked), b = Frame(id: UUID(), edit: FrameEdit())
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]

    // 2.4.0's coder drops the key: a mark kept inside the edit would not survive the older build.
    let inEdit = (try? enc.encode(marked)).flatMap(through240)
    c.expect(inEdit != nil && inEdit?["watermarks"] == nil, "2.4.0's coder drops `watermarks` at its next write (why the shelf)")

    let (bare, record, made) = r.split([a, b], [:])
    let libraryJSON = bare.compactMap { try? enc.encode($0.edit) }.map { String(decoding: $0, as: UTF8.self) }
    c.expect(libraryJSON.count == 2 && libraryJSON.allSatisfy { !$0.contains("watermarks") }, "library.json's edits carry no marks")
    c.expect(made == 1 && record.frames.count == 1 && record.frames[a.id.uuidString] != nil, "watermarks.json holds the marked frame's, by its id")
    c.expect(WatermarkShelf.writes(entries: record.frames.count, made: made, fileExists: false, unreadable: false), "and is written")
    let file = WatermarkShelf.encode(record)
    // An older build rewrites library.json through its own coder, and never opens watermarks.json.
    let olderLibrary = bare.map { f -> Frame in
        var g = f
        if let d = try? enc.encode(f.edit), let o = through240(d), let back = try? JSONSerialization.data(withJSONObject: o),
           let e = try? JSONDecoder().decode(FrameEdit.self, from: back) { g.edit = e }
        return g
    }
    let joined = WatermarkShelf.joined(olderLibrary, WatermarkShelf.read(file), id: \.id, edit: \.edit)
    c.expect(joined.first { $0.id == a.id }?.edit.watermarks == marked.watermarks && joined.first { $0.id == b.id }?.edit.watermarks == [],
             "after an older build's rewrite of library.json, the marks come back from watermarks.json")

    // A library with no mark makes no file.
    let (_, none, noneMade) = WatermarkShelf.split([b], unread: [:], id: \.id, edit: \.edit)
    c.expect(!WatermarkShelf.writes(entries: none.frames.count, made: noneMade, fileExists: false, unreadable: false),
             "a library with no mark and no watermarks.json makes none")
    c.expect(WatermarkShelf.writes(entries: 0, made: 0, fileExists: true, unreadable: false), "one whose marks all went writes the empty record")
    c.expect(!WatermarkShelf.writes(entries: 1, made: 0, fileExists: true, unreadable: true), "a file that did not read is not written over")

    // An entry this build does not read is kept as it was, while its frame is there.
    let later = #"{"version":1,"frames":{"\#(b.id.uuidString)":[{"id":"not-a-uuid"}],"\#(UUID().uuidString)":[{"id":"x"}]}}"#
    let readLater = WatermarkShelf.read(Data(later.utf8))
    c.expect(readLater.unread.count == 2 && readLater.marks.isEmpty, "a later build's entries are read as unread")
    let (_, rewritten, _) = WatermarkShelf.split([a, b], unread: readLater.unread, id: \.id, edit: \.edit)
    c.expect(rewritten.frames.count == 2 && rewritten.frames[b.id.uuidString] != nil, "an unread entry of a frame still here is written back; a gone frame's is dropped")
    c.expect(WatermarkShelf.read(Data("{ no".utf8)).unreadable, "a file that does not read at all is said so")
    c.expect(WatermarkShelf.fileName == "watermarks.json", "the record's name")
}

// MARK: - paste

func pasteChecks(_ c: inout Checker, _ r: Rules) {
    let landscape = CGSize(width: 3000, height: 2000), portrait = CGSize(width: 2000, height: 3000)
    for anchor in DateBackCorner.allCases {
        var source = FrameEdit(); source.watermarks = [corner(anchor, dx: 0.1, dy: 0.08, size: 0.3)]
        let clip = SettingsClip(groups: [.watermark], settings: source, sourceName: "")
        let pasted = r.paste(clip, FrameEdit())
        guard let p = pasted.watermarks.first else { c.expect(false, "a paste lays the mark (\(anchor))"); continue }
        let a = WatermarkGeometry.frame(of: source.watermarks[0], canvas: landscape, aspect: 2)
        let b = WatermarkGeometry.frame(of: p, canvas: portrait, aspect: 2)
        let s = 2000.0
        func inset(_ f: WatermarkFrame, _ canvas: CGSize) -> (Double, Double) {
            (anchor.isRight ? Double(canvas.width - f.center.x) / s : Double(f.center.x) / s,
             anchor.isBottom ? Double(canvas.height - f.center.y) / s : Double(f.center.y) / s)
        }
        let (ax, ay) = inset(a, landscape), (bx, by) = inset(b, portrait)
        c.expect(WatermarkGeometry.nearestCorner(to: b.center, canvas: portrait) == anchor && close(ax, bx) && close(ay, by)
                 && close(ax, 0.1) && close(ay, 0.08),
                 "3:2 → 2:3: the \(anchor.rawValue) mark stays in its corner, 0.1 · 0.08 of the short side in (\(bx), \(by))")
        c.expect(close(Double(a.size.width) / s, 0.3) && close(Double(b.size.width) / s, 0.3) && close(Double(b.size.height) / s, 0.15),
                 "3:2 → 2:3: the \(anchor.rawValue) mark is 0.3 of the short side wide on both")
    }

    var source = FrameEdit()
    source.watermarks = [corner(.br), corner(.tl, mark: logo)]
    var target = FrameEdit()
    target.watermarks = [corner(.bl, mark: logo), corner(.tr), corner(.tl)]
    let clip = SettingsClip(groups: [.watermark], settings: source, sourceName: "")
    let pasted = r.paste(clip, target)
    c.expect(pasted.watermarks.count == 2 && zip(pasted.watermarks, source.watermarks).allSatisfy { $0.samePlace(as: $1) },
             "a paste replaces the target's three marks with the source's two, in order")
    c.expect(Set(pasted.watermarks.map(\.id)).isDisjoint(with: source.watermarks.map(\.id)) && Set(pasted.watermarks.map(\.id)).count == 2,
             "each pasted mark is a new placement (new id)")
    let without = SettingsClip(groups: [.light], settings: source, sourceName: "")
    c.expect(r.paste(without, target).watermarks == target.watermarks, "a paste without 水印 leaves the target's marks")
    c.expect(r.paste(SettingsClip(groups: [.watermark], settings: FrameEdit(), sourceName: ""), target).watermarks.isEmpty,
             "pasting a photograph with no mark clears the target's")
    var six = FrameEdit(); six.watermarks = (0..<6).map { _ in corner(.br) }
    c.expect(r.paste(SettingsClip(groups: [.watermark], settings: six, sourceName: ""), FrameEdit()).watermarks.count == 4,
             "at most 4 marks land")

    // A mark since deleted: dropped, and counted for the note.
    var mixed = FrameEdit(); mixed.watermarks = [corner(.br), corner(.tl, mark: gone), corner(.tr, mark: logo)]
    let names = WatermarkNames(names: [signature: "签名", logo: "Logo"])
    WatermarkNames.library = { names }
    defer { WatermarkNames.library = { .unknown } }
    let held = SettingsClip(groups: [.watermark, .hdr], settings: mixed, sourceName: "")
    c.expect(r.paste(held, FrameEdit()).watermarks.map(\.mark) == [signature, logo] && held.droppedWatermarks == 1,
             "a mark whose PNG is gone is left out of the paste, and counted for the note")
    c.expect(WatermarkNames.unknown.exists(gone) && !names.exists(gone) && names.name(signature) == "签名",
             "the names: unknown takes every mark as there; a known library knows its own")
    // A preset keeps them (transferable is a paste onto a new edit).
    let preset = SettingsClip(groups: [.watermark], settings: source, sourceName: "x").transferable
    c.expect(preset.settings.watermarks.count == 2, "a preset carries the marks (W3)")
    // The clip's own JSON keeps them (a preset file, the clipboard).
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let clipBack = (try? enc.encode(clip)).flatMap { try? JSONDecoder().decode(SettingsClip.self, from: $0) }
    c.expect(clipBack?.settings.watermarks == source.watermarks, "a clip's JSON carries its marks")
    // The sheet's row.
    let offered = ClipboardGroup.offered
    if let h = offered.firstIndex(of: .hdr), let w = offered.firstIndex(of: .watermark) {
        c.expect(w == h + 1, "水印 is offered right after HDR")
    } else { c.expect(false, "水印 is offered (and HDR)") }
    c.expect(!ClipboardGroup.defaultSelection.contains(.watermark), "水印 is unticked when the sheet opens")
    var one = FrameEdit(); one.watermarks = [corner(.br)]
    c.expect(ClipboardGroup.watermark.summary(of: one) == "签名 · Full image · Bottom right",
             "the row says the first mark's name, stage and corner (\(ClipboardGroup.watermark.summary(of: one)))")
    c.expect(ClipboardGroup.watermark.summary(of: FrameEdit()) == "No watermark", "no mark: No watermark")
}

// MARK: - the cap and a new mark

func listChecks(_ c: inout Checker) {
    let canvas = CGSize(width: 4000, height: 3000)
    let p = WatermarkGeometry.newPlacement(mark: signature, canvas: canvas, aspect: 2)
    let f = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: 2)
    c.expect(close(f.center, CGPoint(x: 2000, y: 1500)) && close(Double(f.size.width), 900) && close(Double(f.size.height), 450)
             && p.anchor == .br && p.stage == .full && p.rotation == 0 && p.opacity == 1 && p.on,
             "a new mark is centred, 0.3 of the short side wide, upright, opaque, on 成片 (N10)")
    var list: [WatermarkPlacement] = []
    for _ in 0..<4 { var q = p; q.id = UUID(); list = WatermarkGeometry.adding(q, to: list) ?? list }
    c.expect(list.count == 4 && !WatermarkGeometry.canAdd(to: list) && WatermarkGeometry.adding(p, to: list) == nil,
             "at most 4 marks on a photograph (W2)")
    let up = WatermarkGeometry.reordered(list, moving: list[1].id, by: 1)
    c.expect(up.map(\.id) == [list[0].id, list[2].id, list[1].id, list[3].id], "a mark moved up the z-order swaps with the one above")
    c.expect(WatermarkGeometry.reordered(list, moving: list[3].id, by: 1) == list, "the top mark moved up stays")
}

// MARK: - geometry

func geometryChecks(_ c: inout Checker, _ r: Rules) {
    let canvas = CGSize(width: 3000, height: 2000), s = 2000.0
    var p = corner(.br, dx: 0.2, dy: 0.15, size: 0.3); p.rotation = .pi / 6
    let f = WatermarkGeometry.frame(of: p, canvas: canvas, aspect: 2)
    c.expect(close(f.center, CGPoint(x: 3000 - 400, y: 2000 - 300)), "centre = corner − (dx, dy) · short side")
    c.expect(close(CGPoint(x: 0.5, y: 0.5).applying(f.transform), f.center), "the transform puts the mark's middle on the centre")
    let px = CGSize(width: 1200, height: 600)
    c.expect(close(CGPoint(x: 1200, y: 0).applying(f.transform(markPixels: px)), f.corner(.tr)),
             "the mark's pixels' top-right lands on the frame's top-right corner")
    let d1 = hypot(Double(f.corner(.tr).x - f.corner(.tl).x), Double(f.corner(.tr).y - f.corner(.tl).y))
    c.expect(close(d1, 0.3 * s, 1e-6) && f.corner(.tr).y > f.corner(.tl).y, "the turn is clockwise on a y-down canvas, the size kept")

    // Drawing: the centre's clamp (a centre off the canvas is drawn on its edge).
    let off = WatermarkGeometry.frame(of: corner(.br, dx: -0.5, dy: 2, size: 0.3), canvas: canvas, aspect: 2)
    c.expect(close(off.center, CGPoint(x: 3000, y: 0)), "drawing holds a centre off the canvas on its edge")
    let huge = WatermarkGeometry.frame(of: corner(.br, size: 9), canvas: canvas, aspect: 2)
    c.expect(close(Double(huge.size.width), 3000), "a mark is never wider than the long side")

    // A gesture: the whole turned box on the canvas.
    let half = WatermarkGeometry.placement(corner(.br, size: 0.3), centeredAt: CGPoint(x: 2950, y: 1000), canvas: canvas)
    let held = r.kept(half, canvas, 2)
    let hf = WatermarkGeometry.frame(of: held, canvas: canvas, aspect: 2)
    c.expect(close(Double(hf.bounds.maxX), 3000, 1e-6) && close(Double(hf.center.y), 1000),
             "a mark dragged half off the right edge is held with its right edge on the canvas's (\(hf.bounds.maxX))")
    var turnedNear = WatermarkGeometry.placement(corner(.br, size: 0.3), centeredAt: CGPoint(x: 100, y: 100), canvas: canvas)
    turnedNear.rotation = .pi / 4
    let tb = WatermarkGeometry.frame(of: r.kept(turnedNear, canvas, 2), canvas: canvas, aspect: 2).bounds
    c.expect(tb.minX >= -1e-6 && tb.minY >= -1e-6, "a turned mark's box is held inside too (\(tb.minX), \(tb.minY))")
    let wide = WatermarkGeometry.placement(corner(.br, size: 1.5), centeredAt: CGPoint(x: 2900, y: 1000), canvas: canvas)
    let wf = WatermarkGeometry.frame(of: r.kept(wide, canvas, 1), canvas: canvas, aspect: 1)
    c.expect(close(Double(wf.center.x), 1500, 1e-6), "a mark taller than the canvas is centred on the axis it cannot fit")
    let inside = WatermarkGeometry.placement(corner(.br, size: 0.2), centeredAt: CGPoint(x: 1500, y: 1000), canvas: canvas)
    c.expect(r.kept(inside, canvas, 2) == inside, "a mark inside is left where it is")
    let settled = WatermarkGeometry.settled(half, canvas: canvas, aspect: 2)
    c.expect(settled.anchor == .br && close(Double(WatermarkGeometry.frame(of: settled, canvas: canvas, aspect: 2).bounds.maxX), 3000, 1e-6),
             "a gesture's end is held, then measured from its nearest corner")

    // Re-anchor: the mark stays where it is; the numbers are from the nearest corner.
    let farFromBR = corner(.br, dx: 1.3, dy: 0.85, size: 0.2)
    let before = WatermarkGeometry.storedCenter(of: farFromBR, canvas: canvas)
    let re = r.reanchor(farFromBR, canvas)
    c.expect(re.anchor == .tl, "a mark near the top-left is measured from the top-left")
    c.expect(close(WatermarkGeometry.storedCenter(of: re, canvas: canvas), before), "the re-anchor keeps the mark where it is")
    c.expect(close(re.dx, 0.2) && close(re.dy, 0.15), "its numbers become 0.2 · 0.15 from that corner")

    // Snapping: the centre lines, the margin, a right angle.
    let tol = 24.0
    var near = WatermarkGeometry.placement(corner(.br, size: 0.2), centeredAt: CGPoint(x: 1510, y: 700), canvas: canvas)
    near.rotation = 2 * .pi / 180
    let snapped = r.snap(near, canvas, 2, tol)
    let sc = WatermarkGeometry.frame(of: snapped.placement, canvas: canvas, aspect: 2).center
    c.expect(close(Double(sc.x), 1500) && snapped.guides.contains(.centreX), "10 px off the vertical centre line snaps onto it")
    c.expect(close(Double(sc.y), 700) && !snapped.guides.contains(.centreY), "300 px off the horizontal one does not")
    c.expect(snapped.placement.rotation == 0 && snapped.guides.contains(.rightAngle), "2° snaps to upright")
    var turned = near; turned.rotation = 88 * .pi / 180
    c.expect(close(r.snap(turned, canvas, 2, tol).placement.rotation, .pi / 2), "88° snaps to 90°")
    var tilted = near; tilted.rotation = 10 * .pi / 180
    let t = r.snap(tilted, canvas, 2, tol)
    c.expect(close(t.placement.rotation, tilted.rotation) && !t.guides.contains(.rightAngle), "10° stays 10°")
    let m = 0.04 * s, w = 0.2 * s
    let edge = WatermarkGeometry.placement(corner(.br, size: 0.2), centeredAt: CGPoint(x: 3000 - m - w / 2 + 10, y: 400), canvas: canvas)
    let es = r.snap(edge, canvas, 2, tol)
    let ef = WatermarkGeometry.frame(of: es.placement, canvas: canvas, aspect: 2)
    c.expect(close(Double(ef.bounds.maxX), 3000 - m) && es.guides.contains(.marginRight), "the right edge snaps to the 4 % margin")

    // Hit-testing a mark turned 45°.
    var diamond = WatermarkGeometry.placement(corner(.br, size: 0.3), centeredAt: CGPoint(x: 1500, y: 1000), canvas: canvas)
    diamond.rotation = .pi / 4
    let df = WatermarkGeometry.frame(of: diamond, canvas: canvas, aspect: 2)
    let boxCorner = CGPoint(x: df.bounds.minX + 20, y: df.bounds.minY + 20)
    c.expect(r.hit(boxCorner, [diamond], nil, canvas) == nil, "a point in the turned mark's box but outside the mark misses")
    c.expect(r.hit(df.center, [diamond], nil, canvas) == WatermarkTouch(placement: diamond.id, part: .body), "its middle hits it")
    let tr2 = df.corner(.tr)
    c.expect(r.hit(CGPoint(x: tr2.x + 5, y: tr2.y), [diamond], diamond.id, canvas) == WatermarkTouch(placement: diamond.id, part: .handle(.tr)),
             "the picked mark's corner is its handle")
    let knob = WatermarkGeometry.rotateHandle(of: df, distance: 40)
    c.expect(r.hit(knob, [diamond], diamond.id, canvas) == WatermarkTouch(placement: diamond.id, part: .rotate),
             "the picked mark's turn handle, above its top edge along its own up")
    var top = diamond; top.id = UUID(); top.rotation = 0
    c.expect(r.hit(df.center, [diamond, top], nil, canvas)?.placement == top.id, "where two overlap, the top one (last) is hit")
    var off2 = top; off2.on = false
    c.expect(r.hit(df.center, [diamond, off2], nil, canvas)?.placement == diamond.id, "a mark switched off is not hit")

    // Sizing from a handle: the opposite corner stays, the aspect is kept.
    var sized = WatermarkGeometry.placement(corner(.br, size: 0.2), centeredAt: CGPoint(x: 1500, y: 1000), canvas: canvas)
    sized.rotation = .pi / 6
    let sf = WatermarkGeometry.frame(of: sized, canvas: canvas, aspect: 2)
    let tl = sf.corner(.tl), br = sf.corner(.br)
    let grown = WatermarkGeometry.resized(sized, handle: .br, to: CGPoint(x: tl.x + 2 * (br.x - tl.x), y: tl.y + 2 * (br.y - tl.y)),
                                          canvas: canvas, aspect: 2)
    let gf = WatermarkGeometry.frame(of: grown, canvas: canvas, aspect: 2)
    c.expect(close(grown.size, 0.4) && close(gf.corner(.tl), tl, 1e-6) && close(Double(gf.size.width / gf.size.height), 2),
             "dragging the bottom-right handle to twice the diagonal doubles the mark about its top-left corner")
    // Turning about the centre: a quarter sweep is a quarter turn.
    let quarter = WatermarkGeometry.turn(from: 0.1, center: CGPoint(x: 100, y: 100), start: CGPoint(x: 200, y: 100), point: CGPoint(x: 100, y: 200))
    c.expect(close(quarter, 0.1 + .pi / 2, 1e-9), "a pointer swept a quarter round the centre turns the mark a quarter, clockwise")

    // 成片 ↔ 底片.
    let full = CGRect(x: 0, y: 0, width: 1200, height: 900), base = CGRect(x: 100, y: 80, width: 1000, height: 740)
    let inner = WatermarkGeometry.placement(corner(.br, size: 0.2), centeredAt: CGPoint(x: 900, y: 600), canvas: full.size)
    let onBase = r.convert(inner, .base, full, base, 2)
    let bf = WatermarkGeometry.frame(of: onBase, canvas: base.size, aspect: 2)
    let ff = WatermarkGeometry.frame(of: inner, canvas: full.size, aspect: 2)
    c.expect(onBase.stage == .base && close(CGPoint(x: bf.center.x + base.minX, y: bf.center.y + base.minY), ff.center)
             && close(Double(bf.size.width), Double(ff.size.width)),
             "成片 → 底片: a mark where both cover it keeps its place and width on screen")
}

// MARK: - the one rule, the resets, the history

func ruleChecks(_ c: inout Checker, _ r: Rules) {
    var e = FrameEdit()
    var off = corner(.tl, mark: logo); off.on = false
    var clear = corner(.tr); clear.opacity = 0
    var base = corner(.bl); base.stage = .base
    e.watermarks = [corner(.br), off, clear, base]
    let single = r.finished(e, false)
    c.expect(single.count == 1 && single.allSatisfy { $0.stage == .full } && single.map(\.id) == [e.watermarks[0].id],
             "a photograph draws its 成片 marks that are on and not clear over the finished picture; its 底片 one is not there")
    c.expect(WatermarkRules.base(e, isComposite: false).map(\.id) == [base.id] && WatermarkRules.base(e, isComposite: true).isEmpty,
             "its 底片 mark is laid into the source (the film on); a pair's or a double's never")
    c.expect(r.finished(e, true).isEmpty && WatermarkRules.placements(e, isComposite: true).isEmpty,
             "a pair or a double draws none (W5), panel and exporter alike")
    c.expect(WatermarkRules.refusal(isComposite: true) != nil && WatermarkRules.refusal(isComposite: false) == nil, "and the panel says why")
    var filmOff = e; filmOff.filmOff = FrameEdit.FilmOff(filmEdgeActive: false, dateBackActive: false)
    c.expect(r.finished(filmOff, false).count == 2, "with the film off, 底片 is 成片 (N9)")
    var marked = e
    marked.params.effects.grain = 2; marked.leak.kind = .band
    for scope in PageResetScope.allCases {
        c.expect(r.reset(marked, scope).watermarks == marked.watermarks, "\(scope.rawValue)'s reset leaves the marks")
    }
    var whole = marked; whole.resetDevelop()
    c.expect(whole.watermarks == marked.watermarks, "the page's reset (resetDevelop) leaves the marks")
}

func historyChecks(_ c: inout Checker) {
    WatermarkNames.library = { WatermarkNames(names: [signature: "签名"]) }
    defer { WatermarkNames.library = { .unknown } }
    func rev(_ marks: [WatermarkPlacement]) -> DevelopRevision {
        var e = FrameEdit(); e.watermarks = marks
        return DevelopRevision(edit: e, pair: nil, sourceDecodes: [:])
    }
    func key(_ a: [WatermarkPlacement], _ b: [WatermarkPlacement]) -> String {
        let l = HistoryFields.label(from: rev(a), to: rev(b))
        return l.key + (l.args.isEmpty ? "" : " " + l.args.joined(separator: ","))
    }
    let p = corner(.br)
    var moved = p; moved.dx = 0.2
    var sized = p; sized.size = 0.4
    var turned = p; turned.rotation = 0.5
    var faded = p; faded.opacity = 0.4
    var staged = p; staged.stage = .base
    var hidden = p; hidden.on = false
    let cases: [(String, [WatermarkPlacement], [WatermarkPlacement], String)] = [
        ("add", [], [p], "Add %@ 签名"),
        ("remove", [p], [], "Delete %@ 签名"),
        ("move", [p], [moved], "%@ · Move 签名"),
        ("size", [p], [sized], "%@ · Size 签名"),
        ("turn", [p], [turned], "%@ · Rotation 签名"),
        ("opacity", [p], [faded], "%@ · Opacity 签名"),
        ("stage", [p], [staged], "%@ · Stage 签名"),
        ("eye", [p], [hidden], "%@ · Visible 签名"),
    ]
    for (what, a, b, want) in cases {
        let got = key(a, b)
        c.expect(got == want, "the history names a watermark's \(what): \(got)")
    }
}

@main
enum Main {
    @MainActor static func main() {
        func run(_ r: Rules, quiet: Bool) -> Checker {
            var c = Checker(quiet: quiet)
            codingChecks(&c, r)
            shelfChecks(&c, r)
            pasteChecks(&c, r)
            listChecks(&c)
            geometryChecks(&c, r)
            ruleChecks(&c, r)
            gestureChecks(&c, r)
            historyChecks(&c)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            for rule in Rules.broken {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("watermark model self-test: \(caught) of \(Rules.broken.count) broken rules caught")
            exit(caught == Rules.broken.count ? 0 : 1)
        }
        print("  FrameEdit: \(MemoryLayout<FrameEdit>.size) B; WatermarkPlacement \(MemoryLayout<WatermarkPlacement>.size) B, held by an array of \(MemoryLayout<[WatermarkPlacement]>.size) B")
        let c = run(Rules(), quiet: false)
        print("watermark model checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
