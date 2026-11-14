//  MacFinishedLayersCheck.swift — PRD-E's 成片 layers on every surface that shows the frame, in the running app (RFC-052
//  §10 gate 7; traps 33, 34).
//
//      CFFIXED_USER_HOME=<scratch> SpektraLab --library real --defaults-suite <name> --import DIR \
//          --finished-layers-check [--out DIR]                    (tools/finished_layers_check.sh)
//
//  One photograph, opened as a page takes it, given a layered edit — the whole's own Exposure, a soft radial layer
//  (Exposure −2, Saturation −50), a gradient layer (Contrast +25, Temperature +40) and (M1c) a found subject (Exposure
//  +1, Vibrance +30; Vision on this Mac, kept as the frame's file), masks in S — and walked through
//  four framings: as it is; Edit's crop; Develop's quarter turn with a flip; a film edge with Edit's crop. For each, the
//  same edit on:
//
//    - **the page**: `Layer2Live.shown`, the canvas's own pass at the develop's size (Edit's crop is the view's: cut
//      here as the canvas cuts it);
//    - **the histogram**: `Layer2Live.histogram` (the Curve tool's and the panel's), against the histogram of the page's
//      picture as shown (the histogram is of the whole finished picture: it ignores Edit's crop, a pinned defect);
//    - **the zoom**: `FullView`'s detail of the whole finished picture from the full render, at the page's pixels;
//    - **a tile's copy**: `Layer2Copies.served`, the library's, the browser's and the Light Table's picture;
//    - **the export**: a PNG at the page's long edge, through `ExportService` (the file is already cut).
//
//  Each against the export: 16 × 16 block means in sRGB codes (MacLayersCheck's bar: mean ≤ 3), and the layers' own
//  move on the page beside it (the same means, the page against its develop without Edit: it must be several times
//  the bar, or agreement within it says nothing). Writes `<out>/finished-layers-check.json` and the pictures. Exit 0
//  when every step is as it should be. Not in a release build.

#if DEBUG && SPK_ENGINE
import CoreGraphics
import Foundation
import ImageIO
import UIKit

@MainActor
enum MacFinishedLayersCheck {
    private struct Step: Encodable { var name: String; var ok: Bool; var detail: String; var seconds: Double }

    static func run(_ model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--finished-layers-check") else { return }
        var out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/finished-layers-check", isDirectory: true)
        if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count { out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true) }
        Task { await walk(model, out: out) }
    }

    /// The layered edit: masks in S, so every framing below moves them with the photograph.
    static func layers() -> LocalLayers {
        var disc = LocalLayer(name: "disc", stage: .finished,
                              parts: [.radial(MaskRadial(centre: MaskPoint(0.36, 0.42), rx: 0.26, ry: 0.17, angle: 20, feather: 0.3))])
        disc.finished?.exposure = -2; disc.finished?.saturation = -50
        var ramp = LocalLayer(name: "ramp", stage: .finished, parts: [.linear(MaskLinear(a: MaskPoint(0.5, 0.95), b: MaskPoint(0.6, 0.3)))])
        ramp.finished?.contrast = 25; ramp.finished?.temperature = 40
        var items = [disc, ramp]
        // M1c: a found subject (Vision on this Mac, the photograph's own file, `SubjectFinder`), kept as the edit's file
        // and read back from it by every surface's bake (PRD-E §7.5, §7.7).
        if let found = foundPart {
            var subject = LocalLayer(name: "subject", stage: .finished, parts: [found])
            subject.finished?.exposure = 1; subject.finished?.vibrance = 30
            items.append(subject)
        }
        return LocalLayers(items: items)
    }
    /// The photograph's subject as a part, found once before the framings.
    static var foundPart: MaskPart?

    private static func walk(_ model: AppServices, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var steps: [Step] = []
        var clock = Date()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append(Step(name: name, ok: ok, detail: detail, seconds: Date().timeIntervalSince(clock)))
            print("finished-layers-check: \(ok ? "ok  " : "FAIL") \(name) -- \(detail)")
            clock = Date()
        }
        defer {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(steps).write(to: out.appendingPathComponent("finished-layers-check.json"))
            print("finished-layers-check: done, \(steps.filter(\.ok).count) of \(steps.count) as they should be")
            exit(steps.allSatisfy(\.ok) && !steps.isEmpty ? 0 : 1)
        }
        guard let photo = await settled(model) else { return step("a photograph", false, "the library has none developed") }
        let id = photo.id
        step("a photograph", true, "\(photo.fileName), \(photo.originalSize.width) x \(photo.originalSize.height)")
        let session = model.session(for: id)
        session.enter()
        session.open()
        guard await developed(session) else { return step("the page developed", false, "no develop landed") }
        // The subject, found as 主体 finds it (`MaskFinding`'s source, `SubjectFinder`), its file written for the frame.
        if let source = session.findSource {
            let finder = SubjectFinder()
            await finder.focus(source.tag)
            if let r = try? await finder.subject(source), let part = try? await finder.part(r) { foundPart = part }
        }
        step("a found subject", foundPart != nil, foundPart.map { "asset \($0.asset ?? "nil")" } ?? "Vision found nothing on this photograph")
        let live = session.layer2
        live.holdHistogram("finished-layers-check")
        defer { live.releaseHistogram("finished-layers-check") }

        let cases: [(String, String, Bool, (inout FrameEdit) -> Void)] = [
            ("as it is", "plain", true, { e in e.adjustments.exposure = 0.3; e.layers = layers() }),
            ("Edit's crop", "crop", false, { e in e.printCrop.crop = CropRect(x: 0.15, y: 0.1, width: 0.6, height: 0.7) }),
            ("a quarter turn and a flip", "turn", true, { e in
                e.printCrop = .default; e.geometry.quarterTurns = 1; e.geometry.flipH = true
            }),
            ("a film edge and Edit's crop", "edge", true, { e in
                e.geometry = .default; e.filmEdge.active = true
                e.printCrop.crop = CropRect(x: 0.1, y: 0.15, width: 0.75, height: 0.7)
            }),
        ]
        for (name, file, develops, mutate) in cases {
            let stamp = session.developed?.stamp
            session.change(mutate)
            if develops {
                for _ in 0..<600 where session.developed?.stamp == stamp { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let frame = model.library.frame(id), let base = session.developedCGImage else { step(name, false, "no develop"); continue }
            let expected = model.finishedLayers(frame, edit: session.edit)
            guard let expected, expected.layers.count == layers().items.count else { step(name, false, "the edit's layers do not act (\(expected?.layers.count ?? 0))"); continue }
            let edge = max(base.width, base.height)

            // The page.
            live.display(maxPixel: edge)
            var page: CGImage?
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(100))
                if live.layers?.key == expected.key, live.picture != nil, let s = live.shown, s.width == base.width { page = s; break }
            }
            try? await Task.sleep(for: .milliseconds(800))      // a pass asked meanwhile lands
            page = live.shown ?? page
            guard let page else { step("\(name): the page", false, "no layered picture on the page"); continue }
            let crop = session.edit.printCrop.isIdentity ? nil : session.edit.printCrop.crop.rect
            let shown = crop.flatMap { cropped(page, $0) } ?? page
            write(shown, to: out.appendingPathComponent(file + "-page.png"))
            let moved = difference(shown, crop.flatMap { cropped(base, $0) } ?? base).mean

            // The export.
            guard let exported = await exported(model, id, longEdge: edge, as: out.appendingPathComponent(file + "-export.png")) else {
                step("\(name): the export", false, "the export did not land"); continue
            }
            let pe = difference(shown, exported)
            step("\(name): the page against the export", pe.mean <= 3 && moved > 9,
                 String(format: "mean %.2f, worst %.2f sRGB codes (bar: mean 3); the layers move the page %.2f; export %dx%d", pe.mean, pe.worst, moved, exported.width, exported.height))

            // The histogram, against the page's picture as shown (whole: the histogram does not cut).
            for _ in 0..<50 where live.histogram == nil { try? await Task.sleep(for: .milliseconds(100)) }
            if let h = live.histogram, let renderer = Layer2Renderer.shared,
               let of = try? renderer.histogram(renderer.source(page, maxPixel: Layer2Work.histogramPixel), Adjustments()).0,
               let plain = try? renderer.histogram(renderer.source(base, maxPixel: Layer2Work.histogramPixel), Adjustments()).0 {
                let d = apart(h, of), red = apart(plain, of)
                // Two 640 px copies of a grainy picture — the pass then the resample against the resample then the
                // pass — differ bin by bin by the grain (L1 0.07 measured on a 45 MP NEF, 2026-11-13); a histogram that
                // missed the layers is ten times that and more (1.1 there).
                step("\(name): the histogram", d.mean <= 1 && d.l1 <= 0.15 && red.l1 > 4 * d.l1,
                     String(format: "against the page's picture: mean bins %.2f apart, L1 %.3f (bars 1, 0.15); the develop without Edit's pass: %.2f, %.3f", d.mean, d.l1, red.mean, red.l1))
            } else {
                step("\(name): the histogram", false, "no histogram")
            }

            // The zoom: the full render's detail of the whole finished picture, at the page's pixels.
            let full = session.fullView
            full.want()
            for _ in 0..<1800 where full.state != .ready && full.state != .failed && full.state != .off { try? await Task.sleep(for: .milliseconds(100)) }
            if full.state == .ready {
                full.show(FullView.Ask(rect: CGRect(x: 0, y: 0, width: 1, height: 1), pixels: PixelSize(width: base.width, height: base.height),
                                       adjustments: session.edit.adjustments, layers: expected))
                var detail: CGImage?
                for _ in 0..<300 {
                    if let d = full.detail, d.layers?.key == expected.key { detail = d.image; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let detail {
                    let z = crop.flatMap { cropped(detail, $0) } ?? detail
                    write(z, to: out.appendingPathComponent(file + "-zoom.png"))
                    let ze = difference(z, exported)
                    step("\(name): the zoom against the export", ze.mean <= 3,
                         String(format: "mean %.2f, worst %.2f (detail %dx%d)", ze.mean, ze.worst, detail.width, detail.height))
                } else {
                    step("\(name): the zoom against the export", false, "no detail with the layers")
                }
                full.unwant()
            } else {
                step("\(name): the zoom against the export", false, "the full render is \(full.state)")
            }

            // A tile's copy: the library's picture of the frame, edited. Of its kept develop, which a page leaves
            // behind as it closes; asked here as a click on the frame's Develop would (`AppServices.develop`).
            let want = session.edit.adjustments.key + "|" + expected.key
            let keptBefore = model.library.frame(id)?.developed?.stamp
            model.develop(id)
            for _ in 0..<1200 {
                if let f = model.library.frame(id), !f.develop.isBusy, f.developed != nil, f.developed?.stamp != keptBefore || f.develop == .developed,
                   model.scheduler.snapshots.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            Layer2Copies.shared.reconcileSoon(after: 0)
            var copy: CGImage?
            for _ in 0..<1200 {
                if let f = model.library.frame(id), Layer2Copies.shared.copies[id]?.key == want, let ref = Layer2Copies.shared.served(f),
                   let url = ref.fileURL, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(src, 0, nil) { copy = image; break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if let copy {
                let c = crop.flatMap { cropped(copy, $0) } ?? copy
                write(c, to: out.appendingPathComponent(file + "-tile.png"))
                let ce = difference(c, exported)
                step("\(name): a tile's copy against the export", ce.mean <= 3,
                     String(format: "mean %.2f, worst %.2f (copy %dx%d)", ce.mean, ce.worst, copy.width, copy.height))
            } else {
                step("\(name): a tile's copy against the export", false, "no copy of this edit (\(Layer2Copies.shared.copies[id]?.key ?? "none"))")
            }
        }
        // Back as it was: no layer, no framing.
        session.change { $0 = .default }
    }

    // MARK: helpers (MacLayersCheck's)

    private static func settled(_ model: AppServices) async -> LibraryFrame? {
        for _ in 0..<900 {
            let photos = model.library.frames.filter { !$0.isComposite && !$0.isDemo }
            if let p = photos.first, photos.allSatisfy({ !$0.develop.isBusy }), model.scheduler.snapshots.isEmpty { return p }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    private static func developed(_ session: OpenFrameSession) async -> Bool {
        for _ in 0..<900 {
            if session.developed != nil, session.developedCGImage != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func exported(_ model: AppServices, _ id: LibraryFrame.ID, longEdge: Int, as file: URL) async -> CGImage? {
        var recipe = ExportRecipe()
        recipe.format = .png
        recipe.size = .longEdge(longEdge)
        model.exporter.start([id], recipe: recipe)
        for _ in 0..<1800 {
            if let b = model.exporter.batch, b.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let url = model.exporter.batch?.files.first,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.copyItem(at: url, to: file)
        return image
    }

    /// Two pictures as 16 x 16 block means in sRGB codes: the mean difference, and the worst block's.
    private static func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, worst: Double) {
        guard let x = blocks(a), let y = blocks(b) else { return (255, 255) }
        var sum = 0.0, worst = 0.0
        for i in 0..<(x.count / 3) {
            let d = (abs(x[3 * i] - y[3 * i]) + abs(x[3 * i + 1] - y[3 * i + 1]) + abs(x[3 * i + 2] - y[3 * i + 2])) / 3
            sum += d; worst = max(worst, d)
        }
        return (sum / Double(x.count / 3), worst)
    }

    private static func blocks(_ image: CGImage, side: Int = 16) -> [Double]? {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [Double] = []
        for i in 0..<(side * side) { out.append(Double(px[4 * i])); out.append(Double(px[4 * i + 1])); out.append(Double(px[4 * i + 2])) }
        return out
    }

    /// Two histograms: the mean bin's distance, channel by channel (worst of four), and the L1 of their shares.
    private static func apart(_ a: Layer2Histogram, _ b: Layer2Histogram) -> (mean: Double, l1: Double) {
        var worst = 0.0, l1 = 0.0
        for ch in 0..<4 {
            let x = a.counts[(ch * 256)..<(ch * 256 + 256)].map(Double.init), y = b.counts[(ch * 256)..<(ch * 256 + 256)].map(Double.init)
            let sx = max(x.reduce(0, +), 1), sy = max(y.reduce(0, +), 1)
            let mx = x.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / sx
            let my = y.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / sy
            worst = max(worst, abs(mx - my))
            l1 = max(l1, zip(x, y).reduce(0) { $0 + abs($1.0 / sx - $1.1 / sy) })
        }
        return (worst, l1)
    }

    private static func cropped(_ image: CGImage, _ n: CGRect) -> CGImage? {
        image.cropping(to: CGRect(x: n.minX * CGFloat(image.width), y: n.minY * CGFloat(image.height),
                                  width: n.width * CGFloat(image.width), height: n.height * CGFloat(image.height)).integral)
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? UIImage(cgImage: image).pngData()?.write(to: url)
    }
}
#endif
