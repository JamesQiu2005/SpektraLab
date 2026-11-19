//  MacWatermarkCheck.swift — a debug build's proof of 水印's 成片 composite in the files, in the running app (PRD-8 §8,
//  RFC-067 §6; driven by `tools/watermark_export_check.sh`).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --watermark-export-check <dir> --export-check-pictures <raw> [--export-check-exit]
//
//  The picture (copied into `<dir>/work/Card`, never moved) is linked as a folder and made a frame. A mark is drawn here
//  — a white plate with a red disc on it, clear round them — and added to the app's library (a scratch home's, never the
//  person's). It is placed on the frame as 成片, bottom right, turned 37°, a fifth of the short side wide, with Enable
//  HDR on and Edit's crop a plain cut; then the frame is exported through the app's own batch (`MacExportRun` →
//  `ExportService` → `EngineHost.deliver`) as JPEG (with its map), HEIF (with its map) and 16-bit TIFF, Display P3, at
//  full size. Each file is read as a reader reads it (ImageIO) and held, where the placement alone says the mark is
//  (`WatermarkGeometry.frame` on the file's size — the one arithmetic of the overlay and the composite):
//
//  - **the mark is there**: inside its plate the TIFF is white, inside its disc red; away from it the picture is not;
//  - **the files agree on it**: over the plate's and the disc's flat insides, JPEG and HEIF against the TIFF;
//  - **HDR**: each file's ISO gain map is code 0 (gain 1.0) under the mark's inside, and carries gain elsewhere.
//
//  Also PNG and an SDR-only HEIF (Enable HDR off) against the TIFF, neither with a map (the review of stage 1).
//
//  **底片** (stage 2, `base`): a 底片 mark beside the 成片 one — the develop's stamp with it and without; on the page
//  developed where its placement says on the 底片 canvas, bright and in the film's colour; a move developed again from
//  the page's kept decode (no decode); exported, where it should be through Edit's crop, under the film's grain (a
//  grain-off export against a grain-on one); **a real pointer** (`pointer`: `POINTER READY` / `KEYS READY` lines the
//  script answers with tools/post_pointer.swift and tools/post_keys.swift, to this process only) — a drag on each mark,
//  → and ⌫, a drag the harness cannot deliver reported UNREACHED; Apply Film Emulation off (N9); 叠加于's conversion;
//  and with `--watermark-memory` a 4,096 px mark at full size, its export's peak interleaved with the same without it.
//
//  `<dir>/report.json` and the files are left for a look. Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UIKit

@MainActor
enum MacWatermarkCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = MacCheckFolder.index(of: "--watermark-export-check", in: arguments) else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--export-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        let exits = arguments.contains("--export-check-exit")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, picture: pictures.first)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            let failures = (report["failures"] as? [String]) ?? ["no report"]
            print("watermark-export-check: \(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))") — \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(failures.isEmpty ? 0 : 1)
            }
        }
    }

    /// The check's mark: 400 × 200 (or `w` wide, the same drawing), a white plate inset a tenth, a red disc in its
    /// middle, clear outside the plate.
    static func markPNG(width w: Int = 400) -> Data? {
        let h = w / 2, k = CGFloat(w) / 400
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 40 * k, y: 20 * k, width: 320 * k, height: 160 * k))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 150 * k, y: 50 * k, width: 100 * k, height: 100 * k))
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private static func batch(_ model: AppServices, _ id: LibraryFrame.ID, _ recipe: ExportRecipe, into folder: URL) async -> URL? {
        let run = MacExportRun.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await until(30) { !run.isRunning && !model.exporter.isExporting }
        run.reset()
        try? await Task.sleep(for: .milliseconds(300))
        guard run.start([id], recipe: recipe, folder: folder, exporter: model.exporter) else { return nil }
        _ = await until(900) { !run.isRunning }
        return run.lines.compactMap { l -> URL? in if case .saved(let u) = l.state { u } else { nil } }.first
    }

    /// A file as a reader has it: 8-bit Display P3, and its ISO gain map's codes where it has one.
    struct Read {
        let w: Int, h: Int, px: [UInt8]
        var map: (w: Int, h: Int, codes: [UInt8])?
        init?(_ url: URL) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let iw = image.width, ih = image.height
            w = iw; h = ih
            var buf = [UInt8](repeating: 0, count: iw * ih * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4,
                                          space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
                return true
            }
            guard ok else { return nil }
            px = buf
            // The ISO gain map's type is macOS 15's (Mac Catalyst 18); on 14 a file is read without it.
            let isoGainMap: CFString? = { if #available(iOS 18.0, *) { return kCGImageAuxiliaryDataTypeISOGainMap } else { return nil } }()
            if let isoGainMap, let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, isoGainMap) as? [CFString: Any],
               let data = info[kCGImageAuxiliaryDataInfoData] as? Data,
               let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [String: Any],
               let mw = d["Width"] as? Int, let mh = d["Height"] as? Int, let row = d["BytesPerRow"] as? Int {
                var codes = [UInt8](repeating: 0, count: mw * mh)
                data.withUnsafeBytes { raw in
                    let b = raw.bindMemory(to: UInt8.self)
                    for y in 0..<mh { for x in 0..<mw { codes[y * mw + x] = b[y * row + x] } }
                }
                map = (mw, mh, codes)
            }
        }
        func at(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return SIMD3(Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
    }

    static func run(_ model: AppServices, out: URL, picture: URL?) async -> [String: Any] {
        let fm = FileManager.default
        var failures: [String] = [], facts: [String: Any] = [:]
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what); print("watermark-export-check: FAIL \(what)") } }
        guard let picture else { return ["failures": ["no picture (--export-check-pictures)"]] }
        let work = out.appending(path: "work"), card = work.appending(path: "Card")
        for d in [work, out.appending(path: "files")] { try? fm.removeItem(at: d) }
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.copyItem(at: picture, to: card.appending(path: picture.lastPathComponent))
        check(model.exporter.wroteFiles, "the engine writes files (a real engine)")

        // The mark, in the app's library (the scratch home's).
        guard let png = markPNG(), case .success(let added) = await model.watermarks.add(png, name: "Check mark") else {
            return ["failures": failures + ["the library takes the check's mark"]]
        }
        let mark = added.mark
        let store = model.macLibrary
        await store.start()
        do { _ = try await store.open(card) } catch { check(false, "the folder links: \(error.localizedDescription)") }
        await store.loadAll()
        guard let row = store.images.first(where: { $0.fileName == picture.lastPathComponent }),
              let id = (try? await store.frames(for: [row.id], focus: nil).frames)?[row.id] else {
            return ["failures": failures + ["the picture is a frame"]]
        }
        let placement = WatermarkPlacement(mark: mark.id, anchor: .br, dx: 0.22, dy: 0.16, size: 0.2, rotation: 37 * .pi / 180)
        var crop = Geometry.default
        crop.crop = CropRect(x: 0.04, y: 0.03, width: 0.92, height: 0.94)
        model.library.update(id) { f in
            f.edit.hdrChoice = true
            f.edit.watermarks = [placement]
            f.edit.printCrop = crop
        }
        facts["placement"] = ["anchor": placement.anchor.rawValue, "dx": placement.dx, "dy": placement.dy, "size": placement.size,
                              "rotation_deg": 37, "crop": "0.04 0.03 0.92 0.94"]

        var recipe = ExportRecipe(format: .jpeg, size: .full, colour: .displayP3, destination: .files)
        recipe.quality = 95
        var files: [String: URL] = [:]
        for (name, format) in [("jpeg", ExportRecipe.Format.jpeg), ("heif", .heif), ("tiff", .tiff), ("png", .png)] {
            recipe.format = format
            let got = await batch(model, id, recipe, into: out.appending(path: "files/\(name)"))
            check(got != nil, "\(name): exported")
            files[name] = got
        }
        // An SDR-only HEIF (the review of stage 1): the same frame with Enable HDR off, no map in the file.
        model.library.update(id) { $0.edit.hdrChoice = false }
        recipe.format = .heif
        files["heif-sdr"] = await batch(model, id, recipe, into: out.appending(path: "files/heif-sdr"))
        check(files["heif-sdr"] != nil, "heif-sdr: exported")
        model.library.update(id) { $0.edit.hdrChoice = true }
        facts["files"] = files.mapValues(\.path)
        guard let tiffURL = files["tiff"], let tiff = Read(tiffURL) else { return ["failures": failures + ["the TIFF reads"], "facts": facts] }

        // Where the mark is on the file: the placement on the file's own canvas (the cut picture).
        let canvas = CGSize(width: tiff.w, height: tiff.h)
        let f = WatermarkGeometry.frame(of: placement, canvas: canvas, aspect: 2)
        /// A point of the mark's own unit square on the file.
        func onFile(_ u: Double, _ v: Double) -> (Int, Int) {
            let p = CGPoint(x: u, y: v).applying(f.transform)
            return (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
        }
        // The plate's inside (u 0.15…0.85, v 0.15…0.85 of the mark, off the disc) and the disc's (within 0.6 of its radius).
        var plate: [(Int, Int)] = [], disc: [(Int, Int)] = []
        for i in 0..<24 { for j in 0..<12 {
            let u = 0.15 + 0.7 * Double(i) / 23, v = 0.15 + 0.7 * Double(j) / 11
            let du = (u - 0.5) * 400 / 50, dv = (v - 0.5) * 200 / 50
            let r = sqrt(du * du + dv * dv)
            if r < 0.6 { disc.append(onFile(u, v)) } else if r > 1.4 { plate.append(onFile(u, v)) }
        } }
        for k in 0..<16 {
            let a = Double(k) * .pi / 8
            disc.append(onFile(0.5 + 0.3 * cos(a) * 50 / 400, 0.5 + 0.3 * sin(a) * 50 / 200))
        }
        let white = plate.map { tiff.at($0.0, $0.1) }
        let red = disc.map { tiff.at($0.0, $0.1) }
        check(white.allSatisfy { $0.x >= 245 && $0.y >= 245 && $0.z >= 245 }, "the TIFF is white inside the mark's plate (\(white.prefix(3)))")
        check(red.allSatisfy { $0.x > 180 && $0.y < 90 && $0.z < 90 }, "the TIFF is red inside the mark's disc (\(red.prefix(3)))")
        let away = tiff.at(tiff.w / 8, tiff.h / 8)
        check(!(away.x >= 245 && away.y >= 245 && away.z >= 245), "away from the mark the TIFF is the picture")
        facts["tiff_size"] = [tiff.w, tiff.h]

        for name in ["jpeg", "heif", "png", "heif-sdr"] {
            guard let url = files[name], let file = Read(url) else { check(false, "\(name): reads"); continue }
            check(file.w == tiff.w && file.h == tiff.h, "\(name): the TIFF's size (\(file.w) × \(file.h))")
            var worst = 0
            for p in plate + disc {
                let d = file.at(p.0, p.1) &- tiff.at(p.0, p.1)
                worst = max(worst, abs(d.x), abs(d.y), abs(d.z))
            }
            facts["\(name)_worst_under_mark"] = worst
            check(worst <= 3, "\(name): the mark as the TIFF has it, within 3 levels of compression (\(worst))")
            if name == "png" || name == "heif-sdr" {
                // PNG carries no map (`carriesGainMap`), nor a frame's file with Enable HDR off.
                check(file.map == nil, "\(name): carries no gain map")
                continue
            }
            if let map = file.map {
                let sx = Double(map.w) / Double(file.w), sy = Double(map.h) / Double(file.h)
                let under = (plate + disc).map { p in Int(map.codes[min(map.h - 1, Int(Double(p.1) * sy)) * map.w + min(map.w - 1, Int(Double(p.0) * sx))]) }
                let elsewhere = map.codes.reduce(0) { max($0, Int($1)) }
                facts["\(name)_map"] = ["size": [map.w, map.h], "max_under_mark": under.max() ?? -1, "max": elsewhere]
                check((under.max() ?? 1) == 0, "\(name): the gain map is 0 (gain 1.0) under the mark (max \(under.max() ?? -1))")
                check(elsewhere > 0, "\(name): and carries gain elsewhere (max code \(elsewhere))")
            } else {
                check(false, "\(name): carries a gain map (Enable HDR on)")
            }
        }
        // The page (PRD-8: a layer): the frame in Develop, its watermark's row picked — the canvas's stage
        // draws the mark, the page's pass leaves it out — a gesture's one Undo step, and at rest the pass carries it.
        if let s = await MacMasksCheck.develop(model, id) {
            s.pick(row: .watermark(placement.id))
            await MacMasksCheck.pause(1.0)
            check(s.layerPick == .watermark(placement.id) && s.watermarkOverlayLive && s.layer2.marks == nil,
                  "the row picked: the canvas draws the mark, the page's pass does not (\(s.layerPick.key))")
            await MacMasksCheck.capture("watermark-picked")
            let before = s.edit.watermarks
            s.beganWatermark()
            for k in 1...10 { s.moveWatermark(placement.id) { $0.dx = placement.dx + 0.02 * Double(k) } }
            check(s.edit.watermarks == before && s.shownMarks.first?.dx != placement.dx, "a gesture moves the mark live, nothing written")
            s.endedWatermark()
            check(s.edit.watermarks.first.map { abs($0.dx - (placement.dx + 0.2)) < 1e-9 } == true, "its lift writes it")
            await MacMasksCheck.pause(0.5)
            s.undo()
            await MacMasksCheck.pause(0.5)
            check(s.edit.watermarks == before, "one Undo takes the whole gesture back")
            s.redo()
            await MacMasksCheck.pause(0.5)
            s.pick(row: .film)
            let live = s.layer2
            if let base = s.developedCGImage { live.display(maxPixel: max(base.width, base.height)) }
            _ = await MacMasksCheck.until(20, every: 100) { live.marks != nil && live.shown != nil }
            await MacMasksCheck.pause(1.0)
            check(!s.watermarkOverlayLive && live.marks != nil && live.shown != nil, "at rest the page's picture carries the mark")
            // The canvas proofed (Settings › Appearance's canvas gamut, the Export page's proof): a new picture, which
            // still holds the page's HDR to SDR under the mark (`GamutProof.carryingMarks`; red before it, the review).
            if let shown = live.shown {
                GamutProof.carriesMarks = false
                _ = GamutProof.shared.proofed(shown, .sRGB)
                _ = await MacMasksCheck.until(10, every: 100) { GamutProof.shared.proofed(shown, .sRGB) !== shown }
                let proofed = GamutProof.shared.proofed(shown, .sRGB)
                check(proofed !== shown, "the canvas proofed to sRGB is its own picture")
                let before = WatermarkComposite.planeHold(for: proofed) != nil
                GamutProof.carriesMarks = true
                let again = GamutProof.shared.proofed(shown, .sRGB)
                facts["proof_hold"] = ["as_stage_1_made_it": before, "now": WatermarkComposite.planeHold(for: again) != nil]
                check(!before, "as stage 1 made it, a proofed canvas lost its HDR hold under the mark (the bug, reproduced)")
                check(WatermarkComposite.planeHold(for: again) != nil, "a proofed canvas holds its HDR to SDR under the mark")
            }
            if let shown = live.shown, let laid = live.marks {
                // The mark's disc's middle on the page's picture (uncut: through Edit's crop's map) is red.
                let p = laid.placing(picture: CGSize(width: shown.width, height: shown.height))
                let f = WatermarkGeometry.frame(of: laid.marks.placements[0], canvas: p.canvas, aspect: 2)
                let c = f.center.applying(p.toPicture)
                let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                if let ctx, let px = shown.cropping(to: CGRect(x: Int(c.x), y: Int(c.y), width: 1, height: 1)) {
                    ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    let b = ctx.data!.assumingMemoryBound(to: UInt8.self)
                    facts["page_disc_rgb"] = [Int(b[0]), Int(b[1]), Int(b[2])]
                    check(b[0] > 180 && b[1] < 90 && b[2] < 90, "the page's picture is red at the mark's disc (\(b[0]), \(b[1]), \(b[2]))")
                }
            }
            // The library's tile, the browser, the Light Table and Export's preview draw the frame's edited copy: it is
            // made with the mark (its name carries the marks' key) once the page has closed (its develop kept) and
            // nothing else runs.
            await MacMasksCheck.capture("watermark-rest")
            model.router.toLibrary()
            let served = await MacMasksCheck.until(120, every: 200) {
                guard let f = model.library.frame(id), Layer2Copies.shared.served(f) != nil else { return false }
                return Layer2Copies.shared.copies[id]?.key.contains("|wm ") == true
            }
            check(served, "the library's copy of the frame is made with its mark")
            if let f = model.library.frame(id) {
                facts["copy_state"] = ["shown_develop": f.shownDevelop.map { "\($0.picture)" } ?? "none",
                                       "developed_stamp": f.developed?.stamp ?? "none", "copy": Layer2Copies.shared.copies[id].map { "\($0.of) \($0.key)" } ?? "none",
                                       "finished_acts": f.edit.finishedActs(isComposite: f.isComposite), "jobs": model.scheduler.snapshots.count]
            }
            if let f = model.library.frame(id), let url = Layer2Copies.shared.served(f)?.fileURL,
               let src = CGImageSourceCreateWithURL(url as CFURL, nil), let copy = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let laid = WatermarkComposite.Laid(f.edit, isComposite: false) {
                let p = laid.placing(picture: CGSize(width: copy.width, height: copy.height))
                let c = WatermarkGeometry.frame(of: laid.marks.placements[0], canvas: p.canvas, aspect: 2).center.applying(p.toPicture)
                if let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                       space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                   let px = copy.cropping(to: CGRect(x: Int(c.x), y: Int(c.y), width: 1, height: 1)) {
                    ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    let b = ctx.data!.assumingMemoryBound(to: UInt8.self)
                    facts["copy_disc_rgb"] = [Int(b[0]), Int(b[1]), Int(b[2])]
                    check(b[0] > 180 && b[1] < 90 && b[2] < 90, "the library's copy is red at the mark's disc (\(b[0]), \(b[1]), \(b[2]))")
                }
            }
            await MacMasksCheck.pause(1.0)
            await MacMasksCheck.capture("watermark-library")
        } else {
            check(false, "the frame opens in Develop")
        }
        await base(model, id, mark: mark, full: placement, out: out, memory: CommandLine.arguments.contains("--watermark-memory"),
                   check: check, facts: &facts)
        return ["failures": failures, "facts": facts]
    }

    // MARK: 底片

    // MARK: a real pointer

    /// **A real drag on a mark** (the review of stage 1: the check had driven the session, never the pointer), for the
    /// frame's 成片 mark and then its 底片 one: this prints `POINTER READY <pid> x1 y1 x2 y2 w h` in the window's points
    /// and the script posts a mouse drag there (`tools/post_pointer.swift`, to this process only); then `KEYS READY <pid>
    /// k:124` (→, a point's nudge) and, for the last, `k:51` (⌫). Each held to what it should do: the mark moved by the
    /// drag, one Undo step; a 底片 drag ending in a develop; → a point; ⌫ the mark gone. Where nothing arrives it is
    /// said, not assumed.
    static func pointer(_ model: AppServices, _ id: UUID, check: (Bool, String) -> Void, facts: inout [String: Any]) async {
        guard let s = model.openSession(id), let frame = model.library.frame(id) else { check(false, "pointer: the page"); return }
        var said: [String] = [], unreached: [String] = []
        let pid = ProcessInfo.processInfo.processIdentifier
        for (n, p0) in s.edit.watermarks.enumerated() {
            let word = p0.stage == .base ? "底片" : "成片"
            s.pick(row: .watermark(p0.id))
            s.watermarkSelected = true
            MacHistoryPageCheck.layoutWindows()
            await MacMasksCheck.pause(1.5)
            guard let placed = MaskStageProbe.placed, placed.frame == id,
                  let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
                  let stage = MacMaskToolsCheck.stageView(in: window), let developed = s.developedCGImage else {
                check(false, "pointer \(word): no canvas to post to"); continue
            }
            let finished = CGSize(width: developed.width, height: developed.height)
            let canvases = model.watermarkCanvases(frame, edit: s.edit, finished: finished)
            func centre(_ p: WatermarkPlacement) -> CGPoint {
                let sp = WatermarkStageHit.space(p, shown: placed.shown.size, canvases: canvases, appliesFilm: s.edit.appliesFilm)
                let f = WatermarkGeometry.frame(of: p, canvas: sp.canvas, aspect: 2).through(sp.toLocal)
                return CGPoint(x: placed.shown.minX + f.center.x, y: placed.shown.minY + f.center.y)
            }
            let c0 = centre(p0), by = CGSize(width: 37, height: 23)
            let from = stage.convert(c0, to: window), to = stage.convert(CGPoint(x: c0.x + by.width, y: c0.y + by.height), to: window)
            let steps0 = await MacMaskToolsCheck.steps(model, id)
            let stamp0 = s.developed?.stamp
            print(String(format: "watermark-export-check: POINTER READY %d %.1f %.1f %.1f %.1f %.1f %.1f", pid, from.x, from.y, to.x, to.y,
                         window.bounds.width, window.bounds.height))
            fflush(stdout)
            var pressed = false
            let arrived = await MacMasksCheck.until(25, every: 50) {
                if s.movingMarks != nil { pressed = true }
                return s.edit.watermarks.first { $0.id == p0.id } != p0 && s.movingMarks == nil
            }
            await MacMasksCheck.pause(1.0)
            let (active, why) = MacMaskToolsCheck.deliveryState()
            var p1 = p0
            if arrived, let moved = s.edit.watermarks.first(where: { $0.id == p0.id }) {
                p1 = moved
            } else {
                // Said exactly, not left out (the review): the drag was posted to this process (the script's
                // pointer.log), and the canvas's gesture never began — the same as the masks check's posted stroke
                // (8513434c: "it does not reach a Catalyst window"). The keys below still run.
                said.append("\(word): the posted drag did not reach the mark (the canvas's gesture \(pressed ? "began and ended without a move" : "never began"); this app \(active ? "frontmost with a key window" : "not receiving: " + why))")
                // Not a failure of the canvas: the harness's own reach (the masks check reports it the same way).
                print("watermark-export-check: UNREACHED pointer \(word): the posted drag did not reach the canvas — the pointer path is on the hand-check list")
                unreached.append("pointer \(word)")
            }
            let c1 = centre(p1)
            if p1 != p0 {
                let off = hypot(c1.x - c0.x - by.width, c1.y - c0.y - by.height)
                let steps1 = await MacMaskToolsCheck.steps(model, id)
                said.append(String(format: "%@: moved (%.1f, %.1f) pt for a drag of (%.0f, %.0f), %d step(s)", word, c1.x - c0.x, c1.y - c0.y,
                                   by.width, by.height, steps1 - steps0))
                // A snap may hold the centre up to 8 points from the pointer's (the guides' tolerance).
                check(off < 9, "pointer \(word): a real drag moves the mark with the pointer (\(String(format: "%.1f", off)) pt off)")
                check(steps1 == steps0 + 1, "pointer \(word): one Undo step for the drag (\(steps1 - steps0))")
                if p0.stage == .base {
                    let landed = await MacMasksCheck.until(60, every: 100) { s.developed?.stamp != stamp0 && !s.isCatchingUp }
                    check(landed && s.developedBaseMarks.contains(p1), "pointer 底片: the drag ends in a develop of the mark where it went")
                } else {
                    check(s.developed?.stamp == stamp0, "pointer 成片: the drag develops nothing")
                }
            }
            let stampBeforeKey = s.developed?.stamp
            // → : a point of the canvas to the right.
            print("watermark-export-check: KEYS READY \(pid) k:124")
            fflush(stdout)
            let nudged = await MacMasksCheck.until(15, every: 100) { s.edit.watermarks.first { $0.id == p0.id } != p1 }
            if nudged, let p2 = s.edit.watermarks.first(where: { $0.id == p0.id }) {
                let d = CGPoint(x: centre(p2).x - c1.x, y: centre(p2).y - c1.y)
                said.append(String(format: "%@: → moved (%.2f, %.2f) pt", word, d.x, d.y))
                check(abs(d.x - 1) < 0.05 && abs(d.y) < 0.05, "pointer \(word): → nudges it a point (\(d))")
                if p0.stage == .base {
                    let landed = await MacMasksCheck.until(60, every: 100) { s.developed?.stamp != stampBeforeKey && !s.isCatchingUp }
                    check(landed && s.developedBaseMarks.contains(p2), "pointer 底片: → ends in a develop of the mark where it went")
                }
            } else {
                said.append("\(word): → did not arrive")
                check(false, "pointer \(word): the posted → reached the page")
            }
            if n == s.edit.watermarks.count - 1 {
                await MacMasksCheck.pause(1.0)
                print("watermark-export-check: KEYS READY \(pid) k:51")
                fflush(stdout)
                let gone = await MacMasksCheck.until(15, every: 100) { !s.edit.watermarks.contains { $0.id == p0.id } }
                said.append("\(word): ⌫ " + (gone ? "removed it" : "did not arrive"))
                check(gone, "pointer \(word): ⌫ removes the picked mark")
                if gone { s.undo(); await MacMasksCheck.pause(0.5) }
            }
        }
        facts["pointer"] = said
        facts["unreached"] = unreached
        print("watermark-export-check: pointer: " + said.joined(separator: "; "))
    }

    /// The mark's plate (u, v of its unit square, off the disc) and disc points, for a 400 × 200 drawing of it.
    static func platePoints() -> (plate: [CGPoint], disc: [CGPoint]) {
        var plate: [CGPoint] = [], disc: [CGPoint] = []
        for i in 0..<24 { for j in 0..<12 {
            let u = 0.15 + 0.7 * Double(i) / 23, v = 0.15 + 0.7 * Double(j) / 11
            let du = (u - 0.5) * 400 / 50, dv = (v - 0.5) * 200 / 50
            let r = sqrt(du * du + dv * dv)
            if r < 0.6 { disc.append(CGPoint(x: u, y: v)) } else if r > 1.4 { plate.append(CGPoint(x: u, y: v)) }
        } }
        return (plate, disc)
    }

    /// A picture's 8-bit Display P3 pixels (the page's develop).
    static func pixels(_ image: CGImage) -> Read? {
        let url = FileManager.default.temporaryDirectory.appending(path: "wm-base-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Read(url)
    }

    static func luma(_ p: SIMD3<Int>) -> Double { (0.2126 * Double(p.x) + 0.7152 * Double(p.y) + 0.0722 * Double(p.z)) / 255 }

    /// **The 底片 pass in the running app** (RFC-067 §4.2): the same frame, a 底片 mark beside its 成片 one, developed on
    /// the page and exported — the mark where its placement says on the 底片 canvas, developed (bright, not the file's
    /// white), under the film's grain (a grain-off export against a grain-on one: the grain is their difference), a move
    /// re-developing from the page's kept decode with no decode, the stamp of the 成片 mark alone the markless stamp; with
    /// `--watermark-memory` a 4,096 px mark on the frame at full size, its export's peak interleaved with the same export
    /// without it.
    static func base(_ model: AppServices, _ id: UUID, mark: WatermarkMark, full: WatermarkPlacement, out: URL, memory: Bool,
                     check: (Bool, String) -> Void, facts: inout [String: Any]) async {
        guard let frame = model.library.frame(id) else { check(false, "底片: the frame"); return }
        var noMarks = frame.edit; noMarks.watermarks = []
        var fullOnly = frame.edit; fullOnly.watermarks = [full]
        let edge = frame.previewDevelopLongEdge(frame.edit)
        let plain = model.darkroom.stamp(frame, edit: noMarks, longEdge: edge)
        check(plain != nil && model.darkroom.stamp(frame, edit: fullOnly, longEdge: edge) == plain,
              "底片: a 成片 mark leaves the develop's stamp the markless one")
        let base = WatermarkPlacement(mark: mark.id, stage: .base, anchor: .tl, dx: 0.27, dy: 0.2, size: 0.25)
        var withBase = fullOnly; withBase.watermarks = [full, base]
        check(model.darkroom.stamp(frame, edit: withBase, longEdge: edge) != plain, "底片: a 底片 mark is in the develop's stamp")

        guard let s = await MacMasksCheck.develop(model, id) else { check(false, "底片: the frame opens in Develop"); return }
        let before = s.developed?.stamp
        s.change { $0.watermarks = [full, base] }
        check(s.isCatchingUp, "底片: a 底片 mark placed develops the frame again")
        guard let developed = await MacMasksCheck.developed(s, model, from: before), let page = pixels(developed) else {
            check(false, "底片: the page's develop with the mark"); return
        }
        // Where the mark is on the page's develop: the 底片 canvas, which without a film edge is the developed picture.
        let (platePts, discPts) = platePoints()
        func onCanvas(_ p: WatermarkPlacement, _ w: Int, _ h: Int, through t: CGAffineTransform = .identity) -> ([(Int, Int)], [(Int, Int)]) {
            let f = WatermarkGeometry.frame(of: p, canvas: CGSize(width: w, height: h), aspect: 2)
            func at(_ q: CGPoint) -> (Int, Int) { let r = q.applying(f.transform).applying(t); return (Int(r.x), Int(r.y)) }
            return (platePts.map(at), discPts.map(at))
        }
        let (plate, disc) = onCanvas(base, page.w, page.h)
        let plateLuma = plate.map { luma(page.at($0.0, $0.1)) }
        let plateMean = plateLuma.reduce(0, +) / Double(max(plateLuma.count, 1))
        let discRGB = disc.map { page.at($0.0, $0.1) }
        let red = discRGB.reduce(SIMD3<Int>(0, 0, 0), &+) / max(discRGB.count, 1)
        facts["base_page"] = ["plate_luma": plateMean, "disc_rgb": [red.x, red.y, red.z], "size": [page.w, page.h]]
        check(plateMean > 0.72 && plateMean < 0.97, "底片: the page's develop is bright where the plate is, and not the file's white (\(plateMean))")
        check(red.x > red.y + 40, "底片: and red where the disc is, as the film prints red (\(red))")
        check(s.developedBaseMarks.contains(base), "底片: at rest the page's picture is of the mark (the overlay draws it no more)")

        // A move: a develop, from the page's kept decode — no decode.
        s.pick(row: .watermark(base.id))
        await MacMasksCheck.pause(0.5)
        let moved = s.developed?.stamp
        s.beganWatermark()
        for k in 1...8 { s.moveWatermark(base.id) { $0.dx = base.dx + 0.02 * Double(k) } }
        check(!s.developedBaseMarks.contains(s.shownMarks.first { $0.id == base.id }!), "底片: under the pointer the overlay draws the mark (the picture is not of it)")
        s.endedWatermark()
        check(ChangeDescriber.what(from: withBase, to: s.edit) == L("Watermark") && s.isCatchingUp,
              "底片: its lift develops again, and the status line says so (\(ChangeDescriber.what(from: withBase, to: s.edit)))")
        let records = model.scheduler.records.count
        guard let again = await MacMasksCheck.developed(s, model, from: moved), let page2 = pixels(again) else {
            check(false, "底片: the develop after a move"); return
        }
        let jobs = model.scheduler.records.dropFirst(records).filter { $0.kind == JobKind.canvasDevelop.rawValue }
        let how = jobs.compactMap { $0.measurement?.decodedBy }
        facts["base_move_decodes"] = how
        check(!how.isEmpty && how.allSatisfy { $0 == "the kept decode" }, "底片: a move opens the frame from the kept decode, no decode (\(how))")
        let movedPlace = s.edit.watermarks.first { $0.id == base.id }!
        let (plate2, _) = onCanvas(movedPlace, page2.w, page2.h)
        let l2 = plate2.map { luma(page2.at($0.0, $0.1)) }.reduce(0, +) / Double(max(plate2.count, 1))
        check(l2 > 0.72, "底片: the moved mark is developed where it went (\(l2))")
        await MacMasksCheck.capture("watermark-base-moving-rest")
        s.pick(row: .film)
        await MacMasksCheck.capture("watermark-base-rest")

        // The export: the mark through the film, where its placement says on the 底片 canvas through Edit's crop; under the
        // film's grain (grain off against grain on).
        var recipe = ExportRecipe(format: .jpeg, size: .full, colour: .displayP3, destination: .files)
        recipe.quality = 100
        guard let grainy = await batch(model, id, recipe, into: out.appending(path: "files/base-grain")), let a = Read(grainy) else {
            check(false, "底片: the JPEG exports"); return
        }
        model.library.update(id) { $0.edit.params.grainActive = false }
        let flatURL = await batch(model, id, recipe, into: out.appending(path: "files/base-nograin"))
        model.library.update(id) { $0.edit.params.grainActive = true }
        guard let flatURL, let b = Read(flatURL), a.w == b.w, a.h == b.h else { check(false, "底片: the grain-off JPEG exports"); return }
        facts["base_files"] = [grainy.path, flatURL.path]
        let finished = CGSize(width: developed.width, height: developed.height)
        guard let canvases = model.watermarkCanvases(frame, edit: s.edit, finished: finished) else { check(false, "底片: the canvases"); return }
        let k = CGFloat(a.w) / canvases.full.width
        let toFile = canvases.baseToFull.concatenating(CGAffineTransform(scaleX: k, y: k))
        let baseSize = canvases.base
        let fb = WatermarkGeometry.frame(of: movedPlace, canvas: baseSize, aspect: 2)
        func onFile(_ q: CGPoint) -> (Int, Int) { let r = q.applying(fb.transform).applying(toFile); return (Int(r.x), Int(r.y)) }
        let filePlate = platePts.map(onFile), fileDisc = discPts.map(onFile)
        let fileLuma = filePlate.map { luma(b.at($0.0, $0.1)) }.reduce(0, +) / Double(max(filePlate.count, 1))
        let fileRed = fileDisc.map { b.at($0.0, $0.1) }.reduce(SIMD3<Int>(0, 0, 0), &+) / max(fileDisc.count, 1)
        facts["base_file"] = ["plate_luma": fileLuma, "disc_rgb": [fileRed.x, fileRed.y, fileRed.z], "size": [a.w, a.h]]
        check(fileLuma > 0.72 && fileLuma < 0.97 && fileRed.x > fileRed.y + 40,
              "底片: the export has the developed mark where its placement says (\(fileLuma), \(fileRed))")
        // The grain: a − b, high-passed (5 × 5), its variance under the plate, under the 成片 mark's plate, and in the
        // picture where it is at the plate's own level (the print flattens grain near paper white: the like-for-like).
        func grain(_ x: Int, _ y: Int) -> Double {
            var m = 0.0
            for j in -2...2 { for i in -2...2 { m += luma(a.at(x + i, y + j)) - luma(b.at(x + i, y + j)) } }
            return luma(a.at(x, y)) - luma(b.at(x, y)) - m / 25
        }
        func variance(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(max(v.count, 1)); return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(v.count, 1))
        }
        // Dense samples over the plate: its unit square at 120 × 60.
        var under: [Double] = []
        for i in 0..<120 { for j in 0..<60 {
            let u = 0.15 + 0.7 * Double(i) / 119, v = 0.15 + 0.7 * Double(j) / 59
            let du = (u - 0.5) * 8, dv = (v - 0.5) * 4
            guard sqrt(du * du + dv * dv) > 1.4 else { continue }
            let (x, y) = onFile(CGPoint(x: u, y: v)); under.append(grain(x, y))
        } }
        let ff = WatermarkGeometry.frame(of: full, canvas: CGSize(width: a.w, height: a.h), aspect: 2)
        var overFull: [Double] = []
        for i in 0..<60 { for j in 0..<30 {
            let u = 0.15 + 0.7 * Double(i) / 59, v = 0.15 + 0.7 * Double(j) / 29
            let du = (u - 0.5) * 8, dv = (v - 0.5) * 4
            guard sqrt(du * du + dv * dv) > 1.4 else { continue }
            let r = CGPoint(x: u, y: v).applying(ff.transform); overFull.append(grain(Int(r.x), Int(r.y)))
        } }
        let level = filePlate.map { luma(b.at($0.0, $0.1)) }.reduce(0, +) / Double(max(filePlate.count, 1))
        var beside: [Double] = [], mid: [Double] = []
        let box = fb.bounds.applying(toFile).insetBy(dx: -40, dy: -40), fbox = ff.bounds.insetBy(dx: -40, dy: -40)
        for y in stride(from: 8, to: a.h - 8, by: 7) { for x in stride(from: 8, to: a.w - 8, by: 7) {
            let p = CGPoint(x: x, y: y)
            guard !box.contains(p), !fbox.contains(p) else { continue }
            let l = luma(b.at(x, y))
            if abs(l - level) < 0.03 { beside.append(grain(x, y)) }
            if abs(l - 0.46) < 0.05 { mid.append(grain(x, y)) }
        } }
        let vu = variance(under), vf = variance(overFull), vb = variance(beside), vm = variance(mid)
        facts["base_grain"] = ["under_base_e4": vu * 1e4, "under_full_e4": vf * 1e4, "beside_at_level_e4": vb * 1e4,
                               "beside_n": beside.count, "mid_grey_e4": vm * 1e4, "level": level]
        print(String(format: "watermark-export-check: grain variance ×10⁴: under the 底片 mark %.3f, under the 成片 mark %.4f, the picture at the mark's level (%.2f) %.3f over %d, at mid grey %.3f",
                     vu * 1e4, vf * 1e4, level, vb * 1e4, beside.count, vm * 1e4))
        check(vu > 20 * max(vf, 1e-9), "底片: the film's grain is over the 底片 mark, none over the 成片 one (\(vu) against \(vf))")
        if beside.count >= 200 {
            // The grain's amplitude (its standard deviation) within ×2 of the picture's at the mark's level. Measured on
            // 00_extreme-EV (45 MP, Portra 400 / Supra Endura, 2026-11-16): variance 0.598 against 1.215 ×10⁻⁴ — a ratio
            // of 0.49, so a ×2 bar on the variance misses by a hair; the amplitude's is 0.70. Near paper white the
            // print flattens grain steeply, and "the same level" is a ±0.03 band of it.
            let ratio = sqrt(vu / max(vb, 1e-12))
            check(ratio > 0.5 && ratio < 2, "底片: the grain under the mark is the picture's at its level, its amplitude within ×2 (\(ratio))")
        }
        await MacMasksCheck.capture("watermark-base-export")

        await pointer(model, id, check: check, facts: &facts)

        // Apply Film Emulation off: 底片 works as 成片 (N9) — drawn over Apple's picture by the page's pass, on the 成片
        // canvas, and the page says so; the film back on, it is the develop's again.
        s.pick(row: .film)
        let filmOn = s.developed?.stamp
        s.change { $0.setAppliesFilm(false) }
        _ = await MacMasksCheck.developed(s, model, from: filmOn)
        let offMarks = WatermarkComposite.Laid(s.edit, isComposite: false)?.marks.placements.map(\.id) ?? []
        let baseIDs = s.edit.watermarks.filter { $0.stage == .base && $0.on }.map(\.id)
        check(!baseIDs.isEmpty && baseIDs.allSatisfy { offMarks.contains($0) } && WatermarkRules.base(s.edit, isComposite: false).isEmpty,
              "the film off: a 底片 mark is drawn over the picture as 成片, nothing laid in a source")
        let live = s.layer2
        if let d = s.developedCGImage { live.display(maxPixel: max(d.width, d.height)) }
        _ = await MacMasksCheck.until(20, every: 100) { live.marks?.marks.placements.map(\.id) == offMarks && live.shown != nil }
        check(live.marks?.marks.placements.map(\.id) == offMarks, "the film off: the page's pass lays the 底片 mark with the 成片 ones")
        await MacMasksCheck.capture("watermark-base-film-off")
        let offStamp = s.developed?.stamp
        s.change { $0.setAppliesFilm(true) }
        _ = await MacMasksCheck.developed(s, model, from: offStamp)
        check(WatermarkRules.base(s.edit, isComposite: false).map(\.id) == baseIDs, "the film back on: the 底片 mark is the develop's again")

        // 叠加于 成片 → 底片 on the page: the numbers converted, the mark where it was on screen; one step.
        if let f0 = s.edit.watermarks.first(where: { $0.stage == .full }) {
            s.pick(row: .watermark(f0.id))
            s.watermarkSelected = true
            await MacMasksCheck.pause(1.5)
            if let cv = s.watermarkCanvases {
                s.switchWatermarkStage(f0.id, to: .base)
                if let f1 = s.edit.watermarks.first(where: { $0.id == f0.id }) {
                    let a = WatermarkGeometry.frame(of: f0, canvas: cv.full, aspect: 2)
                    let b = WatermarkGeometry.frame(of: f1, canvas: cv.base, aspect: 2).through(cv.baseToFull)
                    let off = hypot(a.center.x - b.center.x, a.center.y - b.center.y) / cv.full.width
                    facts["switch_offset_share"] = off
                    check(f1.stage == .base && off < 1e-6 && abs(a.size.width - b.size.width) / cv.full.width < 1e-6,
                          "叠加于 成片 → 底片: the mark keeps its place and size on screen (\(off))")
                }
                s.undo()
                await MacMasksCheck.pause(0.5)
                check(s.edit.watermarks.first { $0.id == f0.id } == f0, "and one Undo takes the switch back")
            } else {
                check(false, "叠加于: the canvas told the session where its two canvases are")
            }
            s.pick(row: .film)
        }

        guard memory else { return }
        // The memory (RFC-067 §4.2's risk): a 4,096 px mark on 底片 at full size, the export's job peak (phys_footprint, what
        // `footprint -p` reads) against the same export without it, interleaved.
        guard let big = markPNG(width: 4096), case .success(let added) = await model.watermarks.add(big, name: "Check mark 4096") else {
            check(false, "底片: the library takes the 4,096 px mark"); return
        }
        let heavy = WatermarkPlacement(mark: added.mark.id, stage: .base, anchor: .tl, dx: 0.5, dy: 0.4, size: 0.8)
        var rows: [[String: Any]] = []
        // Enable HDR on for both: an export with a map always renders (`EngineHost.cached` steps aside), so neither is
        // served from a full render the zoom or the prefetch kept.
        for (n, marked) in [false, true, false, true].enumerated() {
            model.library.update(id) { $0.edit.watermarks = marked ? [heavy] : []; $0.edit.hdrChoice = true }
            await MacMasksCheck.pause(3)      // the footprint back down (`RunMeasurement.fromRest`)
            let count = model.scheduler.records.count
            print("watermark-export-check: MEMORY start \(marked ? "marked" : "plain") \(n) \(Date().timeIntervalSince1970)")
            fflush(stdout)
            _ = await batch(model, id, recipe, into: out.appending(path: "files/memory-\(n)"))
            print("watermark-export-check: MEMORY end \(marked ? "marked" : "plain") \(n) \(Date().timeIntervalSince1970)")
            fflush(stdout)
            guard let r = model.scheduler.records.dropFirst(count).last(where: { $0.kind == JobKind.export.rawValue }), let m = r.measurement else {
                check(false, "底片: the memory run's export \(n) ran"); continue
            }
            let row: [String: Any] = ["marked": marked, "before_mb": m.footprintBefore >> 20, "peak_mb": m.peakFootprint >> 20,
                                      "grew_mb": (Int64(m.peakFootprint) - Int64(m.footprintBefore)) >> 20,
                                      "predicted_mb": r.predictedPeakBytes >> 20, "megapixels": r.megapixels, "from_rest": m.fromRest,
                                      "decoded_by": m.decodedBy ?? "-", "open_peak_mb": m.openPeakFootprint >> 20,
                                      "decode_s": m.decodeSeconds, "open_s": m.openSeconds, "render_s": m.renderSeconds,
                                      "deliver_s": m.deliverSeconds, "seconds": r.measuredSeconds ?? -1]
            rows.append(row)
            print("watermark-export-check: MEMORY \(row)")
        }
        facts["base_memory"] = rows
        let grew = { (marked: Bool) in rows.filter { ($0["marked"] as? Bool) == marked }.compactMap { $0["grew_mb"] as? Int64 } }
        if let p = grew(false).max(), let m = grew(true).max(), let mp = rows.first?["megapixels"] as? Double {
            let source = Int64(mp * 1_000_000 * 16) >> 20
            check(m - p < source / 2, "底片: the 4,096 px mark costs no second full-size source (\(m) MB against \(p) MB; a source is \(source) MB)")
        }
    }
}
#endif
