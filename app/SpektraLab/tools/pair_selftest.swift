//  pair_selftest.swift — the half-frame pair's arithmetic, its file and its film, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  `Model/HalfFramePair.swift` is the desktop's model with the desktop's arithmetic, so that a pair
//  means the same piece of film on both and its file can travel. Three things it could get wrong
//  quietly, with no engine and no page needed to show it:
//
//  - **the piece** — two 18 × 24 holes and the gap on 37 mm of film, a picture under its hole as a
//    rectangle cut from it, a drag, a pinch, a crop entered as a placement, the piece's size, where the
//    second frame begins, the film's size the engine is told. Held against **the numbers of the
//    desktop's own tests** (`SpektrafilmTests/HalfFramePairTests.swift` at SpektraLab `main`, 1.3.1):
//    each check names the test it was taken from;
//  - **the file** — a pair the host writes reads back the same; one the desktop wrote opens, keeps
//    every key the desktop reads again from the file (a frame's own grade among them, which the host
//    has no type for) and writes them back; a file from before a field existed opens;
//  - **the film** — a pair made of a slide film is scanned and never printed, whatever its first
//    frame's edit said (`Model/Stock.swift`'s rule, over the bundle's own catalogue).
//
//  And, since a pair is a feature of its own (2026-10-10), what each frame has for itself:
//
//  - **a frame's own print** — the enlarger on a frame, on a frame and the film, and on the film with
//    a frame's own beside it; reset; when the piece is cut together from more than one print. The
//    desktop's `Session.setEnlarger`, `resetEnlarger` and `pairIsLayered`, held to the numbers of its
//    tests — and **what the engine is asked for it** (`Engine/PrintLayers.swift`): which frames print
//    again, with which rows, where each is on the piece, what of it is in a develop's stamp, and where
//    the engine says a strip's two gates are;
//  - **what a change of the piece owes its picture** — other pixels, what the film is told, or a
//    frame's print alone — which is the host's own (`HalfFramePair.changes`);
//  - **the back, a frame at a time** — the owner's rule of 2026-10-10, which the desktop does not have;
//  - **a frame's own Scene Placement** — which frame the shown one is of, through a pick, a swap, a
//    frame replaced and a hole emptied, and the second frame's rows on the wire.
//
//  Compiled with the model, the models it stands on and `Engine/PrintLayers.swift`. No engine, no
//  UIKit, no page.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a rule
//  broken on purpose, one at a time, and requires each run to fail.

import CoreGraphics
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
    mutating func near(_ a: Double, _ b: Double, _ accuracy: Double, _ what: @autoclosure () -> String) {
        expect(abs(a - b) <= accuracy, "\(what()): \(a), not \(b) ± \(accuracy)")
    }
}

typealias Pair = HalfFramePair

/// The rules the checks hold, each as the app has it. `broken` breaks one at a time.
struct Rules {
    var name = "the app's own"
    // The piece.
    var layout: (Int, Double, Bool) -> Pair.Layout = { Pair.layout(holeHeight: $0, spacingMM: $1, turned: $2) }
    var sourceRect: (Pair.Placement, CGSize, Double) -> CGRect = { Pair.sourceRect(for: $0, source: $1, aspect: $2) }
    var turned: (CGSize, Pair.Placement) -> CGSize = { Pair.turned($0, by: $1) }
    var dragged: (Pair.Placement, CGSize, CGSize, Double) -> Pair.Placement = {
        Pair.placement($0, draggedBy: $1, source: $2, aspect: $3)
    }
    var zoomed: (Pair.Placement, Double, CGPoint, CGSize, Double) -> Pair.Placement = {
        Pair.placement($0, zoomedBy: $1, about: $2, source: $3, aspect: $4)
    }
    var fromCrop: (Geometry, CGSize, Double) -> Pair.Placement = { Pair.placement(from: $0, source: $1, aspect: $2) }
    var pieceLayout: (Pair, [Pair.Side: CGSize]) -> Pair.Layout = { $0.pieceLayout(sizes: $1) }
    var spacing: (Pair) -> Double = { $0.effectiveSpacingMM }
    var split: (Pair) -> Double = { $0.split }
    var filmFormat: (Pair, Double) -> Double = { $0.filmFormatMM(frameLongMM: $1) }
    var held: (Pair.Placement) -> Pair.Placement = { $0.held }
    // The camera held the other way, each picture turned with its hole (a tester, 2026-10-20).
    var holdCamera: (inout Pair, Bool, [Pair.Side: CGSize]) -> Void = { $0.holdCamera(turned: $1, pictures: $2) }
    // The piece's edits.
    var expose: (inout Pair, Double, Pair.Side, inout FilmParams) -> Void = { pair, ev, side, look in
        pair.exposure(ev, of: side, look: &look)
    }
    var swap: (inout Pair) -> Void = { $0.swap() }
    var stops: (Pair, Pair.Side) -> Double? = { $0.stops($1) }
    var meterKey: (Pair.Hole, String) -> String = { Pair.meterKey(hole: $0, method: $1) }
    var title: (Pair, Pair.Layer) -> String = { $0.title($1) }
    // A pair entered with one frame (the owner's rule of 2026-10-09).
    var soleFrame: (Pair) -> UUID? = { $0.soleFrame }
    var mayChange: (Pair, Pair.Side, UUID?) -> Bool = { $0.mayChange($1, enteredWith: $2) }
    // The date back on a pair: the first frame's text, the second's, the pair's film edge.
    var dateRows: (DateBackSettings, String, String, FilmEdgeSettings) -> [String: ParamValue] = { back, first, second, edge in
        Rules.keyed(back.pairRows(first: first, second: second, filmEdge: edge))
    }

    static func keyed(_ rows: [(name: String, value: ParamValue, layer: ParamLayer)]) -> [String: ParamValue] {
        rows.reduce(into: [:]) { $0[$1.name] = $1.value }
    }
    // A frame's own print (the desktop's `Session.setEnlarger`, `resetEnlarger`, `enlargerValue`, `pairIsLayered`).
    var trim: (inout Pair, PrintField, Double, Pair.Layer, inout FilmParams) -> Void = { pair, field, value, layer, look in
        pair.print(field, value, on: layer, look: &look)
    }
    var resetPrint: (inout Pair, Pair.Layer, inout FilmParams) -> Void = { pair, layer, look in pair.resetPrint(on: layer, look: &look) }
    var pinPrints: (inout Pair, Pair.PrintTrim) -> Void = { $0.pinPrints(to: $1) }
    var shownTrim: (Pair, Pair.Layer, FilmParams) -> Pair.PrintTrim = { $0.trim(on: $1, look: $2) }
    var isLayered: (Pair, FilmParams) -> Bool = { $0.isLayered(look: $1) }
    // What a change of the piece owes its picture.
    var changes: (Pair, Pair) -> Set<Pair.Change> = { $0.changes(from: $1) }
    // What a guide of the piece is drawn from (`PairGuide.write`, on the main thread, when it moves).
    var guideKey: (Pair) -> String = { $0.guideKey }
    // The back, a frame at a time (the owner, 2026-10-10).
    var setDated: (inout Pair, Bool, Pair.Side, inout DateBackSettings) -> Void = { pair, on, side, back in
        pair.setDated(on, side, back: &back)
    }
    var setBack: (inout Pair, DateBackFace?, inout DateBackSettings) -> Void = { pair, face, back in pair.setBack(face, back: &back) }
    var backSummary: (Pair, DateBackSettings) -> String = { $0.backSummary($1) }
    // A frame's own Scene Placement (the desktop's `Session.pairLayerChanged`, `swapHoles`, `resetPlacement`).
    var show: (Pair.Side, inout FilmParams) -> Void = { Pair.show(placementOf: $0, in: &$1) }
    var swapLook: (inout Pair, inout FilmParams) -> Void = { pair, look in pair.swap(look: &look) }
    var fillLook: (inout Pair, Pair.Side, Pair.Hole?, inout FilmParams) -> Void = { pair, side, hole, look in
        pair.fill(side, with: hole, look: &look)
    }
    var hold: (Pair, inout FilmParams) -> Void = { $0.hold(&$1) }
    var shownSide: (Pair, FilmParams) -> Pair.Side? = { $0.placementSide($1) }
    var wire: (FilmParams) -> [String: ParamValue] = { Rules.keyed($0.wire) }
    // What the engine is asked for a frame's own print (`Engine/PrintLayers.swift`).
    var printLayers: (Pair, FilmParams, StockCatalog) -> [PrintLayer] = { $0.printLayers(look: $1, catalog: $2) }
    var layerKey: (PrintLayer) -> String = { $0.key }
    var gates: (String) -> [CGRect] = { FilmGates.rects($0) }

    /// Each gate's eight numbers, as `FilmGates` finds them in the engine's reply: for a broken reading of them.
    static func corners(_ json: String) -> [[Double]] {
        guard let reply = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              reply["valid"] as? Bool == true, let gates = reply["gates"] as? [[NSNumber]] else { return [] }
        return gates.map { $0.map(\.doubleValue) }.filter { $0.count == 8 }
    }
    // The file.
    var encode: (Pair) -> Data? = { try? $0.encoded() }
    var decode: (Data) -> Pair? = { Pair.decoded($0) }
    // The film.
    var look: (FrameEdit, Bool, StockCatalog) -> FrameEdit = { Pair.look(from: $0, keepFilmEdge: $1, catalog: $2) }
    var loadFilm: (String, inout FrameEdit, StockCatalog) -> Void = { id, look, catalog in
        Pair.load(film: id, into: &look, catalog: catalog)
    }

    static var broken: [Rules] {
        var out: [Rules] = []
        func rule(_ name: String, _ change: (inout Rules) -> Void) {
            var r = Rules()
            r.name = name
            change(&r)
            out.append(r)
        }
        // The camera held the other way (2026-10-20).
        rule("the camera turned and the pictures left lying across their holes") { r in
            r.holdCamera = { pair, turned, _ in pair.turned = turned }
        }
        rule("every picture turned with the camera, the ones that already lay right too") { r in
            r.holdCamera = { pair, turned, _ in
                pair.turned = turned
                for side in Pair.Side.allCases { pair[side]?.placement.quarterTurns += 1 }
            }
        }
        rule("turned on again where turning back was owed") { r in
            r.holdCamera = { pair, turned, pictures in
                let was = pair
                pair.holdCamera(turned: turned, pictures: pictures)
                for side in Pair.Side.allCases where pair[side]?.placement != was[side]?.placement {
                    pair[side]?.placement.quarterTurns = ((was[side]?.placement.quarterTurns ?? 0) + 1) % 4
                }
            }
        }
        rule("a turned picture left where it was under the hole") { r in
            r.holdCamera = { pair, turned, pictures in
                let was = pair
                pair.holdCamera(turned: turned, pictures: pictures)
                for side in Pair.Side.allCases { pair[side]?.placement.x = was[side]?.placement.x ?? 0 }
            }
        }
        // The piece.
        rule("a gap measured on the hole's long side: 1 mm drawn as 1.33") { r in
            r.layout = { across, spacing, turned in
                let good = Pair.layout(holeHeight: across, spacingMM: spacing, turned: turned)
                let along = turned ? good.hole.height : good.hole.width
                let advance = Int((Double(along) + Double(max(across, 8)) * spacing / 18).rounded())
                return Pair.Layout(hole: good.hole, advance: advance, turned: turned)
            }
        }
        rule("a turned pair laid out side by side") { r in
            r.layout = { across, spacing, _ in Pair.layout(holeHeight: across, spacingMM: spacing, turned: false) }
        }
        rule("a wider gap that makes the holes smaller") { r in
            r.layout = { across, spacing, turned in
                Pair.layout(holeHeight: Int(Double(across) * 37 / (36 + spacing)), spacingMM: spacing, turned: turned)
            }
        }
        rule("a picture scaled under its hole: base shows inside a filled hole") { r in
            r.sourceRect = { p, source, aspect in
                guard p.scale < 1 else { return Pair.sourceRect(for: p, source: source, aspect: aspect) }
                var one = p
                one.scale = 1
                let fit = Pair.sourceRect(for: one, source: source, aspect: aspect)
                return CGRect(x: fit.midX - fit.width / p.scale / 2, y: fit.midY - fit.height / p.scale / 2,
                              width: fit.width / p.scale, height: fit.height / p.scale)
            }
        }
        rule("a placement that is not held to the picture's edge") { r in
            r.sourceRect = { p, source, aspect in
                var mid = p
                mid.x = 0; mid.y = 0
                let cut = Pair.sourceRect(for: mid, source: source, aspect: aspect)
                return cut.offsetBy(dx: p.x * (source.width - cut.width) / 2, dy: p.y * (source.height - cut.height) / 2)
            }
        }
        rule("the cut taken from the picture's middle, whatever its placement") { r in
            r.sourceRect = { p, source, aspect in
                var mid = p
                mid.x = 0; mid.y = 0
                return Pair.sourceRect(for: mid, source: source, aspect: aspect)
            }
        }
        rule("the hole cut 2:3 (a full frame's shape) instead of 3:4") { r in
            r.sourceRect = { p, source, aspect in Pair.sourceRect(for: p, source: source, aspect: aspect * 8 / 9) }
        }
        rule("a quarter turn that leaves the picture its shape") { r in r.turned = { size, _ in size } }
        rule("a drag that moves the cut with the finger: the picture goes the other way") { r in
            r.dragged = { p, d, source, aspect in
                Pair.placement(p, draggedBy: CGSize(width: -d.width, height: -d.height), source: source, aspect: aspect)
            }
        }
        rule("a drag that carries the cut past the picture's edge") { r in
            r.dragged = { origin, d, source, aspect in
                let turned = Pair.turned(source, by: origin)
                let cut = Pair.sourceRect(for: origin, source: turned, aspect: aspect)
                var p = origin
                let slackX = (turned.width - cut.width) / 2
                if slackX > 0.5 { p.x = origin.x - Double(d.width * cut.width / slackX) }
                return p
            }
        }
        rule("a zoom about the cut's middle: the picture slides as it scales (the desktop until 2026-10-04)") { r in
            r.zoomed = { origin, factor, _, _, _ in
                var p = origin
                p.scale = (origin.scale * factor).clamped(to: Pair.Placement.scaleRange)
                return p
            }
        }
        rule("a zoom with no end") { r in
            r.zoomed = { origin, factor, anchor, source, aspect in
                var p = Pair.placement(origin, zoomedBy: factor, about: anchor, source: source, aspect: aspect)
                p.scale = origin.scale * factor
                return p
            }
        }
        rule("a half frame entered into a pair at its middle, its Film Edge framing lost") { r in
            r.fromCrop = { g, _, _ in
                var p = Pair.Placement()
                p.quarterTurns = ((g.quarterTurns % 4) + 4) % 4
                return p
            }
        }
        rule("the piece laid out at its frames' own size (two 45 MP frames, an 83 MP piece)") { r in
            r.pieceLayout = { pair, sizes in
                var across: [CGFloat] = []
                for side in Pair.Side.allCases {
                    guard let hole = pair[side], let size = sizes[side] else { continue }
                    var fit = hole.placement
                    fit.scale = 1
                    let cut = Pair.sourceRect(for: fit, source: Pair.turned(size, by: hole.placement), aspect: pair.holeAspect)
                    across.append(pair.turned ? cut.width : cut.height)
                }
                return Pair.layout(holeHeight: Int((across.min() ?? 2400).rounded(.down)), spacingMM: pair.effectiveSpacingMM,
                                   turned: pair.turned)
            }
        }
        rule("a zoom that resizes the piece") { r in
            r.pieceLayout = { pair, sizes in
                var scaled = sizes
                for side in Pair.Side.allCases {
                    guard let hole = pair[side], let size = sizes[side] else { continue }
                    scaled[side] = CGSize(width: size.width / hole.placement.scale, height: size.height / hole.placement.scale)
                }
                return pair.pieceLayout(sizes: scaled)
            }
        }
        rule("the larger picture sets the holes: the smaller one is enlarged") { r in
            r.pieceLayout = { pair, sizes in
                let largest = sizes.values.max { $0.width * $0.height < $1.width * $1.height }
                return pair.pieceLayout(sizes: sizes.mapValues { _ in largest ?? .zero })
            }
        }
        rule("the user's spacing kept on a strip, where the camera's advance decides it") { r in
            r.spacing = { $0.spacingMM.clamped(to: Pair.spacingRange) }
        }
        rule("a spacing outside 0.5–2.0 mm") { r in r.spacing = { $0.onStrip ? 1 : $0.spacingMM } }
        rule("the second frame's curve from where its hole starts, not the middle of the gap") { r in
            r.split = { pair in
                let l = Pair.layout(holeHeight: 2400, spacingMM: pair.effectiveSpacingMM, turned: pair.turned)
                let b = l.normalisedRect(.right)
                return pair.turned ? Double(b.minY) : Double(b.minX)
            }
        }
        rule("the engine told the piece is one half frame long: grain a third too coarse") { r in
            r.filmFormat = { _, frame in frame }
        }
        rule("the engine told 37 mm whatever the spacing") { r in r.filmFormat = { _, frame in 37 * frame / 24 } }
        rule("a placement kept as it was typed: five quarter turns, a scale of nothing") { r in r.held = { $0 } }
        // The piece's edits.
        rule("+ Film that leaves the film's print where it was") { r in
            r.expose = { pair, ev, side, _ in
                var none = FilmParams()
                pair.exposure(ev, of: side, look: &none)
            }
        }
        rule("an exposure on the frame alone that moves the film's print") { r in
            r.expose = { pair, ev, side, look in
                let was = pair[side]?.exposureEV ?? 0
                pair.exposure(ev, of: side, look: &look)
                if pair[side]?.exposureScope == .frame { look.printBrightnessStops += (pair[side]?.exposureEV ?? 0) - was }
            }
        }
        rule("a hole's exposure past five stops") { r in
            r.expose = { pair, ev, side, look in
                pair.exposure(ev, of: side, look: &look)
                pair[side]?.exposureEV = ev
            }
        }
        rule("an exposure that lands on the other hole") { r in
            r.expose = { pair, ev, side, look in pair.exposure(ev, of: side.other, look: &look) }
        }
        rule("a swap that leaves each placement in its hole") { r in
            r.swap = { pair in
                let (a, b) = (pair.left?.placement, pair.right?.placement)
                pair.swap()
                if let a { pair.left?.placement = a }
                if let b { pair.right?.placement = b }
            }
        }
        rule("a hole whose meter is off, exposed by its meter all the same") { r in
            r.stops = { pair, side in pair[side].map { ($0.meteredEV ?? 0) + $0.exposureEV } }
        }
        rule("a hole nobody has metered, exposed as if it read zero") { r in
            r.stops = { pair, side in pair[side].map { ($0.autoExposure ? ($0.meteredEV ?? 0) : 0) + $0.exposureEV } }
        }
        rule("a meter that reads again whenever a picture is moved under its hole") { r in
            r.meterKey = { hole, method in
                Pair.meterKey(hole: hole, method: method) + "|\(hole.placement.scale),\(hole.placement.x),\(hole.placement.y)"
            }
        }
        rule("a meter that keeps its reading across a change of white balance") { r in
            r.meterKey = { hole, method in
                var plain = hole
                plain.decode = DecodeSettings()
                return Pair.meterKey(hole: plain, method: method)
            }
        }
        rule("a turned pair's frames still called left and right") { r in
            r.title = { pair, layer in
                var level = pair
                level.turned = false
                return level.title(layer)
            }
        }
        // The file.
        rule("a file that drops a frame's own print") { r in
            r.encode = { pair in
                var p = pair
                p.left?.print = nil
                p.right?.print = nil
                return try? p.encoded()
            }
        }
        rule("a file that drops the desktop's grade of a frame") { r in
            r.encode = { pair in
                var p = pair
                p.left?.adjustments = nil
                p.right?.adjustments = nil
                return try? p.encoded()
            }
        }
        rule("a file that forgets which frame of the library a hole holds") { r in
            r.encode = { pair in
                var p = pair
                p.left?.frame = nil
                p.right?.frame = nil
                return try? p.encoded()
            }
        }
        rule("a file that needs every key: a pair from before a field existed does not open") { r in
            r.decode = { data in
                struct Strict: Decodable {
                    let schemaVersion: Int, folder: String, spacingMM: Double, onStrip: Bool, turned: Bool
                }
                guard (try? JSONDecoder().decode(Strict.self, from: data)) != nil else { return nil }
                return Pair.decoded(data)
            }
        }
        rule("a file read with the spacing forgotten") { r in
            r.decode = { data in
                var p = Pair.decoded(data)
                p?.spacingMM = 1
                return p
            }
        }
        // The film.
        rule("a pair that copies its first frame's settings: a slide still printed") { r in
            r.look = { first, keep, catalog in
                var e = Pair.look(from: first, keepFilmEdge: keep, catalog: catalog)
                e.params.scanFilm = first.params.scanFilm
                return e
            }
        }
        rule("a film loaded on a pair that sets the film and nothing else") { r in
            r.loadFilm = { id, look, _ in look.params.filmStock = id }
        }
        rule("a pair that keeps its first frame's paper, whatever its film: black and white on a colour paper") { r in
            r.look = { first, keep, catalog in
                var e = Pair.look(from: first, keepFilmEdge: keep, catalog: catalog)
                e.params.printStock = first.params.printStock
                return e
            }
        }
        rule("a film loaded on a pair that keeps the pair's paper, whatever the film") { r in
            r.loadFilm = { id, look, catalog in
                look.params.filmStock = id
                look.params.scanFilm = catalog.isSlide(id)
            }
        }
        rule("a pair metered as one scene: the engine's meter left on") { r in
            r.look = { first, keep, catalog in
                var e = Pair.look(from: first, keepFilmEdge: keep, catalog: catalog)
                e.params.autoExposure = first.params.autoExposure
                return e
            }
        }
        rule("a pair that keeps its first frame's crop and 135 film") { r in
            r.look = { first, keep, catalog in
                var e = Pair.look(from: first, keepFilmEdge: keep, catalog: catalog)
                e.geometry = first.geometry
                e.params.filmFormatMM = first.params.filmFormatMM
                return e
            }
        }
        rule("a pair that takes its first frame's film edge whatever it was entered from") { r in
            r.look = { first, _, catalog in Pair.look(from: first, keepFilmEdge: true, catalog: catalog) }
        }
        // A pair entered with one frame.
        rule("the frame a pair was entered with can be replaced or removed") { r in
            r.mayChange = { _, _, _ in true }
        }
        rule("the first hole is held, whichever frame is under it: after a swap the wrong frame stays") { r in
            r.mayChange = { _, side, origin in origin == nil || side != .left }
        }
        rule("the same frame under both holes can leave neither") { r in
            r.mayChange = { pair, side, origin in origin == nil || pair[side]?.frame != origin }
        }
        rule("a pair entered with two frames holds its first") { r in
            r.soleFrame = { $0.left?.frame }
        }
        rule("a pair entered with its one frame in the second hole holds nothing") { r in
            r.soleFrame = { $0.right == nil ? $0.left?.frame : nil }
        }
        // The date back on a pair.
        rule("a pair's dates written from its first frame's alone: an empty first hole takes the second frame's date with it") { r in
            r.dateRows = { back, first, second, edge in
                var wire = Rules.keyed(back.wire(text: first, filmEdge: edge))
                if wire["date_imprint_active"] == .bool(true) {
                    wire["overscan_format"] = .string(FilmEdgeFormat.half.rawValue)
                    wire["overscan_pair"] = .bool(true)
                    wire["date_imprint_size"] = .double(back.wireSize(on: .half))
                    wire["date_imprint_text_b"] = .string(back.customText ?? second)
                }
                return wire
            }
        }
        rule("words typed by hand printed in an empty hole") { r in
            r.dateRows = { back, first, second, edge in
                var wire = Rules.keyed(back.pairRows(first: first, second: second, filmEdge: edge))
                if let typed = back.customText, wire["date_imprint_active"] == .bool(true) {
                    wire["date_imprint_text"] = .string(typed)
                    wire["date_imprint_text_b"] = .string(typed)
                }
                return wire
            }
        }
        rule("a pair's date that does not say the frame is a pair") { r in
            r.dateRows = { back, first, second, edge in
                var wire = Rules.keyed(back.pairRows(first: first, second: second, filmEdge: edge))
                wire["overscan_pair"] = nil
                return wire
            }
        }
        rule("a pair's date sized for a whole 135 frame") { r in
            r.dateRows = { back, first, second, edge in
                var wire = Rules.keyed(back.pairRows(first: first, second: second, filmEdge: edge))
                if wire["date_imprint_active"] == .bool(true) { wire["date_imprint_size"] = .double(back.wireSize(on: .f135) * 2) }
                return wire
            }
        }
        // A frame's own print.
        rule("a frame's own print that moves the film's print with it, on Frame") { r in
            r.trim = { pair, field, value, layer, look in
                let side = pair.pickedSide(layer), was = pair.trim(on: layer, look: look)[field]
                let onFrame = side.flatMap { pair[$0]?.printScope } == .frame
                pair.print(field, value, on: layer, look: &look)
                if onFrame, let side, let now = pair[side]?.print?[field] {
                    var film = Pair.PrintTrim(look)
                    film[field] += now - was
                    look = film.applied(to: look)
                }
            }
        }
        rule("a frame's print on + Film that leaves the film's print where it was") { r in
            r.trim = { pair, field, value, layer, look in
                guard pair.pickedSide(layer) != nil else { pair.print(field, value, on: layer, look: &look); return }
                var none = look
                pair.print(field, value, on: layer, look: &none)
            }
        }
        rule("a frame's print that gives the other frame none of its own: it rides along with the film") { r in
            r.trim = { pair, field, value, layer, look in
                guard let side = pair.pickedSide(layer) else { pair.print(field, value, on: layer, look: &look); return }
                let other = pair[side.other]?.print
                pair.print(field, value, on: layer, look: &look)
                pair[side.other]?.print = other
            }
        }
        rule("the film's print that leaves behind a frame with a print of its own") { r in
            r.trim = { pair, field, value, layer, look in
                guard pair.pickedSide(layer) == nil else { pair.print(field, value, on: layer, look: &look); return }
                var film = Pair.PrintTrim(look)
                film[field] = value.clamped(to: Pair.PrintTrim.range(field))
                look = film.applied(to: look)
            }
        }
        rule("a frame's print past what the enlarger takes") { r in
            r.trim = { pair, field, value, layer, look in
                pair.print(field, value, on: layer, look: &look)
                if let side = pair.pickedSide(layer) { pair[side]?.print?[field] = value }
            }
        }
        rule("the enlarger on an empty hole that moves nothing: it is the film's") { r in
            r.trim = { pair, field, value, layer, look in
                if let side = layer.side, pair[side] == nil { return }
                pair.print(field, value, on: layer, look: &look)
            }
        }
        rule("a frame's reset that takes the film's print with it") { r in
            r.resetPrint = { pair, layer, look in
                pair.resetPrint(on: layer, look: &look)
                look = Pair.PrintTrim().applied(to: look)
            }
        }
        rule("a frame's reset to the film's print, where the desktop's is a plain one") { r in
            r.resetPrint = { pair, layer, look in
                guard let side = pair.pickedSide(layer) else { pair.resetPrint(on: layer, look: &look); return }
                pair.pinPrints(to: Pair.PrintTrim(look))
                pair[side]?.print = nil
            }
        }
        rule("the film's reset that leaves a frame its own print: still cut together") { r in
            r.resetPrint = { pair, layer, look in
                guard pair.pickedSide(layer) == nil else { pair.resetPrint(on: layer, look: &look); return }
                look = Pair.PrintTrim().applied(to: look)
            }
        }
        rule("a print pinned over the one a frame already has") { r in
            r.pinPrints = { pair, film in for side in Pair.Side.allCases where pair[side] != nil { pair[side]?.print = film } }
        }
        rule("the Print tab showing the film's values on a frame with a print of its own") { r in
            r.shownTrim = { _, _, look in Pair.PrintTrim(look) }
        }
        rule("a piece called one print while a frame prints for itself") { r in r.isLayered = { _, _ in false } }
        rule("a piece called cut together whenever a frame has a print, though it is the film's") { r in
            r.isLayered = { pair, _ in Pair.Side.allCases.contains { pair[$0]?.print != nil } }
        }
        rule("+ Film on an exposure that pins no print: the frames ride along with the film") { r in
            r.expose = { pair, ev, side, look in
                let prints = (pair.left?.print, pair.right?.print)
                pair.exposure(ev, of: side, look: &look)
                pair.left?.print = prints.0
                pair.right?.print = prints.1
            }
        }
        // What a change of the piece owes its picture.
        rule("a meter's reading taken for a change of the piece: every develop asks for another") { r in
            r.changes = { now, old in
                var out = now.changes(from: old)
                for side in Pair.Side.allCases where now[side]?.meteredEV != old[side]?.meteredEV { out.insert(.pixels) }
                return out
            }
        }
        rule("a frame's own print taken for other pixels: the piece composed again for a reprint") { r in
            r.changes = { now, old in
                var out = now.changes(from: old)
                if out.remove(.print) != nil { out.insert(.pixels) }
                return out
            }
        }
        rule("a frame's date that asks nothing of the film") { r in
            r.changes = { now, old in now.changes(from: old).subtracting([.film]) }
        }
        rule("a frame's own print that asks for no print") { r in
            r.changes = { now, old in now.changes(from: old).subtracting([.print]) }
        }
        rule("a picture moved under its hole that asks for nothing") { r in
            r.changes = { now, old in
                var a = now, b = old
                for side in Pair.Side.allCases {
                    a[side]?.placement = Pair.Placement()
                    b[side]?.placement = Pair.Placement()
                }
                return a.changes(from: b)
            }
        }
        rule("where an edit lands (Frame, + Film) taken for a change of the picture") { r in
            r.changes = { now, old in
                var out = now.changes(from: old)
                for side in Pair.Side.allCases
                where now[side]?.printScope != old[side]?.printScope || now[side]?.exposureScope != old[side]?.exposureScope {
                    out.insert(.print)
                }
                return out
            }
        }
        // What a guide is drawn from: v0.1's own key, which a tester's host was ended by (2026-10-15).
        rule("a frame's white balance in what a guide is drawn from: every tick of its ruler draws the guide again") { r in
            r.guideKey = { pair in
                pair.guideKey + Pair.Side.allCases.map { side in
                    pair[side].map { "|\($0.decode.whiteBalance.rawValue),\($0.decode.temperature),\($0.decode.tint),\($0.decode.lensCorrection)" } ?? "|-"
                }.joined()
            }
        }
        rule("a picture moved under its hole that draws no guide") { r in
            r.guideKey = { pair in
                var p = pair
                for side in Pair.Side.allCases { p[side]?.placement = Pair.Placement() }
                return p.guideKey
            }
        }
        rule("a gap typed on a strip taken for another piece, though the camera's advance decides it") { r in
            r.changes = { now, old in
                var out = now.changes(from: old)
                if now.spacingMM != old.spacingMM { out.insert(.pixels) }
                return out
            }
        }
        // The back, a frame at a time.
        rule("a frame switched on while the back is off that prints on both") { r in
            r.setDated = { pair, on, side, back in
                let other = pair[side.other]?.dated
                pair.setDated(on, side, back: &back)
                if let other { pair[side.other]?.dated = other }
            }
        }
        rule("the last frame switched off, and the back left on") { r in
            r.setDated = { pair, on, side, back in
                let was = back.active
                pair.setDated(on, side, back: &back)
                if !on { back.active = was }
            }
        }
        rule("a frame's switch that is the pair's: the other frame's goes with it") { r in
            r.setDated = { pair, on, side, back in
                pair.setDated(on, side, back: &back)
                pair[side.other]?.dated = on
            }
        }
        rule("a face chosen while neither frame prints: the back on, and printing nowhere") { r in
            r.setBack = { pair, face, back in
                let was = (pair.left?.dated, pair.right?.dated)
                pair.setBack(face, back: &back)
                if let first = was.0 { pair.left?.dated = first }
                if let second = was.1 { pair.right?.dated = second }
            }
        }
        rule("a face chosen that switches every frame on, whatever each was left at") { r in
            r.setBack = { pair, face, back in
                pair.setBack(face, back: &back)
                if face != nil { for side in Pair.Side.allCases { pair[side]?.dated = true } }
            }
        }
        rule("the back switched off from the film that forgets which frames it printed on") { r in
            r.setBack = { pair, face, back in
                pair.setBack(face, back: &back)
                if face == nil { for side in Pair.Side.allCases { pair[side]?.dated = true } }
            }
        }
        rule("the back's row naming both frames when one prints") { r in
            r.backSummary = { _, back in back.active ? back.style.label + " · both frames" : "Off" }
        }
        rule("a turned pair's back naming a left frame") { r in
            r.backSummary = { pair, back in
                var level = pair
                level.turned = false
                return level.backSummary(back)
            }
        }
        rule("a frame's own date switch written into every file: a desktop pair is not written back as it said") { r in
            r.encode = { pair in
                guard let data = try? pair.encoded(),
                      var top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                for key in ["left", "right"] {
                    guard var hole = top[key] as? [String: Any] else { continue }
                    if hole["dated"] == nil { hole["dated"] = true }
                    top[key] = hole
                }
                return try? JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys])
            }
        }
        rule("a file that forgets a frame's back was switched off") { r in
            r.encode = { pair in
                var p = pair
                p.left?.dated = true
                p.right?.dated = true
                return try? p.encoded()
            }
        }
        // A frame's own Scene Placement.
        rule("picking a frame that changes what the engine is sent") { r in
            r.show = { side, look in
                guard Pair.placementSide(look) != side else { return }
                let shown = look.sceneLatitude
                look.sceneLatitude = look.sceneLatitudeOther
                look.sceneLatitudeOther = shown
            }
        }
        rule("picking a frame that still shows the other frame's placement") { r in
            r.show = { side, look in look.placementIsRight = side == .right }
        }
        rule("a swap that leaves each placement in its hole") { r in
            r.swapLook = { pair, look in
                pair.swap()
                pair.hold(&look)
            }
        }
        rule("a frame put into a hole that takes the placement of the one that was there") { r in
            r.fillLook = { pair, side, hole, look in
                pair.fill(side, with: hole)
                pair.hold(&look)
            }
        }
        rule("a frame put into a hole that clears the other frame's placement too") { r in
            r.fillLook = { pair, side, hole, look in
                pair.fill(side, with: hole)
                look.sceneLatitude = SceneLatitudeSettings()
                look.sceneLatitudeOther = SceneLatitudeSettings()
                pair.hold(&look)
            }
        }
        rule("the placement left shown of a hole that is empty") { r in
            r.hold = { pair, look in look.pairSplit = pair.split }
        }
        rule("a pair's look held without where its second frame begins") { r in
            r.hold = { pair, look in
                let split = look.pairSplit
                pair.hold(&look)
                look.pairSplit = split
            }
        }
        rule("the frame Scene Placement is about said to be one that is not there") { r in
            r.shownSide = { _, look in Pair.placementSide(look) }
        }
        rule("the second frame's rows carrying the first frame's curve") { r in
            r.wire = { look in
                var wire = Rules.keyed(look.wire)
                for key in ["active", "highlight_knee", "highlight_room", "shadow_knee", "shadow_room"] where wire["scene_latitude_b_" + key] != nil {
                    wire["scene_latitude_b_" + key] = wire["scene_latitude_" + key]
                }
                return wire
            }
        }
        rule("a photograph sent a second frame's curve") { r in
            r.wire = { look in
                var held = look
                if held.pairSplit == 0 { held.pairSplit = 0.5 }
                return Rules.keyed(held.wire)
            }
        }
        rule("a pair sent no second curve") { r in
            r.wire = { look in Rules.keyed(look.wire).filter { !$0.key.hasPrefix("scene_latitude_b_") && $0.key != "scene_latitude_split" } }
        }
        // What the engine is asked for a frame's own print.
        rule("a print asked again for a frame that prints as the film does") { r in
            r.printLayers = { pair, look, _ in
                Pair.Side.allCases.compactMap { side in
                    guard let own = pair[side]?.print, let rect = pair.holeRects[side] else { return nil }
                    return PrintLayer(index: side.rawValue, rows: PrintLayer.rows(of: own.applied(to: look)), rect: rect)
                }
            }
        }
        rule("a frame's own print asked of a film that is scanned, which has no print") { r in
            r.printLayers = { pair, look, catalog in
                var printed = look
                printed.scanFilm = false
                printed.digitalIntermediate = false
                if catalog.isSlide(printed.filmStock) {
                    printed.filmStock = catalog.films.first { !$0.isPositive && !$0.isMonochrome }?.id ?? printed.filmStock
                }
                return pair.printLayers(look: printed, catalog: catalog)
            }
        }
        rule("a layer's rows written past the model's gates: a pre-flash sent while Print Effects is off") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map { layer in
                    var made = layer
                    if let own = Pair.Side(rawValue: layer.index).flatMap({ pair[$0]?.print }) {
                        made.rows["preflash_exposure"] = .double(own.preflashExposure)
                    }
                    return made
                }
            }
        }
        rule("a layer's brightness sent in stops, where the enlarger takes an exposure") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map { layer in
                    var made = layer
                    if let own = Pair.Side(rawValue: layer.index).flatMap({ pair[$0]?.print }) {
                        made.rows["print_exposure"] = .double(own.brightnessStops)
                    }
                    return made
                }
            }
        }
        rule("a layer made of the rows that differ from the film's and no others: not the frame's whole print") { r in
            r.printLayers = { pair, look, catalog in
                let film = PrintLayer.rows(of: look)
                return pair.printLayers(look: look, catalog: catalog).map { layer in
                    PrintLayer(index: layer.index, rows: layer.rows.filter { film[$0.key] != $0.value }, rect: layer.rect)
                }
            }
        }
        rule("the two frames' prints changed over") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map { PrintLayer(index: 1 - $0.index, rows: $0.rows, rect: $0.rect) }
            }
        }
        rule("a frame's print cut in where the other frame is") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map { layer in
                    PrintLayer(index: layer.index, rows: layer.rows, rect: pair.holeRects[layer.index == 0 ? .right : .left] ?? layer.rect)
                }
            }
        }
        rule("a frame's print cut in over the whole piece") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map {
                    PrintLayer(index: $0.index, rows: $0.rows, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
        }
        rule("a layer that names a row of the film's side: its print would develop the negative again") { r in
            r.printLayers = { pair, look, catalog in
                pair.printLayers(look: look, catalog: catalog).map { layer in
                    var made = layer
                    made.rows["grain_amount"] = .double(1)
                    return made
                }
            }
        }
        rule("a stamp that does not hold a frame's own print: its kept develop is not made again") { r in
            r.layerKey = { "print \($0.index)" }
        }
        rule("a stamp that does not say which frame prints for itself") { r in
            r.layerKey = { layer in layer.rows.keys.sorted().map { "\($0)=\(layer.rows[$0]?.description ?? "")" }.joined(separator: ";") }
        }
        rule("a stamp that holds where the frame is, which the piece says already") { r in
            r.layerKey = { $0.key + " at \($0.rect)" }
        }
        // Where a strip's frames are.
        rule("a strip's gates taken in the order they came, whichever way they lie") { r in
            r.gates = { json in
                Rules.corners(json).map { q in
                    let xs = [q[0], q[2], q[4], q[6]], ys = [q[1], q[3], q[5], q[7]]
                    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                }
            }
        }
        rule("a gate taken from two of its corners: a film a little turned loses its edge") { r in
            r.gates = { json in
                let made = Rules.corners(json).map { q in
                    CGRect(x: min(q[0], q[4]), y: min(q[1], q[5]), width: abs(q[4] - q[0]), height: abs(q[5] - q[1]))
                }
                let across = made.count == 2 && abs(made[1].midX - made[0].midX) >= abs(made[1].midY - made[0].midY)
                return made.sorted { across ? $0.minX < $1.minX : $0.minY < $1.minY }
            }
        }
        rule("a strip's gates read with the film's foot at the top") { r in
            r.gates = { FilmGates.rects($0).map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) } }
        }
        rule("gates read from a reply that says it has none") { r in
            r.gates = { FilmGates.rects($0.replacingOccurrences(of: "\"valid\":false", with: "\"valid\":true")) }
        }
        return out
    }
}

// MARK: - the piece

/// `testTheLayoutIsTwoHolesAndTheGap`, `testTurnedThePieceIsStackedAndTheHolesAreLandscape`.
func layoutChecks(_ c: inout Checker, _ rules: Rules) {
    // The drawn pair: two 1600 × 2133 pictures 1.0 mm apart.
    let l = rules.layout(2133, 1.0, false)
    c.expect(l.hole == CGSize(width: 1600, height: 2133), "held level, a hole 2133 across the film is 1600 × 2133: \(l.hole)")
    c.expect(l.advance == 1689, "the second hole starts 1689 px along, 19 of the hole's 18 mm: \(l.advance)")
    c.expect(l.size == CGSize(width: 3289, height: 2133), "the piece is 3289 × 2133: \(l.size)")
    c.expect(l.rect(.left) == CGRect(x: 0, y: 0, width: 1600, height: 2133), "the left hole at the piece's start")
    c.expect(l.rect(.right) == CGRect(x: 1689, y: 0, width: 1600, height: 2133), "the right hole one advance along: \(l.rect(.right))")
    // On a strip the piece is the gate and one advance: 37 × 24.
    c.near(Double(l.size.width / l.size.height), 37.0 / 24.0, 0.001, "the piece is 37 × 24 mm")
    // A wider gap moves only the second hole.
    let wide = rules.layout(2133, 2.0, false)
    c.expect(wide.hole == l.hole, "a wider gap leaves the holes their size")
    c.expect(wide.advance == 1778, "2.0 mm apart, the second hole starts at 1778: \(wide.advance)")
    // Hit-testing: the holes and the gap between them.
    c.expect(l.side(atNormalised: CGPoint(x: 0.2, y: 0.5)) == .left, "a tap at 0.2 across is on the left frame")
    c.expect(l.side(atNormalised: CGPoint(x: 0.8, y: 0.5)) == .right, "a tap at 0.8 across is on the right frame")
    c.expect(l.side(atNormalised: CGPoint(x: 0.5, y: 0.5)) == nil, "a tap in the middle is on the film between them")

    // Turned, the piece is stacked and the holes are landscape.
    let t = rules.layout(2400, 1.0, true)
    c.expect(t.hole == CGSize(width: 2400, height: 1800), "turned, a hole is 2400 × 1800: \(t.hole)")
    c.expect(t.size == CGSize(width: 2400, height: 3700), "turned, the piece is 2400 × 3700: \(t.size)")
    c.expect(t.rect(.left).minY == 0 && t.rect(.right).minY == 1900, "turned, the second frame is 1900 px down")
    c.expect(t.side(atNormalised: CGPoint(x: 0.5, y: 0.2)) == .left, "turned, the first frame is the upper one")
    c.expect(t.side(atNormalised: CGPoint(x: 0.5, y: 0.8)) == .right, "turned, the second is the lower one")
    c.expect(t.side(atNormalised: CGPoint(x: 0.5, y: 0.5)) == nil, "turned, the middle is the film between them")
    var pair = Pair()
    pair.turned = true
    c.near(pair.holeAspect, 24.0 / 18.0, 1e-9, "turned, the hole is 4:3")
    c.expect(rules.title(pair, .left) == "Top frame" && rules.title(pair, .right) == "Bottom frame", "turned, the frames are the top and the bottom one")
    pair.turned = false
    c.near(pair.holeAspect, 0.75, 1e-9, "held level, the hole is 3:4")
    c.expect(rules.title(pair, .left) == "Left frame" && rules.title(pair, .right) == "Right frame" && rules.title(pair, .film) == "Film",
             "held level: Film, Left frame, Right frame")

    // Over the whole of the spacing's range, at the sizes a host decodes: the gap is the spacing, the
    // holes never meet, and the piece is two holes and the gap long.
    for across in [240, 1512, 2133, 2400, 3024] {
        for spacing in stride(from: 0.5, through: 2.0, by: 0.1) {
            for turned in [false, true] {
                let l = rules.layout(across, spacing, turned)
                let along = Double(turned ? l.hole.height : l.hole.width), short = Double(turned ? l.hole.width : l.hole.height)
                let what = "\(across) px across, \(String(format: "%.1f", spacing)) mm\(turned ? ", turned" : "")"
                c.near(short, Double(across), 0.001, "\(what): the hole is as wide across the film as asked")
                c.near(along / short, 0.75, 0.5 / short, "\(what): the hole is 18 × 24")
                let gap = Double(l.advance) - along
                c.near(gap, along * spacing / 18, 0.51, "\(what): the gap is the spacing")
                c.expect(!l.rect(.left).intersects(l.rect(.right)), "\(what): the holes do not meet")
                let long = Double(turned ? l.size.height : l.size.width)
                c.near(long / short, (36 + spacing) / 24, 1.5 / short, "\(what): the piece is two holes and the gap long")
                c.expect(turned ? l.size.width == l.hole.width : l.size.height == l.hole.height, "\(what): the piece is one hole across")
            }
        }
    }
}

/// `testThePlacementCutsTheHolesShapeAndNeverShowsBase`, and the turned hole's cut.
func placementChecks(_ c: inout Checker, _ rules: Rules) {
    let source = CGSize(width: 6000, height: 4000)
    var p = Pair.Placement()
    var r = rules.sourceRect(p, source, 0.75)
    c.expect(r == CGRect(x: 1500, y: 0, width: 3000, height: 4000), "1.00× fills the hole from the middle: \(r)")
    p.x = 1
    r = rules.sourceRect(p, source, 0.75)
    c.near(Double(r.maxX), 6000, 0.001, "moved all the way, the picture's edge is the hole's")
    p.scale = 2; p.x = -1; p.y = 1
    r = rules.sourceRect(p, source, 0.75)
    c.expect(r == CGRect(x: 0, y: 2000, width: 1500, height: 2000), "2.00×, to the left and down: \(r)")
    // Out-of-range values are held, so no base ever shows in a filled hole.
    p.scale = 0.2; p.x = 9; p.y = -9
    r = rules.sourceRect(p, source, 0.75)
    c.expect(CGRect(origin: .zero, size: source).contains(r), "out-of-range values are held inside the picture: \(r)")
    c.near(Double(r.width / r.height), 0.75, 1e-9, "the cut is the hole's shape")
    let kept = rules.held(p)
    c.expect(kept.scale == 1 && kept.x == 1 && kept.y == -1, "a placement is held to 1…4 and −1…1: \(kept.scale), \(kept.x), \(kept.y)")
    var spun = Pair.Placement()
    spun.quarterTurns = 5
    c.expect(rules.held(spun).quarterTurns == 1, "five quarter turns are one")
    spun.quarterTurns = -1
    c.expect(rules.held(spun).quarterTurns == 3, "a quarter turn back is three on")
    // Turned a quarter, a landscape frame is a portrait one.
    p = Pair.Placement(); p.quarterTurns = 1
    c.expect(rules.turned(source, p) == CGSize(width: 4000, height: 6000), "turned a quarter, a landscape frame is a portrait one")
    p.quarterTurns = 2
    c.expect(rules.turned(source, p) == source, "turned half round, it is its own shape")
    // A 3:2 landscape frame fills a landscape hole from its middle.
    let wide = rules.sourceRect(.init(), source, 24.0 / 18.0)
    c.near(Double(wide.height), 4000, 0.001, "a landscape hole takes the frame's whole height")
    c.near(Double(wide.width), 4000 * 24.0 / 18.0, 0.001, "and 4:3 of it across")
    c.near(Double(wide.midX), 3000, 0.001, "from its middle")
    // Every placement, on every shape of picture: the cut is the hole's shape and inside the picture.
    for size in [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000), CGSize(width: 4032, height: 3024),
                 CGSize(width: 3024, height: 4032), CGSize(width: 3000, height: 3000)] {
        for aspect in [0.75, 24.0 / 18.0] {
            for scale in [1.0, 1.37, 2.5, 4.0] {
                for (x, y) in [(0.0, 0.0), (-1.0, 1.0), (1.0, -1.0), (0.3, 0.7)] {
                    var q = Pair.Placement()
                    q.scale = scale; q.x = x; q.y = y
                    let cut = rules.sourceRect(q, size, aspect)
                    let what = "\(Int(size.width)) × \(Int(size.height)) at \(scale)×, (\(x), \(y)), a \(aspect < 1 ? "3:4" : "4:3") hole"
                    c.expect(cut.minX >= -0.001 && cut.minY >= -0.001 && cut.maxX <= size.width + 0.001 && cut.maxY <= size.height + 0.001,
                             "\(what): the cut \(cut) is inside the picture")
                    c.near(Double(cut.width / cut.height), aspect, 1e-9, "\(what): the cut is the hole's shape")
                }
            }
        }
    }
}

/// `testADragMovesThePictureWithThePointerAndStopsAtItsEdge`.
func dragChecks(_ c: inout Checker, _ rules: Rules) {
    let source = CGSize(width: 6000, height: 4000)
    let origin = Pair.Placement()
    // A quarter of a hole to the right: the picture follows, so the cut goes left.
    let moved = rules.dragged(origin, CGSize(width: 0.25, height: 0), source, 0.75)
    let before = Pair.sourceRect(for: origin, source: source), after = Pair.sourceRect(for: moved, source: source)
    c.near(Double(after.minX), Double(before.minX - 0.25 * before.width), 0.5, "the picture follows the finger a quarter of the hole")
    c.near(Double(after.minY), Double(before.minY), 0.001, "a 3:2 frame has no slack down a portrait hole at 1.00×")
    let far = rules.dragged(origin, CGSize(width: 9, height: 0), source, 0.75)
    c.near(Double(Pair.sourceRect(for: far, source: source).minX), 0, 0.001, "held at the picture's edge")
    c.expect(far.x >= -1 && far.x <= 1, "and its placement is one a hole can show: \(far.x)")
    // A level crop becomes the same rectangle under the hole.
    var g = Geometry.default
    g.crop = CropRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
    let p = rules.fromCrop(g, source, 0.75)
    let cut = Pair.sourceRect(for: p, source: source)
    c.near(Double(cut.minX), 3000, 1, "a half frame's crop enters the pair as the same rectangle: its left edge")
    c.near(Double(cut.minY), 1000, 1, "its top")
    c.near(Double(cut.height), 2000, 1, "its height")
    // A crop that is turned is entered at the middle, turned.
    var turned = Geometry.default
    turned.quarterTurns = 1
    let q = rules.fromCrop(turned, source, 0.75)
    c.expect(q.quarterTurns == 1 && q.scale == 1 && q.x == 0 && q.y == 0, "a turned frame enters at the middle, turned")
}

/// `testAZoomHoldsThePointUnderThePointerAndLeavesThePieceItsSize`.
func zoomChecks(_ c: inout Checker, _ rules: Rules) {
    let source = CGSize(width: 4000, height: 6000)
    let aspect = 0.75
    func under(_ p: Pair.Placement, _ a: CGPoint) -> CGPoint {
        let cut = Pair.sourceRect(for: p, source: source, aspect: aspect)
        return CGPoint(x: cut.minX + a.x * cut.width, y: cut.minY + a.y * cut.height)
    }
    var p = Pair.Placement()
    p.scale = 1.5
    let anchor = CGPoint(x: 0.7, y: 0.4)
    let before = under(p, anchor)
    let zoomed = rules.zoomed(p, 1.6, anchor, source, aspect)
    c.near(zoomed.scale, 2.4, 1e-9, "1.5× pinched by 1.6 is 2.4×")
    c.near(Double(under(zoomed, anchor).x), Double(before.x), 0.5, "what is under the fingers stays under them, across")
    c.near(Double(under(zoomed, anchor).y), Double(before.y), 0.5, "and down")
    // And back out again: the same point, as far as the picture's edge allows.
    let back = rules.zoomed(zoomed, 1 / 1.6, anchor, source, aspect)
    c.near(back.scale, 1.5, 1e-9, "pinched back, it is 1.5× again")
    c.near(Double(under(back, anchor).x), Double(before.x), 0.5, "and the same point is under the fingers")
    // The ends.
    c.expect(rules.zoomed(p, 100, anchor, source, aspect).scale == 4, "a pinch stops at 4×")
    let out = rules.zoomed(p, 0.01, anchor, source, aspect)
    c.expect(out.scale == 1, "and at the hole's fill, 1×: \(out.scale)")
    let whole = Pair.sourceRect(for: out, source: source, aspect: aspect)
    c.expect(whole.minX >= -0.5 && whole.maxX <= source.width + 0.5 && whole.minY >= -0.5 && whole.maxY <= source.height + 0.5,
             "pinched all the way out, the cut is inside the picture")

    // The piece's size is the frames' fit, whatever one of them is zoomed to.
    var pair = Pair()
    pair.left = Pair.Hole(path: "a.tif")
    pair.right = Pair.Hole(path: "b.tif")
    let sizes: [Pair.Side: CGSize] = [.left: source, .right: source]
    let plain = rules.pieceLayout(pair, sizes)
    pair.left?.placement.scale = 3
    c.expect(rules.pieceLayout(pair, sizes).size == plain.size, "a zoom does not resize the piece")
}

/// `testThePieceDecodesAsBothPicturesWithUnexposedFilmBetween` (its sizes), and the rest of
/// `PairComposer.layout(for:sizes:)`.
func pieceChecks(_ c: inout Checker, _ rules: Rules) {
    for one in [CGSize(width: 6000, height: 4000), CGSize(width: 4000, height: 6000), CGSize(width: 8256, height: 5504),
                CGSize(width: 4032, height: 3024), CGSize(width: 1024, height: 683)] {
        for turned in [false, true] {
            var pair = Pair()
            pair.turned = turned
            pair.left = Pair.Hole(path: "a")
            pair.right = Pair.Hole(path: "b")
            let layout = rules.pieceLayout(pair, [.left: one, .right: one])
            let what = "two \(Int(one.width)) × \(Int(one.height)) frames\(turned ? ", turned" : "")"
            // Two half frames are one frame's worth of film: the piece is no longer than the frame it
            // was made from, and neither picture is enlarged.
            c.expect(max(layout.size.width, layout.size.height) <= max(one.width, one.height),
                     "\(what): the piece, \(layout.size), is no longer than a frame")
            let fit = Pair.sourceRect(for: .init(), source: one, aspect: pair.holeAspect)
            c.expect(layout.hole.height <= fit.height + 0.001 && layout.hole.width <= fit.width + 0.001,
                     "\(what): a hole of \(layout.hole) enlarges neither picture's \(fit.size)")
            c.expect(layout.turned == turned, "\(what): laid out the way the camera was held")
        }
    }
    // The smaller picture sets the holes.
    var mixed = Pair()
    mixed.left = Pair.Hole(path: "large")
    mixed.right = Pair.Hole(path: "small")
    let small = CGSize(width: 1200, height: 1600), large = CGSize(width: 6000, height: 8000)
    let m = rules.pieceLayout(mixed, [.left: large, .right: small])
    c.expect(m.hole.height <= 1600 && m.hole.width <= 1200, "a small frame beside a large one sets the holes: \(m.hole)")
    // An empty pair takes a nominal size, and one hole filled is laid out for that frame.
    let empty = rules.pieceLayout(Pair(), [:])
    c.expect(empty.hole == CGSize(width: 1800, height: 2400), "an empty pair is laid out at a nominal 1800 × 2400 a hole: \(empty.hole)")
    var half = Pair()
    half.left = Pair.Hole(path: "only")
    let h = rules.pieceLayout(half, [.left: CGSize(width: 3024, height: 4032)])
    c.expect(h.size.width <= 4032 && h.hole.height <= 4032 && h.hole.height > 1000, "one frame in, the piece is laid out for it: \(h.size)")
    // The piece's spacing: the user's within 0.5–2.0 mm, the camera's on a strip.
    var spaced = Pair()
    spaced.spacingMM = 9
    c.expect(rules.spacing(spaced) == 2.0, "spacing is held to 0.5–2.0 mm: \(rules.spacing(spaced))")
    spaced.spacingMM = 0.1
    c.expect(rules.spacing(spaced) == 0.5, "and from below: \(rules.spacing(spaced))")
    spaced.spacingMM = 1.6
    c.expect(rules.spacing(spaced) == 1.6, "1.6 mm is 1.6 mm")
    spaced.onStrip = true
    c.expect(rules.spacing(spaced) == 1.0, "on a strip the camera's advance decides the gap: 1.0 mm")
    c.expect(spaced.pieceLongMM == 37, "and the piece is the gate and one advance, 37 mm")
    c.expect(Pair.holeMM.along + 1.0 == Pair.stripAdvanceMM, "which is the engine's own advance, 19 mm")
    // The piece as it lies, for a page to draw it: 37 × 24 mm held level, 24 × 37 turned.
    var lying = Pair()
    c.expect(lying.pieceSizeMM == CGSize(width: 37, height: 24), "held level the piece lies 37 × 24 mm: \(lying.pieceSizeMM)")
    lying.turned = true
    c.expect(lying.pieceSizeMM == CGSize(width: 24, height: 37), "turned, 24 × 37 mm: \(lying.pieceSizeMM)")
    lying.spacingMM = 2.0
    c.expect(lying.pieceSizeMM == CGSize(width: 24, height: 38), "and a wider gap is a longer piece: \(lying.pieceSizeMM)")
    for turned in [false, true] {
        lying.turned = turned
        let l = lying.layout(forPiece: CGSize(width: lying.pieceSizeMM.width * 100, height: lying.pieceSizeMM.height * 100))
        c.near(Double(l.size.width / l.size.height), Double(lying.pieceSizeMM.width / lying.pieceSizeMM.height), 1e-6,
               "the piece in millimetres is the shape of the piece in pixels\(turned ? ", turned" : "")")
    }
    // A hole's size does not move with the gap: widening it must not render both pictures again.
    var gapped = Pair()
    gapped.left = Pair.Hole(path: "a"); gapped.right = Pair.Hole(path: "b")
    let frames: [Pair.Side: CGSize] = [.left: CGSize(width: 4000, height: 6000), .right: CGSize(width: 4000, height: 6000)]
    let narrow = rules.pieceLayout(gapped, frames)
    gapped.spacingMM = 2.0
    c.expect(rules.pieceLayout(gapped, frames).hole == narrow.hole, "a wider gap leaves the holes their pixels")
}

/// `testEachFrameHasItsOwnPlacementAndDateOnTheWire` (the split), `testTheRightRailIsAboutThePickedFrame`
/// and `testAnOlderPairsFilmFormatIsTheHalfFrames` (the film's size).
func wireChecks(_ c: inout Checker, _ rules: Rules) {
    var pair = Pair()
    c.near(rules.split(pair), 0.5, 0.001, "the second frame's curve takes over at the middle of the gap, half way along")
    c.near(pair.fitRegion(.left)[0], 0, 1e-9, "the first frame's region starts at the piece's start")
    c.expect(pair.fitRegion(.right)[0] > 0.5, "the second frame's region starts past the middle: \(pair.fitRegion(.right)[0])")
    c.expect(pair.fitRegion(.left)[2] < rules.split(pair) && rules.split(pair) < pair.fitRegion(.right)[0],
             "the split lies in the gap, between the two frames")
    for spacing in [0.5, 1.0, 1.4, 2.0] {
        for turned in [false, true] {
            pair.spacingMM = spacing
            pair.turned = turned
            let s = rules.split(pair), a = pair.fitRegion(.left), b = pair.fitRegion(.right)
            let (endA, startB) = turned ? (a[3], b[1]) : (a[2], b[0])
            c.expect(endA < s && s < startB, "\(spacing) mm\(turned ? ", turned" : ""): the split, \(s), is in the gap \(endA)…\(startB)")
            c.near(s, (endA + startB) / 2, 1e-9, "\(spacing) mm\(turned ? ", turned" : ""): at its middle")
            c.near(s, 0.5, 1e-9, "and the gap's middle is the piece's")
        }
    }
    pair = Pair()
    c.near(rules.filmFormat(pair, 24), 37, 0.001, "a half frame, 24 mm long: the engine is told the piece, 37 mm")
    c.near(rules.filmFormat(pair, 36), 37.0 * 36 / 24, 0.001, "a larger frame's piece is as much larger")
    pair.spacingMM = 2.0
    c.near(rules.filmFormat(pair, 24), 38, 0.001, "2.0 mm apart, the piece is 38 mm")
    pair.onStrip = true
    c.near(rules.filmFormat(pair, 24), 37, 0.001, "on a strip it is 37 again")
    c.expect(Pair.gain(stops: 1) == 2 && Pair.gain(stops: 0) == 1 && Pair.gain(stops: -1) == 0.5, "a stop is a doubling of the picture")
}

/// The host's own rule (the owner, 2026-10-09): "the pair mode where you entered with one image, instead
/// of pairing right from the frame, you should not be granted the ability to swap out the original image,
/// only to exchange places." No test of the desktop's: the desktop has no such rule.
func entryChecks(_ c: inout Checker, _ rules: Rules) {
    let a = UUID(), b = UUID(), x = UUID()
    func hole(_ id: UUID) -> Pair.Hole { Pair.Hole(path: id.uuidString, frame: id) }
    var one = Pair()
    one.left = hole(a)
    c.expect(rules.soleFrame(one) == a, "one frame, in the first hole: the page is entered with it")
    var other = Pair()
    other.right = hole(a)
    c.expect(rules.soleFrame(other) == a, "one frame, in the second hole: entered with it as well")
    c.expect(rules.soleFrame(Pair()) == nil, "an empty piece is entered with nothing")
    var two = Pair()
    two.left = hole(a)
    two.right = hole(b)
    c.expect(rules.soleFrame(two) == nil, "two frames: neither is the one the page was entered with")
    var path = Pair()
    path.left = Pair.Hole(path: "a desktop pair's.dng", frame: nil)
    c.expect(rules.soleFrame(path) == nil, "a hole that names no frame of the library holds nothing")

    // Entered with `a`; the second hole filled since.
    var pair = one
    pair.right = hole(b)
    c.expect(!rules.mayChange(pair, .left, a), "the frame the page was entered with is not replaced or removed")
    c.expect(rules.mayChange(pair, .right, a), "the frame added beside it is")
    // It exchanges places, and the rule goes with the frame, not with the hole.
    rules.swap(&pair)
    c.expect(pair.right?.frame == a && pair.left?.frame == b, "Swap moves it to the other hole")
    c.expect(!rules.mayChange(pair, .right, a), "in the other hole it is still the frame that stays")
    c.expect(rules.mayChange(pair, .left, a), "and the frame now in the hole it left is free")
    // Alone in the piece, wherever it is.
    c.expect(!rules.mayChange(one, .left, a), "alone in the piece, it stays")
    c.expect(rules.mayChange(one, .right, a), "the empty hole beside it takes any frame")
    var moved = one
    rules.swap(&moved)
    c.expect(moved.left == nil && moved.right?.frame == a, "alone, Swap moves it into the second hole")
    c.expect(!rules.mayChange(moved, .right, a) && rules.mayChange(moved, .left, a), "and it stays there")
    // The same frame under both holes: either may go while the other still holds it.
    var twice = one
    twice.right = hole(a)
    c.expect(rules.mayChange(twice, .left, a) && rules.mayChange(twice, .right, a), "under both holes, either may go: the other still holds it")
    twice.left = hole(x)
    c.expect(!rules.mayChange(twice, .right, a) && rules.mayChange(twice, .left, a), "the last hole that holds it keeps it")
    // A page entered with two frames, or with none, holds nothing.
    c.expect(rules.mayChange(two, .left, nil) && rules.mayChange(two, .right, nil), "entered with two frames, either is replaced or removed")
    c.expect(rules.mayChange(two, .left, rules.soleFrame(two)) && rules.mayChange(two, .right, rules.soleFrame(two)),
             "which is what a start on two frames says")
    c.expect(rules.mayChange(two, .left, x) && rules.mayChange(two, .right, x), "a frame that is not in the piece holds no hole")
}

/// A pair's dates: each frame its own, and only a frame that is there. The desktop's
/// `testEachFrameHasItsOwnPlacementAndDateOnTheWire` has both frames; an empty hole is the host's to hold.
func dateChecks(_ c: inout Checker, _ rules: Rules) {
    var back = DateBackSettings()
    back.active = true
    var strip = FilmEdgeSettings()
    strip.active = true
    strip.format = .half
    var bare = FilmEdgeSettings()
    bare.format = .half
    for (edge, place) in [(strip, "on its strip"), (bare, "on the bare piece")] {
        let both = rules.dateRows(back, "'26 10 7", "'26 10 8", edge)
        c.expect(both["date_imprint_active"] == .bool(true), "\(place): a date in each frame is on")
        c.expect(both["date_imprint_text"] == .string("'26 10 7") && both["date_imprint_text_b"] == .string("'26 10 8"),
                 "\(place): each frame its own date")
        c.expect(both["overscan_pair"] == .bool(true) && both["overscan_format"] == .string("135_half"),
                 "\(place): the engine is told the frame is a pair of half frames")
        c.expect(both["date_imprint_size"] == .double(back.wireSize(on: .half)), "\(place): the date is sized for a half frame")
        let second = rules.dateRows(back, "", "'26 10 8", edge)
        c.expect(second["date_imprint_active"] == .bool(true), "\(place), the first hole empty: the second frame's date is still printed")
        c.expect(second["date_imprint_text"] == .string("") && second["date_imprint_text_b"] == .string("'26 10 8"),
                 "\(place), the first hole empty: nothing in it, the second frame's date in the second")
        c.expect(second["overscan_pair"] == .bool(true), "\(place), the first hole empty: still a pair")
        for key in ["date_imprint_style", "date_imprint_placement", "date_imprint_corner", "date_imprint_size", "date_imprint_ev",
                    "date_imprint_inset_x", "date_imprint_inset_y"] {
            c.expect(second[key] == both[key] && second[key] != nil, "\(place), the first hole empty: \(key) as with both frames")
        }
        let first = rules.dateRows(back, "'26 10 7", "", edge)
        c.expect(first["date_imprint_active"] == .bool(true) && first["date_imprint_text"] == .string("'26 10 7")
                 && first["date_imprint_text_b"] == .string(""), "\(place), the second hole empty: the first frame's date alone")
        let none = rules.dateRows(back, "", "", edge)
        c.expect(none["date_imprint_active"] == .bool(false) && none["date_imprint_text_b"] == nil, "\(place): no frame, no date")
        // Words typed by hand are a frame's too: an empty hole was never exposed.
        var typed = back
        typed.customText = "HELLO"
        let words = rules.dateRows(typed, "", "HELLO", edge)
        c.expect(words["date_imprint_active"] == .bool(true) && words["date_imprint_text"] == .string("")
                 && words["date_imprint_text_b"] == .string("HELLO"), "\(place): typed words are not printed in an empty hole")
        var off = back
        off.active = false
        c.expect(rules.dateRows(off, "'26 10 7", "'26 10 8", edge)["date_imprint_active"] == .bool(false), "\(place): the back off, no date")
    }
}

/// `testAHoleEditChangesThatHoleAndNothingElse`, `testTheRightRailIsAboutThePickedFrame`.
func editChecks(_ c: inout Checker, _ rules: Rules) {
    var pair = Pair()
    pair.left = Pair.Hole(path: "frame-00.png", frame: UUID())
    pair.right = Pair.Hole(path: "frame-01.png", frame: UUID())
    let first = pair.left
    pair.right?.placement.scale = 1.5
    pair.right?.placement.x = 0.25
    c.expect(pair.left == first, "a placement on the right hole leaves the left one")
    var look = FilmParams()
    rules.expose(&pair, 0.5, .left, &look)
    c.expect(pair.left?.exposureEV == 0.5 && pair.right?.exposureEV == 0, "an exposure lands on its own hole")
    c.expect(look.printBrightnessStops == 0, "exposure starts on the frame alone: the film's print is not moved")
    // Swapped, a hole's placement and exposure travel with its frame.
    rules.swap(&pair)
    c.expect(pair.left?.path == "frame-01.png" && pair.right?.path == "frame-00.png", "swapped, each frame is in the other hole")
    c.expect(pair.left?.placement.scale == 1.5, "a hole's placement travels with its frame")
    c.expect(pair.right?.exposureEV == 0.5, "and its exposure")
    // + Film: the film's print brightness moves by the same stops, so the rebate follows the frame.
    pair.right?.exposureScope = .film
    rules.expose(&pair, 1.5, .right, &look)
    c.near(look.printBrightnessStops, 1.0, 1e-9, "+ Film: the film's print follows by the same amount")
    c.expect(pair.right?.exposureEV == 1.5 && pair.left?.exposureEV == 0, "and the frame is the one that was asked")
    rules.expose(&pair, 1.5, .right, &look)
    c.near(look.printBrightnessStops, 1.0, 1e-9, "the same value again moves nothing")
    rules.expose(&pair, 9, .right, &look)
    c.expect(pair.right?.exposureEV == 5, "a hole's exposure is held to ±5 stops: \(pair.right?.exposureEV ?? .nan)")
    c.expect(look.printBrightnessStops <= 3, "and the film's print to the enlarger's own ±3: \(look.printBrightnessStops)")
    // On an empty hole it is nothing.
    var one = Pair()
    one.left = Pair.Hole(path: "only")
    var untouched = FilmParams()
    rules.expose(&one, 1, .right, &untouched)
    c.expect(one.right == nil && untouched == FilmParams(), "an empty hole has no exposure to set")
    c.expect(!one.isFilled && pair.isFilled, "a pair with an empty hole is not filled")
    c.expect(pair.isComplete { _ in true } && !pair.isComplete { $0.path != "frame-00.png" } && !one.isComplete { _ in true },
             "a pair is complete when both its frames are still there")

    // Each hole is exposed as the meter would expose it alone, plus its own.
    var metered = Pair()
    metered.left = Pair.Hole(path: "a")
    metered.right = Pair.Hole(path: "b")
    c.expect(rules.stops(metered, .left) == nil, "a hole the meter has not read has no exposure yet")
    metered.left?.meteredEV = 0.4375
    metered.left?.exposureEV = 0.5
    c.expect(rules.stops(metered, .left) == 0.9375, "the meter's reading and the hole's own")
    metered.left?.autoExposure = false
    c.expect(rules.stops(metered, .left) == 0.5, "its meter off, the hole's own and nothing else")
    metered.right?.autoExposure = false
    c.expect(rules.stops(metered, .right) == 0, "and a hole with its meter off needs no reading")
    c.expect(rules.stops(Pair(), .left) == nil, "an empty hole has none")

    // A placement does not re-meter; the frame's decode, its crop and the intent do.
    var hole = Pair.Hole(path: "a", frame: UUID())
    let key = rules.meterKey(hole, "balanced")
    hole.placement.scale = 2; hole.placement.x = 0.5
    c.expect(rules.meterKey(hole, "balanced") == key, "a picture moved under its hole is not metered again")
    c.expect(rules.meterKey(hole, "highlights") != key, "another intent is another reading")
    var warm = hole
    warm.decode.temperature = 4000
    c.expect(rules.meterKey(warm, "balanced") != key, "another white balance is another reading")
    var cropped = hole
    cropped.geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
    c.expect(rules.meterKey(cropped, "balanced") != key, "the frame's own crop is another reading")
    c.expect(rules.meterKey(Pair.Hole(path: "a", frame: UUID()), "balanced") != key, "another frame is another reading")

    // The shot stays the frame's: its decode and its own crop are read again when the pair is opened.
    var kept = Pair()
    kept.left = hole
    kept.right = Pair.Hole(path: "b", frame: UUID())
    let other = kept.right
    c.expect(!kept.mirror(.left, decode: hole.decode, geometry: hole.geometry), "a frame as it was left mirrors nothing")
    c.expect(kept.left == hole, "and its hole is as it was")
    c.expect(kept.mirror(.left, decode: warm.decode, geometry: cropped.geometry), "a frame whose shot has moved is mirrored again")
    c.expect(kept.left?.decode == warm.decode && kept.left?.geometry == cropped.geometry, "its hole reads the frame's own decode and crop")
    c.expect(kept.left?.placement == hole.placement && kept.left?.exposureEV == hole.exposureEV,
             "and keeps its own placement and exposure")
    c.expect(kept.left.map { rules.meterKey($0, "balanced") } != key, "so its meter reads again")
    c.expect(kept.right == other, "the other hole is not touched")
    var bare = Pair()
    c.expect(!bare.mirror(.left, decode: warm.decode, geometry: cropped.geometry) && bare.left == nil, "an empty hole mirrors nothing")
}

// MARK: - what each frame has for itself

/// The camera held the other way (a tester, the owner's to take up, 2026-10-20: two landscape
/// pictures switched to side by side were cut into upright strips). Each picture lies the way
/// its hole does after the switch, and the switch back gives it its own turn again.
func cameraChecks(_ c: inout Checker, _ rules: Rules) {
    let wide = CGSize(width: 6000, height: 4000), tall = CGSize(width: 4000, height: 6000)
    var pair = bothFrames()
    pair.turned = true                                    // two landscape frames start one above the other
    rules.holdCamera(&pair, false, [.left: wide, .right: wide])
    c.expect(!pair.turned, "Level: the holes are side by side")
    for side in Pair.Side.allCases {
        let p = pair[side]?.placement ?? .init()
        c.expect(p.quarterTurns == 1, "Level: the \(side) landscape picture is turned a quarter, clockwise: \(p.quarterTurns)")
        let cut = rules.sourceRect(p, rules.turned(wide, p), pair.holeAspect)
        c.near(Double(cut.width), 4000, 0.001, "Level: the \(side) picture's whole short side is in its upright hole")
    }
    rules.holdCamera(&pair, true, [.left: wide, .right: wide])
    c.expect(Pair.Side.allCases.allSatisfy { pair[$0]?.placement.quarterTurns == 0 },
             "Turned again: both pictures have their own turn back")
    // A portrait and a landscape held level: turned, only the portrait one lies down.
    var mixed = bothFrames()
    rules.holdCamera(&mixed, true, [.left: tall, .right: wide])
    c.expect(mixed.left?.placement.quarterTurns == 1 && mixed.right?.placement.quarterTurns == 0,
             "Turned: the upright picture lies down, the wide one is left as it lay")
    // A square picture, and a switch to where the camera already is: nothing moves.
    var square = bothFrames()
    square.turned = true
    rules.holdCamera(&square, false, [.left: CGSize(width: 3000, height: 3000)])
    c.expect(square.left?.placement.quarterTurns == 0 && square.right?.placement.quarterTurns == 0,
             "a square picture, and an empty hole's frame of no known size, are not turned")
    var still = bothFrames()
    still.left?.placement.x = 0.5
    rules.holdCamera(&still, false, [.left: tall, .right: tall])
    c.expect(still.left?.placement == bothFrames().left.map { var p = $0.placement; p.x = 0.5; return p },
             "the camera held as it is: nothing moves")
    // A picture moved under its hole is centred again when it turns; its zoom is kept.
    var moved = bothFrames()
    moved.turned = true
    moved.left?.placement.x = 0.8; moved.left?.placement.scale = 2
    rules.holdCamera(&moved, false, [.left: wide, .right: wide])
    c.expect(moved.left?.placement.x == 0 && moved.left?.placement.y == 0 && moved.left?.placement.scale == 2,
             "turned, the picture is centred under its hole and keeps its zoom")
}

/// A pair with both its holes filled.
func bothFrames() -> Pair {
    var pair = Pair()
    pair.left = Pair.Hole(path: "frame-00.png", frame: UUID())
    pair.right = Pair.Hole(path: "frame-01.png", frame: UUID())
    return pair
}

func trim(brightness: Double = 0, yellow: Double = 0, magenta: Double = 0, preflash: Double = 0) -> Pair.PrintTrim {
    var t = Pair.PrintTrim()
    t.brightnessStops = brightness
    t.yFilterShift = yellow
    t.mFilterShift = magenta
    t.preflashExposure = preflash
    return t
}

/// `testAFramesOwnPrintAndGradeChangeThatFrameOnly` (what it holds of the model: its pixels are
/// `tools/pair_check.sh`'s), `testTheFilmsEnlargerMovesFramesThatPrintForThemselves`, and
/// `Session.resetEnlarger`, `setHoleExposure`.
func printChecks(_ c: inout Checker, _ rules: Rules) {
    // One negative, three prints: the second frame alone, a stop and a half brighter.
    var pair = bothFrames(), look = FilmParams()
    c.expect(!rules.isLayered(pair, look), "nothing is cut together until a frame has a print of its own")
    c.expect(rules.shownTrim(pair, .right, look) == Pair.PrintTrim(look), "a frame that prints as the film does shows the film's values")
    pair.right?.printScope = .frame
    rules.trim(&pair, .brightness, 1.5, .right, &look)
    c.expect(rules.isLayered(pair, look), "a frame with a print of its own: the piece is cut together")
    c.expect(look.printBrightnessStops == 0, "Frame: the film's print is not moved (\(look.printBrightnessStops))")
    c.expect(pair.right?.print?.brightnessStops == 1.5, "the frame's own print is 1.5 stops brighter")
    c.expect(rules.shownTrim(pair, .right, look).brightnessStops == 1.5, "the Print tab shows the picked frame's value")
    c.expect(pair.left?.print == Pair.PrintTrim(look), "the other frame is given a print of its own first, at what the film prints with")
    c.expect(rules.shownTrim(pair, .left, look).brightnessStops == 0 && rules.shownTrim(pair, .film, look).brightnessStops == 0,
             "and with the other frame, or the film, picked the Print tab shows 0")
    // + Film on the first frame: it and the film go up a stop; the second, which has a print of its own, stays.
    c.expect(pair.left?.printScope == .film, "the enlarger starts on the film as well")
    rules.trim(&pair, .brightness, 1.0, .left, &look)
    c.near(look.printBrightnessStops, 1.0, 1e-9, "+ Film: the film's print follows by the same amount")
    c.expect(pair.left?.print?.brightnessStops == 1.0 && pair.right?.print?.brightnessStops == 1.5,
             "+ Film moves its frame and the film, and not the other frame")
    let (same, sameLook) = (pair, look)
    rules.trim(&pair, .brightness, 1.0, .left, &look)
    c.expect(pair == same && look == sameLook, "the same value again moves nothing")
    // + Film keeps the frame and the film as far apart as they were.
    rules.trim(&pair, .brightness, 2.0, .right, &look)           // Frame: the film stays at 1.0
    pair.right?.printScope = .film
    rules.trim(&pair, .brightness, 2.5, .right, &look)
    c.near(look.printBrightnessStops, 1.5, 1e-9, "+ Film from a frame a stop over the film: both move, a stop apart still")
    c.expect(pair.left?.print?.brightnessStops == 1.0, "and the other frame stays where it was")

    // With the film picked the enlarger is the whole piece's: a frame with a print of its own moves
    // with the film and keeps its distance from it.
    pair = bothFrames(); look = FilmParams()
    pair.left?.printScope = .frame
    rules.trim(&pair, .brightness, 1, .left, &look)
    rules.trim(&pair, .yellow, 0.25, .left, &look)
    c.expect(pair.left?.print?.brightnessStops == 1 && pair.right?.print?.brightnessStops == 0, "a frame's own brightness, the other pinned at the film's 0")
    rules.trim(&pair, .brightness, 0.5, .film, &look)
    rules.trim(&pair, .yellow, -0.5, .film, &look)
    c.expect(look.printBrightnessStops == 0.5, "the film's print is 0.5")
    c.expect(pair.left?.print?.brightnessStops == 1.5 && pair.right?.print?.brightnessStops == 0.5,
             "the frames move with the film by the same amount: 1.5 and 0.5")
    c.near(pair.left?.print?.yFilterShift ?? .nan, -0.25, 1e-9, "the first frame's yellow keeps its distance: -0.25")
    c.near(pair.right?.print?.yFilterShift ?? .nan, -0.5, 1e-9, "the second frame's is the film's: -0.5")
    rules.trim(&pair, .brightness, 3, .film, &look)
    c.expect(pair.left?.print?.brightnessStops == 3, "within the control's range, whatever the film asks")
    // Reset on the film is the piece as one print again.
    rules.resetPrint(&pair, .film, &look)
    c.expect(look.printBrightnessStops == 0 && look.yFilterShift == 0, "the film's reset is a plain print")
    c.expect(pair.left?.print == nil && pair.right?.print == nil && !rules.isLayered(pair, look), "with every frame printing as the film again: one print")

    // The film's print with no frame printing for itself gives none a print of its own.
    pair = bothFrames(); look = FilmParams()
    rules.trim(&pair, .magenta, 0.3, .film, &look)
    c.expect(look.mFilterShift == 0.3 && pair.left?.print == nil && pair.right?.print == nil && !rules.isLayered(pair, look),
             "the film's print alone is one print")
    // What the enlarger takes of each (the desktop's `Session.clamped`).
    for (field, low, high) in [(PrintField.brightness, -3.0, 3.0), (.yellow, -1.0, 1.0), (.magenta, -1.0, 1.0), (.preflash, 0.0, 0.03)] {
        var p = bothFrames(), l = FilmParams()
        p.right?.printScope = .frame
        rules.trim(&p, field, 99, .right, &l)
        c.expect(p.right?.print?[field] == high, "\(field.rawValue) on a frame stops at \(high): \(p.right?.print?[field] ?? .nan)")
        rules.trim(&p, field, -99, .right, &l)
        c.expect(p.right?.print?[field] == low, "\(field.rawValue) on a frame stops at \(low): \(p.right?.print?[field] ?? .nan)")
        c.expect(Pair.PrintTrim(l)[field] == 0, "and on Frame the film's \(field.rawValue) is not moved")
        rules.trim(&p, field, 99, .film, &l)
        c.expect(Pair.PrintTrim(l)[field] == high, "\(field.rawValue) on the film stops at \(high)")
    }
    // With an empty hole picked the enlarger is the film's.
    var one = Pair(), oneLook = FilmParams()
    one.left = Pair.Hole(path: "only", frame: UUID())
    rules.trim(&one, .brightness, 0.5, .right, &oneLook)
    c.expect(oneLook.printBrightnessStops == 0.5 && one.left?.print == nil && one.right == nil, "with an empty hole picked the enlarger is the film's")
    c.expect(rules.shownTrim(one, .right, oneLook) == Pair.PrintTrim(oneLook), "and the Print tab shows the film's")

    // Reset on a frame: its own print to a plain one, the other keeping what it had.
    pair = bothFrames(); look = FilmParams()
    look.printBrightnessStops = 0.5
    pair.right?.printScope = .frame
    rules.trim(&pair, .yellow, 0.4, .right, &look)
    rules.resetPrint(&pair, .right, &look)
    c.expect(pair.right?.print == Pair.PrintTrim(), "a frame's reset is a plain print: neutral, not the film's")
    c.expect(pair.left?.print == Pair.PrintTrim(look) && look.printBrightnessStops == 0.5 && look.yFilterShift == 0,
             "the other frame and the film keep what they had")
    c.expect(rules.isLayered(pair, look), "so a plain frame beside a film at +0.5 is still its own print")
    pair = bothFrames()
    rules.resetPrint(&pair, .left, &look)
    c.expect(pair.left?.print == Pair.PrintTrim() && pair.right?.print == Pair.PrintTrim(look),
             "a reset of a frame that printed as the film pins the other at the film's first")
    // Every frame that prints as the film is pinned, and no other.
    pair = bothFrames()
    pair.left?.print = trim(brightness: 1)
    rules.pinPrints(&pair, trim(brightness: 0.25))
    c.expect(pair.left?.print == trim(brightness: 1) && pair.right?.print == trim(brightness: 0.25), "a print is pinned on a frame that has none, and never over one it has")
    var solo = Pair()
    solo.right = Pair.Hole(path: "only", frame: UUID())
    rules.pinPrints(&solo, trim(yellow: 0.1))
    c.expect(solo.left == nil && solo.right?.print == trim(yellow: 0.1), "and nothing is pinned on an empty hole")
    // A print that is the film's own is no second print.
    pair = bothFrames(); look = FilmParams()
    look.mFilterShift = 0.2
    pair.left?.print = Pair.PrintTrim(look)
    c.expect(!rules.isLayered(pair, look), "a frame whose print is what the film prints with: one print")
    pair.left?.print?.preflashExposure = 0.01
    c.expect(rules.isLayered(pair, look), "any of the four values its own: cut together")
    c.expect(!rules.isLayered(Pair(), look), "an empty piece is not cut together")

    // An exposure applied to the film as well: both frames are given the print the film had first,
    // so that what moves is the film round them (the desktop's `Session.setHoleExposure`).
    pair = bothFrames(); look = FilmParams()
    look.printBrightnessStops = 0.25
    pair.right?.exposureScope = .film
    rules.expose(&pair, 1, .right, &look)
    c.near(look.printBrightnessStops, 1.25, 1e-9, "+ Film on an exposure: the film's print follows by the same stops")
    c.expect(pair.left?.print?.brightnessStops == 0.25 && pair.right?.print?.brightnessStops == 0.25,
             "and both frames keep the print the film had: neither rides along")
    c.expect(rules.isLayered(pair, look), "so the piece is cut together: the film moved, the frames' prints did not")
    rules.expose(&pair, 2, .right, &look)
    c.near(look.printBrightnessStops, 2.25, 1e-9, "a further stop moves the film a further stop")
    c.expect(pair.left?.print?.brightnessStops == 0.25 && pair.right?.print?.brightnessStops == 0.25, "and the frames' prints stay pinned where they were")
    pair = bothFrames(); look = FilmParams()
    rules.expose(&pair, 1, .left, &look)
    c.expect(pair.left?.print == nil && pair.right?.print == nil && !rules.isLayered(pair, look), "an exposure on the frame alone pins nothing")
}

/// What an edit of the piece owes its picture (`HalfFramePair.changes`). The host's own: the
/// desktop's session is told edit by edit (`updatePair(redecode:rerender:)`).
func changeChecks(_ c: inout Checker, _ rules: Rules) {
    let base = bothFrames()
    c.expect(rules.changes(base, base).isEmpty, "the same piece owes its picture nothing")
    func after(_ change: (inout Pair) -> Void) -> Set<Pair.Change> {
        var now = base
        change(&now)
        return rules.changes(now, base)
    }
    c.expect(after { $0.left?.meteredEV = 0.4375; $0.left?.meteredFor = "its key" }.isEmpty,
             "a meter's reading kept in the pair is no change: the develop that read it is already of it")
    let pixels: [(String, (inout Pair) -> Void)] = [
        ("a picture enlarged under its hole", { $0.left?.placement.scale = 2 }),
        ("a picture moved under its hole", { $0.right?.placement.x = 0.5 }),
        ("a picture turned under its hole", { $0.right?.placement.quarterTurns = 1 }),
        ("a frame's exposure", { $0.left?.exposureEV = 0.5 }),
        ("another frame in a hole", { $0.left?.frame = UUID() }),
        ("another file in a hole", { $0.left?.path = "frame-09.png" }),
        ("a frame's meter switched off", { $0.right?.autoExposure = false }),
        ("a frame's own meter intent", { $0.right?.meterMethod = "protect_highlights" }),
        ("a frame's white balance", { $0.left?.decode.temperature = 4000 }),
        ("a frame's own crop", { $0.left?.geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5) }),
        ("a frame taken out of its hole", { $0.right = nil }),
        ("the camera turned", { $0.turned = true }),
        ("the pair put on its strip", { $0.onStrip = true }),
        ("a wider gap", { $0.spacingMM = 1.6 }),
    ]
    for (what, change) in pixels {
        c.expect(after(change) == [.pixels], "\(what): other pixels, the piece is composed again (\(after(change)))")
    }
    var half = Pair()
    half.left = base.left
    var filled = half
    filled.right = base.right
    c.expect(rules.changes(filled, half) == [.pixels], "an empty hole filled: other pixels")
    // On a strip the camera's advance decides the gap: a spacing typed there moves no pixel.
    var strip = base
    strip.onStrip = true
    var respaced = strip
    respaced.spacingMM = 1.6
    c.expect(rules.changes(respaced, strip).isEmpty, "on a strip a spacing changes nothing: the gap is the camera's 1.0 mm")
    // What the film is told of a frame, and a frame's print alone.
    c.expect(after { $0.right?.dated = false } == [.film], "a frame's date switched off: the film develops again, from the same pixels")
    c.expect(after { $0.right?.print = trim(brightness: 1) } == [.print], "a frame's own print: a reprint of the same negative")
    c.expect(after { $0.left?.print = trim(yellow: 0.2); $0.right?.print = trim() } == [.print], "both frames' prints: still a reprint")
    c.expect(after { $0.right?.print = trim(brightness: 1); $0.right?.dated = false } == [.film, .print], "a print and a date: each said")
    c.expect(after { $0.right?.print = trim(brightness: 1); $0.left?.placement.scale = 2 } == [.pixels, .print], "a print and a move: each said")
    // Where an edit lands is a switch, not a picture; and the host applies no grade after the print.
    c.expect(after { $0.left?.printScope = .frame; $0.left?.exposureScope = .film }.isEmpty, "Frame or + Film is where the next edit lands: no picture changes")
    c.expect(after { $0.left?.adjustments = .object(["exposure": .number(-1)]) }.isEmpty, "the desktop's grade of a frame is carried, not applied: no picture changes")
}

/// What a guide of the piece is drawn from (`HalfFramePair.guideKey`). The guide is the two files' own
/// previews under their holes (`PairGuide.write`, `PairOriginalPreview`): no decode, exposure, print or
/// date is in it. `AppServices.changePair` writes it again, **on the main thread, from each frame's file**,
/// whenever this key moves — and v0.1 had a frame's white balance in it: every tick of a pair's
/// Temperature or Tint ruler read both files again, a RAW by ImageIO's decoder, until the operating system's watchdog
/// ended the app (a tester's reference device, two RAWs, 2026-10-15: 0x8BADF00D, the main thread in
/// `PairGuide.preview` under `ScenePanel.change`). A frame's decode moves the piece's pixels — the
/// engine composes it again — and never the guide.
func guideChecks(_ c: inout Checker, _ rules: Rules) {
    let base = bothFrames()
    func moves(_ change: (inout Pair) -> Void) -> Bool {
        var now = base
        change(&now)
        return rules.guideKey(now) != rules.guideKey(base)
    }
    let stays: [(String, (inout Pair) -> Void)] = [
        ("a frame's temperature", { $0.left?.decode.whiteBalance = .custom; $0.left?.decode.temperature = 7100 }),
        ("a frame's temperature at the ruler's warm end", { $0.right?.decode.whiteBalance = .custom; $0.right?.decode.temperature = 10000 }),
        ("a frame's temperature at the ruler's cool end", { $0.right?.decode.whiteBalance = .custom; $0.right?.decode.temperature = 2000 }),
        ("a frame's tint", { $0.right?.decode.whiteBalance = .custom; $0.right?.decode.tint = -150 }),
        ("a frame back to As Shot", { $0.left?.decode.whiteBalance = .asShot }),
        ("a frame's lens correction", { $0.left?.decode.lensCorrection.toggle() }),
        ("a frame's exposure", { $0.left?.exposureEV = 0.5 }),
        ("a frame's own print", { $0.right?.print = trim(brightness: 1) }),
        ("a frame's date", { $0.right?.dated = false }),
        ("a meter's reading", { $0.left?.meteredEV = 0.4375; $0.left?.meteredFor = "its key" }),
    ]
    for (what, change) in stays {
        c.expect(!moves(change), "\(what) draws no guide again: a guide is the files' own previews")
    }
    // Every tick of a drag across the whole Temperature ruler, on either frame: not one guide.
    var dragged = 0
    for side in Pair.Side.allCases {
        for kelvin in stride(from: 2000.0, through: 10000, by: 125) {
            var now = base
            now[side]?.decode.whiteBalance = .custom
            now[side]?.decode.temperature = kelvin
            if rules.guideKey(now) != rules.guideKey(base) { dragged += 1 }
        }
    }
    c.expect(dragged == 0, "a drag across the Temperature ruler draws the guide \(dragged) times, never")
    // With one hole empty, the frame left is the same.
    var half = Pair()
    half.right = base.right
    var warmer = half
    warmer.right?.decode.temperature = 9000
    c.expect(rules.guideKey(warmer) == rules.guideKey(half), "one hole empty: the other frame's temperature draws no guide")
    // And what a guide does show still draws it again.
    let draws: [(String, (inout Pair) -> Void)] = [
        ("a picture enlarged under its hole", { $0.left?.placement.scale = 2 }),
        ("a picture moved under its hole", { $0.right?.placement.x = 0.5 }),
        ("a picture turned under its hole", { $0.right?.placement.quarterTurns = 1 }),
        ("a frame's own crop", { $0.left?.geometry.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5) }),
        ("another frame in a hole", { $0.left?.frame = UUID() }),
        ("a frame taken out of its hole", { $0.right = nil }),
        ("the camera turned", { $0.turned = true }),
        ("a wider gap", { $0.spacingMM = 1.6 }),
    ]
    for (what, change) in draws {
        c.expect(moves(change), "\(what) draws the guide again")
    }
}

/// The back, a frame at a time (the owner, 2026-10-10: "each sub image should be able to decide if
/// they want date back or information printed"). No test of the desktop's: there the back prints
/// on both frames or on neither.
func backChecks(_ c: inout Checker, _ rules: Rules) {
    var pair = bothFrames(), back = DateBackSettings()
    c.expect(pair.left?.dated == true && pair.right?.dated == true && !back.active, "a new pair: the back off, each frame's own switch on")
    c.expect(!pair.prints(.left, back: back) && !pair.prints(.right, back: back), "the back off prints on neither frame")
    c.expect(rules.backSummary(pair, back) == "Off", "and its row says Off: \(rules.backSummary(pair, back))")
    // On for one frame while the back is off prints that frame alone.
    rules.setDated(&pair, true, .left, &back)
    c.expect(back.active, "a frame switched on while the back is off: the back comes on")
    c.expect(pair.prints(.left, back: back) && !pair.prints(.right, back: back), "for that frame alone: the other was not asked")
    c.expect(rules.backSummary(pair, back) == "LCD · left frame", "its row names the frame: \(rules.backSummary(pair, back))")
    rules.setDated(&pair, true, .right, &back)
    c.expect(pair.prints(.left, back: back) && pair.prints(.right, back: back), "the other switched on as well: both print")
    c.expect(rules.backSummary(pair, back) == "LCD · both frames", "and the row says both: \(rules.backSummary(pair, back))")
    rules.setDated(&pair, false, .left, &back)
    c.expect(back.active && !pair.prints(.left, back: back) && pair.prints(.right, back: back), "one switched off: the other still prints, the back still on")
    c.expect(rules.backSummary(pair, back) == "LCD · right frame", "the row names the one that prints: \(rules.backSummary(pair, back))")
    // Off on the last frame turns the back off.
    rules.setDated(&pair, false, .right, &back)
    c.expect(!back.active, "switched off on the last frame that printed, the back is off")
    c.expect(pair.left?.dated == false && pair.right?.dated == false && rules.backSummary(pair, back) == "Off", "and each frame is as it was left")
    // A face chosen from the film while neither prints turns both on.
    rules.setBack(&pair, .dots, &back)
    c.expect(back.active && back.style == .dots && back.placement == .frame, "a face chosen from the film: the back on, with that face, in the frame")
    c.expect(pair.left?.dated == true && pair.right?.dated == true, "and on both frames where neither printed: a back that is on and prints nowhere is off")
    c.expect(rules.backSummary(pair, back) == "Dots · both frames", "the row says so: \(rules.backSummary(pair, back))")
    // Coming on, it prints on the frames that were left switched on.
    rules.setDated(&pair, false, .right, &back)
    rules.setBack(&pair, nil, &back)
    c.expect(!back.active && pair.left?.dated == true && pair.right?.dated == false, "the back switched off from the film leaves each frame's switch")
    rules.setBack(&pair, .lcd, &back)
    c.expect(back.active && back.style == .lcd && pair.prints(.left, back: back) && !pair.prints(.right, back: back),
             "and coming on again it prints on the frame that was left on, and not on the other")
    // An empty hole has no switch, and one frame alone is the pair's back.
    var one = Pair(), alone = DateBackSettings()
    one.left = Pair.Hole(path: "only", frame: UUID())
    rules.setDated(&one, true, .right, &alone)
    c.expect(!alone.active && one.right == nil, "an empty hole has no switch to set")
    rules.setDated(&one, true, .left, &alone)
    c.expect(alone.active && one.prints(.left, back: alone) && !one.prints(.right, back: alone), "one frame, switched on: it prints, and nothing in the empty hole")
    rules.setDated(&one, false, .left, &alone)
    c.expect(!alone.active, "switched off again, the back is off")
    // Turned, the frames are the top and the bottom one.
    var turned = bothFrames(), third = DateBackSettings()
    turned.turned = true
    rules.setDated(&turned, true, .right, &third)
    c.expect(rules.backSummary(turned, third) == "LCD · bottom frame", "turned, the row names the bottom frame: \(rules.backSummary(turned, third))")

    // The file: a frame's switch is written only where it was switched off, so a pair the desktop
    // wrote is written back saying what it said.
    pair = bothFrames()
    let plain = rules.encode(pair).map { String(decoding: $0, as: UTF8.self) } ?? "\"dated\""
    c.expect(!plain.contains("\"dated\""), "a pair whose back printed on both frames writes no switch")
    pair.right?.dated = false
    guard let written = rules.encode(pair) else { c.expect(false, "a pair with a frame switched off encodes"); return }
    c.expect(String(decoding: written, as: UTF8.self).components(separatedBy: "\"dated\" : false").count == 2, "a frame switched off writes its switch, once")
    c.expect(rules.decode(written)?.right?.dated == false && rules.decode(written)?.left?.dated == true, "and it reads back: off on that frame, on on the other")
    let desk = rules.decode(Data(desktopFile.utf8))
    c.expect(desk?.left?.dated == true && desk?.right?.dated == true, "a pair the desktop wrote prints on both its frames")
    c.expect(desk.flatMap(rules.encode).map { !String(decoding: $0, as: UTF8.self).contains("\"dated\"") } == true, "and is written back with no switch of the phone's")
}

/// `testEachFrameHasItsOwnPlacementAndDateOnTheWire`: the second frame's Scene Placement rides on
/// the pair's own rows; picking the other frame trades the two placements and changes nothing the
/// engine is sent.
func scenePlacementChecks(_ c: inout Checker, _ rules: Rules) {
    var pair = bothFrames(), look = FilmParams()
    // A photograph is sent none of it.
    let photo = rules.wire(look)
    c.expect(look.pairSplit == 0 && photo["scene_latitude_split"] == nil && !photo.keys.contains { $0.hasPrefix("scene_latitude_b_") },
             "a photograph is sent no split and none of a second frame's rows")
    c.expect(photo["scene_latitude_active"] == .bool(false) && photo["scene_latitude_highlight_room"] != nil, "and its own curve as it always was")
    rules.hold(pair, &look)
    c.near(look.pairSplit, 0.5, 0.001, "a pair's look is held to its piece: the second frame begins at the middle of the gap")
    c.expect(rules.wire(look)["scene_latitude_split"] == .double(look.pairSplit), "which is what the engine is sent")
    c.expect(Pair.placementSide(look) == .left && rules.shownSide(pair, look) == .left, "a new pair's shown placement is its first frame's")
    // A placement set with the left frame picked is the first frame's.
    look.sceneLatitude.active = true
    look.sceneLatitude.highlightRoom = 1.5
    c.expect(rules.wire(look)["scene_latitude_highlight_room"] == .double(1.5), "the first frame's curve is on the engine's own rows")
    c.expect(rules.wire(look)["scene_latitude_b_active"] == .bool(false), "and the second frame has none")
    let before = rules.wire(look)
    // Picking the right frame shows its placement and sends the same thing.
    rules.show(.right, &look)
    c.expect(!look.sceneLatitude.active, "the right frame has no placement yet")
    c.expect(look.sceneLatitudeOther.highlightRoom == 1.5 && look.placementIsRight, "the first frame's is kept beside it")
    c.expect(rules.wire(look) == before, "picking a frame changes nothing the engine is sent")
    c.expect(rules.shownSide(pair, look) == .right, "Scene Placement is now about the right frame")
    let shownOnce = look
    rules.show(.right, &look)
    c.expect(look == shownOnce, "picking the frame already shown changes nothing")
    look.sceneLatitude.active = true
    look.sceneLatitude.shadowRoom = 0.75
    var wire = rules.wire(look)
    c.expect(wire["scene_latitude_b_active"] == .bool(true) && wire["scene_latitude_b_shadow_room"] == .double(0.75), "the second frame's curve is on the pair's own rows")
    c.expect(wire["scene_latitude_highlight_room"] == .double(1.5) && wire["scene_latitude_shadow_room"] == .double(0), "and the first frame's did not move")
    // Swapped, each placement goes with its frame.
    let shown = look.sceneLatitude
    rules.swapLook(&pair, &look)
    wire = rules.wire(look)
    c.expect(pair.left?.path == "frame-01.png" && pair.right?.path == "frame-00.png", "swapped, each frame is in the other hole")
    c.expect(wire["scene_latitude_shadow_room"] == .double(0.75) && wire["scene_latitude_b_highlight_room"] == .double(1.5),
             "and each placement went with its frame")
    c.expect(look.sceneLatitude == shown && rules.shownSide(pair, look) == .left, "the shown placement is still shown, of the frame that is now in the other hole")
    // A frame replaced starts with no placement; the other keeps its own.
    rules.fillLook(&pair, .left, Pair.Hole(path: "frame-02.png", frame: UUID()), &look)
    wire = rules.wire(look)
    c.expect(wire["scene_latitude_active"] == .bool(false), "a frame replaced starts with no placement: the curve was fitted to the scene that was there")
    c.expect(wire["scene_latitude_b_active"] == .bool(true) && wire["scene_latitude_b_highlight_room"] == .double(1.5), "and the other frame keeps its own")
    // A hole emptied starts with none, and the shown one is of a frame that is there.
    look.sceneLatitude.active = true
    look.sceneLatitude.shadowRoom = 0.4
    rules.fillLook(&pair, .left, nil, &look)
    wire = rules.wire(look)
    c.expect(pair.left == nil && wire["scene_latitude_active"] == .bool(false) && wire["scene_latitude_shadow_room"] == .double(0),
             "a hole emptied has no placement: there is no scene to place")
    c.expect(rules.shownSide(pair, look) == .right && Pair.placementSide(look) == .right && look.sceneLatitude.highlightRoom == 1.5,
             "and the shown placement is the frame's that is there")
    c.expect(wire["scene_latitude_b_highlight_room"] == .double(1.5), "which the engine is sent as before")
    // Before a look is held to its piece, the frame the page is about is still one that is there.
    var unheld = FilmParams()
    unheld.placementIsRight = false
    c.expect(rules.shownSide(pair, unheld) == .right, "a look that shows an empty hole's placement is about the frame that is there")
    rules.hold(pair, &unheld)
    c.expect(Pair.placementSide(unheld) == .right && unheld.pairSplit == pair.split, "and held to its piece it shows that frame's, from where the second begins")
    c.expect(rules.shownSide(Pair(), FilmParams()) == nil, "a piece with no frame has no placement to be about")
    // The split follows the piece.
    var spaced = bothFrames(), spacedLook = FilmParams()
    spaced.spacingMM = 2
    spaced.turned = true
    rules.hold(spaced, &spacedLook)
    c.near(spacedLook.pairSplit, spaced.split, 1e-12, "the split is the piece's own, however it lies and however wide its gap")
    // Under a digital intermediate neither curve is on.
    var di = look
    di.digitalIntermediate = true
    c.expect(rules.wire(di)["scene_latitude_active"] == .bool(false) && rules.wire(di)["scene_latitude_b_active"] == .bool(false),
             "a digital intermediate keeps the film's whole range: neither frame's curve is sent on")
}

/// What the engine is asked for a frame's own print (`Engine/PrintLayers.swift`):
/// `testAFramesOwnPrintMovesTheStampTheNativeRenderIsKeptUnder` for the stamp, and the desktop's
/// `Session.pairLayered` for which frames print again and with what.
func printLayerChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    var pair = bothFrames(), look = FilmParams()
    c.expect(rules.printLayers(pair, look, catalog).isEmpty, "a piece that is one print asks for no other")
    // A print that is the film's own is not asked for again.
    pair.right?.print = Pair.PrintTrim(look)
    c.expect(rules.printLayers(pair, look, catalog).isEmpty, "a frame pinned at the film's print is not printed again")
    // The second frame a stop brighter.
    pair.right?.print = trim(brightness: 1)
    var layers = rules.printLayers(pair, look, catalog)
    c.expect(layers.count == 1 && layers.first?.index == 1, "a frame with a print of its own is one print more, and it is that frame's")
    if let layer = layers.first {
        c.expect(Set(layer.rows.keys) == Set(PrintLayer.names), "a layer is the frame's whole print: the enlarger's four rows (\(layer.rows.keys.sorted()))")
        c.expect(layer.rows["print_exposure"] == .double(0.5), "a stop brighter is half the enlarger's exposure: \(String(describing: layer.rows["print_exposure"]))")
        c.expect(layer.rows["y_filter_shift"] == .double(0) && layer.rows["m_filter_shift"] == .double(0) && layer.rows["preflash_exposure"] == .double(0),
                 "and the rest of the frame's own print as it is")
        c.expect(layer.rect == pair.holeRects[.right], "it is cut in where the second frame is on the piece")
        c.expect(Set(layer.rows.keys).isSubset(of: FilmParams.liveMutable), "every row is one the engine writes onto a live pipeline: the negative stays")
        c.expect(layer.rows == rules.wire(trim(brightness: 1).applied(to: look)).filter { PrintLayer.names.contains($0.key) },
                 "the rows are what the wire would carry if the film printed so")
    }
    // Both frames, in the film's order.
    pair.left?.print = trim(yellow: 0.25, magenta: -0.5, preflash: 0.01)
    layers = rules.printLayers(pair, look, catalog)
    c.expect(layers.map(\.index) == [0, 1], "both frames with prints of their own: two more, the first frame's first")
    if layers.count == 2 {
        c.expect(layers[0].rows["y_filter_shift"] == .double(0.25) && layers[0].rows["m_filter_shift"] == .double(-0.5)
                 && layers[0].rows["preflash_exposure"] == .double(0.01) && layers[0].rows["print_exposure"] == .double(1),
                 "the first frame's own filters and pre-flash, at the film's brightness")
        c.expect(layers[0].rect == pair.holeRects[.left] && layers[1].rect == pair.holeRects[.right], "each where its frame is")
        c.expect(!layers[0].rect.intersects(layers[1].rect), "and the two never meet: the film between them is the film's print")
    }
    // The film's own rows are the wire's, whatever the catalogue adds for the pair of stocks.
    let film = PrintLayer.rows(of: look), sent = catalog.wire(for: look)
    c.expect(PrintLayer.names.allSatisfy { film[$0] == sent[$0] && film[$0] != nil }, "the film's four rows are the ones the wire carries")
    // The model's own clamps and gates.
    pair = bothFrames()
    pair.left?.print = trim(brightness: 9)
    c.expect(rules.printLayers(pair, look, catalog).first?.rows["print_exposure"] == .double(FilmParams.printExposure(stops: 9)),
             "a brightness past the enlarger's end is sent as the wire sends it: held to its range")
    pair = bothFrames()
    look.printEffects = false
    pair.left?.print = trim(preflash: 0.02)
    c.expect(rules.isLayered(pair, look) && rules.printLayers(pair, look, catalog).isEmpty,
             "Print Effects off: a frame's own pre-flash is the film's print on the wire, and is not printed again")
    pair.left?.print = trim(brightness: 0.5, preflash: 0.02)
    c.expect(rules.printLayers(pair, look, catalog).first?.rows["preflash_exposure"] == .double(0), "and beside a brightness of its own it is sent as none")
    look.printEffects = true
    c.expect(rules.printLayers(pair, look, catalog).first?.rows["preflash_exposure"] == .double(0.02), "Print Effects on again: the frame's own pre-flash is sent")
    // However the piece lies, and however wide its gap.
    for (turned, spacing) in [(false, 1.0), (true, 1.0), (false, 2.0), (true, 0.5)] {
        var lying = bothFrames()
        lying.turned = turned
        lying.spacingMM = spacing
        lying.right?.print = trim(brightness: -1)
        let made = rules.printLayers(lying, FilmParams(), catalog)
        c.expect(made.count == 1 && made.first?.rect == lying.holeRects[.right], "\(turned ? "turned" : "level"), \(spacing) mm: the frame's print is cut in at its own hole")
        if let rect = made.first?.rect {
            c.expect(turned ? rect.minY > 0.5 && rect.minX == 0 && abs(rect.width - 1) < 1e-9 : rect.minX > 0.5 && rect.minY == 0 && abs(rect.height - 1) < 1e-9,
                     "\(turned ? "turned" : "level"), \(spacing) mm: the second frame is the \(turned ? "lower" : "right") one, the piece's whole \(turned ? "width" : "height")")
        }
    }
    // An empty hole has no print to make.
    var one = Pair()
    one.left = Pair.Hole(path: "only", frame: UUID())
    one.left?.print = trim(brightness: 1)
    c.expect(rules.printLayers(one, FilmParams(), catalog).map(\.index) == [0], "one frame with its own print beside an empty hole: its print, and nothing for the hole")

    // A film that is scanned has no print: nothing is asked, though the frame's print is its own.
    let slides = catalog.films.filter(\.isPositive), negatives = catalog.films.filter { !$0.isPositive && !$0.isMonochrome }
    pair = bothFrames()
    pair.right?.print = trim(brightness: 1)
    for slide in slides {
        var scanned = FilmParams()
        scanned.load(film: slide.id, catalog: catalog)
        c.expect(rules.isLayered(pair, scanned) && rules.printLayers(pair, scanned, catalog).isEmpty, "\(slide.shortName), a slide: scanned, so no frame is printed again")
        // As an older build kept it: the film set, the print left on.
        scanned.scanFilm = false
        c.expect(rules.printLayers(pair, scanned, catalog).isEmpty, "\(slide.shortName) marked to be printed: still a slide, still no print of a frame's own")
    }
    if let negative = negatives.first {
        var printed = FilmParams()
        printed.load(film: negative.id, catalog: catalog)
        c.expect(rules.printLayers(pair, printed, catalog).count == 1, "\(negative.shortName), a negative on its paper: the frame is printed again")
        printed.scanFilm = true
        c.expect(rules.printLayers(pair, printed, catalog).isEmpty, "the same negative scanned (a desktop edit): no print, so none of a frame's own")
        printed.scanFilm = false
        printed.digitalIntermediate = true
        c.expect(rules.printLayers(pair, printed, catalog).isEmpty, "and read as a digital intermediate, which takes the paper's place: none either")
    }
    // Black and white: on a silver paper the two filters are the paper's grade, and a frame may have its own.
    if let silver = catalog.films.first(where: \.isMonochrome) {
        var grey = FilmParams()
        grey.load(film: silver.id, catalog: catalog)
        var graded = bothFrames()
        graded.left?.print = trim(magenta: 0.4)
        let made = rules.printLayers(graded, grey, catalog)
        c.expect(made.count == 1 && made.first?.rows["m_filter_shift"] == .double(0.4), "\(silver.shortName) on its silver paper: a frame's own grade is a print of its own")
        let sent = catalog.wire(for: grey)
        c.expect(PrintLayer.names.allSatisfy { PrintLayer.rows(of: grey)[$0] == sent[$0] }, "and the film's four rows are still the wire's, beside the paper's filter pack")
    }

    // The stamp: a frame's own print is part of what a develop is made from.
    pair = bothFrames(); look = FilmParams()
    let none = rules.printLayers(pair, look, catalog).map(rules.layerKey)
    pair.left?.print = trim(yellow: 0.5)
    let own = rules.printLayers(pair, look, catalog).map(rules.layerKey)
    c.expect(none.isEmpty && !own.isEmpty, "a frame's own filter is in the stamp, and a piece that is one print has nothing to add to it")
    pair.left?.print = trim(yellow: 0.75)
    let more = rules.printLayers(pair, look, catalog).map(rules.layerKey)
    c.expect(more != own, "another value is another stamp")
    pair.left?.print = trim(yellow: 0.5)
    c.expect(rules.printLayers(pair, look, catalog).map(rules.layerKey) == own, "the same print is the same stamp")
    var other = bothFrames()
    other.right?.print = trim(yellow: 0.5)
    c.expect(rules.printLayers(other, look, catalog).map(rules.layerKey) != own, "the same print on the other frame is another picture, and another stamp")
    var lying = pair
    lying.turned = true
    lying.spacingMM = 2
    c.expect(rules.printLayers(lying, look, catalog).map(rules.layerKey) == own, "where the frame is on the piece is the piece's to say: not in a print's word")
    // Back to one print for the whole piece: the film's stamp again.
    var reset = look
    rules.resetPrint(&pair, .film, &reset)
    c.expect(rules.printLayers(pair, reset, catalog).isEmpty, "back to one print for the whole piece: nothing is added to the film's stamp")
}

/// `spk_overscan_geometry`'s reply as the engine writes it (`overscan.cpp`, `overscan_geometry_json`):
/// each gate's four corners in the film's order — (s0, t0), (s1, t0), (s1, t1), (s0, t1) — normalised
/// to the canvas. `lean` puts the film a little out of true, as a scan lies: each corner slid along
/// its edge, so that the rectangle that bounds the four is the gate's own.
func geometryReply(_ gates: [CGRect], vertical: Bool, lean: Double = 0, valid: Bool = true) -> String {
    guard valid else { return "{\"valid\":false}" }
    let quads = gates.map { g -> String in
        let (x0, x1, y0, y1) = (Double(g.minX), Double(g.maxX), Double(g.minY), Double(g.maxY))
        let corners: [(Double, Double)] = vertical
            ? [(x0 + lean, y0), (x0, y1 - lean), (x1 - lean, y1), (x1, y0 + lean)]
            : [(x0 + lean, y0), (x1, y0 + lean), (x1 - lean, y1), (x0, y1 - lean)]
        return "[" + corners.map { String(format: "%.9g,%.9g", $0.0, $0.1) }.joined(separator: ",") + "]"
    }
    return "{\"valid\":true,\"canvas_w\":2463,\"canvas_h\":2269,\"mm_per_px\":0.0154166667,\"vertical\":\(vertical),\"format\":\"135_half\","
        + "\"gate_mm\":[18,24],\"penumbra_mm\":0.05,\"gates\":[" + quads.joined(separator: ",") + "]}"
}

/// `spk_overscan_geometry`'s reply for a pair on its strip, as the engine itself wrote it, and how
/// the pair lay: read off the app's log in the simulator on 2026-10-10 (`EngineHost.deliver`'s
/// debug line, `tools/pair_check.sh`), the piece 2,400 px long. The corners come in another order
/// turned than level, and a gate is a little out of true: the film lies a little turned in the scan.
let engineReplies: [(reply: String, lies: String)] = [
    (#"{"canvas_h":2453,"canvas_w":2269,"format":"135_half","gate_mm":[18,23.9983],"gates":[[0.84220259900000005,0.0087677038099999993,0.84279529099999995,0.484544429,0.15703109200000001,0.48527535700000002,0.15643840000000001,0.0094986319400000001],[0.84282821799999996,0.51097646900000004,0.84342090999999997,0.98675319399999994,0.157656711,0.98748412200000002,0.157064019,0.51170739700000001]],"mm_per_px":0.015423093000000001,"penumbra_mm":0.120464,"valid":true,"vertical":true}"#,
     "turned"),
    (#"{"canvas_h":2269,"canvas_w":2453,"format":"135_half","gate_mm":[18,23.9983],"gates":[[0.0087677038099999993,0.157797401,0.484544429,0.157204709,0.48527535700000002,0.84296890800000002,0.0094986319400000001,0.84356160000000002],[0.51097646900000004,0.15717178200000001,0.98675319399999994,0.15657909,0.98748412200000002,0.842343289,0.51170739700000001,0.842935981]],"mm_per_px":0.015423093000000001,"penumbra_mm":0.120464,"valid":true,"vertical":false}"#,
     "level"),
]

/// Where a strip's two frames are: the engine's reply, read (`FilmGates`). The desktop's
/// `EngineClient.overscanGates` and `Session.pairHoleRects`.
func gateChecks(_ c: inout Checker, _ rules: Rules) {
    func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-8 && abs(a.minY - b.minY) < 1e-8 && abs(a.maxX - b.maxX) < 1e-8 && abs(a.maxY - b.maxY) < 1e-8
    }
    // Held level: the film runs across, the first frame on the left.
    let left = CGRect(x: 0.031, y: 0.23, width: 0.449, height: 0.54), right = CGRect(x: 0.52, y: 0.23, width: 0.449, height: 0.54)
    for lean in [0.0, 0.004] {
        let level = rules.gates(geometryReply([left, right], vertical: false, lean: lean))
        c.expect(level.count == 2, "a pair's strip has two gates")
        if level.count == 2 {
            c.expect(near(level[0], left) && near(level[1], right),
                     "held level\(lean > 0 ? ", the film a little out of true" : ""): each gate is the rectangle that bounds its four corners (\(level))")
        }
        // The first frame's first, whichever way the reply lists them.
        let listed = rules.gates(geometryReply([right, left], vertical: false, lean: lean))
        c.expect(listed.count == 2 && near(listed[0], left) && near(listed[1], right), "the first frame's gate is the left one, however the reply lists them")
    }
    // Turned: the film runs down, the first frame at the top.
    let upper = CGRect(x: 0.23, y: 0.031, width: 0.54, height: 0.449), lower = CGRect(x: 0.23, y: 0.52, width: 0.54, height: 0.449)
    for lean in [0.0, 0.004] {
        let turned = rules.gates(geometryReply([upper, lower], vertical: true, lean: lean))
        c.expect(turned.count == 2 && near(turned[0], upper) && near(turned[1], lower),
                 "turned\(lean > 0 ? ", the film a little out of true" : ""): the first frame's gate is the upper one (\(turned))")
        let listed = rules.gates(geometryReply([lower, upper], vertical: true, lean: lean))
        c.expect(listed.count == 2 && near(listed[0], upper) && near(listed[1], lower), "turned: and stays the upper one, however the reply lists them")
    }
    // One frame's film has one gate; no film, none.
    let single = rules.gates(geometryReply([CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6)], vertical: false))
    c.expect(single.count == 1 && near(single[0], CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.6)), "a single frame's film has its one gate")
    c.expect(rules.gates(geometryReply([left, right], vertical: false, valid: false)).isEmpty, "no film edge, or nothing rendered yet: no gates")
    c.expect(rules.gates("{\"valid\":false,\"gates\":[[0,0,1,0,1,1,0,1],[0,0,1,0,1,1,0,1]]}").isEmpty, "a reply that is not valid has none, whatever else it holds")
    c.expect(rules.gates("not a reply").isEmpty && rules.gates("{}").isEmpty && rules.gates("{\"valid\":true}").isEmpty, "and neither has anything that is not a reply")
    c.expect(rules.gates("{\"valid\":true,\"gates\":[[0.1,0.2,0.4,0.2,0.4,0.8],[0.6,0.2,0.9,0.2,0.9,0.8,0.6,0.8]]}").isEmpty,
             "a gate with a corner missing is not guessed at: no gates")
    c.expect(rules.gates("{\"valid\":true,\"gates\":[[0.3,0.2,0.3,0.2,0.3,0.8,0.3,0.8],[0.6,0.2,0.9,0.2,0.9,0.8,0.6,0.8]]}").isEmpty,
             "nor is a gate of no width")
    // As the engine wrote it for a pair on its strip (the simulator, 2026-10-10; `tools/pair_check.sh`).
    for (reply, lies) in engineReplies {
        let read = rules.gates(reply)
        c.expect(read.count == 2, "the engine's own reply, \(lies): two gates")
        guard read.count == 2 else { continue }
        let (first, second) = (read[0], read[1])
        c.expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(first) && CGRect(x: 0, y: 0, width: 1, height: 1).contains(second) && !first.intersects(second),
                 "\(lies): both inside the canvas, and apart")
        c.expect(lies == "turned" ? first.maxY < second.minY : first.maxX < second.minX, "\(lies): the first frame's gate comes first along the film")
        // A gate is a half frame, 18 × 24 mm, in the canvas's own pixels: 2,269 across the film and 2,453 along it.
        let canvas = lies == "turned" ? CGSize(width: 2269, height: 2453) : CGSize(width: 2453, height: 2269)
        for gate in [first, second] {
            let shape = Double(gate.width * canvas.width) / Double(gate.height * canvas.height)
            c.expect(abs(shape - (lies == "turned" ? 24.0 / 18 : 18.0 / 24)) < 0.01, "\(lies): a gate is a half frame's shape (\(shape))")
        }
    }
    c.expect(engineReplies.count == 2, "the engine's own reply is held both ways a pair lies")
}

// MARK: - the file

/// A pair as the desktop writes it (`HalfFramePair.save`: pretty, keys sorted), with a frame's own
/// print, its grade, its meter, and a key of the desktop's `Geometry` the host's does not have.
let desktopFile = """
{
  "folder" : "/Users/someone/Pictures/Roll 12",
  "left" : {
    "adjustments" : {
      "contrast" : 0.25,
      "curve" : [[0, 0], [0.5, 0.56], [1, 1]],
      "exposure" : -1,
      "label" : "cooler",
      "on" : true
    },
    "autoExposure" : false,
    "decode" : {
      "lensCorrection" : true,
      "temperature" : 4800,
      "tint" : 12,
      "whiteBalance" : "Custom"
    },
    "exposureEV" : 0.5,
    "exposureScope" : "film",
    "geometry" : {
      "angle" : 0,
      "aspect" : "free",
      "crop" : {
        "height" : 1,
        "width" : 1,
        "x" : 0,
        "y" : 0
      },
      "flipH" : false,
      "flipV" : false,
      "lockedRatio" : 0.75,
      "quarterTurns" : 1
    },
    "meteredEV" : 0.4375,
    "meteredFor" : "/Users/someone/Pictures/Roll 12/DSC_0041.NEF|Custom|4800.0|12.0|true|highlights|0.0,0.0,1.0,1.0,1",
    "meterMethod" : "highlights",
    "path" : "/Users/someone/Pictures/Roll 12/DSC_0041.NEF",
    "placement" : {
      "quarterTurns" : 3,
      "scale" : 1.5,
      "x" : 0.25,
      "y" : -0.5
    },
    "print" : {
      "brightnessStops" : 1.5,
      "mFilterShift" : -0.125,
      "preflashExposure" : 0.01,
      "yFilterShift" : 0.25
    },
    "printScope" : "frame"
  },
  "onStrip" : true,
  "right" : {
    "autoExposure" : true,
    "decode" : {
      "lensCorrection" : false,
      "temperature" : 5500,
      "tint" : 0,
      "whiteBalance" : "As Shot"
    },
    "exposureEV" : 0,
    "exposureScope" : "frame",
    "geometry" : {
      "angle" : 0,
      "aspect" : "free",
      "crop" : {
        "height" : 1,
        "width" : 1,
        "x" : 0,
        "y" : 0
      },
      "flipH" : false,
      "flipV" : false,
      "quarterTurns" : 0
    },
    "path" : "/Users/someone/Pictures/Roll 12/DSC_0042.NEF",
    "placement" : {
      "quarterTurns" : 0,
      "scale" : 1,
      "x" : 0,
      "y" : 0
    },
    "printScope" : "film"
  },
  "schemaVersion" : 1,
  "spacingMM" : 1.6,
  "turned" : true
}
"""

/// A JSON object with the keys the host's own types do not carry taken out, for holding a file the
/// host wrote against the one it read.
func json(_ data: Data, dropping: Set<String> = []) -> NSObject? {
    func strip(_ any: Any) -> Any {
        if let d = any as? [String: Any] {
            return d.filter { !dropping.contains($0.key) }.mapValues(strip)
        }
        if let a = any as? [Any] { return a.map(strip) }
        return any
    }
    guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return strip(any) as? NSObject
}

func fileChecks(_ c: inout Checker, _ rules: Rules) {
    // 1. A pair the host writes reads back the same.
    var pair = Pair()
    pair.left = Pair.Hole(path: "IMG_0041.DNG", frame: UUID())
    pair.left?.placement.scale = 1.5
    pair.left?.placement.x = 0.25
    pair.left?.placement.quarterTurns = 1
    pair.left?.exposureEV = 0.5
    pair.left?.exposureScope = .film
    pair.left?.meteredEV = 0.4375
    pair.left?.meteredFor = "the key"
    pair.left?.decode.temperature = 4800
    pair.left?.geometry.quarterTurns = 1
    pair.left?.print = Pair.PrintTrim()
    pair.left?.print?.brightnessStops = 1.5
    pair.left?.autoExposure = false
    pair.left?.meterMethod = "highlights"
    pair.right = Pair.Hole(path: "IMG_0042.DNG", frame: UUID())
    pair.spacingMM = 1.6
    pair.turned = true
    guard let written = rules.encode(pair) else { c.expect(false, "a pair encodes"); return }
    c.expect(rules.decode(written) == pair, "a pair the phone writes reads back the same")
    c.expect(String(decoding: written, as: UTF8.self).contains("\"spacingMM\" : 1.6"), "written as the desktop writes: pretty, the desktop's own keys")
    c.expect(rules.decode(written)?.left?.frame == pair.left?.frame && pair.left?.frame != nil, "each hole says which frame of the library it holds")
    c.expect(rules.decode(written)?.left?.print?.brightnessStops == 1.5, "a frame's own print is kept")
    // An empty hole, and an empty pair.
    var one = pair
    one.right = nil
    c.expect(rules.encode(one).flatMap(rules.decode) == one, "a pair with an empty hole reads back with it empty")
    c.expect(rules.encode(Pair()).flatMap(rules.decode) == Pair(), "an empty pair reads back empty")

    // 2. A pair the desktop wrote opens, with what it says.
    let desk = Data(desktopFile.utf8)
    guard let read = rules.decode(desk) else { c.expect(false, "a pair the desktop wrote opens"); return }
    c.expect(read.folder == "/Users/someone/Pictures/Roll 12" && read.schemaVersion == 1, "its folder and version")
    c.expect(read.spacingMM == 1.6 && read.onStrip && read.turned, "its spacing, its strip and the way the camera was held")
    c.expect(read.effectiveSpacingMM == 1.0, "on its strip the camera's advance decides the gap")
    guard let l = read.left, let r = read.right else { c.expect(false, "both its holes"); return }
    c.expect(l.path.hasSuffix("DSC_0041.NEF") && r.path.hasSuffix("DSC_0042.NEF"), "each hole's frame")
    c.expect(l.frame == nil && r.frame == nil, "which the phone's library has yet to find")
    c.expect(l.placement.scale == 1.5 && l.placement.x == 0.25 && l.placement.y == -0.5 && l.placement.quarterTurns == 3, "a placement")
    c.expect(l.exposureEV == 0.5 && l.exposureScope == .film && l.printScope == .frame, "an exposure and where each edit lands")
    c.expect(l.meteredEV == 0.4375 && l.meterMethod == "highlights" && !l.autoExposure, "its meter")
    c.expect(l.meteredFor?.hasSuffix("|highlights|0.0,0.0,1.0,1.0,1") == true, "and what the reading was taken for")
    c.expect(l.decode.temperature == 4800 && l.decode.tint == 12 && l.decode.whiteBalance == .custom && l.decode.lensCorrection, "its decode")
    c.expect(l.geometry.quarterTurns == 1 && l.geometry.crop.isFull, "its own turn")
    c.expect(l.print?.brightnessStops == 1.5 && l.print?.yFilterShift == 0.25 && l.print?.mFilterShift == -0.125 && l.print?.preflashExposure == 0.01,
             "its own print")
    c.expect(r.print == nil && r.adjustments == nil && r.meteredEV == nil && r.autoExposure && r.printScope == .film && r.exposureScope == .frame,
             "a frame with nothing of its own prints as the film does")
    if case .object(let grade)? = l.adjustments {
        c.expect(grade["exposure"] == .number(-1) && grade["label"] == .string("cooler") && grade["on"] == .bool(true),
                 "the desktop's grade of a frame, as it was written")
        c.expect(grade["curve"] == .array([.array([.number(0), .number(0)]), .array([.number(0.5), .number(0.56)]), .array([.number(1), .number(1)])]),
                 "its curve among it")
    } else {
        c.expect(false, "the desktop's grade of a frame is carried")
    }
    // And written back: every key the desktop wrote, but the one the host's `Geometry` has no place
    // for (`lockedRatio`, of a mirror the desktop reads again from the frame's own file).
    guard let rewritten = rules.encode(read) else { c.expect(false, "it encodes again"); return }
    c.expect(l.decode.rawExposureTreatment == .legacy && r.decode.rawExposureTreatment == .legacy,
             "old desktop holes retain their exact legacy RAW exposure recipe")
    let encodedPair = (try? JSONSerialization.jsonObject(with: rewritten)) as? [String: Any]
    let explicitLegacy = ["left", "right"].filter { key in
        let hole = encodedPair?[key] as? [String: Any]
        let decode = hole?["decode"] as? [String: Any]
        return decode?["rawExposureTreatment"] as? String == "legacy.1"
    }.count
    c.expect(explicitLegacy == 2, "both old holes write the explicit legacy recipe")
    c.expect(json(rewritten, dropping: ["rawExposureTreatment"]) == json(desk, dropping: ["lockedRatio"]),
             "apart from explicit legacy recipe, every existing pair field is unchanged")
    c.expect(json(rewritten) != json(desk), "less `lockedRatio`, which the phone does not carry (if this fails the header's note is stale)")
    c.expect(rules.decode(rewritten) == read, "and reads back the same")

    // 3. A file from before a field existed opens: every key but a hole's path is optional.
    let old = Data(#"{"folder":"/tmp/roll","left":{"path":"/tmp/roll/a.tif"}}"#.utf8)
    let opened = rules.decode(old)
    c.expect(opened != nil, "a pair from before a field existed opens")
    c.expect(opened?.left?.placement == Pair.Placement() && opened?.left?.exposureEV == 0 && opened?.left?.autoExposure == true
             && opened?.left?.printScope == .film && opened?.left?.exposureScope == .frame,
             "with a hole at the middle, on the meter, the enlarger on the film as well and exposure on the frame")
    c.expect(opened?.spacingMM == 1.0 && opened?.onStrip == false && opened?.turned == false && opened?.right == nil,
             "1.0 mm apart, held level, no strip, the second hole empty")
    c.expect(rules.decode(Data(#"{"left":{"path":"a"}}"#.utf8))?.folder == "", "a pair with no folder is the phone's")
    c.expect(rules.decode(Data(#"{"folder":"x","left":{"placement":{}}}"#.utf8)) == nil, "a hole with no frame is no pair")
    c.expect(rules.decode(Data("not a pair".utf8)) == nil, "and neither is anything else")
    // A scope a newer build wrote falls back, and does not lose the pair.
    let newer = Data(#"{"folder":"","left":{"path":"a","printScope":"both","exposureScope":"piece"}}"#.utf8)
    c.expect(rules.decode(newer)?.left?.printScope == .film && rules.decode(newer)?.left?.exposureScope == .frame,
             "a scope this build does not know falls back to the default")

    // 4. On disk: a pair is a file, numbered, and its folder lists it.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spk-pair-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = Pair.newURL(in: dir)
    c.expect(Pair.isPair(url) && url.lastPathComponent == "Half-Frame Pair 1.spektrapair", "a new pair's file: \(url.lastPathComponent)")
    c.expect((try? pair.save(to: url)) != nil, "it saves, making its folder")
    c.expect(Pair.load(url) == pair, "and loads")
    let second = Pair.newURL(in: dir)
    c.expect(second != url && second.lastPathComponent == "Half-Frame Pair 2.spektrapair", "a second pair takes another file")
    try? one.save(to: second)
    try? Data("stray".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    let listed = Pair.pairs(in: dir)
    c.expect(listed.map(\.url.lastPathComponent) == ["Half-Frame Pair 1.spektrapair", "Half-Frame Pair 2.spektrapair"], "the folder lists its pairs, in order")
    c.expect(listed.first?.pair == pair && listed.last?.pair == one, "each as it was saved")
    c.expect(Pair.load(dir.appendingPathComponent("notes.txt")) == nil, "a file of another kind is no pair")
    c.expect(Pair.pairs(in: dir.appendingPathComponent("nowhere")).isEmpty, "a folder that is not there has none")
}

// MARK: - the film

func scanned(_ wire: [String: ParamValue]) -> Bool? {
    if case .bool(let on)? = wire["scan_film"] { return on }
    return nil
}

func filmChecks(_ c: inout Checker, _ rules: Rules, catalog: StockCatalog) {
    // Over the colour stocks, where any paper prints any negative; black and white is below.
    let slides = catalog.films.filter(\.isPositive), negatives = catalog.films.filter { !$0.isPositive && !$0.isMonochrome }
    let papers = catalog.papers.filter { !$0.isMonochrome }
    let silverFilms = catalog.films.filter(\.isMonochrome), silverPapers = catalog.papers.filter(\.isMonochrome)
    // Without these the checks below hold nothing.
    c.expect(slides.count >= 2 && negatives.count >= 10 && papers.count >= 4 && silverFilms.count >= 4 && silverPapers.count >= 1,
             "the catalogue has slide films (\(slides.count)), negatives (\(negatives.count)) and papers (\(papers.count)), "
             + "black-and-white films (\(silverFilms.count)) and a silver paper (\(silverPapers.count))")
    guard let negative = negatives.first, let paper = papers.first, let silver = silverPapers.first else { return }

    for slide in slides {
        for kept in papers {
            // The first frame as an older build kept it: the film set, the print left on.
            var first = FrameEdit()
            first.params.filmStock = slide.id
            first.params.printStock = kept.id
            first.params.scanFilm = false
            let look = rules.look(first, false, catalog)
            c.expect(look.params.filmStock == slide.id && look.params.scanFilm, "a pair made of \(slide.shortName) over \(kept.shortName): scanned")
            c.expect(scanned(catalog.wire(for: look.params)) == true, "\(slide.shortName): the engine is told to scan the pair")
            c.expect(catalog.pairText(look.params) == "\(slide.shortName) · scanned", "and the pair is named \"\(catalog.pairText(look.params))\"")
            c.expect(look.params.printStock == kept.id, "\(slide.shortName): the paper its first frame had, \(kept.shortName), waits")
            // A frame's own print laid over the film's does not print a slide either.
            var trim = Pair.PrintTrim()
            trim.brightnessStops = 1
            c.expect(scanned(catalog.wire(for: trim.applied(to: look.params))) == true, "\(slide.shortName): a frame's own print is still a scan")
            // A negative selected on the pair brings its recommended paper; a slide scans.
            var changed = look
            rules.loadFilm(negative.id, &changed, catalog)
            c.expect(!changed.params.scanFilm && changed.params.printStock == catalog.ownPaper(of: negative.id),
                     "\(negative.shortName) selected on the pair: printed on its recommended paper")
            rules.loadFilm(slide.id, &changed, catalog)
            c.expect(changed.params.scanFilm && scanned(catalog.wire(for: changed.params)) == true, "\(slide.shortName) loaded on the pair after it: scanned")
        }
    }
    // A negative's pair prints, on its frame's paper.
    for film in negatives {
        var first = FrameEdit()
        first.params.load(film: film.id, catalog: catalog)
        first.params.printStock = paper.id
        let look = rules.look(first, false, catalog)
        c.expect(!look.params.scanFilm && look.params.printStock == paper.id && scanned(catalog.wire(for: look.params)) == false,
                 "a pair made of \(film.shortName) prints on \(paper.shortName)")
    }
    // Silver on silver, colour on colour (`Model/Stock.swift`): a pair is printed as a frame is.
    for film in silverFilms {
        for kept in papers {
            // The first frame as an edit can carry it: the film set, a colour paper left on.
            var first = FrameEdit()
            first.params.filmStock = film.id
            first.params.printStock = kept.id
            let look = rules.look(first, false, catalog)
            c.expect(look.params.filmStock == film.id && look.params.printStock == silver.id && !look.params.scanFilm,
                     "a pair made of \(film.shortName) over \(kept.shortName): printed on \(silver.shortName)")
            let wire = catalog.wire(for: look.params)
            c.expect(wire["print_stock"] == .string(silver.id) && wire["y_filter_neutral"] != nil && wire["grain_sublayers_active"] == .bool(false),
                     "\(film.shortName): the engine is sent the pair on \(silver.shortName), with its filter pack and its grain as one layer")
            // A frame's own print laid over the film's is still on the pair's paper.
            var trim = Pair.PrintTrim()
            trim.brightnessStops = 1
            c.expect(catalog.wire(for: trim.applied(to: look.params))["print_stock"] == .string(silver.id), "\(film.shortName): a frame's own print is on the pair's paper")
            // A colour negative loaded on the pair leaves the silver paper; the film again brings it back.
            var changed = look
            rules.loadFilm(negative.id, &changed, catalog)
            c.expect(!changed.params.scanFilm && !catalog.isMonochrome(changed.params.printStock) && catalog.stock(changed.params.printStock)?.isPaper == true,
                     "\(negative.shortName) loaded on a pair of \(film.shortName): printed on a colour paper")
            rules.loadFilm(film.id, &changed, catalog)
            c.expect(!changed.params.scanFilm && changed.params.printStock == silver.id, "\(film.shortName) loaded on the pair after it: on \(silver.shortName) again")
        }
    }
    for film in negatives {
        // A colour negative's first frame still carrying the silver paper.
        var first = FrameEdit()
        first.params.filmStock = film.id
        first.params.printStock = silver.id
        let look = rules.look(first, false, catalog)
        c.expect(!catalog.isMonochrome(look.params.printStock) && !look.params.scanFilm, "a pair made of \(film.shortName) over \(silver.shortName): printed on a colour paper")
    }
    // What else a pair's look is, whatever its first frame's was.
    var first = FrameEdit()
    first.params.load(film: negative.id, catalog: catalog)
    first.params.exposureCompensationEV = 0.7
    first.params.printBrightnessStops = 0.5
    first.params.effects.grain = 1.4
    first.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    first.geometry.quarterTurns = 1
    first.solvedEV = 0.3
    first.filmEdge.active = true
    first.filmEdge.format = .f135
    first.filmEdge.cameraSeed = 19
    first.dateBack.active = true
    let look = rules.look(first, false, catalog)
    c.expect(!look.params.autoExposure, "the strip is metered a hole at a time: the engine's own meter is off")
    c.expect(look.params.exposureCompensationEV == 0, "and the piece has no exposure of its own")
    c.near(look.params.filmFormatMM, 37, 0.001, "the engine is told the piece, 37 mm")
    c.expect(look.params.filmFrame == FilmFrame.custom.id && look.params.filmSide == FilmSide.long.rawValue && look.params.sideLengthMM == 24,
             "Film Format describes one half frame, 24 mm on its long side")
    c.expect(look.geometry == .default && look.solvedEV == nil, "the piece has no crop and no reading of its first frame's")
    c.expect(look.params.printBrightnessStops == 0.5 && look.params.effects.grain == 1.4, "the rest of the look is its first frame's")
    c.expect(!look.filmEdge.active && look.filmEdge == FilmEdgeSettings(), "a pair made from two frames starts with no film edge")
    c.expect(look.dateBack == first.dateBack, "and its first frame's date back")
    let entered = rules.look(first, true, catalog)
    c.expect(entered.filmEdge.active && entered.filmEdge.format == .half && entered.filmEdge.cameraSeed == 19 && entered.filmEdge.framing == nil,
             "a pair entered from a half frame's film edge keeps the film edge, as half frame, its body, and no framing of one frame's")
}

@main
struct PairSelfTest {
    static func main() {
        // The bundle's own catalogue, from the repository: tools/../Resources.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let catalog = StockCatalog(contentsOf: root.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("pair checks: no catalogue at Resources/StockCatalog.json")
            exit(1)
        }
        func run(_ rules: Rules, quiet: Bool) -> Checker {
            var c = Checker(quiet: quiet)
            layoutChecks(&c, rules)
            placementChecks(&c, rules)
            cameraChecks(&c, rules)
            dragChecks(&c, rules)
            zoomChecks(&c, rules)
            pieceChecks(&c, rules)
            wireChecks(&c, rules)
            editChecks(&c, rules)
            entryChecks(&c, rules)
            dateChecks(&c, rules)
            fileChecks(&c, rules)
            filmChecks(&c, rules, catalog: catalog)
            printChecks(&c, rules)
            changeChecks(&c, rules)
            guideChecks(&c, rules)
            backChecks(&c, rules)
            scenePlacementChecks(&c, rules)
            printLayerChecks(&c, rules, catalog: catalog)
            gateChecks(&c, rules)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("pair self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("pair checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
