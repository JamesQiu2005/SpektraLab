//  scheduler_selftest.swift — the scheduler's rules, checked on this Mac.
//
//      tools/selftest.sh                # the checks
//      tools/selftest.sh --self-test    # the checks' own check: each mutation must be caught
//
//  Compiled with the scheduler's own sources (no UIKit, no engine) and the
//  simulated engine running 50 times faster than the measured one. It checks
//  the arithmetic against the numbers RFC-036 cites and the queue's behaviour
//  against its rules. It measures nothing about a host: memory readings are
//  injected, and the engine is simulated.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the
//  same checks with one rule broken at a time and requires each run to fail.

import Foundation

// MARK: - a tiny harness

struct Mutation: Equatable {
    var name: String
    static let none = Mutation(name: "none")
    static let all = ["no-margin", "no-camera-reserve", "never-yield", "ignore-pressure", "free-memory", "never-trim",
                      "wrong-capture-rule", "no-second-capture", "renders-as-asked",
                      "camera-never-warm", "camera-stays-warm", "darkroom-open-beside-camera",
                      "print-layers-free", "previews-wait-their-turn", "previews-jump-the-queue",
                      "previews-not-coalesced"].map(Mutation.init)
}

@MainActor
final class Checks {
    let mutation: Mutation
    private(set) var passed = 0
    private(set) var failed: [String] = []
    init(mutation: Mutation) { self.mutation = mutation }

    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if mutation == .none { print("  FAIL  \(what)") } }
    }

    func near(_ a: Double, _ b: Double, within tolerance: Double, _ what: String) {
        expect(abs(a - b) <= tolerance * abs(b), "\(what): \(String(format: "%.1f", a)) against \(String(format: "%.1f", b))")
    }
}

let MB: UInt64 = 1 << 20

/// Megabytes an engine's pool holds idle, for a test to take back from another thread.
final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var mb: UInt64
    init(_ mb: UInt64) { self.mb = mb }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return mb }
    func take() -> UInt64 { lock.lock(); defer { lock.unlock() }; let v = mb; mb = 0; return v }
}
let frame48 = PixelSize(width: 8064, height: 6048), frame12 = PixelSize(width: 4032, height: 3024)
let canvas = PixelSize(width: 2400, height: 1600)

func reading(app: UInt64, phone: UInt64) -> MemoryReading {
    MemoryReading(appAvailable: app * MB, free: phone * MB, inactive: 0, purgeable: 0, wired: 0, compressed: 0, footprint: 0)
}

func job(_ kind: JobKind, _ size: PixelSize, tier: RenderTier = .full, frame: UUID = UUID(),
         layers: Set<ParamLayer> = [], decodes: Bool = false, bandable: Bool = true, original: PixelSize? = nil,
         printLayers: Int = 0) -> RenderJob {
    RenderJob(frameID: frame, kind: kind, tier: tier, canvas: size, layers: layers, what: "test", decodesOriginal: decodes,
              bandable: bandable, original: original, printLayers: printLayers)
}

// MARK: - the checks

@MainActor
func run(_ mutation: Mutation) async -> Checks {
    let c = Checks(mutation: mutation)
    let policy = DevicePolicy(developCapMegapixels: 48)
    let model = CostModel(policy: policy)
    var tuning = BudgetTuning()
    if mutation.name == "no-margin" { tuning.margin = -2 }
    if mutation.name == "no-camera-reserve" { tuning.cameraGrowthAt48MP = 0; tuning.cameraGrowthAt12MP = 0 }

    // ---- the budget (RFC-036 §6.3) ----
    let idle = FrontendState()
    let b1 = MemoryBudget.compute(reading(app: 3365, phone: 2000), frontend: idle, tuning: tuning)
    c.near(b1.bytes.megabytes, (2000 - 600) * 0.85, within: 0.001, "budget: min(A - r_app, P - r_floor) x (1 - m)")
    c.expect(b1.binding == .phone, "budget: the phone binds when it is the tighter side")
    let b2 = MemoryBudget.compute(reading(app: 1000, phone: 6000), frontend: idle, tuning: tuning)
    c.expect(b2.binding == .allowance, "budget: the allowance binds when it is the tighter side")
    var shooting = FrontendState()
    shooting.camera = .live(photoMegapixels: 48)
    shooting.capturesInFlight = 1
    let b3 = MemoryBudget.compute(reading(app: 6133, phone: 3000), frontend: shooting, tuning: tuning)
    c.near(b3.bytes.megabytes, (3000 - 2 * 750 - 600) * 0.85, within: 0.001, "budget: the camera's growth (750 MB at 48 MP) is reserved per capture, plus one")
    // Once the session has delivered a photo, one more grows it by far less than the first did:
    // 133-245 MB against 600-725 at 48 MP (reference device). 420 MB is reserved.
    let b3warm = MemoryBudget.compute(reading(app: 6133, phone: 3000), frontend: shooting, tuning: tuning, cameraWarm: true)
    c.near(b3warm.bytes.megabytes, (3000 - 2 * 420 - 600) * 0.85, within: 0.001,
           "budget: once the camera has delivered a photo, the next one's growth is reserved at 420 MB")
    c.expect(tuning.cameraGrowth(photoMegapixels: 12, warm: true) == tuning.cameraGrowth(photoMegapixels: 12),
             "budget: at 12 MP the reserve is 420 MB before the first photo and after")
    let b4 = MemoryBudget.compute(reading(app: 6133, phone: 200), frontend: shooting, tuning: tuning)
    c.expect(b4.bytes == 0 || mutation.name == "no-camera-reserve", "budget: never negative, and nothing is left when the phone has nothing")

    // ---- the cost model against RFC-036 §2.2's table ----
    let full48 = job(.export, frame48), full12 = job(.export, frame12)
    c.near(model.seed(full48, mode: .bands(rows: 1120)).peakBytes.megabytes, 1484, within: 0.03, "cost: 48 MP in 1,120-row bands peaks at ~1,484 MB")
    c.near(model.seed(full48, mode: .bands(rows: 280)).peakBytes.megabytes, 1019, within: 0.03, "cost: 48 MP in 280-row bands peaks at ~1,019 MB")
    c.near(model.seed(full12, mode: .bands(rows: 1512)).peakBytes.megabytes, 804, within: 0.04, "cost: 12 MP in 1,512-row bands peaks at 786-822 MB (iPhone 17)")
    c.near(model.seed(full12, mode: .bands(rows: 280)).peakBytes.megabytes, 402, within: 0.04, "cost: 12 MP in 280-row bands peaks at 398-407 MB (iPhone 17)")
    c.near(model.seed(full48, mode: .whole).peakBytes.megabytes, 3239, within: 0.03, "cost: 48 MP whole peaks at ~3,239 MB")
    c.near(model.seed(full12, mode: .whole).peakBytes.megabytes, 1004, within: 0.03, "cost: 12 MP whole peaks at ~1,004 MB")
    c.near(model.seed(full48, mode: .bands(rows: 1120)).seconds, 2.28 + 0.137 * 6, within: 0.03, "cost: time is t0 + c_band x bands (48 MP on the iPhone 17: 2.28 s + 137 ms a band)")
    c.near(model.seed(full12, mode: .whole).seconds, 0.69 + 0.060, within: 0.03, "cost: a whole render is one band (12 MP on the iPhone 17: 0.75 s)")
    var slower = policy; slower.timeRatio = 2
    c.near(CostModel(policy: slower).seed(full48, mode: .bands(rows: 1120)).seconds, 2 * (2.28 + 0.137 * 6), within: 0.03,
           "cost: another device's times are the iPhone 17's by its ratio")
    c.near(model.seed(job(.canvasReprint, PixelSize(width: 2560, height: 1920), tier: .live, layers: [.print]), mode: .whole).seconds,
           0.055, within: 0.05, "cost: a reprint at 2,560 px is ~55 ms (iPhone 17)")
    c.near(model.seed(job(.canvasDevelop, PixelSize(width: 2560, height: 1920), tier: .live, layers: [.shoot]), mode: .whole).seconds,
           0.21, within: 0.05, "cost: a film-side develop at 2,560 px is ~210 ms (iPhone 17)")
    c.near(model.seed(job(.export, frame48, decodes: true), mode: .bands(rows: 280)).peakBytes.megabytes, 1181, within: 0.03,
           "cost: a 48 MP HEIF in 280-row bands peaks at ~1,181 MB (iPhone 17), which is its open")
    c.near(model.seed(job(.export, frame48, decodes: true), mode: .bands(rows: 1008)).peakBytes.megabytes, 1585, within: 0.03,
           "cost: and in 1,008-row bands at ~1,585 MB, which is its render with what the decode leaves behind")
    c.near(model.seed(job(.shot, frame12, decodes: true), mode: .bands(rows: 144)).peakBytes.megabytes, 394, within: 0.06,
           "cost: a 12 MP HEIF's open is 355-406 MB (iPhone 17)")
    c.near(Double(BandGeometry(canvas: frame48).bytesPerRow) / Double(MB), 0.554, within: 0.01, "cost: a band row is 6 planes x 12 B x width (0.554 MB at 48 MP)")

    // ---- a pair's frames that print as their own (`RenderJob.printLayers`) ----
    // Each is a print more of the job's negative, cut into its result: one more result held while
    // it is made (rgba16, 8 B a pixel of the canvas), and a print pass more. Arithmetic, not a
    // host's measurement. `print-layers-free` hands the model every such job as one print.
    func own(_ n: Int) -> Int { mutation.name == "print-layers-free" ? 0 : n }
    let page = PixelSize(width: 2560, height: 1920), pagePixels = UInt64(2560 * 1920)
    let onePrint = model.seed(job(.canvasReprint, page, tier: .live, layers: [.print]), mode: .whole)
    let oneOwn = model.seed(job(.canvasReprint, page, tier: .live, layers: [.print], printLayers: own(1)), mode: .whole)
    let twoOwn = model.seed(job(.canvasReprint, page, tier: .live, layers: [.print], printLayers: own(2)), mode: .whole)
    c.expect(oneOwn.peakBytes == onePrint.peakBytes + 8 * pagePixels,
             "layers: a job with a frame's own print holds one more result, 8 B a pixel of its canvas (\(oneOwn.peakBytes.megabytes) MB against \(onePrint.peakBytes.megabytes))")
    c.expect(twoOwn.peakBytes == oneOwn.peakBytes, "layers: and no more for a second: one layer's print is alive at a time")
    c.expect(oneOwn.phoneBytes - oneOwn.peakBytes == onePrint.phoneBytes - onePrint.peakBytes,
             "layers: the source plane is the job's, whatever it prints")
    c.near(oneOwn.seconds - onePrint.seconds, 0.055, within: 0.02, "layers: one is a reprint more (55 ms at 2,560 px)")
    c.near(twoOwn.seconds - onePrint.seconds, 0.110, within: 0.02, "layers: two are two")
    c.expect(model.seed(job(.canvasReprint, page, tier: .live, layers: [.print], printLayers: 0), mode: .whole) == onePrint,
             "layers: a job with none costs what it did")
    c.expect(job(.canvasReprint, page, tier: .live, printLayers: -3).printLayers == 0, "layers: there are never fewer than none")
    // At full size: whole, a layer is a reprint of the negative the render kept; in bands the engine
    // keeps none, so a layer develops again, band by band.
    let export12 = job(.export, frame12, decodes: true), export12own = job(.export, frame12, decodes: true, printLayers: own(2))
    let pixels12 = UInt64(4032 * 3024)
    c.expect(model.seed(export12own, mode: .whole).peakBytes == model.seed(export12, mode: .whole).peakBytes + 8 * pixels12,
             "layers: an export's second result is 8 B a pixel too (93 MB at 12 MP)")
    c.near(model.seed(export12own, mode: .whole).seconds - model.seed(export12, mode: .whole).seconds, 2 * 0.055 * 12.19 / 4.9152, within: 0.02,
           "layers: whole, an export's layer is a reprint at its size")
    let bands12 = RenderMode.bands(rows: 760)
    c.near(model.seed(export12own, mode: bands12).seconds - model.seed(export12, mode: bands12).seconds,
           2 * (0.69 + 0.060 * Double(BandGeometry(canvas: frame12).bandCount(rows: 760))), within: 0.02,
           "layers: in bands each layer is the develop again (t0 + c_band x bands)")

    // ---- the band arithmetic against the engine's (probes/engine/band_asked.py, 2026-10-03) ----
    // The engine cuts rows = floor8(budget / per_row - above - halo). Measured on a 36 mm frame:
    // above + halo is 722 rows at 8,064 px wide and 426 at 4,032.
    func engineCuts(_ g: BandGeometry, budget: UInt64, overhead: Int) -> Int {
        max(8, (Int(budget / g.bytesPerRow) - overhead) / 8 * 8)
    }
    // An upright frame has the reach of the same frame on its side: the pitch is by the long edge.
    let upright48 = PixelSize(width: 6048, height: 8064), upright12 = PixelSize(width: 3024, height: 4032)
    for (size, overhead) in [(frame48, 722), (frame12, 426), (upright48, 722), (upright12, 426)] {
        let g = BandGeometry(canvas: size)
        for mode in Planner.ladder(for: job(.export, size)) {
            guard case .bands(let rows) = mode else { continue }
            let cut = engineCuts(g, budget: g.engineBudgetBytes(rows: rows), overhead: overhead)
            c.expect(cut == rows, "bands: \(size.width) x \(size.height), \(rows) rows asked is \(rows) rows cut (the engine would cut \(cut))")
            c.expect(g.bandCount(rows: cut) == g.bandCount(rows: rows),
                     "bands: \(size.width) x \(size.height), \(rows) rows is \(g.bandCount(rows: rows)) bands predicted and \(g.bandCount(rows: cut)) run")
        }
    }

    // ---- the planner (§6.4, §6.7) ----
    func budget(_ mb: UInt64) -> MemoryBudget {
        MemoryBudget.compute(reading(app: 100_000, phone: mb), frontend: idle, tuning: BudgetTuning(appReserve: 0, floorReserve: 0, margin: mutation.name == "no-margin" ? -2 : 0))
    }
    c.expect(Planner.plan(full12, budget: budget(1445), frontend: idle, model: model).mode == .whole, "plan: 12 MP runs whole when it fits")
    // What a job takes from the host is its footprint and its source plane, which the footprint
    // does not count: 12 B a pixel, 558 MiB at 48 MP (measured, reference device).
    let plane48 = Double(12 * 8064 * 6048) / Double(MB)
    c.near(model.seed(full48, mode: .bands(rows: 1008)).phoneBytes.megabytes - model.seed(full48, mode: .bands(rows: 1008)).peakBytes.megabytes,
           plane48, within: 0.001, "cost: a 48 MP job takes 558 MiB more from the phone than its footprint shows")
    let p48 = Planner.plan(full48, budget: budget(2003), frontend: idle, model: model)
    if case .bands(let rows) = p48.mode {
        c.expect(p48.budget.fits(p48.estimate), "plan: the chosen mode's cost fits the budget")
        c.expect(rows == 1008, "plan: 48 MP in 2,003 MB of phone takes the largest band that fits (6 of 1,008 rows: 1,422 MB and the plane), got \(rows)")
    } else {
        c.expect(false, "plan: 48 MP in 2,003 MB runs in bands, got \(p48.mode.name)")
    }
    // The same 1,445 MB that once took 1,008-row bands: by its footprint alone it fits, and the
    // host would have paid 1,980 MB for it. The smallest band costs the host 1,577 MB.
    c.expect(Planner.plan(full48, budget: budget(1445), frontend: idle, model: model).mode == .wait(.memory),
             "plan: the phone's side counts the source plane (48 MP does not fit in 1,445 MB of phone)")
    c.expect(Planner.plan(full48, budget: budget(1900), frontend: idle, model: model).mode == .bands(rows: 760),
             "plan: and in 1,900 MB it is 760-row bands, not the 1,008 its footprint alone would allow")
    // The allowance is the footprint's: there the plane is not counted, because the operating system does not count it.
    let tight = MemoryBudget.compute(reading(app: 1650, phone: 100_000), frontend: idle,
                                     tuning: BudgetTuning(appReserve: 150, floorReserve: 0, margin: mutation.name == "no-margin" ? -2 : 0))
    c.expect(Planner.plan(full48, budget: tight, frontend: idle, model: model).mode == .bands(rows: 1008),
             "plan: the allowance's side is the footprint alone (1,008-row bands in 1,500 MB of allowance)")
    c.expect(Planner.plan(full48, budget: budget(200), frontend: idle, model: model).mode == .wait(.memory), "plan: a job that cannot fit waits; it does not gamble")
    let floor = BandGeometry(canvas: frame48).floorRows
    c.expect(Planner.ladder(for: full48).allSatisfy { if case .bands(let r) = $0 { r >= floor } else { true } },
             "plan: no band is shorter than its own halo's floor (~280 rows at 48 MP)")
    c.expect(Planner.ladder(for: job(.canvasDevelop, canvas, tier: .live)) == [.whole], "plan: a canvas is one piece")
    // What the planner makes of it: the same frame in the same memory, a mode smaller.
    let fitsWhole = UInt64(model.seed(export12, mode: .whole).phoneBytes.megabytes.rounded(.up)) + 1
    c.expect(Planner.plan(export12, budget: budget(fitsWhole), frontend: idle, model: model).mode == .whole
             && Planner.plan(export12own, budget: budget(fitsWhole), frontend: idle, model: model).mode != .whole,
             "layers: a pair that prints a frame for itself is planned with its second result (whole without, not whole with, in \(fitsWhole) MB)")
    // The engine bands no frame with a crop or a turn: it renders it whole whatever it is asked.
    let cropped = job(.export, frame48, bandable: false)
    c.expect(Planner.ladder(for: cropped) == [.whole], "plan: a frame the engine cannot band is one piece")
    c.expect(Planner.plan(cropped, budget: budget(1500), frontend: idle, model: model).mode == .wait(.memory),
             "plan: a cropped 48 MP frame waits in 1,500 MB; it is not planned as bands the engine would not cut")
    c.expect(Planner.plan(cropped, budget: budget(3900), frontend: idle, model: model).mode == .whole,
             "plan: and runs whole when a whole render fits")
    var live = FrontendState(); live.camera = .live(photoMegapixels: 48)
    c.expect(Planner.plan(job(.shot, frame48, decodes: true), budget: budget(8000), frontend: live, model: model).mode == .wait(.camera),
             "plan: a 48 MP shot waits while the camera is live (the kill, twice)")
    c.expect(Planner.plan(job(.shot, frame12, decodes: true), budget: budget(8000), frontend: live, model: model).mode != .wait(.camera),
             "plan: a 12 MP shot develops behind the viewfinder")
    c.expect(Planner.plan(full12, budget: budget(8000), frontend: live, model: model).mode == .wait(.camera), "plan: an export waits while the camera is live")
    var inFlight = live; inFlight.capturesInFlight = 1
    c.expect(Planner.plan(job(.shot, frame12), budget: budget(8000), frontend: inFlight, model: model).mode == .wait(.capture),
             "plan: everything holds while a photo is in flight")
    // A photo in flight and a develop below the full tier: the capture rule. (The owner's flow,
    // 2026-10-03: photos are taken and developed at the same time, at preview size.)
    // `wrong-capture-rule` hands each check another rule than the one it names.
    func rule(_ r: CaptureRule) -> CaptureRule {
        mutation.name == "wrong-capture-rule" ? (r == .shares ? .stops : .shares) : r
    }
    let preview = job(.shot, canvas, tier: .preview, decodes: true)
    c.expect(Planner.plan(preview, budget: budget(8000), frontend: inFlight, model: model, captures: rule(.stops)).mode == .wait(.capture),
             "capture: under `stops` no develop starts while a photo is in flight")
    c.expect(Planner.plan(preview, budget: budget(8000), frontend: inFlight, model: model, captures: rule(.holds)).mode == .wait(.capture),
             "capture: under `holds` none starts either")
    c.expect(Planner.plan(preview, budget: budget(8000), frontend: inFlight, model: model, captures: rule(.shares)).mode == .whole,
             "capture: under `shares` a preview develops beside a photo in flight when the budget has room")
    c.expect(Planner.plan(job(.shot, frame12, decodes: true), budget: budget(8000), frontend: inFlight, model: model, captures: .shares).mode
                == .wait(.capture), "capture: a full-size job never starts under a photo, whatever the rule")
    c.expect(Planner.plan(preview, budget: budget(300), frontend: inFlight, model: model, captures: .shares).mode == .wait(.camera),
             "capture: and under `shares` a preview that does not fit waits for the camera")
    // The job the app submits behind the viewfinder: a shot at 2,400 px, its frame decoded at
    // that size. Measured on the reference device beside a live camera (EngineBench `shoot`, 70 jobs).
    let shotPreview = job(.shot, PixelSize(width: 2400, height: 1800), tier: .preview, decodes: true)
    let shotCost = model.seed(shotPreview, mode: .whole)
    c.expect(shotCost.peakBytes.megabytes >= 455 && shotCost.peakBytes.megabytes <= 455 * 1.25,
             "cost: a shot's preview at 2,400 px is predicted at or over its measured peak (394-455 MB) and within a quarter of it, got \(Int(shotCost.peakBytes.megabytes))")
    c.near(shotCost.seconds, 0.45, within: 0.25, "cost: and at about its measured time (0.33-0.56 s)")
    // The small decode is priced by the original: a decoder may hold all of it while it works.
    // Core Image's open of a 2,400 px frame was 290-308 MB from 12 MP and 438-588 MB from 48 MP.
    let shot12 = job(.shot, PixelSize(width: 2400, height: 1800), tier: .preview, decodes: true, original: frame12)
    let shot48 = job(.shot, PixelSize(width: 2400, height: 1800), tier: .preview, decodes: true, original: frame48)
    let cost12 = model.seed(shot12, mode: .whole).peakBytes.megabytes, cost48 = model.seed(shot48, mode: .whole).peakBytes.megabytes
    c.expect(cost48 >= 588 && cost48 <= 588 * 1.05,
             "cost: a 48 MP photo's preview is priced at the dearest open measured (588 MB, by Core Image), got \(Int(cost48))")
    c.expect(cost12 >= 456 && cost12 <= 456 * 1.25, "cost: a 12 MP photo's at its render (360-456 MB measured), got \(Int(cost12))")
    c.near(model.seed(shot48, mode: .whole).seconds, 0.55, within: 0.25, "cost: a 48 MP photo's preview takes 0.35-0.64 s")
    var taught = CostModel(policy: policy)
    for _ in 0..<10 { taught.learn(shot12, mode: .whole, measuredPeakBytes: 360 * MB, measuredSeconds: 0.4) }
    c.expect(taught.estimate(shot12, mode: .whole).peakBytes < model.seed(shot12, mode: .whole).peakBytes,
             "learn: a 12 MP photo's previews teach the model what a 12 MP photo's preview costs")
    c.expect(taught.estimate(shot48, mode: .whole).peakBytes == model.seed(shot48, mode: .whole).peakBytes,
             "learn: and nothing about a 48 MP photo's: the small decode's cost is the original's")
    var live48 = FrontendState(); live48.camera = .live(photoMegapixels: 48)
    let afterPhotos = MemoryBudget.compute(reading(app: 6085, phone: 2011), frontend: live48, tuning: tuning)
    c.expect(Planner.plan(shotPreview, budget: afterPhotos, frontend: live48, model: model).mode == .whole,
             "plan: a shot's preview develops beside a camera live at 48 MP, the phone as it was after photos (2,011 MB of headroom)")
    let tighter = MemoryBudget.compute(reading(app: 6085, phone: 1900), frontend: live48, tuning: tuning)
    c.expect(Planner.plan(shotPreview, budget: tighter, frontend: live48, model: model).mode == .wait(.camera),
             "plan: and waits for the camera when the phone has 1,900 MB and the camera has yet to take its first photo")
    // The host as it was through a whole run with the camera live at 48 MP: 1,850 MB.
    let warmed = MemoryBudget.compute(reading(app: 6085, phone: 1850), frontend: live48, tuning: tuning, cameraWarm: true)
    c.expect(Planner.plan(shot48, budget: warmed, frontend: live48, model: model).mode == .whole,
             "plan: once the camera has delivered a photo, a 48 MP shot's preview develops beside it with 1,850 MB of headroom")
    let spent = MemoryBudget.compute(reading(app: 6085, phone: 1519), frontend: live48, tuning: tuning, cameraWarm: true)
    c.expect(Planner.plan(shot48, budget: spent, frontend: live48, model: model).mode == .wait(.camera),
             "plan: and still waits with 1,519 MB, where the phone was just after the first photos")
    let unwarmed = MemoryBudget.compute(reading(app: 6085, phone: 1850), frontend: live48, tuning: tuning)
    c.expect(Planner.plan(shot48, budget: unwarmed, frontend: live48, model: model).mode == .wait(.camera),
             "plan: with the first photo's growth reserved it waits at 1,850 MB too (a whole run of the phone, before this)")
    var away = FrontendState(); away.scene = .background
    c.expect(Planner.plan(full12, budget: budget(8000), frontend: away, model: model).mode == .wait(.background), "plan: nothing renders in the background")

    // ---- the cost model learns (R9) ----
    var learning = CostModel(policy: policy)
    let predicted = learning.estimate(full12, mode: .whole).seconds
    for _ in 0..<20 { learning.learn(full12, mode: .whole, measuredPeakBytes: 0, measuredSeconds: predicted * 1.25) }
    c.near(learning.estimate(full12, mode: .whole).seconds, predicted * 1.25, within: 0.10, "learn: after 20 jobs a 25 % slow engine is predicted within 10 %")
    c.expect(learning.estimate(full12, mode: .whole).peakBytes == CostModel(policy: policy).estimate(full12, mode: .whole).peakBytes,
             "learn: a peak that was not measured leaves the peak's prediction alone")

    // ---- the queue (§6.9), over the simulated engine ----
    func scheduler(speed: Double = 50,
                   memory: @escaping @MainActor () -> MemoryReading = { reading(app: 6000, phone: 6000) }) -> RenderQueue {
        let s = RenderQueue(engine: SimulatedEngine(policy: policy, speed: speed), policy: policy, defaults: nil)
        s.readMemory = mutation.name == "free-memory" ? { reading(app: 100_000, phone: 100_000) } : memory
        s.replanInterval = 0.02
        s.pressureRecovery = 0.3
        if mutation.name == "never-yield" { s.yieldThreshold = .infinity }
        return s
    }

    // Latest wins: five canvas edits on one frame end as one or two renders.
    do {
        let s = scheduler(), f = UUID()
        var ids: [UUID] = []
        for _ in 0..<5 { ids.append(s.submit(job(.canvasReprint, canvas, tier: .live, frame: f, layers: [.print]))) }
        var finished = 0
        for id in ids { if case .finished = await s.outcome(of: id) { finished += 1 } }
        c.expect(await s.outcome(of: ids.last!) != .cancelled, "queue: the newest canvas edit is the one that renders")
        c.expect(finished <= 2, "queue: superseded canvas work is cancelled, not finished (\(finished) of 5 ran)")
        c.expect(s.isIdle, "queue: nothing is left behind")
    }
    // An export gives way to a canvas edit, and still finishes.
    do {
        let s = scheduler()
        let export = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 20_000_000)
        let edit = s.submit(job(.canvasDevelop, canvas, tier: .live, layers: [.shoot]))
        let editDone = await s.outcome(of: edit)
        let exportStillWaiting = s.snapshots.contains { $0.id == export }
        c.expect(editDone != .cancelled && exportStillWaiting, "queue: an export gives way to a canvas edit")
        let exportDone = await s.outcome(of: export)
        if case .finished = exportDone { c.expect(true, "") } else { c.expect(false, "queue: an export that gave way still finishes") }
        c.expect(s.records.contains { $0.outcome.contains("gave way") } , "log: a job that gave way says so in its record")
    }
    // A job that cannot fit waits, says why, and runs when memory comes back.
    do {
        var free: UInt64 = 300
        let s = scheduler(memory: { reading(app: 6000, phone: free) })
        let id = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 60_000_000)
        let waiting = s.snapshots.first { $0.id == id }?.state == .waiting(.memory)
        c.expect(waiting, "queue: with 300 MB free a 48 MP export waits for memory, and says so")
        free = 6000
        let done = await s.outcome(of: id)
        if case .finished = done { c.expect(true, "") } else { c.expect(false, "queue: a waiting job runs once memory returns") }
        c.expect(s.records.last?.waits.contains("memory") ?? false, "log: a job's waits are in its record")
    }
    // A job waits for memory the engine's own idle pool is holding: the pool is given back, and
    // the job runs. Measured on the reference device before this: 8 s of waiting beside 1,568 MB of pool.
    do {
        let held = Held(2000)
        let engine = SimulatedEngine(policy: policy, speed: 50)
        engine.onTrim = { held.take() * MB }
        let s = RenderQueue(engine: engine, policy: policy, defaults: nil)
        s.readMemory = { reading(app: 6000, phone: 4000 - held.value) }   // 2,000 MB while the pool is held: not enough
        s.replanInterval = 0.02
        if mutation.name == "never-trim" { s.trimsWhenWaiting = false; s.reclaimsForAsked = false }   // both ways a wait gives the pool back
        let id = s.submit(job(.export, frame48, decodes: true))
        var ran = false
        for _ in 0..<150 where !ran {
            try? await Task.sleep(nanoseconds: 10_000_000)
            ran = !s.snapshots.contains { $0.id == id }
        }
        c.expect(ran, "wait: a job waiting for memory has the engine's idle pool given back, and runs")
        c.expect(held.value == 0 || mutation.name == "never-trim", "wait: the pool was trimmed")
        s.cancel(id)
    }
    // Critical pressure: the job is cancelled and runs again in a smaller mode.
    do {
        let s = scheduler(memory: { reading(app: 6000, phone: 3400) })
        let id = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 15_000_000)
        let first = s.snapshots.first { $0.id == id }?.mode
        if mutation.name != "ignore-pressure" { s.memoryPressure(.critical) }
        let done = await s.outcome(of: id)
        let modes = s.records.filter { $0.jobID == id }.map(\.mode)
        c.expect(modes.count >= 2 && modes.first != modes.last, "pressure: the job runs again in a smaller mode (\(modes.joined(separator: " then ")))")
        if case .finished = done { c.expect(true, "") } else { c.expect(false, "pressure: the job still finishes") }
        c.expect(first != nil, "pressure: the job was running when the pressure came")
    }
    // The background: a running export stops, waits, and finishes when the app is back.
    do {
        let s = scheduler()
        let id = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 15_000_000)
        s.frontend.scene = .background
        try? await Task.sleep(nanoseconds: 80_000_000)
        c.expect(s.snapshots.first { $0.id == id }?.state == .waiting(.background), "background: an export stops and says it is paused")
        s.frontend.scene = .active
        if case .finished = await s.outcome(of: id) { c.expect(true, "") } else { c.expect(false, "background: it finishes when the app is back") }
    }
    // The camera: an export waits while it is live, and a capture in flight holds a shot's develop.
    do {
        let s = scheduler()
        s.frontend.camera = .live(photoMegapixels: 12)
        let export = s.submit(job(.export, frame12, decodes: true))
        let shot = s.submit(job(.shot, frame12, tier: .preview, decodes: true))
        if case .finished = await s.outcome(of: shot) { c.expect(true, "") } else { c.expect(false, "camera: a 12 MP shot develops while the camera is live") }
        c.expect(s.snapshots.first { $0.id == export }?.state == .waiting(.camera), "camera: an export waits while the camera is live")
        s.frontend.camera = .off
        if case .finished = await s.outcome(of: export) { c.expect(true, "") } else { c.expect(false, "camera: the export runs once the camera is off") }
    }
    // A photo taken while a shot's preview develops, under each capture rule. The engine at a
    // tenth of the usual test speed, so a develop lasts long enough to be interrupted (~90 ms).
    func whileShooting(_ r: CaptureRule) -> RenderQueue {
        let s = scheduler(speed: 5)
        s.captureRule = rule(r)
        s.frontend.camera = .live(photoMegapixels: 12)
        return s
    }
    func gaveWay(_ s: RenderQueue, _ id: UUID) -> Bool { s.records.contains { $0.jobID == id && $0.outcome.contains("gave way") } }
    c.expect(scheduler().captureRule == .holds,
             "capture: by default a develop under way finishes under a photo and none starts under one (the owner's flow)")
    /// Whether the job finishes within two seconds: a check must fail on a broken rule, not wait for ever on it.
    func finishes(_ s: RenderQueue, _ id: UUID) async -> Bool {
        let until = Date().addingTimeInterval(2)
        while Date() < until, s.snapshots.contains(where: { $0.id == id }) { try? await Task.sleep(nanoseconds: 5_000_000) }
        guard !s.snapshots.contains(where: { $0.id == id }) else { return false }
        if case .finished = await s.outcome(of: id) { return true }
        return false
    }
    do {
        // stops: the develop is cancelled when the photo is taken, and runs again once it lands.
        let s = whileShooting(.stops)
        let id = s.submit(preview)
        try? await Task.sleep(nanoseconds: 25_000_000)
        s.frontend.capturesInFlight = 1
        try? await Task.sleep(nanoseconds: 120_000_000)
        let waitsForIt = s.snapshots.first { $0.id == id }?.state == JobSnapshot.State.waiting(.capture)
        c.expect(gaveWay(s, id) && waitsForIt, "capture, stops: a photo stops the develop, which waits for it to land")
        s.frontend.capturesInFlight = 0
        c.expect(await finishes(s, id), "capture, stops: the develop runs again once the photo has landed")
    }
    do {
        // holds: the develop finishes under the photo; the next one waits for the photo to land.
        let s = whileShooting(.holds)
        let id = s.submit(preview)
        try? await Task.sleep(nanoseconds: 25_000_000)
        s.frontend.capturesInFlight = 1
        let next = s.submit(job(.shot, canvas, tier: .preview, decodes: true))
        let finished = await finishes(s, id)
        let stillInFlight = s.frontend.capturesInFlight == 1
        c.expect(finished && !gaveWay(s, id) && stillInFlight, "capture, holds: a develop under way finishes under the photo")
        try? await Task.sleep(nanoseconds: 40_000_000)
        let nextWaits = s.snapshots.first { $0.id == next }?.state == JobSnapshot.State.waiting(.capture)
        c.expect(nextWaits, "capture, holds: the next develop waits for the photo to land")
        s.frontend.capturesInFlight = 0
        c.expect(await finishes(s, next), "capture, holds: and runs once it has")
        s.cancel(id); s.cancel(next)
    }
    do {
        // shares: a develop starts and finishes with the photo still in flight; a full-size shot does not start.
        let s = whileShooting(.shares)
        s.frontend.capturesInFlight = 1
        let id = s.submit(preview)
        let full = s.submit(job(.shot, frame12, decodes: true))
        let finished = await finishes(s, id)
        let stillInFlight = s.frontend.capturesInFlight == 1
        c.expect(finished && !gaveWay(s, id) && stillInFlight, "capture, shares: a preview develops while the photo is in flight")
        try? await Task.sleep(nanoseconds: 40_000_000)
        let fullWaits = s.snapshots.first { $0.id == full }?.state == JobSnapshot.State.waiting(.capture)
        c.expect(fullWaits, "capture, shares: a full-size shot still waits for the photo")
        s.cancel(full); s.cancel(id)
    }
    do {
        // The budget kept one capture's growth aside. A second photo in flight is more than that:
        // the develop gives way. (`no-second-capture` takes only the one.)
        let s = whileShooting(.holds)
        let id = s.submit(preview)
        try? await Task.sleep(nanoseconds: 25_000_000)
        s.frontend.capturesInFlight = mutation.name == "no-second-capture" ? 1 : 2
        try? await Task.sleep(nanoseconds: 120_000_000)
        c.expect(gaveWay(s, id), "capture: a develop goes on under the captures its budget kept aside, and gives way to one more")
        s.frontend.capturesInFlight = 0
        c.expect(await finishes(s, id), "capture: and it finishes once they have landed")
    }
    // The darkroom closed to a live camera (`developsBesideCamera` false; the app's setting since
    // 2026-10-05, the owner: "no shooting while developing enabled first"). Nothing but a thumbnail
    // starts while a camera session runs, whatever its size and whatever the capture rule; a job
    // under way gives way when the camera goes live; the queue runs when the camera is off.
    // `darkroom-open-beside-camera` leaves the darkroom open, as the bench runs it.
    let closed = mutation.name != "darkroom-open-beside-camera"
    c.expect(scheduler().developsBesideCamera, "darkroom: open beside a camera unless the host closes it (the bench's flows; the app closes it)")
    for (kind, tier) in [(JobKind.shot, RenderTier.preview), (.importDevelop, .preview), (.canvasDevelop, .live), (.canvasReprint, .live), (.export, .full)] {
        let j = job(kind, tier == .full ? frame12 : canvas, tier: tier, decodes: kind != .canvasReprint)
        c.expect(Planner.plan(j, budget: budget(8000), frontend: live, model: model, captures: .shares, besideCamera: !closed).mode == .wait(.camera),
                 "darkroom, closed: \(kind.rawValue) waits for the camera with 8 GB to spare and under `shares`")
        c.expect(Planner.plan(j, budget: budget(8000), frontend: idle, model: model, besideCamera: !closed).mode != .wait(.camera),
                 "darkroom, closed: \(kind.rawValue) does not wait for a camera that is off")
    }
    c.expect(Planner.gate(job(.thumbnail, canvas, tier: .preview), frontend: live, policy: policy, besideCamera: !closed) == nil,
             "darkroom, closed: a thumbnail is not a develop")
    do {
        // A shot taken with the page open waits; it is developed when the camera has stopped.
        let s = scheduler(speed: 5)
        s.developsBesideCamera = !closed
        s.frontend.camera = .live(photoMegapixels: 12)
        let shot = s.submit(preview)
        try? await Task.sleep(nanoseconds: 150_000_000)       // longer than the develop would take (~90 ms)
        c.expect(s.snapshots.first { $0.id == shot }?.state == .waiting(.camera) && s.records.isEmpty,
                 "darkroom, closed: a shot's develop does not start while the camera is live")
        s.frontend.camera = .off
        c.expect(await finishes(s, shot), "darkroom, closed: it is developed once the camera has stopped")
    }
    do {
        // The Shoot page opens while the queue is developing: the job gives way, at once, and
        // runs again from the start when the camera has stopped.
        let s = scheduler(speed: 5)
        s.developsBesideCamera = !closed
        let id = s.submit(job(.importDevelop, canvas, tier: .preview, decodes: true))
        try? await Task.sleep(nanoseconds: 25_000_000)
        let wasRunning = s.snapshots.first { $0.id == id }.map { if case .running = $0.state { true } else { false } } ?? false
        s.frontend.camera = .live(photoMegapixels: 48)
        try? await Task.sleep(nanoseconds: 120_000_000)
        c.expect(wasRunning && gaveWay(s, id) && s.snapshots.first { $0.id == id }?.state == .waiting(.camera),
                 "darkroom, closed: a develop under way gives way when the camera goes live, and waits for it")
        s.frontend.camera = .off
        c.expect(await finishes(s, id), "darkroom, closed: and runs again once the camera has stopped")
    }
    do {
        // A camera session starting is when the closed darkroom gives back what it holds: the
        // frontend's caches, once, as the session starts -- and not again at every photo.
        let s = scheduler()
        s.developsBesideCamera = !closed
        var trims = 0
        s.onTrimCaches = { trims += 1 }
        s.frontend.camera = .live(photoMegapixels: 48)
        c.expect(trims == 1, "darkroom, closed: the frontend's caches are given back when a camera session starts, got \(trims)")
        s.frontend.capturesInFlight = 1
        s.frontend.capturesInFlight = 0
        s.frontend.camera = .live(photoMegapixels: 12)
        c.expect(trims == 1, "darkroom, closed: and not again while the session runs, got \(trims)")
        s.frontend.camera = .off
        s.frontend.camera = .live(photoMegapixels: 12)
        c.expect(trims == 2, "darkroom, closed: the next session gives them back again, got \(trims)")
    }

    // The scheduler knows the camera has delivered a photo from the captures it is told of, and
    // forgets when the camera is set up again or has taken none for a while.
    do {
        let s = scheduler()
        if mutation.name == "camera-never-warm" { s.tuning.cameraWarmSeconds = -1 }
        func reserve() -> UInt64 { s.budgetNow().budget.cameraReserve / MB }
        s.frontend.camera = .live(photoMegapixels: 48)
        c.expect(reserve() == 750, "camera: before its first photo the reserve is the first photo's growth (750 MB at 48 MP), got \(reserve())")
        s.frontend.capturesInFlight = 1
        c.expect(reserve() == 1500, "camera: with that photo in flight, twice it, got \(reserve())")
        s.frontend.capturesInFlight = 0
        c.expect(reserve() == 420, "camera: once it has landed, the next one's (420 MB), got \(reserve())")
        s.frontend.camera = .off
        s.frontend.camera = .live(photoMegapixels: 48)
        c.expect(reserve() == 750, "camera: a session started again has yet to take its first, got \(reserve())")
        s.frontend.capturesInFlight = 1
        s.frontend.capturesInFlight = 0
        s.tuning.cameraWarmSeconds = mutation.name == "camera-stays-warm" ? .infinity : (mutation.name == "camera-never-warm" ? -1 : 0.03)
        try? await Task.sleep(nanoseconds: 60_000_000)
        c.expect(reserve() == 750, "camera: and one that has taken none for a while is reserved its first again, got \(reserve())")
    }
    // The picture is the size that was asked for and priced. An engine handed a frame larger than
    // the job's canvas renders its own tier: a shot asked at 2,400 px came back 3,400 px at 1.6
    // times the predicted peak (EngineBench, 2026-10-03). The record says so.
    do {
        let engine = SimulatedEngine(policy: policy, speed: 50)
        if mutation.name != "renders-as-asked" {
            engine.renders = { $0.kind == .shot ? PixelSize(width: 3400, height: 2267) : $0.canvas }
        }
        let s = RenderQueue(engine: engine, policy: policy, defaults: nil)
        s.readMemory = { reading(app: 6000, phone: 6000) }
        _ = await s.outcome(of: s.submit(preview))
        c.expect(s.records.last?.renderedInstead == "3400x2267", "log: a render that is not the size the job asked for says so in its record")
        c.expect(s.costModel.corrections[CostModel.key(preview, mode: .whole)] == nil,
                 "learn: a render that was not the job priced teaches the cost model nothing")
        let edit = job(.canvasDevelop, canvas, tier: .live)
        _ = await s.outcome(of: s.submit(edit))
        c.expect(s.records.last?.renderedInstead == nil, "log: and a render of the size asked says nothing")
        c.expect(s.costModel.corrections[CostModel.key(edit, mode: .whole)] != nil, "learn: and one that was is learned from")
        let over = preview.isOverAsked(PixelSize(width: 3400, height: 2267))
        let rounded = preview.isOverAsked(PixelSize(width: 2399, height: 1601))
        let smaller = preview.isOverAsked(PixelSize(width: 1600, height: 1067))
        c.expect(over && !rounded && !smaller, "log: larger than asked is over; the canvas to a pixel's rounding, or a smaller frame, is not")
    }

    // ---- Develop's strips: a stock's preview (design/v4 §6) ----
    // A card is the frame through one film and paper at the live tier's smallest (800 px), opened at
    // the meter's 1,600 px. The page's own develop always wins: a card starts only when nothing else
    // is queued, gives way at once to anything submitted, and a newer card in the same slot replaces
    // the one before it. `previews-wait-their-turn` leaves a running card to finish as any small job
    // is left; `previews-jump-the-queue` lets one start beside a job that waits; `previews-not-coalesced`
    // keeps every card asked for.
    let cardCanvas = PixelSize(width: 800, height: 600), cardOpens = PixelSize(width: 1600, height: 1200)
    func card(_ frame: UUID = UUID(), slot: String = "film:a", decodes: Bool = false, original: PixelSize? = nil) -> RenderJob {
        RenderJob(frameID: frame, kind: .stockPreview, tier: .live, canvas: cardCanvas, what: "card", decodesOriginal: decodes,
                  original: original, opens: cardOpens, slot: slot)
    }
    func previewScheduler(speed: Double, memory: @escaping @MainActor () -> MemoryReading = { reading(app: 6000, phone: 6000) }) -> RenderQueue {
        let s = scheduler(speed: speed, memory: memory)
        if mutation.name == "previews-wait-their-turn" { s.previewsGiveWayAtOnce = false }
        if mutation.name == "previews-jump-the-queue" { s.previewsWaitForTheQueue = false }
        if mutation.name == "previews-not-coalesced" { s.previewsCoalesce = false }
        return s
    }
    func running(_ s: RenderQueue, _ id: UUID) -> Bool {
        s.snapshots.first { $0.id == id }.map { if case .running = $0.state { true } else { false } } ?? false
    }
    // 2026-10-21: after everything someone waits on and the shots; before the library's own develops of
    // other frames and the thumbnails (a RAW's cards waited 20 minutes behind 85 of them on the owner's reference device).
    c.expect(JobKind.allCases.filter { $0.isAsked || $0 == .shot }.allSatisfy { $0.priority < JobKind.stockPreview.priority }
             && JobKind.stockPreview.priority < JobKind.importDevelop.priority && JobKind.stockPreview.priority < JobKind.thumbnail.priority,
             "previews: a stock's preview comes after the page, the shots and the exports, and before the library's own develops")
    c.expect(Planner.gate(card(), frontend: live, policy: policy, besideCamera: true) == .camera,
             "previews: a card waits for a live camera even where the darkroom is open beside one")
    c.expect(Planner.ladder(for: card()) == [.whole], "previews: a card is one piece")
    // Priced by the frame it opens: the source plane is 12 B a pixel of 1,600 x 1,200, not of the canvas.
    let cardCost = model.seed(card(), mode: .whole)
    c.expect(cardCost.phoneBytes - cardCost.peakBytes == UInt64(12 * 1600 * 1200),
             "previews: the source plane is priced by the frame opened (1,600 px), got \((cardCost.phoneBytes - cardCost.peakBytes).megabytes) MB")
    let decodingCard = model.seed(card(decodes: true, original: frame48), mode: .whole)
    c.expect(decodingCard.peakBytes > cardCost.peakBytes, "previews: the card that decodes the strip's picture is priced for the decode")
    c.expect(CostModel.key(card(decodes: true, original: frame48), mode: .whole)
             != CostModel.key(job(.canvasDevelop, cardCanvas, tier: .live, decodes: true, original: frame48), mode: .whole),
             "previews: a card teaches the cost model nothing about the page's develop")
    c.expect(card().openedInstead(cardOpens) == nil && !card().isOverOpened(cardOpens) && card().isOverOpened(frame48),
             "previews: opening 1,600 px is what a card was priced for; opening the original is not")
    do {
        // The page's develop is submitted while a card runs: the card gives way at once and runs again
        // after it. At this speed a card takes ~0.3 s, under the 0.4 s a small job is otherwise left.
        let s = previewScheduler(speed: 0.18)
        let preview = s.submit(card())
        try? await Task.sleep(nanoseconds: 40_000_000)
        let wasRunning = running(s, preview)
        let asked = Date()
        let develop = s.submit(job(.canvasDevelop, canvas, tier: .live, layers: [.shoot]))
        var started: Double?
        for _ in 0..<100 where started == nil {
            if running(s, develop) || s.records.contains(where: { $0.jobID == develop }) { started = Date().timeIntervalSince(asked) }
            else { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        c.expect(wasRunning && (started ?? 9) < 0.1,
                 "previews: the page's develop starts at once over a running card (\(String(format: "%.0f", (started ?? 9) * 1000)) ms)")
        c.expect(s.records.contains { $0.jobID == preview && $0.outcome.contains("gave way") }, "previews: the card says it gave way")
        let developDone = await s.outcome(of: develop)
        let previewDone = await s.outcome(of: preview)
        if case .finished = developDone, case .finished = previewDone { c.expect(true, "") }
        else { c.expect(false, "previews: the develop finishes, and the card after it") }
    }
    // ---- reclaim before waiting (the owner, 2026-10-21: "really really aggressive") ----
    do {
        var r = reading(app: 6000, phone: 1500)
        r.compressed = 1000 * MB
        let strict = MemoryBudget.compute(r, frontend: FrontendState())
        let asked = MemoryBudget.compute(r, frontend: FrontendState(), asked: true)
        c.expect(asked.phoneSide / MB == 1500 + 500 - 450 && strict.phoneSide / MB == 1500 - 600,
                 "asked: the phone side counts half the compressed memory and a 450 MB floor (\(asked.phoneSide / MB) MB, strict \(strict.phoneSide / MB))")
        var live = FrontendState(); live.camera = .live(photoMegapixels: 12)
        c.expect(MemoryBudget.compute(r, frontend: live, asked: true) == MemoryBudget.compute(r, frontend: live),
                 "asked: with the camera live nothing is loosened")
        c.expect(asked.appSide == strict.appSide, "asked: the app's own allowance is never loosened")
    }
    do {
        // An export that does not fit: the frontend's caches go first, and what they free lets it start.
        var phone: UInt64 = 500
        var reclaims = 0
        let s = scheduler(memory: { reading(app: 6000, phone: phone) })
        s.onReclaim = { reclaims += 1; phone = 6000 }
        let started = Date()
        let export = s.submit(job(.export, frame48, decodes: true))
        let out = await s.outcome(of: export)
        if case .finished = out { c.expect(reclaims == 1 && Date().timeIntervalSince(started) < 1,
                                            "reclaim: a waiting export has the caches given back and starts (\(reclaims) reclaim, \(String(format: "%.2f", Date().timeIntervalSince(started))) s)") }
        else { c.expect(false, "reclaim: the export finishes once the caches are given back") }
    }
    do {
        // Nothing to give back: the export starts in its smallest mode against the allowance alone.
        let s = scheduler(memory: { reading(app: 6000, phone: 700) })
        s.forceAfter = 0.2
        let export = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let waited = s.snapshots.first { $0.id == export }?.state == .waiting(.memory)
        let out = await s.outcome(of: export)
        let mode = s.records.first { $0.jobID == export && $0.outcome == "done" }?.mode ?? "none"
        if case .finished = out { c.expect(waited && mode == Planner.ladder(for: job(.export, frame48, decodes: true)).last?.name,
                                            "reclaim: with nothing left to give back an export waits a moment, then runs in its smallest mode (\(mode))") }
        else { c.expect(false, "reclaim: the export runs in the end") }
    }
    do {
        // Not past the allowance: an export the app's own allowance cannot hold still waits.
        let s = scheduler(memory: { reading(app: 300, phone: 700) })
        s.forceAfter = 0.05
        let export = s.submit(job(.export, frame48, decodes: true))
        try? await Task.sleep(nanoseconds: 400_000_000)
        c.expect(s.snapshots.first { $0.id == export }?.state == .waiting(.memory) && !s.records.contains { $0.jobID == export },
                 "reclaim: a job the app's allowance cannot hold is never forced")
        s.cancelAll(frameID: s.snapshots.first { $0.id == export }?.job.frameID ?? UUID())
    }

    do {
        // The owner's reference device, 2026-10-21: a RAW's preview never landed. A canvas job whose open takes the
        // host's headroom under the watch's line while it runs (a RAW open is priced at a quarter of what it
        // takes) must still land: the watch is for full-size jobs, never the page's own picture.
        let s = scheduler(speed: 2, memory: { reading(app: 6000, phone: 1800) })
        s.readMemory = { [weak s] in reading(app: 6000, phone: s?.isIdle == false ? 300 : 1800) }
        let f = UUID()
        let canvas = s.submit(job(.canvasDevelop, PixelSize(width: 2400, height: 1600), tier: .live, frame: f))
        // Not awaited: a job the watch keeps cancelling never ends.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let landed = s.records.contains { $0.jobID == canvas && $0.outcome == "done" }
        let cancels = s.records.filter { $0.jobID == canvas && $0.outcome.contains("pressure") }.count
        c.expect(landed && cancels == 0, "watch: the page's picture lands under a dip in headroom, never cancelled by the watch (landed \(landed), \(cancels) cancels)")
        s.cancelAll(frameID: f)
    }

    do {
        // the operating system's own critical warning during the page's picture: the caches go, the picture still lands.
        let s = scheduler(speed: 1)
        let f = UUID()
        let canvas = s.submit(job(.canvasDevelop, PixelSize(width: 2400, height: 1600), tier: .live, frame: f))
        try? await Task.sleep(nanoseconds: 30_000_000)
        s.memoryPressure(.critical)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let landed = s.records.contains { $0.jobID == canvas && $0.outcome == "done" }
        c.expect(landed && !s.records.contains { $0.jobID == canvas && $0.outcome.contains("pressure") },
                 "pressure: a critical warning does not cancel the page's picture (landed \(landed))")
        s.cancelAll(frameID: f)
    }

    do {
        // The owner's reference device, 2026-10-21: a frame's cards under a library of develops still land.
        let s = previewScheduler(speed: 0.5)
        let library = (0..<12).map { _ in s.submit(job(.importDevelop, PixelSize(width: 2400, height: 1600), tier: .preview, frame: UUID())) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let preview = s.submit(card(decodes: false))
        let out = await s.outcome(of: preview)
        let left = library.filter { id in s.snapshots.contains { $0.id == id } }.count
        if case .finished = out { c.expect(left >= 8, "previews: a card lands ahead of the library's develops of other frames (\(left) of 12 still waiting)") }
        else { c.expect(false, "previews: the card lands") }
        for id in library { s.cancel(id) }
        // Asked twice before it starts, a frame's develop is one job.
        let f = UUID()
        let a = s.submit(job(.importDevelop, PixelSize(width: 2400, height: 1600), tier: .preview, frame: f))
        let b = s.submit(job(.importDevelop, PixelSize(width: 2400, height: 1600), tier: .preview, frame: f))
        let first = await s.outcome(of: a)
        c.expect(first == .cancelled && s.snapshots.contains { $0.id == b } || s.records.contains { $0.jobID == b },
                 "coalesce: a frame's develop asked twice before it starts is one job")
        s.cancel(b)
        // 2026-11-05: a frame's preview develop (a paste onto it) and the Mac's full-size prefetch of the
        // same frame (Develop's neighbour) are two jobs of two sizes: the prefetch must not cancel the
        // preview, or the tile reads developed and keeps the picture of the old edit.
        let g = UUID()
        let small = s.submit(job(.importDevelop, PixelSize(width: 2400, height: 1600), tier: .preview, frame: g))
        let full = s.submit(job(.importDevelop, PixelSize(width: 2400, height: 1600), tier: .full, frame: g))
        let smallOut = await s.outcome(of: small)
        let fullOut = await s.outcome(of: full)
        func landed(_ o: JobOutcome) -> Bool { if case .finished = o { true } else { false } }
        c.expect(landed(smallOut) && landed(fullOut),
                 "coalesce: a frame's preview develop and its full-size prefetch both land (\(smallOut), \(fullOut))")
    }

    do {
        // A 48 MP export waits for memory a card would fit in: the card does not start beside it.
        var free: UInt64 = 1500
        let s = previewScheduler(speed: 50, memory: { reading(app: 6000, phone: free) })
        let export = s.submit(job(.export, frame48, decodes: true))
        let preview = s.submit(card(decodes: true, original: frame12))
        try? await Task.sleep(nanoseconds: 80_000_000)
        let exportWaits = s.snapshots.first { $0.id == export }?.state == .waiting(.memory)
        let previewHeld = s.snapshots.contains { $0.id == preview } && !s.records.contains { $0.jobID == preview }
        c.expect(exportWaits && previewHeld, "previews: a card does not start while a job ahead of it waits for memory")
        free = 6000
        _ = await s.outcome(of: export)
        let previewDone = await s.outcome(of: preview)
        let order = s.records.filter { $0.outcome == "done" }.map(\.kind)
        c.expect(order == ["export", "stockPreview"], "previews: the job ahead runs first, then the card (\(order.joined(separator: ", ")))")
        if case .finished = previewDone { c.expect(true, "") } else { c.expect(false, "previews: and the card finishes") }
    }
    do {
        // Two cards for one slot: the newer replaces the older, queued or running. Another slot is its own.
        let s = previewScheduler(speed: 0.18)
        let f = UUID()
        let first = s.submit(card(f, slot: "film:a"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let queuedOther = s.submit(card(f, slot: "film:b"))
        let queuedSame = s.submit(card(f, slot: "film:b"))
        let newer = s.submit(card(f, slot: "film:a"))
        let firstOut = await s.outcome(of: first), queuedOut = await s.outcome(of: queuedOther)
        let sameOut = await s.outcome(of: queuedSame), newerOut = await s.outcome(of: newer)
        c.expect(firstOut == .cancelled, "previews: a running card is replaced by a newer one for its slot")
        c.expect(queuedOut == .cancelled, "previews: a queued card is replaced by a newer one for its slot")
        if case .finished = sameOut, case .finished = newerOut { c.expect(true, "") }
        else { c.expect(false, "previews: the newer cards finish") }
        c.expect(s.records.filter { $0.outcome == "done" }.count == 2, "previews: two slots, two renders")
    }
    do {
        // Scrolled away: a card queued or running is cancelled, and nothing of it is left behind.
        let s = previewScheduler(speed: 0.18)
        let a = s.submit(card(slot: "film:a")), b = s.submit(card(slot: "film:b"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        s.cancel(b); s.cancel(a)
        let aOut = await s.outcome(of: a), bOut = await s.outcome(of: b)
        c.expect(aOut == .cancelled && bOut == .cancelled && s.isIdle, "previews: a card cancelled, queued or running, is gone")
        c.expect(s.records.first { $0.jobID == a }?.outcome == "cancelled", "previews: and the running one says it was cancelled")
    }
    return c
}

// MARK: - main

@main
struct SelfTest {
    static func main() async {
        let selfTest = CommandLine.arguments.contains("--self-test")
        let result = await run(.none)
        print("scheduler checks: \(result.passed) passed, \(result.failed.count) failed")
        var exitCode: Int32 = result.failed.isEmpty ? 0 : 1
        if selfTest {
            var caught = 0
            for m in Mutation.all {
                let r = await run(m)
                if r.failed.isEmpty { print("  NOT CAUGHT  \(m.name): every check still passed") } else {
                    caught += 1
                    print("  caught  \(m.name): \(r.failed.count) check(s) failed, e.g. \(r.failed[0])")
                }
            }
            print("self-test: \(caught) of \(Mutation.all.count) broken rules caught")
            if caught != Mutation.all.count { exitCode = 1 }
        }
        exit(exitCode)
    }
}
