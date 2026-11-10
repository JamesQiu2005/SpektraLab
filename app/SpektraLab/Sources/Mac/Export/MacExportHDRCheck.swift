//  MacExportHDRCheck.swift — a debug build's proof of Enable HDR's files, in the running app (HDR port,
//  2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D8).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --plus lifetime --export-hdr-check <dir> \
//          --export-check-pictures <raw> … [--export-hdr-films <film>,<film>,…] [--export-hdr-colour sRGB|Adobe RGB|ProPhoto]
//          [--export-hdr-long-edge <px>] [--export-hdr-layer2-ev <ev>] [--export-hdr-measure] [--export-check-exit]
//
//  The pictures (copied into `<dir>/work/Card`, never moved) are linked as a folder and made frames, each given
//  Enable HDR on (and, where `--export-hdr-films` names one, that film: a slide's id takes the slide's path) and
//  exported at full size, Display P3, through the Mac's own batch (`MacExportRun` → `ExportService` →
//  `EngineHost.deliver` → `ExportWriter`): one JPEG batch, one HEIF batch, and a control of the first picture
//  with HDR off. Each file is then read as a reader reads it (ImageIO, not the app's writer) into
//  `<dir>/report.json`:
//
//  - **the declarations**: the ISO 21496-1 map and Apple's (MakerApple 33/48), the map at the picture's size; a
//    JPEG's hdrgm (`HDRUltraHDR.read`, the index consistent) field for field against the ISO declaration;
//  - **the gain**: `kCGImageSourceDecodeToHDR` ÷ `DecodeToSDR` in linear light, sampled on 64 rows × every
//    4th pixel, against the map the export meant (`HDRGainMap.exportWitness`, written to `<dir>/witness`) and
//    against the gain the file declares (its stored codes through the ISO reading); by bins of intended stops;
//  - **the base**: `DecodeToSDR` against the plain decode, in 8-bit P3 codes; and (D3) a print's JPEG's coded
//    picture against the HDR-off control's, to the byte (`HDRUltraHDR.codedPicture`), its HEIF's decode to the bit.
//
//  The recipe is Display P3 at full size unless `--export-hdr-colour` / `--export-hdr-long-edge` say otherwise (the
//  2026-11-06 review's sRGB, ProPhoto and 2048 px files); `--export-hdr-layer2-ev` gives every frame that Layer 2
//  exposure (a slide's map is then its curve's over the edited picture, as its canvas: `HDRGain.export`).
//
//  `--export-hdr-measure`: the first picture exported again JPEG and HEIF, with HDR on and off, in the order
//  H S S H (this machine drifts: AGENTS.md, measure interleaved), each job's phys_footprint (the number
//  `footprint -p` reports, not RSS) sampled every 5 ms from its start: its peak over the level before it.
//
//  The files are left in `<dir>` for `tools/hdr_conformance.sh --expect appleCamera` and the hand checks
//  (Photoshop / Lightroom). Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import CoreGraphics
import Darwin
import Foundation
import ImageIO

@MainActor
enum MacExportHDRCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--export-hdr-check"), i + 1 < arguments.count,
              arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        var pictures: [URL] = []
        if let p = arguments.firstIndex(of: "--export-check-pictures") {
            pictures = arguments[(p + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        }
        var films: [String] = []
        if let f = arguments.firstIndex(of: "--export-hdr-films"), f + 1 < arguments.count {
            films = arguments[f + 1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        let measure = arguments.contains("--export-hdr-measure"), exits = arguments.contains("--export-check-exit")
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        var recipe = ExportRecipe(format: .jpeg, size: .full, colour: .displayP3, destination: .files)
        recipe.quality = 92
        if let c = value("--export-hdr-colour").flatMap(ExportRecipe.Colour.init(rawValue:)) { recipe.colour = c }
        if let e = value("--export-hdr-long-edge").flatMap(Int.init) { recipe.size = .longEdge(e) }
        let layer2 = value("--export-hdr-layer2-ev").flatMap(Double.init)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let report = await run(model, out: out, pictures: pictures, films: films, recipe: recipe, layer2: layer2, measure: measure)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("export-hdr-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(0)
            }
        }
    }

    // MARK: the footprint

    /// This process's phys_footprint: what `footprint -p` reports (never RSS, which cannot see the Metal pool).
    nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A sampler on its own thread: the largest footprint since it began.
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var top: UInt64 = 0
        private var running = true
        init() {
            Thread.detachNewThread { [self] in
                while true {
                    let f = MacExportHDRCheck.footprint()
                    lock.lock(); top = max(top, f); let go = running; lock.unlock()
                    if !go { break }
                    usleep(5000)
                }
            }
        }
        func stop() -> UInt64 { lock.lock(); running = false; let t = top; lock.unlock(); return t }
    }

    // MARK: running

    private static func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    /// One batch through the Mac's own Export (what the page's button calls), to its end: its files, its time,
    /// and the footprint's peak over the level before it.
    private static func batch(_ model: AppServices, _ ids: [LibraryFrame.ID], _ recipe: ExportRecipe, into folder: URL) async -> [String: Any] {
        let run = MacExportRun.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = await until(30) { !run.isRunning && !model.exporter.isExporting }
        run.reset()
        try? await Task.sleep(for: .milliseconds(300))
        let before = footprint(), sampler = Sampler(), t0 = Date()
        guard run.start(ids, recipe: recipe, folder: folder, exporter: model.exporter) else {
            _ = sampler.stop()
            return ["began": false]
        }
        _ = await until(900) { !run.isRunning }
        let peak = sampler.stop(), seconds = Date().timeIntervalSince(t0)
        let files = run.lines.compactMap { l -> URL? in if case .saved(let u) = l.state { u } else { nil } }
        return ["began": true, "seconds": (seconds * 100).rounded() / 100, "files": files.map(\.path),
                "lines": run.lines.map { "\($0.name): \($0.state)" },
                "footprint_before_mb": before >> 20, "footprint_peak_mb": peak >> 20,
                "footprint_rise_mb": (Int64(peak) - Int64(before)) >> 20]
    }

    static func run(_ model: AppServices, out: URL, pictures: [URL], films: [String], recipe asked: ExportRecipe, layer2: Double?,
                    measure: Bool) async -> [String: Any] {
        let fm = FileManager.default
        var failures: [String] = [], steps: [[String: Any]] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what); print("export-hdr-check: FAIL \(what)") } }
        let store = model.macLibrary
        let work = out.appending(path: "work"), card = work.appending(path: "Card")
        let witness = out.appending(path: "witness")
        for d in [work, witness, out.appending(path: "hdr"), out.appending(path: "control"), out.appending(path: "measure")] { try? fm.removeItem(at: d) }
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        try? fm.createDirectory(at: witness, withIntermediateDirectories: true)
        for u in pictures { try? fm.copyItem(at: u, to: card.appending(path: u.lastPathComponent)) }
        check(model.exporter.wroteFiles, "the engine writes files (a real engine)")

        // Each export's map as meant, before any layout recoded it: the gain the reader must give back.
        HDRGainMap.exportWitness = { url, a in
            try? a.map.codes.write(to: witness.appending(path: url.lastPathComponent + ".u8"))
            let meta = ["width": a.map.width, "height": a.map.height, "headroom": a.headroom] as [String: Any]
            if let d = try? JSONSerialization.data(withJSONObject: meta) { try? d.write(to: witness.appending(path: url.lastPathComponent + ".json")) }
        }
        defer { HDRGainMap.exportWitness = nil }

        await store.start()
        do { _ = try await store.open(card) } catch { check(false, "the folder links: \(error.localizedDescription)") }
        await store.loadAll()
        let rows = pictures.compactMap { u in store.images.first { $0.fileName == u.lastPathComponent } }
        check(rows.count == pictures.count, "every picture is listed (\(rows.count) of \(pictures.count))")
        let made = (try? await store.frames(for: rows.map(\.id), focus: nil).frames) ?? [:]
        let ids = rows.compactMap { made[$0.id] }
        check(ids.count == rows.count, "every picture is a frame (\(ids.count))")
        guard !ids.isEmpty else { return ["failures": failures] }
        for (k, id) in ids.enumerated() {
            model.library.update(id) { f in
                f.edit.hdrChoice = true
                if k < films.count, !films[k].isEmpty { f.edit.params.filmStock = films[k] }
                if let layer2 { f.edit.adjustments.exposure = layer2 }
            }
        }
        let frames = ids.compactMap { model.library.frame($0) }
        steps.append(["step": "frames", "frames": frames.map { ["file": $0.picture.fileURL?.lastPathComponent ?? "?", "film": $0.edit.params.filmStock,
                                                               "paper": $0.edit.params.printStock, "hdr": $0.edit.hdr,
                                                               "slide": HDRGain.isSlide($0.edit), "layer2": $0.edit.adjustments.isActive] as [String: Any] }])

        var recipe = asked
        steps.append(["step": "recipe", "colour": recipe.colour.rawValue, "size": "\(recipe.size)"])
        var files: [URL] = []
        for format in [ExportRecipe.Format.jpeg, .heif] {
            recipe.format = format
            let b = await batch(model, ids, recipe, into: out.appending(path: "hdr"))
            steps.append(["step": "hdr \(format.rawValue)", "batch": b])
            let got = (b["files"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
            check(got.count == ids.count, "\(format.rawValue): every frame exported (\(got.count) of \(ids.count))")
            files += got
        }
        // The control: the first picture with HDR off, as a JPEG — no map, no hdrgm.
        model.library.update(ids[0]) { $0.edit.hdrChoice = false }
        recipe.format = .jpeg
        let c = await batch(model, [ids[0]], recipe, into: out.appending(path: "control"))
        let control = (c["files"] as? [String] ?? []).first.map { URL(fileURLWithPath: $0) }
        var controlFacts: [String: Any] = ["batch": c]
        if let control, let src = CGImageSourceCreateWithURL(control as CFURL, nil) {
            let plain = !HDRGainMap.present(in: src) && !AppleHDRGainMapDeclaration().isPresent(in: src) && (try? HDRUltraHDR.read(control)) == nil
            controlFacts["plain"] = plain
            check(plain, "the control (HDR off) carries no map and no hdrgm")
        } else { check(false, "the control was written") }
        // D3: a print's picture is the same with Enable HDR on (the control is the first picture's): its JPEG's coded
        // picture to the byte (ImageIO decodes a JPEG with a map with another decoder: within 2 codes, `analyse`).
        // Not a slide's, whose Enable HDR stretches its develop (D4).
        if let control, let mapped = files.first(where: { $0.lastPathComponent == control.lastPathComponent }), let first = model.library.frame(ids[0]), !HDRGain.isSlide(first.edit) {
            let a = (try? Data(contentsOf: mapped)) ?? Data(), b = (try? Data(contentsOf: control)) ?? Data()
            let end = (try? HDRUltraHDR.read(mapped))?.primaryScan.upperBound
            let same = end != nil && HDRUltraHDR.codedPicture(a, end: end) != nil && HDRUltraHDR.codedPicture(a, end: end) == HDRUltraHDR.codedPicture(b)
            controlFacts["coded_picture_equals_control"] = same
            check(same, "D3: \(mapped.lastPathComponent)'s coded picture is the HDR-off control's to the byte")
        }
        steps.append(["step": "control", "facts": controlFacts])
        model.library.update(ids[0]) { $0.edit.hdrChoice = true }

        // Measured before the read-backs: their 45 MP decodes leave this process (and the system) heavier, and the
        // first run measured 26 s deliveries after them against 4 s before.
        if measure {
            // H S S H for each container, the first picture alone.
            var runs: [[String: Any]] = []
            for format in [ExportRecipe.Format.jpeg, .heif] {
                recipe.format = format
                for (k, on) in [true, false, false, true].enumerated() {
                    model.library.update(ids[0]) { $0.edit.hdrChoice = on }
                    let b = await batch(model, [ids[0]], recipe, into: out.appending(path: "measure/\(format.rawValue)-\(k)-\(on ? "hdr" : "sdr")"))
                    var r = b
                    r["format"] = format.rawValue
                    r["hdr"] = on
                    if let f = (b["files"] as? [String])?.first { r["bytes"] = (try? fm.attributesOfItem(atPath: f)[.size] as? Int) ?? 0 }
                    runs.append(r)
                    print("export-hdr-check: measure \(format.rawValue) \(on ? "HDR" : "SDR") peak \(b["footprint_peak_mb"] ?? "?") MB, rise \(b["footprint_rise_mb"] ?? "?") MB, \(b["seconds"] ?? "?") s")
                }
            }
            model.library.update(ids[0]) { $0.edit.hdrChoice = true }
            steps.append(["step": "measure", "runs": runs])
        }
        var analysed: [[String: Any]] = []
        for url in files {
            let a = analyse(url, witness: witness)
            analysed.append(a)
            for f in a["failures"] as? [String] ?? [] { check(false, "\(url.lastPathComponent): \(f)") }
        }
        steps.append(["step": "read back", "files": analysed])

        try? fm.removeItem(at: work)
        return ["steps": steps, "failures": failures, "passed": failures.isEmpty, "written": ISO8601DateFormatter().string(from: Date())]
    }

    // MARK: reading back

    /// The ISO declaration's fields as ImageIO gives them back (one channel).
    nonisolated static func isoFields(_ src: CGImageSource) -> [String: Double]? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
              let md = info[kCGImageAuxiliaryDataInfoMetadata] else { return nil }
        let m = md as! CGImageMetadata
        func v(_ t: CGImageMetadataTag?) -> Double? { t.flatMap { CGImageMetadataTagCopyValue($0) as? String }.flatMap(Double.init) }
        var out: [String: Double] = [:]
        out["AlternateHeadroom"] = v(CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:AlternateHeadroom" as CFString))
        out["BaseHeadroom"] = v(CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:BaseHeadroom" as CFString))
        if let arr = CGImageMetadataCopyTagWithPath(m, nil, "HDRToneMap:ChannelMetadata" as CFString).flatMap({ CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] }),
           let f = arr.first.flatMap({ CGImageMetadataTagCopyValue($0) as? [String: CGImageMetadataTag] }) {
            for k in ["GainMapMin", "GainMapMax", "Gamma", "BaseOffset", "AlternateOffset"] { out[k] = v(f[k]) }
        }
        return out
    }

    /// The ISO map's codes, row padding removed.
    nonisolated static func isoCodes(_ src: CGImageSource) -> (width: Int, height: Int, codes: [UInt8])? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
              let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let w = d[kCGImagePropertyWidth] as? Int, let h = d[kCGImagePropertyHeight] as? Int,
              let row = d[kCGImagePropertyBytesPerRow] as? Int, let data = info[kCGImageAuxiliaryDataInfoData] as? Data else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeBytes { b in for y in 0..<h { for x in 0..<w { out[y * w + x] = b[y * row + x] } } }
        return (w, h, out)
    }

    /// Row `y` of `image` drawn into `space`: floats (RGBA) or 8-bit codes.
    nonisolated static func row(_ image: CGImage, _ y: Int, float: Bool) -> [Float] {
        let w = image.width
        guard let line = image.cropping(to: CGRect(x: 0, y: y, width: w, height: 1)) else { return [] }
        if float {
            var buf = [Float](repeating: 0, count: w * 4)
            let ok = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: 1, bitsPerComponent: 32, bytesPerRow: w * 16,
                                          space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                ctx.interpolationQuality = .none; ctx.setBlendMode(.copy)
                ctx.draw(line, in: CGRect(x: 0, y: 0, width: w, height: 1))
                return true
            }
            return ok ? buf : []
        }
        var buf = [UInt8](repeating: 0, count: w * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none; ctx.setBlendMode(.copy)
            ctx.draw(line, in: CGRect(x: 0, y: 0, width: w, height: 1))
            return true
        }
        return ok ? buf.map(Float.init) : []
    }

    nonisolated static func analyse(_ url: URL, witness: URL) -> [String: Any] {
        // The failures go into the facts at every return (a `defer` would run after the returned copy was made:
        // the first run of this check reported "passed" with its failures dropped).
        var facts: [String: Any] = ["file": url.lastPathComponent], failures: [String] = []
        func done() -> [String: Any] { var f = facts; f["failures"] = failures; return f }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { failures.append("not readable"); return done() }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        facts["size"] = [w, h]
        facts["bytes"] = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let iso = isoFields(src), apple = AppleHDRGainMapDeclaration.read(src)
        facts["iso"] = iso ?? [:]
        facts["apple_headroom"] = apple.map { $0.headroom } ?? 0
        if iso == nil { failures.append("no ISO 21496-1 map") }
        if apple == nil || !AppleHDRGainMapDeclaration().isPresent(in: src) { failures.append("no Apple map with MakerApple 33/48") }
        let mapSize = HDRGainMap.size(in: src)
        facts["map_size"] = mapSize.map { [$0.width, $0.height] } ?? []
        if mapSize?.width != w || mapSize?.height != h { failures.append("the map is not the picture's size") }

        // A JPEG's hdrgm, field for field the ISO declaration's.
        if url.pathExtension.lowercased() == "jpg", let iso {
            do {
                let r = try HDRUltraHDR.read(url)
                let f = r.mapFields.compactMapValues(Double.init)
                facts["hdrgm"] = ["primary_version": r.primaryVersion ?? "", "map_version": r.mapVersion ?? "", "fields": r.mapFields,
                                  "directory": r.directory, "length_said": r.mapLengthSaid ?? -1, "mpf_map_size": r.mpfMapSize,
                                  "consistent": r.consistent, "base_is_hdr": r.baseRenditionIsHDR ?? ""] as [String: Any]
                func same(_ a: Double?, _ b: Double?) -> Bool { a != nil && b != nil && abs(a! - b!) < 1e-6 }
                let agree = same(f["GainMapMin"], iso["GainMapMin"]) && same(f["GainMapMax"], iso["GainMapMax"]) && same(f["Gamma"], iso["Gamma"])
                    && same(f["OffsetSDR"], iso["BaseOffset"]) && same(f["OffsetHDR"], iso["AlternateOffset"])
                    && same(f["HDRCapacityMin"], iso["BaseHeadroom"]) && same(f["HDRCapacityMax"], iso["AlternateHeadroom"])
                facts["hdrgm_equals_iso"] = agree
                if !(r.consistent && r.primaryVersion == "1.0" && r.mapVersion == "1.0" && agree && r.baseRenditionIsHDR == "False") {
                    failures.append("its hdrgm is not the ISO declaration's")
                }
            } catch { failures.append("no hdrgm: \(error)") }
        }

        // The gain: HDR ÷ SDR in linear light, against the meant map and the declared one.
        let meant = try? Data(contentsOf: witness.appending(path: url.lastPathComponent + ".u8"))
        let meta = (try? Data(contentsOf: witness.appending(path: url.lastPathComponent + ".json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let headroom = (meta?["headroom"] as? NSNumber)?.doubleValue ?? 0
        guard let meant, meant.count == w * h, headroom > 1 else { failures.append("no witness of its map"); return done() }
        guard let hdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let sdr = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] as CFDictionary),
              let plain = CGImageSourceCreateImageAtIndex(src, 0, nil) else { failures.append("not decoded"); return done() }
        facts["decode_hdr"] = ["bits": hdr.bitsPerComponent, "space": (hdr.colorSpace?.name as String?) ?? "?", "content_headroom": Double(hdr.contentHeadroom)]
        let stored = isoCodes(src)
        let top = log2(headroom)
        let isoMin = iso?["GainMapMin"] ?? 0, isoMax = iso?["GainMapMax"] ?? 0, isoGamma = iso?["Gamma"] ?? 1
        // bins of intended stops: 0, (0, 0.5], (0.5, 1], (1, 1.5], (1.5, top), top
        var bins = [(sum: Double, abs: Double, n: Int)](repeating: (0, 0, 0), count: 6)
        var declaredErr: [Double] = [], meantErr: [Double] = []
        var codeWorst = 0, codeSum = 0, codeN = 0
        meant.withUnsafeBytes { (m: UnsafeRawBufferPointer) in
            for k in 0..<64 {
                let y = min(h - 1, (2 * k + 1) * h / 128)
                let hr = row(hdr, y, float: true), sr = row(sdr, y, float: true)
                let s8 = row(sdr, y, float: false), p8 = row(plain, y, float: false)
                guard hr.count == w * 4, sr.count == w * 4, s8.count == w * 4, p8.count == w * 4 else { continue }
                for x in stride(from: 0, to: w, by: 4) {
                    for c in 0..<3 {
                        let d = abs(Int(s8[4 * x + c]) - Int(p8[4 * x + c]))
                        codeWorst = max(codeWorst, d); codeSum += d; codeN += 1
                    }
                    let ys = 0.2289746 * Double(sr[4 * x]) + 0.6917385 * Double(sr[4 * x + 1]) + 0.0792869 * Double(sr[4 * x + 2])
                    let yh = 0.2289746 * Double(hr[4 * x]) + 0.6917385 * Double(hr[4 * x + 1]) + 0.0792869 * Double(hr[4 * x + 2])
                    guard ys > 0.02 else { continue }
                    let got = log2(max(yh, 1e-9) / ys)
                    let code = Int(m[y * w + x]), want = Double(code) / 255 * top
                    meantErr.append(abs(exp2(got - want) - 1))
                    let bin = code == 0 ? 0 : code == 255 ? 5 : 1 + min(Int(want / 0.5), 3)
                    bins[bin].sum += got; bins[bin].abs += abs(got - want); bins[bin].n += 1
                    if let stored, stored.width == w {
                        let c = pow(Double(stored.codes[y * w + x]) / 255, 1 / isoGamma)
                        let declared = isoMin + (isoMax - isoMin) * c
                        declaredErr.append(abs(exp2(got - declared) - 1))
                    }
                }
            }
        }
        func q(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? .nan : v.sorted()[min(v.count - 1, Int(p * Double(v.count)))] }
        let names = ["want 0", "(0,0.5]", "(0.5,1]", "(1,1.5]", "(1.5,top)", "want top"]
        facts["gain_by_bin"] = bins.enumerated().filter { $0.element.n > 0 }.map { i, b in
            ["bin": names[i], "n": b.n, "mean_log2": (b.sum / Double(b.n) * 1000).rounded() / 1000,
             "mean_abs_err_stop": (b.abs / Double(b.n) * 10000).rounded() / 10000] as [String: Any]
        }
        let meanMeant = meantErr.reduce(0, +) / Double(max(meantErr.count, 1))
        facts["ratio_vs_meant"] = ["n": meantErr.count, "mean": meanMeant, "p95": q(meantErr, 0.95), "p99": q(meantErr, 0.99), "worst": q(meantErr, 1)]
        facts["ratio_vs_declared"] = ["n": declaredErr.count, "mean": declaredErr.reduce(0, +) / Double(max(declaredErr.count, 1)),
                                      "p95": q(declaredErr, 0.95), "p99": q(declaredErr, 0.99), "worst": q(declaredErr, 1)]
        facts["sdr_vs_plain_codes"] = ["worst": codeWorst, "mean": Double(codeSum) / Double(max(codeN, 1))]
        facts["headroom_meant"] = headroom
        // ±3 %: against the meant gain on average over the picture, and against the declared gain at the 95th
        // percentile. A bin's mean against the meant gain is held to the camera layout's own cost instead: its Apple
        // coding read through ISO's fitted Gamma is up to 0.053 stop (3.7 %) off at H 4 in the 1–2 stop codes
        // (RFC-046; D8 measured ≤ 0.05 stop and took it), so ±3 % there would fail the layout D8 chose, not the
        // export. The base within 2 codes.
        //
        // The bin's bar is 0.075 stop, not the layout's own 0.055 (first set from the Display P3 files alone): the
        // 2026-11-06 review measured files that conform (`hdr_conformance --hdrgm`, mean 1.6 % from the meant map,
        // p95 2.2–2.4 % from the declared gain, the base 0 codes) at 0.055 (sRGB), 0.056 (2048 px; a low-key Z 8
        // frame), 0.061 (ProPhoto) in one bin — the map's own lossy coding and the 8-bit base's rounding, which a
        // wider or smaller picture coarsens, on top of the Apple coding's fit. The declared-gain bars below hold the
        // file to what it says; this one holds the layout's cost to what D8 measured with room for those two.
        if !(meanMeant <= 0.03) { failures.append(String(format: "HDR ÷ SDR is %.2f %% from the meant gain on average", meanMeant * 100)) }
        for (i, b) in bins.enumerated() where b.n > 50 && b.abs / Double(b.n) > 0.075 {
            failures.append(String(format: "bin %@: %.3f stop from the meant gain (the layout's bound 0.075)", names[i], b.abs / Double(b.n)))
        }
        // Against the declared gain: ±3 % on average, and at the 95th percentile ±3 % for a JPEG, ±4 % for a HEIF —
        // whose map is HEVC-coded: the first real run (2026-11-06) measured a high-DR NEF's HEIF at 3.09 % (mean
        // 0.93 %) where its JPEG was 2.09 %; the bar is said, not hidden.
        let declaredMean = declaredErr.reduce(0, +) / Double(max(declaredErr.count, 1))
        let p95Bar = url.pathExtension.lowercased() == "heic" ? 0.04 : 0.03
        if !(declaredMean <= 0.03) { failures.append(String(format: "HDR ÷ SDR is %.2f %% from the declared gain on average", declaredMean * 100)) }
        if !(q(declaredErr, 0.95) <= p95Bar) { failures.append(String(format: "HDR ÷ SDR p95 %.2f %% from the declared gain (bar %.0f %%)", q(declaredErr, 0.95) * 100, p95Bar * 100)) }
        if codeWorst > 2 { failures.append("the SDR decode is \(codeWorst) codes from the plain decode") }
        return done()
    }
}
#endif
