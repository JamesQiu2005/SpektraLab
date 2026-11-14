//  double_selftest.swift — the double exposure's model, its arithmetic and its file, checked on this Mac.
//
//      tools/selftest.sh                # with the other checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  `Model/DoubleExposure.swift` is RFC-047 §2's model (the owner approved PRD 2 and RFC-047..050 on
//  2026-11-07). What it could get wrong quietly, with no engine and no page to show it (RFC-047 §9):
//
//  - **the file** — a double exposure written reads back the same; one written before a field existed
//    (any key but an exposure's `frame` missing) opens with that field's default, and an exposure written
//    without its decode reads as the old decode, as a pair's hole does;
//  - **exposure and balance, one truth** (RFC-047 §4) — made: each −1 EV, Balance 50 %, the frame's light
//    1; Balance moved holds the total; an exposure's own slider moves it alone, and with it the total and
//    Balance; Film Exposure on the whole holds Balance; Balance held to 10…90 %;
//  - **who is on top** (RFC-047 §3, PRD 2 §8.2) — a swap carries Balance with the position, in one
//    mutation; the placements go with their exposures where the shape holds, and are laid again where
//    the new bottom is another shape;
//  - **the frame it began with** — cannot be replaced or removed, only swapped (PRD 2 D7);
//  - **the frame's size** (RFC-048 §5) — the bottom's, but no larger than the top fills unenlarged;
//  - the window, the meter's keeping, the whole's look, the layers' names;
//  - **a photograph removed** (RFC-047 §5) — its layer left empty whatever the origin says, the origin
//    let go, the other layer and its placement where they were; a double exposure with no exposure left
//    is removed, one with one left is not, and a photograph the library no longer has counts as gone;
//  - **the guide before develop** (RFC-047 §5.1) — each exposure's gain is its own stops alone (Balance as
//    set, readings and Film Exposure left out), a flipped exposure's window is the frame's mirrored, an
//    empty layer is left out, the guide's key moves with what it shows and never with a decode; and the
//    pixels: two flat sRGB pictures added in linear light by `DoubleGuide.added` (Core Image on this Mac)
//    read back against the arithmetic, and a flip read back as a flip;
//  - **the older-build guard** (RFC-047 §2, `LibraryShelf`) — a double exposure is split off to
//    `doubles.json`; what a build from before reads of `library.json` (its own `StoredLibrary` shape, as a
//    `JSONDecoder` reads it: an unknown key passed over) holds no double exposure, so it shows none rather
//    than a broken photograph; what it writes back leaves `doubles.json` as it was, and this build joins
//    the two again, each item once.
//
//  The older build's reading is a struct here of that build's shape, with the item reduced to the keys
//  that matter (an id, a name, a pair): `StoredFrame` and `LibraryFrame` need UIKit and the app's import
//  service, which a Mac check does not compile. What is held is the split, the join and what a
//  `JSONDecoder` does with the files they make — not the app's own `LibraryPersistence`.
//
//  Not here: the composition (RFC-048, lane B), the darkroom (RFC-050, lane D). Compiled with the model,
//  the models it stands on, `Model/HalfFramePair.swift`, `Engine/HostCut.swift` and
//  `Engine/PiecePlacer.swift` (the guide's laying), `Services/LibraryShelf.swift` and
//  `Services/DoubleGuideLight.swift`. No engine, no UIKit, no page.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a rule
//  broken on purpose, one at a time, and requires each run to fail.

import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

// `Stock.color` is the app's (`Theme.swift`, which is not compiled here). Nothing below looks at a colour.
extension Color {
    init(hexString: String) { self = .gray }
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
    mutating func near(_ a: Double?, _ b: Double, _ accuracy: Double, _ what: @autoclosure () -> String) {
        guard let a else { expect(false, "\(what()): nil, not \(b)"); return }
        expect(abs(a - b) <= accuracy, "\(what()): \(a), not \(b) ± \(accuracy)")
    }
}

typealias Double2 = DoubleExposure
typealias Position = DoubleExposure.Position

/// The rules the checks hold, each as the app has it. `broken` breaks one at a time.
struct Rules {
    var name = "the app's own"
    var decoded: (Data) -> Double2? = { Double2.decoded($0) }
    var balance: (Double2) -> Double? = { $0.balance }
    var setBalance: (inout Double2, Double) -> Void = { $0.setBalance($1) }
    var exposure: (inout Double2, Double, Position) -> Void = { $0.exposure($1, of: $2) }
    var stops: (Double2, Position, FilmParams) -> Double? = { $0.stops($1, look: $2) }
    var swap: (inout Double2, Double2.Framed) -> Void = { $0.swap(framed: $1) }
    var mayChange: (Double2, Position) -> Bool = { $0.mayChange($1) }
    var fill: (inout Double2, Position, Double2.Exposure?) -> Bool = { $0.fill($1, with: $2) }
    var frameSize: (Double2, Double2.Framed, Int?) -> PixelSize? = { $0.frameSize($1, longEdge: $2) }
    var window: (Double2.Placement, CGSize, Double) -> CGRect = { Double2.window($0, framed: $1, aspect: $2) }
    var keep: (inout Double2, Double, Position, String) -> Bool = { $0.keep(reading: $1, of: $2, for: $3) }
    var look: (FrameEdit, StockCatalog) -> FrameEdit = { Double2.look(from: $0, catalog: $1) }
    var empty: (inout Double2, Set<UUID>, Double2.Framed, Double2.Framed) -> Bool = { $0.empty(holding: $1, before: $2, after: $3) }
    var leftEmpty: (Double2, Set<UUID>, (UUID) -> Bool) -> Bool = { $0.isLeftEmpty(removing: $1, has: $2) }
    var guideLayers: (Double2, Double2.Framed) -> [Double2.GuideLayer] = { $0.guideLayers($1) }
    var guideKey: (Double2) -> String = { $0.guideKey }
    var developed: (Double2) -> Double2 = { $0.developed }
    var added: (Double2, Double2.Framed, [Position: CIImage], CGSize) -> CIImage? = {
        DoubleGuide.added($0, framed: $1, pictures: $2, size: $3)
    }
    var split: ([Item]) -> (library: [Item], doubles: [Item]) = { LibraryShelf.split($0, isDouble: { $0.double != nil }) }
    var joined: ([Item], [Item]) -> [Item] = { LibraryShelf.joined($0, $1, id: \.id) }
    var read: (Data?) -> LibraryShelf.Read<Item> = { LibraryShelf.read($0, as: Item.self, with: JSONDecoder()) }
    var writes: (Int, Int, Bool, Bool) -> Bool = { LibraryShelf.writes(doubles: $0, unread: $1, fileExists: $2, unreadable: $3) }

    static var broken: [Rules] {
        var out: [Rules] = []
        func rule(_ name: String, _ change: (inout Rules) -> Void) {
            var r = Rules()
            r.name = name
            change(&r)
            out.append(r)
        }
        rule("a file written before a field existed refused") { r in
            // As a decoder with no defaults would: every key of the struct and of each exposure required.
            r.decoded = { data in
                guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      ["schemaVersion", "folder", "exposures"].allSatisfy({ o[$0] != nil }),
                      let list = o["exposures"] as? [Any],
                      list.allSatisfy({ ($0 as? [String: Any]).map { e in
                          ["frame", "decode", "cut", "placement", "exposureEV", "autoExposure", "meterMethod", "meterReadings"].allSatisfy { e[$0] != nil }
                      } ?? ($0 is NSNull) }) else { return nil }
                return Double2.decoded(data)
            }
        }
        rule("a missing exposure EV read as 0, not as made") { r in
            r.decoded = { data in
                guard var d = Double2.decoded(data) else { return nil }
                let o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let list = (o["exposures"] as? [Any]) ?? []
                for (i, e) in list.enumerated() where (e as? [String: Any])?["exposureEV"] == nil && i < d.exposures.count {
                    d.exposures[i]?.exposureEV = 0
                }
                return d
            }
        }
        rule("Balance read as the bottom's share") { r in r.balance = { $0.balance.map { 1 - $0 } } }
        rule("Balance read with the readings in") { r in
            r.balance = { d in
                guard let t = d[.top], let b = d[.bottom] else { return nil }
                return Double2.share(top: t.exposureEV + (d.reading(.top) ?? 0), bottom: b.exposureEV + (d.reading(.bottom) ?? 0))
            }
        }
        rule("Balance moved without holding the frame's light") { r in
            r.setBalance = { d, s in
                let share = s.clamped(to: Double2.balanceRange)
                d[.top]?.exposureEV = log2(share)
                d[.bottom]?.exposureEV = log2(1 - share)
            }
        }
        rule("Balance not held to 10…90 %") { r in
            r.setBalance = { d, s in
                guard let total = d.totalGain else { return }
                d[.top]?.exposureEV = log2(s * total)
                d[.bottom]?.exposureEV = log2((1 - s) * total)
            }
        }
        rule("an exposure's own slider moving both") { r in
            r.exposure = { d, ev, p in
                let moved = ev - (d[p]?.exposureEV ?? 0)
                d.exposure(ev, of: p)
                d.exposure((d[p.other]?.exposureEV ?? 0) + moved, of: p.other)
            }
        }
        rule("an exposure's own stops past the pair's range") { r in r.exposure = { d, ev, p in d[p]?.exposureEV = ev } }
        rule("Film Exposure on the top alone") { r in
            r.stops = { d, p, look in
                var own = look
                if p == .bottom { own.exposureCompensationEV = 0 }
                return d.stops(p, look: own)
            }
        }
        rule("a reading used whatever it was read for") { r in
            r.stops = { d, p, look in
                guard let e = d[p] else { return nil }
                let plus = e.exposureEV + look.exposureCompensationEV
                guard e.autoExposure, look.autoExposure else { return plus }
                return e.meterReadings.values.first.map { $0 + plus }
            }
        }
        rule("a swap keeping each picture's own light") { r in
            r.swap = { d, _ in let b = d[.bottom]; d[.bottom] = d[.top]; d[.top] = b }
        }
        rule("a swap that does not swap") { r in
            r.swap = { d, _ in
                let b = d[.bottom]?.exposureEV, t = d[.top]?.exposureEV
                if let b, let t { d[.bottom]?.exposureEV = t; d[.top]?.exposureEV = b }
            }
        }
        rule("a swap to another shape leaving the placements") { r in
            r.swap = { d, _ in d.swap(framed: [:]) }
        }
        rule("a swap to the same shape laying both again") { r in
            r.swap = { d, framed in
                d.swap(framed: framed)
                d[.bottom]?.placement = Double2.Placement()
            }
        }
        rule("the frame it began with replaceable") { r in r.mayChange = { _, _ in true }; r.fill = { d, p, e in d[p] = e; return true } }
        rule("the frame it began with held in both layers") { r in
            r.mayChange = { d, p in d.origin == nil || (d[p]?.frame != d.origin && d[p.other]?.frame != d.origin) }
        }
        rule("the frame as large as the bottom") { r in
            r.frameSize = { d, framed, _ in
                guard let b = framed[.bottom] else { return nil }
                return PixelSize(width: Int(b.width), height: Int(b.height))
            }
        }
        rule("the frame resized by a zoom") { r in
            r.frameSize = { d, framed, long in
                var unzoomed = d
                for p in Position.allCases { unzoomed[p]?.placement.base.scale = 1 }
                guard let size = unzoomed.frameSize(framed, longEdge: long) else { return nil }
                let zoom = d[.top]?.placement.base.scale ?? 1
                return PixelSize(width: Int(Double(size.width) / zoom), height: Int(Double(size.height) / zoom))
            }
        }
        rule("the frame not capped for a smaller job") { r in r.frameSize = { d, framed, _ in d.frameSize(framed) } }
        rule("the top's quarter turn ignored in the frame's size") { r in
            r.frameSize = { d, framed, long in
                var level = d
                for p in Position.allCases { level[p]?.placement.base.quarterTurns = 0 }
                return level.frameSize(framed, longEdge: long)
            }
        }
        rule("a flip moving the window") { r in
            r.window = { p, framed, aspect in
                let w = Double2.window(p, framed: framed, aspect: aspect)
                return p.flipped ? CGRect(x: 1 - w.maxX, y: w.minY, width: w.width, height: w.height) : w
            }
        }
        rule("a window at the hole's 3:4, not the frame's") { r in
            r.window = { p, framed, _ in Double2.window(p, framed: framed, aspect: 0.75) }
        }
        rule("a reading kept for another key") { r in
            r.keep = { d, ev, p, key in d[p]?.meterReadings[key] = ev; return true }
        }
        rule("the bottom's cut kept on the whole") { r in
            r.look = { first, catalog in
                var e = Double2.look(from: first, catalog: catalog)
                e.geometry = first.geometry
                return e
            }
        }
        rule("the whole metered by the engine") { r in
            r.look = { first, catalog in
                var e = Double2.look(from: first, catalog: catalog)
                e.params.autoExposure = true
                return e
            }
        }
        rule("the film copied, not loaded") { r in
            r.look = { first, catalog in
                var e = Double2.look(from: first, catalog: catalog)
                e.params.scanFilm = first.params.scanFilm
                return e
            }
        }
        rule("the film edge dropped, as on a pair") { r in
            r.look = { first, catalog in
                var e = Double2.look(from: first, catalog: catalog)
                e.filmEdge = FilmEdgeSettings()
                return e
            }
        }
        // A photograph removed (RFC-047 §5).
        rule("a removal that the origin refuses") { r in
            r.empty = { d, removed, before, after in
                var any = false
                for p in Position.allCases where d[p].map({ removed.contains($0.frame) }) == true {
                    if d.fill(p, with: nil, before: before, after: after) { any = true }
                }
                return any
            }
        }
        rule("the origin kept after its photograph went") { r in
            r.empty = { d, removed, before, after in
                let origin = d.origin
                let done = d.empty(holding: removed, before: before, after: after)
                d.origin = origin
                return done
            }
        }
        rule("the other layer's placement laid again") { r in
            r.empty = { d, removed, before, after in
                let done = d.empty(holding: removed, before: before, after: after)
                for p in Position.allCases where d[p] != nil { d[p]?.placement = Double2.Placement() }
                return done
            }
        }
        rule("a double exposure with one exposure left removed") { r in
            r.leftEmpty = { d, removed, _ in Position.allCases.contains { d[$0].map { removed.contains($0.frame) } ?? true } }
        }
        rule("a photograph gone from the library counted as there") { r in
            r.leftEmpty = { d, removed, _ in d.isLeftEmpty(removing: removed) { _ in true } }
        }
        // The guide (RFC-047 §5.1).
        rule("the guide's gains with the readings in") { r in
            r.guideLayers = { d, framed in
                d.guideLayers(framed).map { l in
                    var l = l
                    l.gain = Double2.gain((d[l.position]?.exposureEV ?? 0) + (d.reading(l.position) ?? 0))
                    return l
                }
            }
        }
        rule("the guide at full light for each") { r in
            r.guideLayers = { d, framed in d.guideLayers(framed).map { l in var l = l; l.gain = 1; return l } }
        }
        rule("a flipped exposure's window not mirrored") { r in
            r.guideLayers = { d, framed in
                d.guideLayers(framed).map { l in
                    var l = l
                    if l.flipped { l.window = Double2.mirrored(l.window) }
                    return l
                }
            }
        }
        rule("the guide's key with the decode in") { r in
            r.guideKey = { d in d.guideKey + Position.allCases.map { d[$0].map { "\($0.decode)" } ?? "-" }.joined() }
        }
        rule("the guide's key without the stops") { r in
            r.guideKey = { d in
                var level = d
                for p in Position.allCases { level[p]?.exposureEV = 0 }
                return level.guideKey
            }
        }
        rule("a kept reading counted as a change of the develop") { r in
            r.developed = { $0 }
        }
        rule("the develop's piece without the exposures' placements") { r in
            r.developed = { d in
                var level = d.developed
                for p in Position.allCases { level[p]?.placement = Double2.Placement() }
                return level
            }
        }
        rule("the guide added by CIAdditionCompositing") { r in
            r.added = { DoubleGuide.added($0, framed: $1, pictures: $2, size: $3, addition: "CIAdditionCompositing") }
        }
        rule("the guide laid over, not added") { r in
            r.added = { DoubleGuide.added($0, framed: $1, pictures: $2, size: $3, addition: "CISourceOverCompositing") }
        }
        rule("the guide's flip ignored") { r in
            r.added = { d, framed, pictures, size in
                var level = d
                for p in Position.allCases { level[p]?.placement.flipped = false }
                return DoubleGuide.added(level, framed: framed, pictures: pictures, size: size)
            }
        }
        // The older-build guard (RFC-047 §2).
        rule("the double exposures written to library.json") { r in r.split = { ($0, []) } }
        rule("a double exposure read twice") { r in r.joined = { $0 + $1 } }
        rule("doubles.json not read back") { r in r.joined = { library, _ in library } }
        // A doubles.json this build cannot read, never written over (the 2026-11-07 review).
        rule("doubles.json read whole, as before the review") { r in
            r.read = { data in
                guard let data else { return LibraryShelf.Read() }
                let whole = try? JSONDecoder().decode(StoredDoubles<Item>.self, from: data)
                return LibraryShelf.Read(frames: whole?.frames ?? [])
            }
        }
        rule("an item this build does not read dropped, not kept") { r in
            r.read = { data in var read = LibraryShelf.read(data, as: Item.self, with: JSONDecoder()); read.unread = []; return read }
        }
        rule("a doubles.json that did not read written over") { r in
            r.writes = { doubles, unread, exists, _ in doubles + unread > 0 || exists }
        }
        return out
    }
}

// MARK: - helpers

let A = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
let B = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
let C = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

/// A double exposure as `makeDouble` makes one: two photographs, each in the middle at −1 EV.
func made(_ bottom: UUID = A, _ top: UUID = B, origin: UUID? = nil) -> Double2 {
    var edit = FrameEdit()
    edit.params.autoExposureMethod = "balanced"
    return Double2(bottom: Double2.Exposure(frame: bottom, sourceEdit: edit, sourceGeometry: .default),
                   top: Double2.Exposure(frame: top, sourceEdit: edit, sourceGeometry: .default), origin: origin)
}

func ev(_ d: Double2, _ p: Position) -> Double { d[p]?.exposureEV ?? .nan }

// MARK: - the file

func fileChecks(_ c: inout Checker, _ rules: Rules) {
    // A round trip of everything a double exposure carries.
    var d = made(origin: A)
    d.folder = "here"
    d[.bottom]?.placement = Double2.Placement(base: { var p = HalfFramePair.Placement(); p.scale = 1.5; p.x = -0.25; p.y = 0.5; p.quarterTurns = 3; return p }(), flipped: true)
    d[.bottom]?.decode.whiteBalance = .tungsten
    d[.bottom]?.decode.lensCorrection = true
    d[.bottom]?.cut.crop = CropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
    d[.bottom]?.cut.quarterTurns = 1
    d[.top]?.exposureEV = 0.75
    d[.top]?.autoExposure = false
    d[.top]?.meterMethod = "protect_highlights"
    d[.top]?.meterReadings = ["k": 1.25, "j": -0.5]
    guard let data = try? d.encoded() else { c.expect(false, "a double exposure encodes"); return }
    c.expect(rules.decoded(data) == d, "a double exposure written reads back the same")
    let text = String(decoding: data, as: UTF8.self)
    c.expect(text.contains("\"exposures\"") && text.contains("\"flipped\" : true") && text.contains("\"base\""),
             "its file names its exposures, each placement as the pair's and its flip")
    // An empty layer is a null in the list, and reads back empty.
    var holed = made()
    holed[.top] = nil
    if let data = try? holed.encoded() {
        let back = rules.decoded(data)
        c.expect(back == holed && back?[.top] == nil && back?.exposures.count == 2, "a layer whose photograph was removed reads back empty")
    }

    // **A file from before a field existed**: every key but an exposure's frame may be missing.
    let bare = Data("{\"exposures\":[{\"frame\":\"\(A.uuidString)\"}]}".utf8)
    let read = rules.decoded(bare)
    c.expect(read != nil, "a file with only an exposure's frame opens")
    if let read {
        c.expect(read.schemaVersion == 1 && read.folder == "" && read.origin == nil, "with schema 1, no folder and no origin")
        c.expect(read.exposures.count == Double2.maxExposures && read[.top] == nil, "its list padded to two layers, the missing one empty")
        let e = read[.bottom]
        c.expect(e?.frame == A, "the exposure is its photograph's")
        c.expect(e?.exposureEV == Double2.madeEV, "an exposure written without its stops is as made, −1 EV (RFC-047 §4)")
        c.expect(e?.autoExposure == true && e?.meterMethod == "legacy" && e?.meterReadings == [:],
                 "metered alone, with the engine's own intent and nothing read")
        c.expect(e?.placement == Double2.Placement() && e?.cut == .default, "in the middle, uncut")
        c.expect(e?.decode.rawExposureTreatment == .legacy, "and an exposure written without its decode reads as the old decode, as a pair's hole")
    }
    c.expect(rules.decoded(Data("{}".utf8)).map { $0.exposures == [nil, nil] && $0.isEmpty } == true, "an empty file opens as an empty double exposure")
    let partial = Data("{\"exposures\":[{\"frame\":\"\(A.uuidString)\",\"placement\":{\"base\":{\"scale\":2}}},null],\"origin\":\"\(A.uuidString)\"}".utf8)
    let p = rules.decoded(partial)
    c.expect(p?[.bottom]?.placement.base.scale == 2 && p?[.bottom]?.placement.base.x == 0 && p?[.bottom]?.placement.flipped == false,
             "a placement with only its scale: centred, unflipped")
    c.expect(p?.origin == A, "the origin read")
    c.expect(rules.decoded(Data("{\"exposures\":[{\"exposureEV\":1}]}".utf8)) == nil, "an exposure with no photograph is not read")

    // The file itself, beside the pair's.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("double-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = Double2.newURL(in: dir)
    c.expect(first.lastPathComponent == "Double Exposure 1.spektradouble", "a new file is \"Double Exposure 1.spektradouble\", not \(first.lastPathComponent)")
    try? d.save(to: first)
    c.expect(Double2.load(first) == d && Double2.isDouble(first), "saved and loaded the same")
    c.expect(Double2.newURL(in: dir).lastPathComponent == "Double Exposure 2.spektradouble", "the next is number 2")
    c.expect(Double2.doubles(in: dir).count == 1 && !Double2.isDouble(dir.appendingPathComponent("x.spektrapair")), "a pair's file is not one")
}

// MARK: - exposure and balance (RFC-047 §4)

func balanceChecks(_ c: inout Checker, _ rules: Rules) {
    var d = made()
    c.expect(ev(d, .bottom) == -1 && ev(d, .top) == -1, "made: each exposure −1 EV, log2(1/2)")
    c.near(rules.balance(d), 0.5, 1e-12, "made: Balance 50 %")
    c.near(d.totalGain, 1, 1e-12, "made: the frame's light one normal exposure")

    // Moving Balance holds the total.
    rules.setBalance(&d, 0.7)
    c.near(rules.balance(d), 0.7, 1e-9, "Balance moved to 70 %")
    c.near(d.totalGain, 1, 1e-9, "and the frame's light held")
    c.near(ev(d, .top), log2(0.7), 1e-9, "the top at log2(0.7)")
    c.near(ev(d, .bottom), log2(0.3), 1e-9, "the bottom at log2(0.3)")
    // From a total that is not 1.
    var other = made()
    other[.top]?.exposureEV = 0.5
    other[.bottom]?.exposureEV = -0.3
    let total = pow(2, 0.5) + pow(2, -0.3)
    rules.setBalance(&other, 0.3)
    c.near(rules.balance(other), 0.3, 1e-9, "Balance to 30 % from 0.5 / −0.3 EV")
    c.near(other.totalGain, total, 1e-9, "the total 2^0.5 + 2^−0.3 held")
    // Clamped.
    var hi = made(), lo = made()
    rules.setBalance(&hi, 0.97)
    rules.setBalance(&lo, 0.02)
    c.near(rules.balance(hi), 0.9, 1e-9, "Balance held to 90 %")
    c.near(rules.balance(lo), 0.1, 1e-9, "Balance held to 10 %")
    c.near(hi.totalGain, 1, 1e-9, "the total held at the clamp")
    // One layer: nothing to balance.
    var one = made()
    one[.top] = nil
    c.expect(rules.balance(one) == nil, "with one exposure there is no Balance")
    rules.setBalance(&one, 0.8)
    c.expect(ev(one, .bottom) == -1, "and moving it does nothing")

    // An exposure's own slider moves it alone.
    var own = made()
    rules.exposure(&own, 0, .top)
    c.expect(ev(own, .top) == 0 && ev(own, .bottom) == -1, "the top's own slider to 0 EV moves the top alone")
    c.near(rules.balance(own), 2.0 / 3.0, 1e-12, "and Balance moves with it: 1 / (1 + ½)")
    c.near(own.totalGain, 1.5, 1e-12, "and the frame is brighter: 1 + ½")
    rules.exposure(&own, 9, .bottom)
    c.expect(ev(own, .bottom) == Double2.exposureRange.upperBound, "an exposure's own stops held to the pair's −5…5")
    rules.exposure(&own, -9, .top)
    c.expect(ev(own, .top) == Double2.exposureRange.lowerBound, "at both ends")

    // Film Exposure on the whole adds the same stops to both: Balance unchanged.
    var film = made()
    rules.setBalance(&film, 0.6)
    var look = FilmParams.default
    look.autoExposure = false
    let s0 = rules.balance(film)
    look.exposureCompensationEV = 1.25
    c.near(rules.stops(film, .top, look), log2(0.6) + 1.25, 1e-9, "Film Exposure +1¼ on the top")
    c.near(rules.stops(film, .bottom, look), log2(0.4) + 1.25, 1e-9, "and the same on the bottom")
    c.near(rules.balance(film), s0 ?? .nan, 1e-12, "Balance not moved by Film Exposure")
    if let t = rules.stops(film, .top, look), let b = rules.stops(film, .bottom, look) {
        c.near(Double2.share(top: t, bottom: b), 0.6, 1e-9, "nor the share of light the two get")
    }
    // Metered: the reading under the right key, plus its own and the whole's.
    look.autoExposure = true
    c.expect(rules.stops(film, .top, look) == nil, "metered and not read yet: no stops")
    if let top = film[.top] {
        film[.top]?.meterReadings = ["stale": 4]
        c.expect(rules.stops(film, .top, look) == nil, "a reading for something else is not this one's")
        film[.top]?.meterReadings[Double2.meterKey(top)] = 0.8
    }
    c.near(rules.stops(film, .top, look), 0.8 + log2(0.6) + 1.25, 1e-9, "metered: its reading, its own, the whole's")
    c.near(rules.balance(film), 0.6, 1e-12, "and Balance leaves the readings out (PRD 2: 50 % is each as metered, halved)")

    // ↺: as made.
    var reset = film
    reset[.top]?.autoExposure = false
    reset.resetExposures()
    c.near(rules.balance(reset), 0.5, 1e-12, "↺ puts Balance back to 50 %")
    c.expect(reset[.top]?.autoExposure == true && reset[.top]?.placement == film[.top]?.placement, "metered alone again, placed where it was")
}

// MARK: - who is on top (RFC-047 §3)

func swapChecks(_ c: inout Checker, _ rules: Rules) {
    // The same shape: 4:3 under 4:3.
    let same: Double2.Framed = [.bottom: CGSize(width: 4000, height: 3000), .top: CGSize(width: 8000, height: 6000)]
    var d = made()
    rules.setBalance(&d, 0.7)
    var moved = HalfFramePair.Placement()
    moved.scale = 2; moved.x = 0.4; moved.y = -0.2; moved.quarterTurns = 1
    d[.top]?.placement = Double2.Placement(base: moved, flipped: true)
    let before = d
    rules.swap(&d, same)
    c.expect(d[.bottom]?.frame == B && d[.top]?.frame == A, "the swap reverses the order")
    c.near(rules.balance(d), 0.7, 1e-9, "Balance stays with the position: the new top has the old top's share (PRD 2 §8.2)")
    c.near(d.totalGain, before.totalGain ?? .nan, 1e-12, "and the frame's light")
    c.near(ev(d, .top), ev(before, .top), 1e-12, "the top's stops are the position's")
    c.expect(d[.bottom]?.placement == before[.top]?.placement && d[.top]?.placement == before[.bottom]?.placement,
             "the same shape: each placement goes with its exposure")
    c.expect(d[.bottom]?.decode == before[.top]?.decode && d[.bottom]?.meterMethod == before[.top]?.meterMethod,
             "and its decode and meter")
    var back = d
    var swapped: Double2.Framed = [:]
    swapped[.bottom] = same[.top]; swapped[.top] = same[.bottom]
    rules.swap(&back, swapped)
    c.expect(back == before, "swapped twice: as it was")

    // Another shape: 3:2 goes under, 4:3 over it.
    let shapes: Double2.Framed = [.bottom: CGSize(width: 4000, height: 3000), .top: CGSize(width: 6000, height: 4000)]
    var e = made()
    rules.setBalance(&e, 0.25)
    var low = HalfFramePair.Placement()
    low.scale = 1.6; low.x = -0.5; low.y = 0.3; low.quarterTurns = 2
    e[.bottom]?.placement = Double2.Placement(base: low, flipped: true)
    e[.top]?.placement = Double2.Placement(base: moved, flipped: true)
    let was = e
    rules.swap(&e, shapes)
    c.near(rules.balance(e), 0.25, 1e-9, "another shape: Balance still with the position")
    c.expect(e[.bottom]?.frame == B && e[.bottom]?.placement == Double2.Placement(),
             "the new bottom, of another shape, sets the frame: centred, scale 1, no turn, no flip")
    c.expect(e[.top]?.placement == was[.bottom]?.placement.held, "the new top keeps its centre, turn and flip, its zoom held")
    var after: Double2.Framed = [:]
    after[.bottom] = shapes[.top]; after[.top] = shapes[.bottom]
    c.near(e.frameAspect(after), 1.5, 1e-12, "and the frame is the new bottom's 3:2")

    // A layer empty: the one there moves to the other.
    var holed = made()
    holed[.top] = nil
    rules.swap(&holed, [.bottom: CGSize(width: 4000, height: 3000)])
    c.expect(holed[.top]?.frame == A && holed[.bottom] == nil, "a swap with one exposure moves it to the other layer")
}

// MARK: - the frame it began with (PRD 2 D7)

func originChecks(_ c: inout Checker, _ rules: Rules) {
    var d = made(origin: A)
    c.expect(!rules.mayChange(d, .bottom), "the frame it began with cannot be replaced or removed")
    c.expect(rules.mayChange(d, .top), "the other can")
    c.expect(!rules.fill(&d, .bottom, nil) && d[.bottom]?.frame == A, "Remove stands down on it")
    c.expect(!rules.fill(&d, .bottom, Double2.Exposure(frame: C)) && d[.bottom]?.frame == A, "and Replace")
    c.expect(rules.fill(&d, .top, Double2.Exposure(frame: C)) && d[.top]?.frame == C, "the other is replaced")
    rules.swap(&d, [:])
    c.expect(d[.top]?.frame == A && !rules.mayChange(d, .top) && rules.mayChange(d, .bottom), "swapped to the top, it is still held there")
    c.expect(d.origin == A, "the swap keeps the origin")
    let twice = made(A, A, origin: A)
    c.expect(rules.mayChange(twice, .bottom) && rules.mayChange(twice, .top), "the same photograph in both: either may go, the other holds it")
    let picked = made()
    c.expect(rules.mayChange(picked, .bottom) && rules.mayChange(picked, .top), "two picked together hold neither")
}

// MARK: - the frame's size (RFC-048 §5), the window (RFC-047 §3)

func sizeChecks(_ c: inout Checker, _ rules: Rules) {
    let d = made()
    let big = CGSize(width: 8064, height: 6048), twelve = CGSize(width: 4032, height: 3024)
    c.expect(rules.frameSize(d, [.bottom: big, .top: twelve], nil) == PixelSize(width: 4032, height: 3024),
             "a 48 MP bottom under a 12 MP top: a 12 MP frame, neither enlarged")
    c.expect(rules.frameSize(d, [.bottom: twelve, .top: big], nil) == PixelSize(width: 4032, height: 3024), "a 12 MP bottom: its own size")
    c.expect(rules.frameSize(d, [.bottom: big, .top: CGSize(width: 4032, height: 2268)], nil) == PixelSize(width: 3024, height: 2268),
             "a 16:9 top over a 4:3 bottom: as large as the top fills at 4:3, 3024 × 2268")
    var turned = d
    turned[.top]?.placement.base.quarterTurns = 1
    c.expect(rules.frameSize(turned, [.bottom: big, .top: twelve], nil) == PixelSize(width: 3024, height: 2268),
             "a 4:3 top turned upright: what it fills of a 4:3 frame, 3024 × 2268")
    var zoomed = d
    zoomed[.top]?.placement.base.scale = 3
    c.expect(rules.frameSize(zoomed, [.bottom: big, .top: twelve], nil) == PixelSize(width: 4032, height: 3024), "a zoom does not resize the frame")
    c.expect(rules.frameSize(d, [.bottom: big, .top: twelve], 1920) == PixelSize(width: 1920, height: 1440), "a smaller job: the same shape at its long edge")
    var holed = d
    holed[.top] = nil
    c.expect(rules.frameSize(holed, [.bottom: big, .top: twelve], nil) == PixelSize(width: 8064, height: 6048), "an empty top limits nothing")
    c.expect(rules.frameSize(d, [:], nil) == nil, "no picture known: no size")
    c.near(d.frameAspect([.bottom: big], gateAspect: 1.5), 1.5, 1e-12, "the gate's shape while the whole wears a film edge")
    var bottomless = d
    bottomless[.bottom] = nil
    c.near(bottomless.frameAspect([.bottom: big, .top: CGSize(width: 3000, height: 4000)]), 0.75, 1e-12,
           "the bottom's layer empty: the top's shape")

    // The window, at the frame's shape.
    let whole = rules.window(Double2.Placement(), CGSize(width: 4000, height: 3000), 4.0 / 3.0)
    c.expect(abs(whole.minX) < 1e-9 && abs(whole.width - 1) < 1e-9 && abs(whole.height - 1) < 1e-9, "the same shape, centred: the whole picture")
    let wide = rules.window(Double2.Placement(), CGSize(width: 6000, height: 4000), 4.0 / 3.0)
    c.near(Double(wide.width), (4000.0 * 4 / 3) / 6000, 1e-9, "a 3:2 picture under a 4:3 frame: its middle 8/9 across")
    c.near(Double(wide.minX), (1 - (4000.0 * 4 / 3) / 6000) / 2, 1e-9, "centred")
    var right = HalfFramePair.Placement()
    right.x = 1
    let plain = rules.window(Double2.Placement(base: right), CGSize(width: 6000, height: 4000), 4.0 / 3.0)
    let flipped = rules.window(Double2.Placement(base: right, flipped: true), CGSize(width: 6000, height: 4000), 4.0 / 3.0)
    c.expect(plain == flipped, "a flip mirrors the window's content, not the window")
    c.near(Double(plain.maxX), 1, 1e-9, "x = 1: the window at the picture's right edge")
    var up = HalfFramePair.Placement()
    up.quarterTurns = 1
    let upright = rules.window(Double2.Placement(base: up), CGSize(width: 4000, height: 3000), 4.0 / 3.0)
    c.near(Double(upright.height), (3000.0 * 3 / 4) / 4000, 1e-9, "a quarter turn: the window of the turned picture")
}

// MARK: - the meter, kept a picture at a time

func meterChecks(_ c: inout Checker, _ rules: Rules) {
    var d = made()
    guard let top = d[.top] else { return }
    let key = Double2.meterKey(top)
    c.expect(rules.keep(&d, 0.6, .top, key) && d.reading(.top) == 0.6, "a reading kept for the exposure it was read for")
    c.expect(!rules.keep(&d, 2, .top, "another") && d.reading(.top) == 0.6, "a reading for something else is dropped")
    var placed = d
    placed[.top]?.placement.base.x = 0.5
    c.expect(placed.reading(.top) == 0.6, "placing a picture does not re-meter it")
    var warmer = DecodeSettings()
    warmer.whiteBalance = .tungsten
    c.expect(placed.mirror(.top, decode: warmer, cut: .default), "another decode read from the photograph moves the picture")
    c.expect(placed.reading(.top) == nil, "and its meter reads again")
    c.expect(!placed.mirror(.top, decode: warmer, cut: .default), "the same decode again moves nothing")
    for i in 0..<20 {
        var e = d
        e[.top]?.decode.tint = Double(i)
        if let t = e[.top] { _ = e.keep(reading: 0, of: .top, for: Double2.meterKey(t)) }
        d = e
    }
    c.expect((d[.top]?.meterReadings.count ?? 99) <= Double2.readingsKept, "a file keeps at most \(Double2.readingsKept) readings an exposure")
    c.expect(d[.top]?.wireMethod == "balanced" && Double2.Exposure(frame: A).wireMethod == nil, "\"legacy\" is no intent on the wire")
}

// MARK: - the whole's look

func lookChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    let negatives = catalog.films.filter { !$0.isPositive && !$0.isMonochrome }
    guard let negative = negatives.first, let slide = catalog.films.first(where: \.isPositive),
          let paper = catalog.papers.first(where: { !$0.isMonochrome }) else {
        c.expect(false, "the catalogue has a negative, a slide and a colour paper"); return
    }
    var bottom = FrameEdit()
    bottom.params.load(film: negative.id, catalog: catalog)
    bottom.params.exposureCompensationEV = 0.7
    bottom.params.printBrightnessStops = 0.5
    bottom.params.effects.grain = 1.4
    bottom.params.filmFormatMM = 54
    bottom.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    bottom.geometry.quarterTurns = 1
    bottom.solvedEV = 0.3
    bottom.filmEdge.active = true
    bottom.filmEdge.format = .f135
    bottom.filmEdge.cameraSeed = 19
    bottom.filmEdge.framing = Geometry.default
    bottom.dateBack.active = true
    let look = rules.look(bottom, catalog)
    c.expect(!look.params.autoExposure && look.params.exposureCompensationEV == 0,
             "the whole is developed with the meter off and no Film Exposure of its own: each exposure carries its light")
    c.expect(look.geometry == .default && look.solvedEV == nil, "no cut of the whole's own, no reading of the bottom's")
    c.near(look.params.filmFormatMM, 54, 1e-12, "one frame: the bottom's own Film Format, not a half frame's")
    c.expect(look.params.printBrightnessStops == 0.5 && look.params.effects.grain == 1.4, "the rest of the look is the bottom's")
    c.expect(look.filmEdge.active && look.filmEdge.cameraSeed == 19 && look.filmEdge.format == .f135 && look.filmEdge.framing == nil,
             "the film edge kept, its framing gone into the bottom's cut")
    c.expect(look.dateBack == bottom.dateBack, "the bottom's date back (PRD 2 §4.2)")
    var old = FrameEdit()
    old.params.filmStock = slide.id
    old.params.printStock = paper.id
    old.params.scanFilm = false
    let scanned = rules.look(old, catalog)
    c.expect(scanned.params.filmStock == slide.id && scanned.params.scanFilm, "a slide's double exposure is scanned, never printed")
    // The meter's switch given back when kept, as on the pair.
    let d = made()
    c.expect(d.startingLook(look).params.autoExposure, "kept: the look's meter on, each exposure metered alone")
    var off = d
    off[.top]?.autoExposure = false; off[.bottom]?.autoExposure = false
    c.expect(!off.startingLook(look).params.autoExposure, "with neither metered, off")
}

// MARK: - a photograph removed (RFC-047 §5)

func cascadeChecks(_ c: inout Checker, _ rules: Rules) {
    // The bottom's photograph goes from one made from the viewer (A is the origin).
    var d = made(origin: A)
    var top = Double2.Placement()
    top.base.scale = 2; top.base.x = 0.5; top.base.quarterTurns = 1; top.flipped = true
    d[.top]?.placement = top
    let shape = CGSize(width: 6000, height: 4000)
    let emptied = rules.empty(&d, [A], [.bottom: shape, .top: shape], [.top: CGSize(width: 3000, height: 4000)])
    c.expect(emptied && d[.bottom] == nil && d[.top]?.frame == B, "a removed photograph's layer is left empty, the other stays where it is")
    c.expect(d.origin == nil, "the frame it began with is let go once its photograph has gone")
    c.expect(d[.top]?.placement == top, "the layer left keeps its placement (held, and inside its range: as it was)")
    c.expect(d[.top]?.exposureEV == Double2.madeEV, "the layer left keeps its own stops")

    // The top's goes: the bottom still sets the frame, nothing moves.
    var t = made()
    var bottom = Double2.Placement()
    bottom.base.scale = 1.5
    t[.bottom]?.placement = bottom
    _ = rules.empty(&t, [B], [.bottom: shape, .top: shape], [.bottom: shape])
    c.expect(t[.top] == nil && t[.bottom]?.placement == bottom, "the top's photograph gone: the bottom as it was")

    var none = made()
    c.expect(!rules.empty(&none, [C], [:], [:]) && none == made(), "a photograph it does not hold changes nothing")
    var twice = made(A, A, origin: A)
    _ = rules.empty(&twice, [A], [:], [:])
    c.expect(twice.isEmpty, "the same photograph in both layers: both are left empty")

    // Which double exposures go with their last photograph.
    let all: (UUID) -> Bool = { _ in true }
    c.expect(!rules.leftEmpty(made(), [A], all), "one exposure left: the double exposure stays")
    c.expect(rules.leftEmpty(made(), [A, B], all), "both photographs removed: it goes")
    c.expect(rules.leftEmpty(made(A, A), [A], all), "its one photograph in both layers removed: it goes")
    var half = made()
    half[.top] = nil
    c.expect(rules.leftEmpty(half, [A], all) && !rules.leftEmpty(half, [], all), "a layer already empty and the other's photograph removed: it goes")
    c.expect(rules.leftEmpty(made(), [A]) { $0 != B }, "a photograph the library no longer has (an older build removed it) counts as gone")
    c.expect(!rules.leftEmpty(made(), [], all), "nothing removed: nothing goes")
}

// MARK: - the guide before develop (RFC-047 §5.1)

/// A flat sRGB picture, 8-bit, as a camera's preview is.
func flat(_ v: CGFloat, width: Int = 8, height: Int = 4, rightHalf: CGFloat? = nil) -> CIImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: space, components: [v, v, v, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let rightHalf {
        ctx.setFillColor(CGColor(colorSpace: space, components: [rightHalf, rightHalf, rightHalf, 1])!)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    }
    return CIImage(cgImage: ctx.makeImage()!)
}

/// The sRGB byte at (x, y) of a guide, y down, read through the guide's own context.
func byte(_ image: CIImage, x: Int, y: Int) -> Int {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = DoubleGuide.context()
    ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: Int(image.extent.height) - 1 - y, width: 1, height: 1),
               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return Int(px[0])
}

func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func encoded(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }

func guideChecks(_ c: inout Checker, _ rules: Rules) {
    let size = CGSize(width: 8, height: 4)
    let framed: Double2.Framed = [.bottom: size, .top: size]
    var d = made()
    var layers = rules.guideLayers(d, framed)
    c.expect(layers.map(\.position) == [.bottom, .top], "the guide lays both, bottom first")
    c.near(layers.first?.gain, 0.5, 1e-12, "made: the bottom at half its light")
    c.near(layers.last?.gain, 0.5, 1e-12, "made: the top at half its light (the two add to one)")
    // The meter's readings are no part of the guide.
    let key = Double2.meterKey(d[.bottom]!)
    _ = d.keep(reading: 2, of: .bottom, for: key)
    c.near(rules.guideLayers(d, framed).first?.gain, 0.5, 1e-12, "a reading kept: the guide's gain is its own stops alone")
    d.setBalance(0.7)
    layers = rules.guideLayers(d, framed)
    c.near(layers.last?.gain, 0.7, 1e-9, "Balance 70 %: the top at 0.7 of the frame's light")
    c.near(layers.first?.gain, 0.3, 1e-9, "Balance 70 %: the bottom at 0.3")

    // A flip mirrors the window's content: the window cut from the unflipped picture is the frame's mirrored.
    var p = Double2.Placement()
    p.base.scale = 2; p.base.x = 0.6
    var f = made()
    f[.top]?.placement = p
    let window = Double2.window(p, framed: size, aspect: 2)
    c.expect(rules.guideLayers(f, framed).last?.window == window, "unflipped: the frame's own window")
    f[.top]?.placement.flipped = true
    let flipped = rules.guideLayers(f, framed).last
    c.expect(flipped?.flipped == true && flipped?.window == Double2.mirrored(window) && abs((flipped?.window.minX ?? 0) - (1 - window.maxX)) < 1e-12,
             "flipped: the window mirrored, \(String(describing: flipped?.window)) for \(window)")
    var one = made()
    one[.top] = nil
    c.expect(rules.guideLayers(one, framed).map(\.position) == [.bottom], "an empty layer is left out of the guide")

    // The guide's key moves with what it shows, and not with a decode or a reading.
    let base = made()
    var decode = base
    decode[.bottom]?.decode.whiteBalance = .tungsten
    decode[.top]?.decode.lensCorrection.toggle()
    c.expect(rules.guideKey(decode) == rules.guideKey(base), "a white balance or a lens correction does not draw the guide again")
    var read = base
    _ = read.keep(reading: 1.5, of: .top, for: Double2.meterKey(read[.top]!))
    read[.top]?.autoExposure = false
    c.expect(rules.guideKey(read) == rules.guideKey(base), "a reading or the meter's switch does not draw it again")
    var stops = base
    stops.setBalance(0.6)
    c.expect(rules.guideKey(stops) != rules.guideKey(base), "Balance moved: the guide is drawn again")
    var moved = base
    moved[.top]?.placement.flipped = true
    var other = base
    other[.top]?.frame = C
    c.expect(rules.guideKey(moved) != rules.guideKey(base) && rules.guideKey(other) != rules.guideKey(base),
             "a flip or another photograph: the guide is drawn again")

    // What the develop page compares (`DoubleExposure.developed`, `DevelopSession.owed`): a reading kept
    // after the develop that read it is not an edit; everything that is the picture's is.
    var readOnly = base
    _ = readOnly.keep(reading: 0.75, of: .bottom, for: Double2.meterKey(readOnly[.bottom]!))
    c.expect(readOnly != base && rules.developed(readOnly) == rules.developed(base),
             "a reading kept after a develop owes the page no develop")
    var placed = base
    placed[.top]?.placement.base.x = 0.3
    var meterOff = base
    meterOff[.bottom]?.autoExposure = false
    c.expect(rules.developed(moved) != rules.developed(base) && rules.developed(stops) != rules.developed(base)
             && rules.developed(decode) != rules.developed(base) && rules.developed(placed) != rules.developed(base)
             && rules.developed(meterOff) != rules.developed(base) && rules.developed(other) != rules.developed(base),
             "a flip, Balance, a decode, a placement, the meter's switch or another photograph each owe a develop")

    // The pixels, through Core Image on this Mac: sRGB 0.5 and 0.8, half their light each, added in linear light.
    let pictures: [Position: CIImage] = [.bottom: flat(0.5), .top: flat(0.8)]
    let want = encoded(0.5 * linear(0.5) + 0.5 * linear(0.8)) * 255
    if let guide = rules.added(made(), framed, pictures, size) {
        let got = byte(guide, x: 3, y: 2)
        c.expect(abs(Double(got) - want) <= 1.5, "made: 0.5 and 0.8 added in linear light read \(got), the arithmetic \(String(format: "%.1f", want))")
        c.expect(guide.extent.size == size, "the guide is the frame's size")
    } else {
        c.expect(false, "made: no guide drawn")
    }
    var seventy = made()
    seventy.setBalance(0.7)
    let want70 = encoded(0.3 * linear(0.5) + 0.7 * linear(0.8)) * 255
    if let guide = rules.added(seventy, framed, pictures, size) {
        let got = byte(guide, x: 1, y: 1)
        c.expect(abs(Double(got) - want70) <= 1.5, "Balance 70 %: read \(got), the arithmetic \(String(format: "%.1f", want70))")
    } else {
        c.expect(false, "Balance 70 %: no guide drawn")
    }
    // A flip, read back: the top alone at its full light, black on its left and white on its right.
    var mirror = made()
    mirror[.bottom] = nil
    mirror[.top]?.exposureEV = 0
    mirror[.top]?.placement.flipped = true
    if let guide = rules.added(mirror, [.top: size], [.top: flat(0, rightHalf: 1)], size) {
        c.expect(byte(guide, x: 0, y: 2) >= 250 && byte(guide, x: 7, y: 2) <= 5,
                 "flipped: white on the left, black on the right (read \(byte(guide, x: 0, y: 2)), \(byte(guide, x: 7, y: 2)))")
    } else {
        c.expect(false, "flipped: no guide drawn")
    }
    c.expect(rules.added(made(), framed, [:], size) == nil, "no picture to read: no guide")
}

// MARK: - the older-build guard (RFC-047 §2, `LibraryShelf`)

/// An item of the library as it is written, reduced to what the guard is about.
struct Item: Codable, Equatable {
    var id: UUID
    var fileName: String
    var pair: Int? = nil
    var double: DoubleExposure? = nil
}

/// `library.json` as this build writes it: the shape of `StoredLibrary`.
struct NewLibrary: Codable { var schemaVersion = 1; var frames: [Item]; var selectedID: UUID? }

/// `library.json` as **a build from before 2026-11-07** reads it: its `StoredLibrary`, whose frames have no
/// `double` key. A `JSONDecoder` passes over a key a struct does not have, which is what makes a double
/// exposure among them a photograph to that build.
struct OldLibrary: Codable {
    struct OldFrame: Codable { var id: UUID; var fileName: String; var pair: Int? }
    var schemaVersion = 1
    var frames: [OldFrame]
    var selectedID: UUID?
}

func shelfChecks(_ c: inout Checker, _ rules: Rules) {
    let p1 = Item(id: UUID(), fileName: "_DSC0061.ARW"), p2 = Item(id: UUID(), fileName: "IMG_0002.HEIC")
    let pair = Item(id: UUID(), fileName: "Half-Frame Pair 1", pair: 1)
    let d1 = Item(id: UUID(), fileName: "Double Exposure 1", double: made(p1.id, p2.id))
    let d2 = Item(id: UUID(), fileName: "Double Exposure 2", double: made(p2.id, p2.id))
    let library = [p1, d1, pair, p2, d2]
    let (kept, doubles) = rules.split(library)
    c.expect(kept.map(\.id) == [p1.id, pair.id, p2.id] && doubles.map(\.id) == [d1.id, d2.id],
             "split: photographs and pairs in library.json, in their order; the double exposures in doubles.json")

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let libraryJSON = try? enc.encode(NewLibrary(frames: kept, selectedID: d1.id)),
          let doublesJSON = try? enc.encode(StoredDoubles(frames: doubles)) else { return c.expect(false, "the library encodes") }
    // What an older build reads of it.
    guard let old = try? JSONDecoder().decode(OldLibrary.self, from: libraryJSON) else { return c.expect(false, "an older build reads library.json") }
    c.expect(!old.frames.contains { $0.fileName.hasPrefix("Double Exposure") } && old.frames.count == 3,
             "an older build reads no double exposure: it shows the library without them, not as broken photographs (\(old.frames.map(\.fileName)))")
    // It writes the library back as it has it, and never opens doubles.json; this build joins the two again.
    guard let written = try? enc.encode(old),
          let back = try? JSONDecoder().decode(NewLibrary.self, from: written),
          let shelf = try? JSONDecoder().decode(StoredDoubles<Item>.self, from: doublesJSON) else { return c.expect(false, "read back") }
    let joined = rules.joined(back.frames, shelf.frames)
    c.expect(joined.map(\.id) == [p1.id, pair.id, p2.id, d1.id, d2.id] && joined.last?.double == d2.double && shelf.schemaVersion == 1,
             "after an older build has written library.json, this build reads both double exposures back, each whole")
    // A development build put one among the frames of library.json: it is read once.
    let both = rules.joined([p1, d1], [d1, d2])
    c.expect(both.map(\.id) == [p1.id, d1.id, d2.id], "a double exposure in both files is read once")
    // An older build removed a photograph meanwhile: the double exposure holding it has that layer empty.
    let there = Set(back.frames.map(\.id)).subtracting([p1.id])
    c.expect(!rules.leftEmpty(d1.double!, [], { there.contains($0) }) && rules.leftEmpty(made(p1.id, p1.id), [], { there.contains($0) }),
             "at launch a photograph an older build removed is a gone one: one exposure left stays, none left goes")
    unreadShelfChecks(&c, rules, d1: d1)
}

/// **A doubles.json this build cannot read is never written over** (the 2026-11-07 review): read whole,
/// one item of a later build's made the file read as none, and the next change wrote `frames: []` over
/// every double exposure. Read item by item, an item it cannot read is kept as it was and written back;
/// a file that does not read at all is copied aside and not written over.
func unreadShelfChecks(_ c: inout Checker, _ rules: Rules, d1: Item) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let goodJSON = try? enc.encode(d1), let good = try? JSONSerialization.jsonObject(with: goodJSON) as? [String: Any] else {
        return c.expect(false, "an item encodes")
    }
    // A later build's double exposure: a value this build has no type for (here `pair`, written as a word).
    var later = good
    later["id"] = UUID().uuidString
    later["fileName"] = "Double Exposure 3"
    later["pair"] = "a later build's kind"
    later["exposure"] = ["stops": 1.5, "count": 3, "kept": true, "none": NSNull(), "list": [1, "two", 3.25]] as [String: Any]
    guard let file = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "frames": [good, later]], options: [.sortedKeys]) else {
        return c.expect(false, "the file is made")
    }
    let read = rules.read(file)
    c.expect(read.frames.map(\.id) == [d1.id] && read.frames.first?.double == d1.double && !read.unreadable,
             "an item this build does not read fails only itself: the others are read (\(read.frames.map(\.fileName)))")
    c.expect(read.unread.count == 1, "the item it does not read is kept (\(read.unread.count))")
    // Written back as this build writes it: the items it reads, then the ones it kept, as they were.
    let back = StoredDoubles<ShelfItem<Item>>(frames: read.frames.map { .read($0) } + read.unread.map { .unread($0) })
    let laterJSON = try? JSONSerialization.data(withJSONObject: later, options: [.sortedKeys])
    if let written = try? enc.encode(back),
       let again = try? JSONDecoder().decode(StoredDoubles<ShelfJSON>.self, from: written),
       let laterJSON, let wanted = try? JSONDecoder().decode(ShelfJSON.self, from: laterJSON) {
        c.expect(again.frames.count == 2 && again.frames.last == wanted,
                 "written back, the later build's item is the JSON it was, value for value")
        let reread = rules.read(written)
        c.expect(reread.frames.map(\.id) == [d1.id] && reread.unread.count == 1, "and it reads back the same: one read, one kept")
    } else {
        c.expect(false, "the shelf with an unread item is written and read again")
    }
    c.expect(rules.writes(read.frames.count, read.unread.count, true, read.unreadable),
             "a file with an item kept unread is written, with it")
    c.expect(rules.writes(0, 1, true, false), "the double exposures this build reads all removed: the kept one is still written")

    // A file that does not read at all: another layout (a later schema), or one cut short.
    for (name, bytes) in [("another layout", Data(#"{"schemaVersion":2,"frames":{"bottom":[1]}}"#.utf8)),
                          ("cut short", Data(file.prefix(file.count / 2)))] {
        let none = rules.read(bytes)
        c.expect(none.frames.isEmpty && none.unread.isEmpty && none.unreadable, "\(name): the file does not read, and says so")
        c.expect(!rules.writes(0, 0, true, none.unreadable), "\(name): the library's next change does not write over it")
        c.expect(rules.writes(1, 0, true, none.unreadable), "\(name): a double exposure made since is kept (the copy aside holds the rest)")
    }
    let nothing = rules.read(nil)
    c.expect(nothing.frames.isEmpty && !nothing.unreadable && !rules.writes(0, 0, false, nothing.unreadable),
             "no doubles.json: none, and none made")
    c.expect(rules.writes(0, 0, true, false), "a file that read, every double exposure removed: the empty list is written")

    // The copy aside, byte for byte, the file left where it is.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spk-shelf-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let shelfURL = LibraryShelf.doublesURL(beside: dir.appendingPathComponent("library.json"))
    let cut = Data(file.prefix(file.count / 2))
    try? cut.write(to: shelfURL)
    let when = Date(timeIntervalSince1970: 1_794_000_000)
    let aside = LibraryShelf.setAside(shelfURL, at: when)
    c.expect(aside?.lastPathComponent.hasPrefix("doubles.unreadable-") == true && aside.flatMap { try? Data(contentsOf: $0) } == cut
             && (try? Data(contentsOf: shelfURL)) == cut,
             "a file that does not read is copied aside byte for byte, and stays where it is (\(aside?.lastPathComponent ?? "none"))")
    c.expect(LibraryShelf.setAside(shelfURL, at: when) == aside, "set aside twice in one second: the one copy")
}

// MARK: - the layers

func layerChecks(_ c: inout Checker, _ rules: Rules) {
    c.expect(Double2.Layer.band == [.bottom, .film, .top], "the band reads Bottom · Film · Top")
    c.expect(Double2.Layer.bottom.title == "Bottom" && Double2.Layer.film.title == "Film" && Double2.Layer.top.title == "Top",
             "named Bottom, Film, Top")
    c.expect(Double2.Layer.film.rawValue == 0 && Double2.Layer.film.position == nil && Double2.Layer(.top) == .top,
             "Film is the whole, 0 as the pair's; an exposure's layer is its position")
    var d = made()
    d[.top] = nil
    c.expect(d.pickedPosition(.top) == nil && d.pickedPosition(.bottom) == .bottom, "an empty layer is not picked")
    c.expect(made(A, A).frameIDs == [A] && made().frameIDs == [A, B] && made().position(of: B) == .top, "its photographs, bottom first, each once")
}

@main
struct DoubleSelfTest {
    static func main() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let catalog = StockCatalog(contentsOf: root.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("double checks: no catalogue at Resources/StockCatalog.json")
            exit(1)
        }
        func run(_ rules: Rules, quiet: Bool) -> Checker {
            var c = Checker(quiet: quiet)
            fileChecks(&c, rules)
            balanceChecks(&c, rules)
            swapChecks(&c, rules)
            originChecks(&c, rules)
            sizeChecks(&c, rules)
            meterChecks(&c, rules)
            lookChecks(&c, rules, catalog: catalog)
            layerChecks(&c, rules)
            cascadeChecks(&c, rules)
            guideChecks(&c, rules)
            shelfChecks(&c, rules)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("double self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("double checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
