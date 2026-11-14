//  lens_edge_selftest.swift — PRD-D's app side (2026-11-11): 片幅's filter, 135 全宽, the 120 keyholes, 漏光, 镜头,
//  孔间数据 and the date's LED base, checked on this Mac with no engine and no page.
//
//      tools/selftest.sh                # with the other checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  - **what the engine is sent**: on `main`'s engine (no API-SPEC §21 fields) a frame with every new setting on sends
//    exactly what it sent before; on an engine with them, each field only while its effect is on, the falloff and
//    the keyholes every time the film edge is, the leak's seeds the film edge's own when the film edge is off, and
//    every switch's rest when it leaves (`FilmParams.step` over `sometimesSent`);
//  - **the cards**: the filter's formats, 135 Full Width in Wide after XPan and only where the engine has it, a Vision3
//    film on 120 only with the keyholes, the keyholes' start and keeping, 135 Full Width's black holes, the 65mm size;
//  - **the layout** (the app's port of the engine's, `FilmLayout`; the surface every film-edge card and guide draws):
//    135 Full Width laid on the whole 35 mm with its holes in the picture and its phase the frame's, a canvas the
//    develop's price never under-counts; the keyholes on 120 with no 120 edge print, and nothing else of the layout moved;
//  - **what is kept**: a 2.3.2 edit opens with nothing new on and is written back without a new key (its 3.5 EV date
//    read as 5.5), a new edit round-trips, Copy Settings and each section's reset carry and clear their own;
//  - **孔间数据**: its line from EXIF, and the face's rules (a film edge on 135 or Half, alone, on the `data` style).

import CoreGraphics
import Foundation
import SwiftUI

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

/// The app's rules, or one broken on purpose.
struct Rules {
    var name = "the app's"
    var filterFormats: (FilmEdgeFormat.Filter) -> [FilmEdgeFormat] = { $0.formats() }
    var engineWire: (FrameEdit) -> [String: ParamValue] = { wire($0) }
    var take: (inout FilmEdgeSettings, FilmEdgeFormat, String) -> Void = { $0.take(format: $1, stockID: $2) }
    var line: (PerforationLine) -> String = { $0.text }
    var decode: (Data) -> FrameEdit? = { try? JSONDecoder().decode(FrameEdit.self, from: $0) }

    static var broken: [Rules] {
        var a = Rules(name: "the filter shows every format whatever is chosen")
        a.filterFormats = { _ in FilmEdgeFormat.offered }
        var b = Rules(name: "the falloff is sent to an engine without it")
        b.engineWire = { e in var w = wire(e); if e.filmEdge.effective { w["overscan_falloff"] = .double(e.filmEdge.format.falloff) }; return w }
        var c = Rules(name: "a leak with the film edge off sends no seeds")
        c.engineWire = { e in var w = wire(e); if !e.filmEdge.effective { w["overscan_camera_seed"] = nil }; return w }
        var d = Rules(name: "the keyholes stay on when the format leaves 120")
        d.take = { s, f, id in let p = s.perforation; s.take(format: f, stockID: id); s.perforation = p }
        var e = Rules(name: "the line invents a compensation the file does not have")
        e.line = { l in var x = l; x.biasEV = x.biasEV ?? 0; return x.text }
        var f = Rules(name: "a kept 3.5 EV date is read as it was")
        f.decode = { data in
            guard var e = try? JSONDecoder().decode(FrameEdit.self, from: data) else { return nil }
            if String(decoding: data, as: UTF8.self).contains("\"brightnessEV\":3.5") { e.dateBack.brightnessEV = 3.5 }
            return e
        }
        var g = Rules(name: "135 Full Width sends the View kept")
        g.engineWire = { e in var w = wire(e); if e.filmEdge.effective { w["overscan_mode"] = .string(e.filmEdge.mode.rawValue) }; return w }
        var h = Rules(name: "picking 135 Full Width writes Strip over the View kept")
        h.take = { s, f, id in s.take(format: f, stockID: id); if f == .sprocket135 { s.mode = .strip } }
        var i = Rules(name: "135 Full Width keeps its toy lens's falloff")
        i.engineWire = { e in var w = wire(e); if e.filmEdge.effective, e.filmEdge.format == .sprocket135 { w["overscan_falloff"] = .double(1) }; return w }
        var j = Rules(name: "the falloff is left out, so the engine's default stands")
        j.engineWire = { e in var w = wire(e); w["overscan_falloff"] = nil; return w }
        return [a, b, c, d, e, f, g, h, i, j]
    }
}

/// The engine is told this for a frame (`EngineWire.engineWire`'s film branch, without the catalogue's look-up): the
/// film edge's, the date's, the leak's and the lens's words, as `FrameEdit` writes them.
func wire(_ e: FrameEdit, body: Int = 7) -> [String: ParamValue] {
    var w: [String: ParamValue] = [:]
    var edge = e.filmEdge
    if edge.cameraSeed == 0 { edge.cameraSeed = body }
    for f in edge.wire(edgeText: "KODAK PORTRA 400", frameSeed: e.frameSeed, fNumber: 2.8) { w[f.name] = f.value }
    for f in e.dateBack.wire(text: "'26 11 11", filmEdge: e.filmEdge) { w[f.name] = f.value }
    for f in e.leakWire(bodySeed: body) { w[f.name] = f.value }
    for f in e.lens.wire { w[f.name] = f.value }
    return w
}

let newFields: Set<String> = [
    "overscan_falloff", "overscan_perforation", "leak_kind", "leak_amount", "leak_rate", "leak_front",
    "diffusion_filter_active", "diffusion_filter_family", "diffusion_filter_strength", "lens_aberrations_active",
    "date_imprint_data_placement",
]
let mainEngine: Set<String> = []   // what `main`'s engine knows of §21: nothing
let laneAEngine: Set<String> = newFields

func everythingOn() -> FrameEdit {
    var e = FrameEdit.default
    e.filmEdge.active = true
    e.filmEdge.format = .sprocket135
    e.leak.kind = .band
    e.leak.amount = 2
    e.lens.filter = .glimmer
    e.lens.strength = 1
    e.lens.character = .swirl
    return e
}

// MARK: - the wire

func wireChecks(_ c: inout Checker, _ r: Rules) {
    // main's engine: nothing new, whatever the edit holds.
    EngineFeatures.publish(mainEngine)
    var plain = FrameEdit.default
    plain.filmEdge.active = true
    let before = r.engineWire(plain)
    c.expect(Set(before.keys).isDisjoint(with: newFields), "main's engine is never named a §21 field: \(Set(before.keys).intersection(newFields))")
    let on = r.engineWire(everythingOn())
    c.expect(Set(on.keys).isDisjoint(with: newFields), "with every new setting on, main's engine is still never named one")

    EngineFeatures.publish(laneAEngine)
    // At rest: the film edge's two always-sent fields, and nothing else new.
    let rest = r.engineWire(plain)
    c.expect(rest["overscan_falloff"] == .double(0) && rest["overscan_perforation"] == .string("none"),
             "the falloff and the keyholes ride with every film edge, at 0 and none")
    c.expect(Set(rest.keys).intersection(newFields) == ["overscan_falloff", "overscan_perforation"],
             "nothing else new is sent at rest: \(Set(rest.keys).intersection(newFields))")
    var bare = FrameEdit.default
    bare.filmEdge.active = false
    c.expect(Set(r.engineWire(bare).keys).isDisjoint(with: newFields), "with the film edge off, nothing new at rest")
    // No format's falloff (the owner, 2026-11-11: Edit › 镜头 › 暗角 is the only vignette), 135 Full Width's too:
    // sent at 0 with every film edge, so the engine's own never leaks in.
    for f in FilmEdgeFormat.allCases {
        var e = plain; e.filmEdge.format = f
        c.expect(r.engineWire(e)["overscan_falloff"] == .double(0), "\(f.rawValue)'s falloff is sent, at 0")
    }
    // The keyholes: the kept choice on 120, none elsewhere.
    for f in FilmEdgeFormat.allCases {
        var e = plain; e.filmEdge.format = f; e.filmEdge.perforation = .ks65
        let want = f.is120 ? "ks65" : "none"
        c.expect(r.engineWire(e)["overscan_perforation"] == .string(want), "keyholes on \(f.rawValue) send \(want)")
    }
    // View (the owner, 2026-11-11): 135 Full Width is drawn as a strip whatever is kept -- its picture is the film's
    // whole width -- and the View kept comes back on the next format.
    for f in FilmEdgeFormat.allCases {
        for kept in FilmEdgeView.allCases {
            var e = plain; e.filmEdge.format = f; e.filmEdge.mode = kept
            let want = f == .sprocket135 ? "strip" : kept.rawValue
            c.expect(r.engineWire(e)["overscan_mode"] == .string(want), "\(f.rawValue) with \(kept.rawValue) kept sends \(want)")
        }
    }
    var kept = FilmEdgeSettings(); kept.active = true; kept.mode = .filed
    r.take(&kept, .sprocket135, "kodak_portra_400")
    let onFull = kept.view
    r.take(&kept, .f135, "kodak_portra_400")
    c.expect(onFull == .strip && kept.mode == .filed && kept.view == .filed,
             "Filed kept through 135 Full Width (drawn \(onFull.rawValue)) and back (\(kept.mode.rawValue))")
    var stripFull = FilmEdgeSettings(); stripFull.format = .sprocket135
    var filedFull = stripFull; filedFull.mode = .filed
    let picture = PixelSize(width: 8256, height: 4128)
    c.expect(stripFull.canvasEstimate(picture: picture) == filedFull.canvasEstimate(picture: picture),
             "135 Full Width is priced as the strip it is, whatever View is kept")
    // A leak, with the film edge off: its own fields and the film edge's seeds, from the same body and frame.
    var leak = FrameEdit.default
    leak.leak.kind = .wash
    leak.frameSeed = 41
    let alone = r.engineWire(leak)
    c.expect(alone["leak_kind"] == .string("wash") && alone["leak_amount"] == .double(1) && alone["leak_rate"] == .double(1)
             && alone["leak_front"] == .double(-1), "a leak sends kind, amount, rate 1 and the camera's front share")
    c.expect(alone["overscan_camera_seed"] == .double(7) && alone["overscan_frame_seed"] == .double(41)
             && alone["overscan_format"] == .string("135") && alone["overscan_active"] == .bool(false),
             "with the film edge off the leak sends the host's body, the frame's seed and a 135 camera")
    var edged = leak
    edged.filmEdge.active = true
    let withEdge = r.engineWire(edged)
    c.expect(withEdge["overscan_camera_seed"] == alone["overscan_camera_seed"] && withEdge["overscan_frame_seed"] == alone["overscan_frame_seed"],
             "the leak's seeds are the film edge's: it does not move when the film edge goes on")
    var spot = leak
    spot.leak.kind = .spot
    c.expect(r.engineWire(spot)["leak_kind"] == nil, "a spot on a 135 camera is not sent (the engine refuses it)")
    spot.filmEdge.active = true; spot.filmEdge.format = .f6x7
    c.expect(r.engineWire(spot)["leak_kind"] == .string("spot"), "a spot on a 120 film edge is sent")
    c.expect(edged.leakWire(bodySeed: 7, rate: LeakSettings.rateBatch).contains { $0.name == "leak_rate" && $0.value == .double(0.25) },
             "a batch export's rate is a quarter")
    // The lens: the filter's three fields; the character held back by its flag.
    var lens = FrameEdit.default
    lens.lens.filter = .blackMist
    let lw = r.engineWire(lens)
    c.expect(lw["diffusion_filter_active"] == .bool(true) && lw["diffusion_filter_family"] == .string("black_pro_mist")
             && lw["diffusion_filter_strength"] == .double(0.5), "the soft filter sends its switch, family and grade")
    lens.lens.character = .toy
    c.expect(r.engineWire(lens)["lens_aberrations_active"] == nil, "像差 is held back (FeatureFlags.lensCharacter) and sends nothing")
    let toy = LensCharacter.toy.preset.wire(amount: 0.5)
    c.expect(toy.contains { $0.name == "lens_field_curvature_um" && $0.value == .double(17.5) }
             && toy.contains { $0.name == "lens_spherical_um" && $0.value == .double(120) }
             && toy.contains { $0.name == "lens_lateral_ca_b" && $0.value == .double(-0.75) },
             "程度 scales a lens's sizes and fringes, not the glow's radius")
    // Each switch back to its rest when it leaves; nothing told never comes back as a rest.
    var applied = r.engineWire(everythingOn())
    let off = r.engineWire(plain)
    let delta = FilmParams.step(from: &applied, to: off)
    c.expect(delta["leak_kind"] == .string("off") && delta["diffusion_filter_active"] == .bool(false),
             "turning the leak and the filter off sends their rest: \(delta.filter { newFields.contains($0.key) })")
    var never = r.engineWire(plain)
    c.expect(FilmParams.step(from: &never, to: r.engineWire(bare)).keys.allSatisfy { !["leak_kind", "diffusion_filter_active", "lens_aberrations_active", "date_imprint_data_placement"].contains($0) },
             "a rest is never sent for a field the session was never told")
    // Perforation Data on the wire: the data style, between the holes.
    var perfs = plain
    perfs.dateBack.active = true
    perfs.dateBack.tap(.perfs)
    let pw = r.engineWire(perfs)
    c.expect(pw["date_imprint_style"] == .string("data") && pw["date_imprint_data_placement"] == .string("perfs")
             && pw["date_imprint_text"] == .string("'26 11 11") && pw["date_imprint_active"] == .bool(true),
             "Perforation Data is the data style placed between the holes")
    var dated = plain
    dated.dateBack.active = true
    c.expect(r.engineWire(dated)["date_imprint_data_placement"] == nil, "any other face sends no placement")
    EngineFeatures.publish(mainEngine)
    c.expect(r.engineWire(perfs)["date_imprint_active"] == .bool(false), "on an engine without it Perforation Data prints nothing")
}

// MARK: - the cards and the model

func cardChecks(_ c: inout Checker, _ r: Rules, catalog: StockCatalog) {
    EngineFeatures.publish(mainEngine)
    c.expect(!FilmEdgeFormat.offered.contains(.sprocket135), "135 Full Width has no card on main's engine")
    EngineFeatures.publish(laneAEngine)
    c.expect(r.filterFormats(.all) == FilmEdgeFormat.offered, "All is every card")
    c.expect(r.filterFormats(.film135) == [.f135, .half], "135 is 135 and Half")
    c.expect(r.filterFormats(.film120) == [.f645, .f6x6, .f6x7, .f6x8, .f6x9], "120 is the five 120 backs")
    c.expect(r.filterFormats(.panoramic) == [.xpan, .sprocket135, .f6x12, .f6x17], "Wide is XPan, 135 Full Width, 6×12, 6×17")
    c.expect(Set(FilmEdgeFormat.Filter.allCases.flatMap { r.filterFormats($0) }) == Set(FilmEdgeFormat.allCases),
             "every format is under some filter")
    let s = FilmEdgeFormat.sprocket135
    c.expect(s.gauge == "135" && s.isPerforated && s.alongMM == 72 && s.acrossMM == 36 && s.families == [.square]
             && !s.drawsAnyDate && s.startingHoles == .black, "135 Full Width: 135, perforated, 72 × 36, square, no date, black holes")
    var edge = FilmEdgeSettings()
    r.take(&edge, .sprocket135, "kodak_portra_400")
    c.expect(edge.holes == .black, "picking 135 Full Width starts its holes black")
    r.take(&edge, .f6x7, "kodak_vision3_250d")
    c.expect(edge.perforation == .ks65, "a Vision3 film comes onto 120 with the keyholes on")
    edge.perforation = .none
    r.take(&edge, .f6x9, "kodak_vision3_250d")
    c.expect(edge.perforation == .none, "between two 120 formats the person's choice is kept")
    edge.perforation = .ks65
    r.take(&edge, .f135, "kodak_vision3_250d")
    c.expect(edge.perforation == .none, "off 120 the keyholes go")
    r.take(&edge, .f6x6, "kodak_portra_400")
    c.expect(edge.perforation == .none, "a still film comes onto 120 without them")
    // Which films are made on 120.
    func made(_ id: String, _ f: FilmEdgeFormat, keyholes: Bool) -> Bool? { catalog.stock(id)?.isMade(in: f, keyholes: keyholes) }
    for v in FilmEdgePerforation.cine65Stocks.sorted() {
        c.expect(made(v, .f6x7, keyholes: true) == true && made(v, .f6x7, keyholes: false) == false && made(v, .f135, keyholes: true) == true,
                 "\(v): on 120 with an engine that draws the keyholes, on 135 always")
    }
    c.expect(made("kodak_verita_200d", .f6x7, keyholes: true) == false, "Verita 200D stays 135-only")
    c.expect(made("cinestill_800t", .f6x7, keyholes: true) == true && made("cinestill_800t", .f6x7, keyholes: false) == true,
             "CineStill 800T keeps its own 120")
    // 格式's 65mm size.
    c.expect(FilmFrame.offered(stockID: "kodak_vision3_500t").contains { $0.id == FilmFrame.max65.id }
             && !FilmFrame.offered(stockID: "kodak_portra_400").contains { $0.id == FilmFrame.max65.id }
             && FilmFrame.offered(stockID: "kodak_portra_400", chosen: FilmFrame.max65.id).contains { $0.id == FilmFrame.max65.id },
             "65mm is a size card on the Vision3 films only, or where a frame has it")
    c.expect(FilmFrame.max65.title == "65mm" && FilmFrame.max65.short == 56 && FilmFrame.named(FilmFrame.max65.id) == FilmFrame.max65
             && FilmFrame.named("65mm").long > 50, "65mm is 120's 56 mm across, and the old 65mm cine frame is still itself")
    var p = FilmParams.default
    p.take(size: FilmFrame.max65, photo: PixelSize(width: 3000, height: 2000))
    c.expect(abs(p.filmFormatMM - 84) < 1e-9, "65mm on a 3:2 picture is a 56 × 84 frame, as 120's")
    var shown: [String] = FilmEdgeFormat.allCases.map(\.label)
    shown += SoftFilter.allCases.map(\.label)
    shown += LensCharacter.allCases.map(\.label)
    shown += LeakKind.allCases.map(\.label)
    shown += [FilmFrame.max65.title, FilmEdgePerforation.filmName, DateBackFace.perfs.label]
    let marks = ["IMAX", "MAX 65", "Pro-Mist", "Glimmerglass", "Sprocket", "MZ-S"]
    let found = shown.filter { name in marks.contains { name.contains($0) } }
    c.expect(found.isEmpty, "no maker's mark is shown: \(found)")
}

// MARK: - the layout

func request(_ f: FilmEdgeFormat, perforation: FilmEdgePerforation = .none, stock: String = "kodak_portra_400",
             camera: Int = 19, frame seed: Int = 5) -> FilmEdgeRequest {
    var r = FilmEdgeRequest()
    r.format = f
    r.cameraSeed = camera
    r.frameSeed = seed
    r.stockID = stock
    r.edgeText = "KODAK PORTRA 400"
    r.perforation = perforation
    r.frame = PixelSize(width: 3600, height: Int((3600 * f.acrossMM / f.alongMM).rounded()))
    return r
}

/// The full tier (the page's zoom, `FullRenderJobs`, and an export at Full, `ExportService`): its job is made of an
/// export plan whose canvas is the layout's own, not `canvasEstimate`, and is priced to open `plan.opens` or the
/// canvas. On 135 Full Width as a strip the canvas (the 35 mm film) has fewer pixels than the 72 × 36 frame handed
/// over, and every such job refused its own decode: "decoded 4128x8256 exceeds the priced open 4013x8432", the page
/// showing "Full size unavailable" (the owner, 2026-11-11). Each job is made here as those two make it.
func fullTierChecks(_ c: inout Checker) {
    func plan(_ f: FilmEdgeFormat, _ mode: FilmEdgeView, source: PixelSize) -> ExportPlan {
        let ask = ExportPlan.Ask(source: source, film: .init(framing: .default, hostCut: .default, hostTurns: 0),
                                 size: .full, capMegapixels: 400)
        return ExportPlan.make(ask) { framing in
            var r = request(f); r.mode = mode; r.frame = framing
            return FilmLayout.layout(r)?.canvas
        }
    }
    func job(_ p: ExportPlan, _ kind: JobKind) -> RenderJob {
        RenderJob(frameID: UUID(), kind: kind, tier: .full, canvas: p.engineCanvas, decodesOriginal: true,
                  bandable: !p.engineCuts, original: p.decoded, opens: p.opens)
    }
    // A Z7 II's 45.7 MP cut to the gate's 2 : 1, both ways up, and a small one; strip and filed.
    for source in [PixelSize(width: 8256, height: 4128), PixelSize(width: 4128, height: 8256), PixelSize(width: 1920, height: 960)] {
        for mode in FilmEdgeView.allCases {
            let p = plan(.sprocket135, mode, source: source)
            for kind in [JobKind.fullView, .export] {
                c.expect(!job(p, kind).isOverOpened(p.frame),
                         "135 Full Width \(mode.rawValue), \(kind): the full tier opens the frame it is priced for (\(p.frame) on a \(p.engineCanvas) canvas, priced \(job(p, kind).pricedOpen))")
            }
        }
    }
    // Every other format's canvas has more pixels than its frame: its jobs are made exactly as before.
    for f in FilmEdgeFormat.allCases where f != .sprocket135 {
        for mode in FilmEdgeView.allCases {
            let gate = request(f).frame
            let p = plan(f, mode, source: PixelSize(width: gate.width * 2, height: gate.height * 2))
            c.expect(p.opens == nil, "\(f.rawValue) \(mode.rawValue): no open priced past its canvas (\(p.frame) on \(p.engineCanvas))")
        }
    }
}

func layoutChecks(_ c: inout Checker) {
    EngineFeatures.publish(laneAEngine)
    guard let g = FilmLayout.layout(request(.sprocket135)) else { c.expect(false, "135 Full Width: no layout"); return }
    c.expect(abs(g.px - 72.0 / 3600) < 1e-12, "135 Full Width: the 72 mm gate is the picture's long edge")
    c.expect(abs(Double(g.canvas.height) * g.px - 35) < g.px, "135 Full Width: the canvas is the whole 35 mm across (\(g.canvas))")
    c.expect(g.gateAcross > g.filmW, "135 Full Width: the gate is wider than the film")
    let gateS = g.gateS0...(g.gateS0 + g.gateAlong)
    let inPicture = g.holes.filter { gateS.contains(Double($0.midX)) }
    c.expect(inPicture.count >= 2 * 14, "135 Full Width: the holes run through the picture (\(inPicture.count) of them)")
    c.expect(g.perfPhase <= 0 && g.perfPhase > -FilmGeometry.perfPitch, "135 Full Width: the phase is within one pitch")
    let phases = Set((1...12).compactMap { FilmLayout.layout(request(.sprocket135, frame: $0))?.perfPhase })
    c.expect(phases.count >= 10 && phases.contains { $0 > -1.5 } && phases.contains { $0 < -3.5 },
             "135 Full Width: where the holes land is the frame's, over the whole pitch")
    c.expect(FilmLayout.layout(request(.f135))?.perfPhase ?? 0 < -2.5, "135's own phase is untouched (the pawl's)")
    // The develop is priced on `canvasEstimate`; the guide is this layout. The price must never be under the guide.
    var edge = FilmEdgeSettings(); edge.format = .sprocket135
    let est = edge.canvasEstimate(picture: request(.sprocket135).frame)
    c.expect(est.width >= g.canvas.width && est.height >= g.canvas.height, "135 Full Width: the price covers the guide (\(est) for \(g.canvas))")
    // ...and the frame it is handed: the develop's open is priced at the estimate, and a decode larger than its
    // price is refused (`RenderJob.isOverOpened`) -- the gate is wider than the film, so the canvas alone is not.
    for picture in [PixelSize(width: 1920, height: 960), PixelSize(width: 960, height: 1920), PixelSize(width: 8000, height: 4000)] {
        let e = edge.canvasEstimate(picture: picture)
        c.expect(e.width >= picture.width && e.height >= picture.height, "135 Full Width: the price covers the picture (\(e) for \(picture))")
    }
    fullTierChecks(&c)
    // The keyholes on 120.
    guard let plain = FilmLayout.layout(request(.f6x7)), let keyed = FilmLayout.layout(request(.f6x7, perforation: .ks65)) else {
        c.expect(false, "6×7: no layout"); return
    }
    c.expect(plain.holes.isEmpty && !keyed.holes.isEmpty, "6×7: holes only with the keyholes")
    c.expect(keyed.holes.allSatisfy { abs($0.width - 1.981) < 1e-9 && abs($0.height - 2.794) < 1e-9 }, "the keyholes are KS holes, 1.981 × 2.794")
    c.expect(keyed.edge.isEmpty && !plain.edge.isEmpty, "a keyholed 120 carries no edge print, on any stock")
    c.expect(keyed.gateT0 == plain.gateT0 && keyed.canvas == plain.canvas && keyed.scanRot == plain.scanRot && keyed.quads == plain.quads,
             "the keyholes move nothing else of the layout")
    // Into the gate's near edge: the hole's inner edge less the gate's. A camera centres its gate within ±0.45 mm and
    // the slitter wanders ±0.25 (the engine's draws), so the bite is the engine's 1.3 mm on average, not on every body.
    func bite(_ g: FilmGeometry) -> Double { (g.holes.map { Double($0.maxY) }.filter { $0 < g.filmW / 2 }.max() ?? 0) - g.gateT0 }
    let bites = (1...40).compactMap { FilmLayout.layout(request(.f6x7, perforation: .ks65, camera: $0)) }.map(bite)
    let mean = bites.reduce(0, +) / Double(max(bites.count, 1))
    c.expect(mean > 1.1 && mean < 1.5 && bites.allSatisfy { $0 > 0.4 && $0 < 2.2 },
             "the keyholes bite about 1.3 mm into the 56 mm gate (mean \(mean), \(bites.min() ?? 0)…\(bites.max() ?? 0))")
    var asked = FilmLayout.layout(request(.f135, perforation: .ks65))
    asked?.request.perforation = .none
    c.expect(asked == FilmLayout.layout(request(.f135)), "keyholes asked on 135 change nothing (the wire sends none)")
}

// MARK: - what is kept

/// A 2.3.2 edit as 2.3.2 wrote it: a film edge, a date at its 3.5 EV, a vignette.
let edit232 = """
{"schemaVersion":5,"decoder":"coreimage","decode":{"whiteBalance":"As Shot","temperature":5500,"tint":0,"lensCorrection":false,"rawExposureTreatment":"source-reference.2"},
"params":\(String(decoding: try! JSONEncoder().encode(FilmParams.default), as: UTF8.self)),
"geometry":\(String(decoding: try! JSONEncoder().encode(Geometry.default), as: UTF8.self)),
"filmEdge":{"active":true,"format":"120_6x7","mode":"strip","gate":"auto","holes":"white","fog":1,"leaks":0,"turn":0,"cameraSeed":12,"frameNumber":0,"edgeBrightness":1},
"dateBack":{"active":true,"style":"lcd","order":"japan","placement":"frame","corner":"br","insetXMM":3,"insetYMM":2.4,"size":1,"brightnessEV":3.5,"alsoData":false,"brightness":1},
"placementNeedsFit":false,"frameSeed":3,
"adjustments":\(String(decoding: try! JSONEncoder().encode({ () -> Adjustments in var a = Adjustments(); a.vignette.amount = -30; return a }()), as: UTF8.self))}
"""

func keptChecks(_ c: inout Checker, _ r: Rules) {
    guard let e = r.decode(Data(edit232.utf8)) else { c.expect(false, "a 2.3.2 edit does not open"); return }
    c.expect(e.leak.isAtRest && e.lens.isAtRest && e.filmEdge.perforation == .none, "a 2.3.2 edit opens with no leak, no lens, no keyholes")
    c.expect(e.adjustments.vignette.amount == -30, "its vignette opens where it was (now under Lens)")
    c.expect(e.dateBack.brightnessEV == 5.5, "its 3.5 EV date reads as the LED's 5.5")
    let back = String(decoding: try! JSONEncoder().encode(e), as: UTF8.self)
    c.expect(!back.contains("\"leak\"") && !back.contains("\"lens\"") && !back.contains("\"perforation\""),
             "written back, it gains no new key")
    var other = edit232.replacingOccurrences(of: "\"brightnessEV\":3.5", with: "\"brightnessEV\":4.25")
    c.expect(r.decode(Data(other.utf8))?.dateBack.brightnessEV == 4.25, "any other base is kept as it was")
    other = edit232.replacingOccurrences(of: "\"brightnessEV\":3.5,", with: "")
    c.expect(r.decode(Data(other.utf8))?.dateBack.brightnessEV == 5.5 && DateBackSettings().brightnessEV == 5.5,
             "a new date, and one with no base kept, is at 5.5")
    // A new edit round-trips with everything.
    var n = everythingOn()
    n.filmEdge.format = .f6x7; n.filmEdge.perforation = .ks65
    let nb = r.decode(try! JSONEncoder().encode(n))
    c.expect(nb == n, "an edit with a leak, a lens and keyholes round-trips")
    // An unknown word falls back.
    let odd = edit232.replacingOccurrences(of: "\"frameSeed\":3,", with: "\"frameSeed\":3,\"leak\":{\"kind\":\"rainbow\",\"amount\":2},\"lens\":{\"filter\":\"fog\",\"strength\":1},")
    let o = r.decode(Data(odd.utf8))
    c.expect(o?.leak.kind == .off && o?.leak.amount == 2 && o?.lens.filter == nil && o?.lens.strength == 1, "an unknown kind or filter falls back, the rest kept")
    // Copy Settings and the resets.
    EngineFeatures.publish(laneAEngine)
    let src = everythingOn()
    let pic = PixelSize(width: 3000, height: 2000)
    let fmt = SettingsClip(groups: [.format], settings: src, sourceName: "x").applied(to: .default, picture: pic)
    c.expect(fmt.leak == src.leak && fmt.lens.isAtRest, "Format's group carries the leak and not the lens")
    let lensClip = SettingsClip(groups: [.lens], settings: src, sourceName: "x").applied(to: .default, picture: pic)
    c.expect(lensClip.lens == src.lens && lensClip.leak.isAtRest, "Lens's group carries the soft filter and character, and not the leak")
    var vig = src; vig.adjustments.vignette.amount = -40
    c.expect(SettingsClip(groups: [.light], settings: vig, sourceName: "x").applied(to: .default, picture: pic).adjustments.vignette.amount == -40,
             "the vignette travels with Light, as it always has")
    let edgeClip = SettingsClip(groups: [.filmEdgeAndDateBack], settings: n, sourceName: "x").applied(to: .default, picture: pic)
    c.expect(edgeClip.filmEdge.perforation == .ks65, "Film Edge & Date Back carries the keyholes")
    c.expect(ClipboardGroup.offered.contains(.lens), "Lens is offered where the engine has the filter")
    EngineFeatures.publish(mainEngine)
    c.expect(!ClipboardGroup.offered.contains(.lens), "and not where it does not")
    var reset = vig
    reset = reset.resetting(.lens)
    c.expect(reset.lens.isAtRest && reset.adjustments.vignette.isNeutral && reset.leak == vig.leak, "Lens's ↺ is the vignette and the lens, nothing else")
    reset = vig.resetting(.leak)
    c.expect(reset.leak.isAtRest && reset.lens == vig.lens, "the leak's ↺ is the leak's")
    reset = n.resetting(.filmEdge)
    c.expect(reset.filmEdge.perforation == .none, "Film Edge's ↺ takes the keyholes off")
}

// MARK: - 孔间数据

func perforationChecks(_ c: inout Checker, _ r: Rules) {
    let full = PerforationLine(exposureProgram: 2, meteringMode: 5, seconds: 1.0 / 180, fNumber: 8, biasEV: 0)
    c.expect(r.line(full) == "P|{meter:multi}|180|F8|±0.0", "the full line: \(r.line(full))")
    c.expect(r.line(PerforationLine(exposureProgram: 3, meteringMode: 2, seconds: 2, fNumber: 5.6, biasEV: 0.7)) == "Av|{meter:center}|2\"|F5.6|+0.7",
             "aperture priority, centre-weighted, 2 s, f/5.6, +0.7")
    c.expect(r.line(PerforationLine(exposureProgram: 4, meteringMode: 3, seconds: 1.0 / 1000, fNumber: 2.8, biasEV: -1)) == "Tv|{meter:spot}|1000|F2.8|-1.0",
             "shutter priority, spot, 1/1000, f/2.8, −1.0")
    c.expect(r.line(PerforationLine(exposureProgram: 1, seconds: 1.0 / 60, fNumber: 11)) == "M|60|F11", "a field the file lacks is left out")
    c.expect(r.line(PerforationLine(exposureProgram: 0, meteringMode: 6, biasEV: nil)) == "", "an unknown mode or metering says nothing")
    c.expect(r.line(PerforationLine(biasEV: 0.33)) == "+0.3" && r.line(PerforationLine(biasEV: -0.04)) == "±0.0", "compensation to a tenth")
    c.expect(PerforationLine.shown("P|{meter:multi}|180|F8") == "P 180 F8", "a card's sample has no marks and no bars")
    // The face.
    EngineFeatures.publish(laneAEngine)
    var edge = FilmEdgeSettings(); edge.active = true
    var back = DateBackSettings(); back.active = true
    c.expect(back.prints(.perfs, filmEdge: edge), "Perforation Data prints on a 135 film edge")
    edge.format = .half
    c.expect(back.prints(.perfs, filmEdge: edge), "and on Half")
    for f in FilmEdgeFormat.allCases where f != .f135 && f != .half {
        edge.format = f
        c.expect(!back.prints(.perfs, filmEdge: edge), "not on \(f.rawValue)")
    }
    edge.format = .f135; edge.active = false
    c.expect(!back.prints(.perfs, filmEdge: edge) && back.reason(.perfs, filmEdge: edge) != nil, "without a film edge it says it needs one")
    back.alsoData = true
    back.tap(.perfs)
    c.expect(back.style == .perfs && !back.alsoData && back.shows(.perfs) && !back.shows(.data) && !back.shows(.lcd),
             "Perforation Data is alone: no date, no data line beside it")
    back.tap(.lcd)
    c.expect(back.style == .lcd && !back.alsoData, "a date face takes its place")
    EngineFeatures.publish(mainEngine)
    c.expect(!DateBackFace.offered.contains(.perfs), "no card on main's engine")
    EngineFeatures.publish(laneAEngine)
    c.expect(DateBackFace.offered.contains(.perfs) && DateBackFace.dateFaces == [.lcd, .dots, .data], "a card on lane A's; never a pair's")
}

@main
enum Main {
    static func main() {
        guard let catalog = StockCatalog(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
            print("lens edge checks: no catalogue at \(CommandLine.arguments[1])"); exit(1)
        }
        func run(_ rules: Rules, quiet: Bool) -> Checker {
            var c = Checker(quiet: quiet)
            wireChecks(&c, rules)
            cardChecks(&c, rules, catalog: catalog)
            layoutChecks(&c)
            keptChecks(&c, rules)
            perforationChecks(&c, rules)
            return c
        }
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let rules = Rules.broken
            for rule in rules {
                if run(rule, quiet: true).failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            print("lens edge self-test: \(caught) of \(rules.count) broken rules caught")
            exit(caught == rules.count ? 0 : 1)
        }
        let c = run(Rules(), quiet: false)
        print("lens edge checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
