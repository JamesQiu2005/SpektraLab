//  Exporter.swift — delivery.
//
//  Two routes (frontend SPEC §6):
//    - finished: JPEG, PNG 8-bit, TIFF 16-bit — Display P3, Layer 2 baked in,
//      cropped, straightened and turned. The engine renders the print at full
//      resolution into a texture; the client applies Layer 2 and the geometry
//      in Metal and writes through ImageIO with a P3 tag.
//    - DI package: the negative as normalised density (16-bit TIFF) plus the
//      print stock's `.cube` — grade the flat file in Photoshop under a Color
//      Lookup layer, or convert the cube to an ICC for Capture One. Layer 2
//      does not apply; it is pre-print by definition.
//
//  **Both routes are native now.** They used to call a Python service that
//  wrote files into a workspace and returned paths; the engine returns
//  textures and a pointer to the LUT table, and the three files — the DI
//  TIFF, the `.cube`, the optional print preview — are written here. That is
//  where they belong: ImageIO is already how the finished formats are
//  written, and `writeCube` is thirty lines of text formatting that no C++
//  file writer needs to exist for.
//
//  Filenames: `<original>_<film>_<paper>.<ext>` in `<source dir>/_prints/`.

import AppKit
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG", png = "PNG 8-bit", tiff = "TIFF 16-bit", di = "DI package"
    var id: String { rawValue }
    var ext: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .tiff: "tif"; case .di: "tif" } }
    var utType: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .tiff, .di: .tiff } }
    var note: String {
        switch self {
        case .jpeg: "Display P3, quality 0.95. Adjustments baked in."
        case .png: "Display P3, 8-bit lossless. Adjustments baked in."
        case .tiff: "Display P3, 16-bit. Adjustments baked in; headroom is the scan margin only."
        case .di: "Negative density TIFF + print .cube. For grading under the print LUT in Photoshop."
        }
    }
}

@MainActor
enum Exporter {
    struct Result: Sendable {
        let urls: [URL]
        /// What to tell the user about this export beyond its paths. `var`
        /// because the colour fallback's reason is appended to whatever the
        /// route itself produced (RFC-018 §5.4: a substitution is never
        /// silent).
        var note: String?
        /// The EV the meter applied to the render this was written from.
        /// Carried out of the render so the export record and the job log can
        /// say which exposure produced the file (RFC-015 P.1's invariant, in
        /// the field).
        var appliedEV: Double?
        var pixels: (w: Int, h: Int)?
    }

    /// What one export produced.
    ///
    /// `skipped` is a real outcome, not an error: a recipe set to skip an
    /// existing file did exactly what it was asked to, and reporting that as
    /// a thrown error would put "the export failed" in front of a user whose
    /// export did not fail.
    enum Outcome: Sendable {
        case wrote(urls: [URL], note: String?, fellBackToDisplayP3: Bool)
        case skipped(URL)

        var urls: [URL] {
            switch self {
            case .wrote(let urls, _, _): urls
            case .skipped: []
            }
        }
    }

    /// The legacy destination: the default recipe's answer.
    ///
    /// Kept because it is the one place the *old* naming is written down, and
    /// `PrintLUTTests.testTheExportFilenames` pins it. It delegates rather
    /// than duplicating the rule, so the default recipe and this cannot drift
    /// — if they ever disagree, that test is what says so.
    static func destination(for source: URL, params: FilmParams, format: ExportFormat) -> URL {
        var recipe = ExportRecipe()
        recipe.format = format
        let context = NamingRule.Context(
            originalName: source.deletingPathExtension().lastPathComponent,
            filmStock: params.filmStock, printStock: params.printStock,
            pixelSize: .zero, counter: 1, date: Date())
        // `.overwrite` so this stays a pure function of its arguments: the
        // suffix policy would make it depend on what is already on disk, and
        // this one is used to *describe* a destination, not to claim it.
        recipe.existing = .overwrite
        return recipe.destination(for: source, context: context)
            ?? source.deletingLastPathComponent().appending(path: "_prints")
                     .appending(path: "\(source.deletingPathExtension().lastPathComponent).\(format.ext)")
    }

    /// One export, and the record of its own making (RFC-016 §3 `export`,
    /// §11.4's job log).
    ///
    /// The job log is written **beside the output**, always — succeeded or
    /// failed. That is the point of it: a folder of exports then carries the
    /// evidence of how each one was made, and a failure carries its own
    /// explanation rather than leaving a missing file and a shrug.
    static func export(session: Session, recipe: ExportRecipe,
                       context: NamingRule.Context, sessionID: String) async throws -> Outcome {
        guard let source = session.selection else { throw ExportError.nothingOpen }
        let format = recipe.format
        // The directory is created here rather than while *describing* a
        // destination: this is the only place that can tell the user it could
        // not be, and a recipe pointed at an unmounted volume must say so
        // rather than quietly writing somewhere else.
        let dir = recipe.directory(for: source)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ExportError.directory(dir, error.localizedDescription)
        }
        guard let out = recipe.destination(for: source, context: context) else {
            // `.skip`, and the file is already there. Recorded, because "why
            // is there no new file" is a question the log should answer.
            session.log.info(.export, "export skipped", [
                .init("reason", "exists"),
                .init("frame", source.lastPathComponent),
                .init("recipe", recipe.name),
            ])
            let existing = dir.appending(path: "\(recipe.naming.stem(context)).\(format.ext)")
            return .skipped(existing)
        }
        let (target, _, fellBack, fellBackReason) = resolveTarget(recipe)
        var job = JobLog()
        job.note(.info, "export.start", jobHeader(session: session, recipe: recipe, out: out,
                                                  fellBack: fellBack))
        if let fellBackReason { job.note(.warn, "export.colour_fallback", [.init("why", fellBackReason)]) }
        let started = Date()
        do {
            var result = format == .di
                ? try await exportDI(session: session, to: out)
                // The export page's output size belongs here — stream B's
                // `ExportRecipe.outputSize`. It is `nil` until that field
                // lands, which is the frame's own size (see `exportPrint`).
                : try await exportPrint(session: session, to: out, format: format,
                                        target: target, outputSize: nil,
                                        quality: recipe.quality, sessionID: sessionID)
            // The fallback's reason, if the route did not have one of its own.
            // Merged rather than set, because the DI route has a note of its
            // own (a film/paper mismatch) and losing it to a colour note would
            // be trading one silent substitution for another.
            if let fellBackReason {
                result.note = result.note.map { "\($0) \(fellBackReason)" } ?? fellBackReason
            }
            let elapsed = Date().timeIntervalSince(started) * 1000
            for url in result.urls {
                job.note(.info, "export.file", [.init("path", url.lastPathComponent)])
            }
            job.note(.info, "export.done", [
                .init("elapsed_ms", elapsed),
                .init("files", result.urls.count),
                .init("ev", result.appliedEV ?? Double.nan),
            ])
            try? job.write(beside: out)
            noteExport(session, recipe: recipe, result: result, elapsedMs: elapsed,
                       fellBack: fellBack, job: job)
            // §3: after an export is a memory boundary — the full-tier render
            // it just made is the biggest thing the app allocates.
            session.sampleMemory("export")
            return .wrote(urls: result.urls, note: result.note, fellBackToDisplayP3: fellBack)
        } catch {
            job.note(.error, "export.failed", [
                .init("elapsed_ms", Date().timeIntervalSince(started) * 1000),
                .init("error", "\(error)"),
                .init("raw", EngineMessage.technical(error)),
            ])
            try? job.write(beside: out)
            session.noteFailure(error, operation: "export", frame: source.lastPathComponent)
            throw error
        }
    }

    /// §3 `export`: destination format, bit depth, colour space, pixels,
    /// elapsed, and the applied EV — "so an export can be reconciled with the
    /// canvas that was approved".
    private static func noteExport(_ session: Session, recipe: ExportRecipe, result: Result,
                                   elapsedMs: Double, fellBack: Bool, job: JobLog) {
        let format = recipe.format
        var fields: [LogField] = [
            .init("format", format.rawValue),
            .init("ext", format.ext),
            .init("bit_depth", depth(format)),
            .init("color_space", colourSpace(recipe)),
            .init("recipe", recipe.name),
            .init("profile_fell_back", fellBack),
            .init("elapsed_ms", elapsedMs),
            .init("files", result.urls.count),
            .init("frame", session.selection?.lastPathComponent ?? "-"),
            .init("job_log", JobLog.url(beside: result.urls[0]).lastPathComponent),
        ]
        if let pixels = result.pixels {
            fields.append(.init("w", pixels.w)); fields.append(.init("h", pixels.h))
            fields.append(.init("px", pixels.w * pixels.h))
        }
        if let ev = result.appliedEV { fields.append(.init("ev", ev)) }
        session.log.info(.export, "export", fields)
        _ = job
    }

    /// The space this export will actually be in: a `CGColorSpace`, the
    /// engine's name for it, and — when those are not what the recipe asked
    /// for — why, in words a user can act on.
    ///
    /// There are two ways to land on Display P3 and they are different
    /// failures. A profile that is not on this machine is the one
    /// `resolvedColorSpace()` has always reported. A profile that *is*
    /// installed but has no baked colour space in the engine is new with
    /// RFC-018: the transform cannot be built for it, and since §2.4 retired
    /// Core Graphics' clip there is nothing left to fall back *to*. Neither is
    /// silent — §5.4's rule, and the reason this returns a sentence rather
    /// than a bool.
    /// Not private: `SoftProof` resolves its destination through this same
    /// function, because a proof of a space other than the file's is
    /// decoration (RFC-018 §7.6).
    static func resolveTarget(_ recipe: ExportRecipe)
        -> (space: CGColorSpace, name: String, fellBack: Bool, reason: String?) {
        // Resolved once: `.installed` reads an ICC profile off disk, and some
        // of those are a megabyte.
        let resolved = recipe.resolvedColorSpace().space
        if let resolved {
            if let name = ColourManagement.engineName(for: resolved) {
                return (resolved, name, false, nil)
            }
            let asked = ColorSpaceCatalog.name(for: recipe.colorSpace) ?? "The recipe's profile"
            return (ImageDecoder.displayP3, "Display P3", true,
                    "\(asked) has no colour space in the engine, so the perceptual transform cannot be built for it. The file is in Display P3.")
        }
        // `resolvedColorSpace` returned nil: either the format carries no
        // colour at all (the DI package — handled by its own route, and this
        // value is never used) or the profile could not be read.
        guard recipe.format.takesColorSpace else {
            return (CGColorSpaceCreateDeviceRGB(), "device RGB (density)", false, nil)
        }
        return (ImageDecoder.displayP3, "Display P3", true,
                "The recipe's profile is not on this machine. The file is in Display P3.")
    }

    private static func depth(_ format: ExportFormat) -> Int {
        switch format {
        case .jpeg, .png: 8
        case .tiff, .di: 16
        }
    }

    /// What the log and the job log call the export's colour space. The DI
    /// file is deliberately untagged-ish: its channels are densities, not
    /// colours (see `exportDI`), and it has no profile to name.
    private static func colourSpace(_ recipe: ExportRecipe) -> String {
        guard recipe.format.takesColorSpace else { return "device RGB (density)" }
        return ColorSpaceCatalog.name(for: recipe.colorSpace) ?? "unresolved profile"
    }

    /// What the job log's header record carries: the recipe, in one place, so
    /// a folder of exports can be read without the app that made them.
    private static func jobHeader(session: Session, recipe: ExportRecipe, out: URL,
                                  fellBack: Bool) -> [LogField] {
        let p = session.params
        return [
            .init("recipe", recipe.name),
            .init("format", recipe.format.rawValue),
            .init("bit_depth", depth(recipe.format)),
            .init("color_space", colourSpace(recipe)),
            .init("profile_fell_back", fellBack),
            .init("destination", out.lastPathComponent),
            .init("directory", out.deletingLastPathComponent().path),
            .init("film", p.filmStock),
            .init("print", p.printStock),
            .init("exposure_comp_ev", session.sidecar.solvedEV ?? Double.nan),
            .init("y_shift", p.yFilterShift),
            .init("m_shift", p.mFilterShift),
            .init("layer2", session.adjustments.enabled),
            .init("render_core", session.renderCore ?? "unreported"),
            .init("engine", session.diagnostics.engineVersion ?? "unknown"),
            .init("app", Diagnostics.bundleInfo.version),
            .init("marker", "job"),
        ]
    }

    /// Render, grade, frame, size, convert, write — in that order, and the
    /// order is the whole of RFC-018's export claim.
    ///
    /// The last two steps are the ones that changed: the image is converted to
    /// the recipe's space by **our** output transform (§5.4), which rolls
    /// out-of-gamut colour off instead of clipping it, and `write` is then
    /// handed pixels that are already in the target and never converts a
    /// colour. The old path rendered in Display P3 and let Core Graphics clip
    /// into the destination — `redraw`'s colour branch, which is gone.
    ///
    /// `outputSize` is the export page's output size (nil = the frame's own).
    /// It is applied **before** the transform so the transform and its clip
    /// statistics run on the pixels that actually reach the file.
    private static func exportPrint(session: Session, to out: URL, format: ExportFormat,
                                    target: CGColorSpace, outputSize: CGSize?, quality: Double,
                                    sessionID: String) async throws -> Result {
        // `.export` is a full-tier reprint: the engine reuses the working
        // negative when one is warm and runs the film side when it is not.
        let outcome = try await session.client.render(
            .export, RenderRequest(sessionID: sessionID, tier: "full"))
        guard let full = outcome.texture else { throw ExportError.noPixels }
        guard let adjusted = session.renderer.applyLayer2(to: full, uniforms: session.adjustments.uniforms)
            else { throw ExportError.noPixels }
        // Crop, straighten, quarter turns and flips, through the same
        // `geometryMap` the canvas samples with — not a CoreGraphics
        // transform written a second time. The old path cropped with
        // `CGImage.cropping` and could not rotate at all, so a straightened
        // frame exported unstraightened and nothing in the app said so.
        let framed = session.renderer.applyGeometry(session.geometry, to: adjusted) ?? adjusted
        // The page's output size, through the geometry pass's own resampler.
        let sized: MTLTexture
        if let outputSize {
            guard let resized = session.renderer.applyResize(framed, width: Int(outputSize.width.rounded()),
                                                             height: Int(outputSize.height.rounded()))
            else { throw ExportError.noPixels }
            sized = resized
        } else {
            sized = framed
        }
        // The one conversion, at the end, out of the working space and into
        // the destination — the same kernel the canvas and the soft proof run,
        // which is what makes the proof a proof.
        let (setup, problem) = await ColourManagement.setup(client: session.client,
                                                            source: session.workingSpaceName,
                                                            target: target,
                                                            device: session.renderer.device)
        guard let setup else { throw ExportError.colourSpace(problem ?? "the engine refused it") }
        guard let converted = session.renderer.applyOutputTransform(to: sized, setup: setup)
        else { throw ExportError.noPixels }
        guard let cg = converted.texture.makeCGImage(space: target) else { throw ExportError.noPixels }
        try write(cg, to: out, format: format, quality: quality)
        return Result(urls: [out], note: nil,
                      appliedEV: outcome.progress?.autoExposureEV,
                      pixels: (converted.texture.width, converted.texture.height))
    }

    // MARK: - the DI package

    /// Three files: the normalised-density negative, the print stock's
    /// `.cube`, and a print preview so the flat file can be checked against
    /// what the LUT does to it.
    ///
    /// The geometry is already in the negative — `node_geometry` runs on the
    /// film side, before the density curves — so the crop and the straighten
    /// are baked in and nothing is applied here. Layer 2 is not, and must not
    /// be: it lives after the print and the DI file is before it.
    private static func exportDI(session: Session, to out: URL) async throws -> Result {
        let di = try await session.client.exportDI()
        guard let texture = di.texture else { throw ExportError.noPixels }
        // Device RGB, not Display P3. These are not colours: each channel is
        // a film density normalised by the LUT's own axis, and the `.cube`
        // beside it indexes exactly those numbers. Tagging the file with a
        // rendering space invites whatever opens it to convert the values and
        // silently move the cube's domain out from under it, so this asks
        // ImageIO for the most nearly untagged thing it will write.
        guard let cg = texture.makeCGImage(space: CGColorSpaceCreateDeviceRGB())
            else { throw ExportError.noPixels }
        try write(cg, to: out, format: .tiff)

        let base = out.deletingPathExtension()
        let cube = base.deletingLastPathComponent()
            .appending(path: "\(base.lastPathComponent)_\(di.meta.printStock).cube")
        let table = try await session.client.printLUTTable(di.meta.printStock)
        try writeCube(table.table, size: table.size, to: cube,
                      title: "spektrafilm \(di.meta.printStock) print (from \(di.meta.pairedFilm))")

        var urls = [out, cube]
        // The print preview is the same table applied to the same negative,
        // which is what `preview_stock_lut` is. It is written last and its
        // failure is not the export's: the two files that carry the grade are
        // already on disk.
        if let preview = try? await session.client.previewStockLUT(di.meta.printStock, tier: "full"),
           let tex = preview.texture, let cg = tex.makeCGImage() {
            let path = base.deletingLastPathComponent()
                .appending(path: "\(base.lastPathComponent)_print.tif")
            if (try? write(cg, to: path, format: .tiff)) != nil { urls.append(path) }
        }
        return Result(urls: urls, note: di.meta.warning,
                      appliedEV: di.progress?.autoExposureEV,
                      pixels: (di.width, di.height))
    }

    /// A plain 3D `.cube`: `LUT_3D_SIZE N`, domain 0..1, red fastest.
    ///
    /// `table` is (N, N, N, 3) indexed [r, g, b] — the bake's own axis order
    /// — so iterating blue outermost and red innermost gives the cube's
    /// ordering. The domain is 0..1 because the DI file beside it was
    /// normalised by the same axes, which is what lets this carry no
    /// `DOMAIN_MIN`/`DOMAIN_MAX` for a host to misread.
    static func writeCube(_ table: [Float], size n: Int, to url: URL, title: String) throws {
        guard table.count == n * n * n * 3 else { throw ExportError.noPixels }
        var text = """
        TITLE "\(title)"
        LUT_3D_SIZE \(n)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0


        """
        text.reserveCapacity(n * n * n * 26 + 128)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let i = ((r * n + g) * n + b) * 3
                    text += String(format: "%.6f %.6f %.6f\n",
                                   min(max(table[i], 0), 1),
                                   min(max(table[i + 1], 0), 1),
                                   min(max(table[i + 2], 0), 1))
                }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write one image.
    ///
    /// **`write` does not convert colour.** RFC-018 §5.4: it draws only when
    /// the *bit depth* has to change, and even then it redraws into the
    /// image's own colour space, so the numbers that reach the file are the
    /// ones the output transform produced. Callers hand it a `CGImage` already
    /// in the destination's space — `applyOutputTransform` then
    /// `makeCGImage(space:)` — and the tag travels with the pixels rather than
    /// being applied to them.
    ///
    /// The parameter that used to say otherwise is gone rather than ignored. A
    /// `colorSpace` argument that silently meant "and also re-draw into this"
    /// was the very Core Graphics clip this RFC removes; one that silently
    /// meant nothing would be worse, because it would look like it worked.
    ///
    /// Bit depth is decided by the format, not by the caller: ImageIO would
    /// otherwise write a 16-bit PNG.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, format: ExportFormat,
                      quality: Double = 0.95) throws -> URL {
        var cg = image
        let needsEight = format.isEightBit
        if needsEight {
            // Into the image's *own* space, so this is a depth reduction and
            // not a conversion. The fallback is for a CGImage that arrived
            // with no profile at all, which is the DI route.
            guard let converted = redraw(cg, in: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                         bitsPerComponent: 8) else { throw ExportError.noPixels }
            cg = converted
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.write(url)
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = quality.clamped(to: 0.1...1) }
        if format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.write(url) }
        return url
    }

    /// Core Graphics does the colour conversion; this only sets up the
    /// context it does it in. 16-bit needs the little-endian byte order flag
    /// — without it the context is created but the channels come out
    /// byte-swapped, which looks like a colour-management bug and is not one.
    private static func redraw(_ cg: CGImage, in space: CGColorSpace, bitsPerComponent: Int) -> CGImage? {
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bitsPerComponent == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    enum ExportError: Error, LocalizedError {
        case nothingOpen, noPixels, write(URL), directory(URL, String), colourSpace(String)
        var errorDescription: String? {
            switch self {
            case .nothingOpen: "Nothing is open."
            case .noPixels: "The render came back empty."
            case .colourSpace(let why): "Could not convert to the recipe's colour space: \(why)."
            case .write(let u): "Could not write \(u.lastPathComponent)."
            case .directory(let u, let why):
                "Could not create \(u.path): \(why). Choose another folder in the export recipe."
            }
        }
    }
}
