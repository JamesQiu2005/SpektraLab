//  DoubleHarness.swift — a double exposure walked through the Mac app's own path, on the engine (RFC-048 §7).
//
//  `--double-check [--frames BOTTOM TOP] [--out DIR]`, a debug build with a real library (`tools/double_check.sh`
//  runs it under a scratch `CFFIXED_USER_HOME` with two photographs imported). It walks the model, the router, the
//  queue, the page's session and the Export service, and leaves the pages for phase 2 (the 图层 panel):
//
//  1. **made and kept**: `makeDouble` of two photographs — the frame's size (the bottom's shape, no larger than
//     either fills), the item after its bottom, its recipe and the Mac row's record, `doubles.json`;
//  2. **the wire** (RFC-048 §3): no pair rows, the meter off, no Film Exposure of its own, the look's film format,
//     and every name in the engine's schema;
//  3. **the queue's develop**: each exposure metered once, alone, and kept; the open priced as a composed open
//     (`|double`), its seed against its measured peak — the cost re-fit's numbers;
//  4. **film truth**: the engine's 50 % double at
//     1,920 px against a naive code-value average of the two photographs and a naive code-value sum, and against
//     the average of each exposure developed alone (`developAlone`, R9's render) — paper white, crushed, mean,
//     brightest, the 99.9th luma;
//  5. **swap**: at 50 % of two photographs of one shape the same picture, at 70 % another;
//  6. **R2**: a Balance drag on the page's session asks the live tier while the finger is down, and undoes in one
//     step; **R3**: the whole's white balance writes no photograph, an exposure's writes its own; **R10**: an
//     emptied layer refuses the export, and says why;
//  7. **removal**: the double goes, its photographs stay, its recipe and row with it.
//
//  Each step is a line of `double-check.json` in `--out` (default `~/Desktop/double-check` of the run's home), with
//  the pictures it made; the script reads it and fails on a step that did otherwise.

#if DEBUG
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum DoubleHarness {
    struct Step: Codable {
        var name: String
        var ok: Bool
        var detail: String
        var seconds: Double
    }

    /// The double's jobs, as the queue was handed them and as they ran: each one's composition, the cost model's
    /// own seed of it (unlearned: `CostModel(policy:)`, so a run's corrections do not hide the seed's error), and
    /// the record the queue made of it — the measured peak is the job's `phys_footprint` over rest
    /// (`MemoryProbe`), `footprint -p`'s number.
    final class Recorder {
        struct Job { var job: RenderJob; var seed: CostEstimate; var record: JobRecord? }
        var jobs: [UUID: Job] = [:]
        var order: [UUID] = []
    }
    static let recorder = Recorder()

    static func run(_ model: AppServices, arguments: [String]) {
        guard arguments.contains("--double-check") else { return }
        var out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/double-check", isDirectory: true)
        if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count { out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true) }
        var names: [String] = []
        if let i = arguments.firstIndex(of: "--frames"), i + 2 < arguments.count { names = [arguments[i + 1], arguments[i + 2]] }
        let composition = model.scheduler.composition, record = model.scheduler.onRecord
        model.scheduler.composition = { job in
            let c = composition?(job)
            let priced = c.map { job.composed($0) } ?? job
            recorder.jobs[job.id] = Recorder.Job(job: priced, seed: CostModel(policy: .current).seed(priced, mode: .whole))
            recorder.order.append(job.id)
            return c
        }
        model.scheduler.onRecord = { r in
            record?(r)
            recorder.jobs[r.jobID]?.record = r
        }
        Task { await walk(model, names: names, out: out) }
    }

    private static func walk(_ model: AppServices, names: [String], out: URL) async {
        let arguments = CommandLine.arguments
        queue = model.scheduler
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var steps: [Step] = []
        var clock = Date()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append(Step(name: name, ok: ok, detail: detail, seconds: Date().timeIntervalSince(clock)))
            print("double-check: \(ok ? "ok  " : "FAIL") \(name) -- \(detail)")
            clock = Date()
        }
        defer {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(steps).write(to: out.appendingPathComponent("double-check.json"))
            print("double-check: done, \(steps.filter(\.ok).count) of \(steps.count) as they should be")
            exit(steps.allSatisfy(\.ok) ? 0 : 1)
        }

        // The library's photographs, once every import has developed.
        let photos = await settled(model) { $0.filter { !$0.isComposite && !$0.isDemo } }
        let chosen: [LibraryFrame]
        if names.count == 2, let a = photos.first(where: { $0.fileName.hasPrefix(names[0]) }),
           let b = photos.first(where: { $0.fileName.hasPrefix(names[1]) }) {
            chosen = [a, b]
        } else {
            chosen = Array(photos.prefix(2))
        }
        guard chosen.count == 2 else { return step("two photographs", false, "the library has \(photos.count)") }
        step("two photographs", true, chosen.map { "\($0.fileName) \($0.originalSize.width)x\($0.originalSize.height)" }.joined(separator: ", "))

        // A scratch home has no library of the Mac's to hold a row: one is made there (`tools/double_check.sh`'s
        // home only, never a person's), selected, as a person's first catalog would be.
        if !model.macLibrary.sources.contains(where: \.acceptsImports), NSHomeDirectory().contains("double-check-home") {
            let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Pictures", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let made = try await model.macLibrary.newCatalog(named: "Double Check", in: folder)
                print("double-check: a catalog for the row, \(made.name) at \(made.path ?? "-")")
            } catch {
                print("double-check: no catalog made: \(error.localizedDescription)")
            }
        }

        // 1. made and kept
        guard let id = model.makeDouble(chosen[0].id, chosen[1].id, beginsWithFirst: true), let item = model.library.frame(id),
              let double = item.double else { return step("made", false, "makeDouble returned nothing") }
        let frames = model.darkroom.held(by: double)
        let framed = double.framed(frames)
        let own = double.ownSize(frames)
        let fits = framed.values.allSatisfy { Double($0.width) >= Double(own.width) - 1 || Double($0.height) >= Double(own.height) - 1 }
        step("made", item.isDouble && double.balance.map { abs($0 - 0.5) < 1e-9 } == true && fits,
             "\(item.fileName), frame \(own.width)x\(own.height), balance \(double.balance ?? -1), each \(DoubleExposure.madeEV) EV")
        let recipe = CatalogSourcesStore.doubleFile(item)
        let shelf = model.library.persistence.map { LibraryShelf.doublesURL(beside: $0.url) }
        model.library.flush()
        try? await Task.sleep(for: .seconds(1.5))
        step("kept", FileManager.default.fileExists(atPath: recipe.path) && shelf.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
             "recipe \(recipe.lastPathComponent), doubles.json \(shelf?.path ?? "none")")
        // Its row of the Mac library, by reference (`placeDouble`: the helper's `images.add` of the recipe in the
        // library holding the bottom), recorded in `MacLibrary/doubles.json`. Waited for: the add is the helper's.
        var placed = CatalogSourcesStore.readDoubleRecord().placed[id.uuidString]
        for _ in 0..<40 where placed == nil {
            try? await Task.sleep(for: .milliseconds(250))
            placed = CatalogSourcesStore.readDoubleRecord().placed[id.uuidString]
        }
        step("a row of the Mac library", placed.map { $0.path == recipe.path } == true,
             placed.map { "row \($0.image) in \($0.source), by reference to \(URL(fileURLWithPath: $0.path).lastPathComponent)" } ?? "no row recorded in 10 s")

        // 2. the wire
        let wire = model.darkroom.wire(double.mirrored(frames), item: item, frames: frames, look: item.edit, longEdge: 1600)
        let pairOnly = wire.keys.filter(FrameEdit.isPairOnly)
        let schema = Set(await model.darkroom.schemaNames())
        // `product_defaults` is a switch of the open, not a schema field (`EngineWire.swift`).
        let unknown = schema.isEmpty ? [] : wire.keys.filter { !schema.contains($0) && $0 != "product_defaults" }
        step("the wire", pairOnly.isEmpty && unknown.isEmpty && wire["auto_exposure"] == .bool(false)
                && wire["exposure_compensation_ev"].map { $0 == .double(0) } ?? true,
             "\(wire.count) rows; pair-only \(pairOnly); unknown to the engine \(unknown); film_format_mm \(wire["film_format_mm"].map { "\($0)" } ?? "-")")

        // 3. the queue's develop, priced as a composed open
        guard await developed(model, id) else { return step("developed", false, "the queue's develop did not land") }
        let read = model.library.frame(id)?.double
        let readings = DoubleExposure.Position.allCases.compactMap { read?.reading($0) }
        step("developed and metered", readings.count == 2,
             "readings \(readings.map { String(format: "%+.2f", $0) }), picture \(model.library.frame(id)?.developed?.size.width ?? 0) px")
        let composed = recorder.order.compactMap { recorder.jobs[$0] }.filter { $0.job.frameID == id && $0.job.composition != nil }
        step("priced as a composed open", !composed.isEmpty && composed.allSatisfy { CostModel.key($0.job, mode: .whole).contains("|double") },
             composed.map { "\($0.job.tier.rawValue) seed \($0.seed.peakBytes >> 20) MB" }.joined(separator: ", "))

        // 4. film truth
        let edge = 1920
        guard let engine = await exported(model, id, longEdge: edge, as: out.appendingPathComponent("engine-double-50.png")) else {
            return step("film truth", false, "the export did not land")
        }
        let alone = await (model.developAlone(id, .bottom), model.developAlone(id, .top))
        var lines: [String] = []
        if let a = alone.0, let b = alone.1 {
            write(a, to: out.appendingPathComponent("engine-bottom-alone.png"))
            write(b, to: out.appendingPathComponent("engine-top-alone.png"))
        }
        let size = CGSize(width: engine.width, height: engine.height)
        let laid = laidPhotographs(double, frames: frames, size: size)
        let naiveMix = laid.count == 2 ? codes(laid, size: size, combine: { ($0 + $1) / 2 }) : nil
        let naiveSum = laid.count == 2 ? codes(laid, size: size, combine: { min($0 + $1, 255) }) : nil
        let aloneMix = (alone.0.flatMap { codes(of: $0, size: size) }, alone.1.flatMap { codes(of: $0, size: size) })
        let engineCodes = codes(of: engine, size: size)
        if let naiveMix { write(naiveMix, size: size, to: out.appendingPathComponent("naive-mix-50.png")) }
        if let naiveSum { write(naiveSum, size: size, to: out.appendingPathComponent("naive-sum.png")) }
        var stats: [String: Stats] = [:]
        if let engineCodes { stats["engine double, 50 %"] = Stats(engineCodes) }
        if let naiveMix { stats["naive code mix, 50 %"] = Stats(naiveMix) }
        if let naiveSum { stats["naive code sum"] = Stats(naiveSum) }
        if let a = aloneMix.0, let b = aloneMix.1 {
            stats["bottom developed alone"] = Stats(a)
            stats["top developed alone"] = Stats(b)
            stats["mix of the two alone"] = Stats(zip(a, b).map { ($0 + $1) / 2 })
        }
        for (k, v) in stats.sorted(by: { $0.key < $1.key }) { lines.append("\(k): \(v.text)") }
        let e = stats["engine double, 50 %"], sum = stats["naive code sum"]
        // Film truth: the engine's double never reaches the paper's white where a code-value sum clips.
        step("film truth", e.map { $0.paperWhite < 0.001 && $0.crushed < 0.001 } == true && (sum?.anyHigh ?? 0) > (e?.anyHigh ?? 1),
             lines.joined(separator: "; "))

        // 5. swap: at 50 % one shape develops the same, at 70 % another
        let sameShape = DoubleExposure.sameShape(framed[.bottom].map { Double($0.width / $0.height) }, framed[.top].map { Double($0.width / $0.height) })
        let before = await exportedCodes(model, id, edge: 960, out: out, name: "swap-50-before.png")
        model.swapDouble(id)
        let swapped = await exportedCodes(model, id, edge: 960, out: out, name: "swap-50-after.png")
        if sameShape, let before, let swapped {
            let d = zip(before, swapped).map { abs($0 - $1) }.max() ?? 255
            step("swap at 50 %", d <= 2, "max difference \(d) codes of 255 (two photographs of one shape)")
        } else {
            step("swap at 50 %", true, "not run: the two are not of one shape")
        }
        model.setDoubleBalance(id, 0.7)
        let at70 = await exportedCodes(model, id, edge: 960, out: out, name: "balance-70.png")
        model.swapDouble(id)
        let at70swapped = await exportedCodes(model, id, edge: 960, out: out, name: "balance-70-swapped.png")
        let b70 = model.library.frame(id)?.double
        let evs = DoubleExposure.Position.allCases.compactMap { b70?[$0]?.exposureEV }
        let d70 = (at70.flatMap { a in at70swapped.map { b in zip(a, b).map { abs($0 - $1) }.max() ?? 0 } }) ?? 0
        step("Balance 70 % and a swap", d70 > 4 && abs((b70?.balance ?? 0) - 0.7) < 1e-9,
             "EVs \(evs.map { String(format: "%.4f", $0) }) (log2 0.7 = -0.5146, log2 0.3 = -1.7370), swapped differs by \(d70) codes")

        // 6. R2: a Balance drag on the page's session asks the live tier while the finger is down, one Undo step
        // As a page takes it up (`enter`): only a held session is the page's (`AppServices.openSession`).
        let session = model.session(for: id)
        session.enter()
        session.open()
        _ = await developedOnPage(session)
        let startBalance = model.library.frame(id)?.double?.balance ?? 0
        model.balanceDrag(id, .began, to: 0.55)
        var liveAsked = false
        for s in stride(from: 0.56, through: 0.62, by: 0.01) {
            model.balanceDrag(id, .changed, to: s)
            try? await Task.sleep(for: .milliseconds(120))
        }
        let beforeDrag = Set(recorder.order)
        try? await Task.sleep(for: .milliseconds(900))
        // A canvas develop of the double at the live tier asked while the finger is still down (the film side's
        // rest, `filmSidePause`), before `ended`.
        liveAsked = recorder.order.contains { jid in
            guard let j = recorder.jobs[jid]?.job else { return false }
            return j.frameID == id && j.kind.isCanvas && j.tier == .live
        }
        _ = beforeDrag
        model.balanceDrag(id, .ended, to: 0.62)
        let dragged = model.library.frame(id)?.double?.balance ?? 0
        session.undo()
        let undone = model.library.frame(id)?.double?.balance ?? 0
        step("R2: Balance develops while dragged, one Undo step", liveAsked && abs(dragged - 0.62) < 1e-9 && abs(undone - startBalance) < 1e-9,
             "live develop asked under the finger: \(liveAsked); \(String(format: "%.2f", startBalance)) -> \(String(format: "%.2f", dragged)) -> undo \(String(format: "%.2f", undone))")

        // R3: white balance is each exposure's
        let bottomID = model.library.frame(id)?.double?[.bottom]?.frame
        let wbBefore = bottomID.flatMap { model.library.frame($0)?.edit.decode }
        let wroteWhole = model.changeDecode(on: .film, inDouble: id) { $0.temperature += 500 }
        let wbAfterWhole = bottomID.flatMap { model.library.frame($0)?.edit.decode }
        let wroteTop = model.changeDecode(on: .top, inDouble: id) { $0.tint += 3 }
        step("R3: the whole's white balance writes no photograph", !wroteWhole && wbBefore == wbAfterWhole && wroteTop,
             "whole: \(wroteWhole ? "written" : "refused"), the bottom's photograph \(wbBefore == wbAfterWhole ? "unchanged" : "changed"); top: \(wroteTop ? "written" : "refused")")

        // R10: an emptied layer refuses the export
        let held = model.library.frame(id)?.double
        var emptied = held
        emptied?[.top] = nil
        let refusal = emptied.flatMap { DoubleWords.exportRefusal($0, has: { model.library.frame($0) != nil }) }
        model.changeDouble(id) { piece, _ in piece.origin = nil; _ = piece.fill(.top, with: nil) }
        let source = model.library.frame(id).flatMap { model.darkroom.exportSource($0) }
        step("R10: one exposure left does not export", refusal != nil && source == nil, "\(refusal ?? "no refusal"); export source \(source?.lastPathComponent ?? "none")")
        session.undo()
        session.leave()

        // **The cost re-fit's measurements** (PRD-D §3.6: the earlier figures were never measured):
        // each job alone from rest, its `phys_footprint` sampled every 20 ms in this process — `footprint -p`'s
        // number, never RSS — and the peak over the footprint at rest before it. A double and its bottom
        // photograph alone, at the full tier (a full-size export) and at the preview tier (the queue's develop).
        if !arguments.contains("--no-full") {
            var measures: [String] = []
            func export(_ which: LibraryFrame.ID, _ name: String) async {
                var full = ExportRecipe()
                full.format = .jpeg
                full.size = .full
                let (rest, peak, seconds) = await sampled {
                    model.exporter.start([which], recipe: full)
                    for _ in 0..<3000 {
                        if let b = model.exporter.batch, b.finished { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                let file = model.exporter.batch?.files.first
                let props = file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                measures.append("\(name) full export \(w)x\(h): +\((peak - rest) >> 20) MB over rest \(rest >> 20) MB, \(String(format: "%.2f", seconds)) s")
            }
            func develop(_ which: LibraryFrame.ID, _ name: String) async {
                let (rest, peak, seconds) = await sampled {
                    model.develop(which)
                    _ = await developed(model, which)
                }
                measures.append("\(name) preview develop: +\((peak - rest) >> 20) MB over rest \(rest >> 20) MB, \(String(format: "%.2f", seconds)) s")
            }
            if let bottom = model.library.frame(id)?.double?[.bottom]?.frame {
                // Interleaved (trap 17): the double, then its photograph, then each again.
                for _ in 0..<2 {
                    await develop(id, "double"); await develop(bottom, "photograph")
                    await export(id, "double"); await export(bottom, "photograph")
                }
            }
            for line in measures { print("double-check: measure \(line)") }
            try? measures.joined(separator: "\n").write(to: out.appendingPathComponent("measure.txt"), atomically: true, encoding: .utf8)
            step("measured from rest", measures.count == 8, "\(measures.count) jobs (measure.txt)")
        }

        // The cost re-fit's numbers: every composed job of the walk, its seed against its measured peak.
        var fit: [String] = []
        for j in recorder.order.compactMap({ recorder.jobs[$0] }) {
            guard let r = j.record, let measured = r.measuredPeakBytes else { continue }
            let what = j.job.composition.map { c in "double: decodes \(c.decodes.map { "\($0.width)x\($0.height)" }) raw \(c.raw) scratch \(c.scratchBytes >> 20) MB" }
                ?? "photograph: original \(j.job.original.map { "\($0.width)x\($0.height)" } ?? "-")"
            let line = "\(j.job.kind.rawValue) \(j.job.tier.rawValue) \(r.mode) opens \(j.job.decodesOriginal) canvas \(j.job.canvas.width)x\(j.job.canvas.height) \(what): seed \(j.seed.peakBytes >> 20) MB, measured \(measured >> 20) MB, \(String(format: "%.2f", r.measuredSeconds ?? 0)) s (seed \(String(format: "%.2f", j.seed.seconds)) s)"
            print("double-check: cost \(line)")
            fit.append(line)
        }
        try? fit.joined(separator: "\n").write(to: out.appendingPathComponent("cost.txt"), atomically: true, encoding: .utf8)
        step("cost measured", !fit.isEmpty, "\(fit.count) composed jobs measured (cost.txt)")

        // 7. removal: the double goes, its photographs stay
        model.remove([id])
        try? await Task.sleep(for: .seconds(1.5))
        let left = chosen.allSatisfy { model.library.frame($0.id) != nil }
        let rowLeft = CatalogSourcesStore.readDoubleRecord().placed[id.uuidString] != nil
        step("removed", model.library.frame(id) == nil && left && !FileManager.default.fileExists(atPath: recipe.path) && !rowLeft,
             "photographs \(left ? "stay" : "gone"), recipe \(FileManager.default.fileExists(atPath: recipe.path) ? "still there" : "gone"), row \(rowLeft ? "still recorded" : "forgotten")")
    }

    // MARK: - waiting

    /// `body` run from rest — the queue empty, a second's quiet — with this process's `phys_footprint` sampled
    /// every 20 ms: the footprint at rest, the peak, and the seconds it took.
    private static func sampled(_ body: () async -> Void) async -> (UInt64, UInt64, Double) {
        for _ in 0..<600 where !model_idle() { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))
        let rest = MemoryProbe.footprint()
        let box = PeakBox(rest)
        let sampler = Task.detached(priority: .high) {
            while !Task.isCancelled {
                box.see(MemoryProbe.footprint())
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let t0 = Date()
        await body()
        let seconds = Date().timeIntervalSince(t0)
        sampler.cancel()
        box.see(MemoryProbe.footprint())
        return (rest, box.peak, seconds)
    }

    private final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64
        init(_ v: UInt64) { value = v }
        func see(_ v: UInt64) { lock.lock(); value = max(value, v); lock.unlock() }
        var peak: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The queue has nothing queued or running (set by `walk`).
    nonisolated(unsafe) static var queue: RenderQueue?
    private static func model_idle() -> Bool { queue?.snapshots.isEmpty ?? true }

    private static func settled(_ model: AppServices, _ pick: ([LibraryFrame]) -> [LibraryFrame]) async -> [LibraryFrame] {
        for _ in 0..<600 {
            let photos = pick(model.library.frames)
            if photos.count >= 2, photos.allSatisfy({ !$0.develop.isBusy }), model.scheduler.snapshots.isEmpty { return photos }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return pick(model.library.frames)
    }

    private static func developed(_ model: AppServices, _ id: LibraryFrame.ID) async -> Bool {
        for _ in 0..<900 {
            if let f = model.library.frame(id), f.developed != nil, !f.develop.isBusy,
               model.scheduler.snapshot(frameID: id) == nil { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func developedOnPage(_ session: OpenFrameSession) async -> Bool {
        for _ in 0..<300 {
            if session.developed != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: - export, and the pictures' codes

    private static func exported(_ model: AppServices, _ id: LibraryFrame.ID, longEdge: Int, as file: URL) async -> CGImage? {
        _ = await developed(model, id)
        var recipe = ExportRecipe()
        recipe.format = .png
        recipe.size = .longEdge(longEdge)
        model.exporter.start([id], recipe: recipe)
        for _ in 0..<1200 {
            if let b = model.exporter.batch, b.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let url = model.exporter.batch?.files.first,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.copyItem(at: url, to: file)
        return image
    }

    private static func exportedCodes(_ model: AppServices, _ id: LibraryFrame.ID, edge: Int, out: URL, name: String) async -> [Double]? {
        guard let image = await exported(model, id, longEdge: edge, as: out.appendingPathComponent(name)) else { return nil }
        return codes(of: image, size: CGSize(width: image.width, height: image.height))
    }

    /// Each photograph's own preview laid as its exposure lies (`DoubleGuide`'s placing, gain 1), in sRGB codes.
    private static func laidPhotographs(_ double: DoubleExposure, frames: DoubleExposure.Frames, size: CGSize) -> [[Double]] {
        let framed = double.framed(frames)
        let context = CIContext(options: [.cacheIntermediates: false])
        var out: [[Double]] = []
        for layer in double.guideLayers(framed) {
            guard let e = double[layer.position], let frame = frames[layer.position], let url = ThumbnailStore.url(for: frame.picture),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)) * 2] as CFDictionary)
            else { continue }
            var placed = PiecePlacer.place(CIImage(cgImage: thumb), cut: e.cut, quarterTurns: layer.quarterTurns, window: layer.window, size: size)
            if layer.flipped { placed = placed.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
            guard let cg = context.createCGImage(placed, from: CGRect(origin: .zero, size: size),
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { continue }
            if let c = codes(of: cg, size: size) { out.append(c) }
        }
        return out
    }

    private static func codes(_ pictures: [[Double]], size: CGSize, combine: (Double, Double) -> Double) -> [Double] {
        zip(pictures[0], pictures[1]).map(combine)
    }

    /// RGB codes, 0…255, of `image` drawn at `size` in sRGB.
    private static func codes(of image: CGImage, size: CGSize) -> [Double]? {
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [Double] = []
        out.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) { out.append(Double(px[4 * i])); out.append(Double(px[4 * i + 1])); out.append(Double(px[4 * i + 2])) }
        return out
    }

    struct Stats {
        var paperWhite = 0.0, anyHigh = 0.0, crushed = 0.0, mean = 0.0, brightest = [0.0, 0.0, 0.0], lumaP999 = 0.0
        init(_ c: [Double]) {
            let n = c.count / 3
            var white = 0, high = 0, black = 0, sum = 0.0
            var luma: [Double] = []
            luma.reserveCapacity(n)
            for i in 0..<n {
                let r = c[3 * i], g = c[3 * i + 1], b = c[3 * i + 2]
                if r >= 254 && g >= 254 && b >= 254 { white += 1 }
                if r >= 254 || g >= 254 || b >= 254 { high += 1 }
                if r <= 1 && g <= 1 && b <= 1 { black += 1 }
                sum += r + g + b
                brightest = [max(brightest[0], r), max(brightest[1], g), max(brightest[2], b)]
                luma.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            luma.sort()
            paperWhite = Double(white) / Double(max(n, 1)); anyHigh = Double(high) / Double(max(n, 1))
            crushed = Double(black) / Double(max(n, 1)); mean = sum / Double(max(3 * n, 1))
            lumaP999 = luma.isEmpty ? 0 : luma[min(luma.count - 1, Int(Double(luma.count) * 0.999))]
        }
        var text: String {
            String(format: "white %.3f%%, any>=254 %.3f%%, crushed %.3f%%, mean %.1f, brightest %.0f/%.0f/%.0f, luma p99.9 %.0f",
                   100 * paperWhite, 100 * anyHigh, 100 * crushed, mean, brightest[0], brightest[1], brightest[2], lumaP999)
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func write(_ codes: [Double], size: CGSize, to url: URL) {
        let w = Int(size.width), h = Int(size.height)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<3 { px[4 * i + c] = UInt8(max(0, min(255, codes[3 * i + c].rounded()))) } }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let image = ctx.makeImage() else { return }
        write(image, to: url)
    }
}
#endif
