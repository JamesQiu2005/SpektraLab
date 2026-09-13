//  SoftProofParityTests.swift — RFC-018 §7.6: the proof and the file are the
//  same pixels.
//
//  This is the measurement the export page rests on. If a proof and the export
//  it proves can differ, the preview is decoration and §2.4's main claim is
//  unearned — so the bar here is **identical**, not close, and the comparison
//  is against the file **read back off disk** rather than against a second run
//  of the code that wrote it. (A comparison that passes by comparing a thing
//  to itself proves nothing, which is the trap this file is written around.)
//
//  **"Identical" is unconditional now, and that is the point of this file.**
//  It used to be qualified twice over: `softProof` bounded its render by
//  `min(exportSize, framed)`, where `framed` descends from the tier the
//  *canvas* was showing, and by a `maxPixels` budget — so the identity held
//  only while the canvas happened to hold the frame's own pixels, and the test
//  had to wait for that. Both bounds are gone: `softProof` is
//  `Exporter.filePixels`, the export's own chain, and the proof is the file's
//  pixels at the file's size. There is nothing left to wait for and nothing
//  left to assert conditionally.
//
//  What makes "identical" well-posed, and what does not:
//
//  * **The two sides render the frame twice**: the export's `.export` and the
//    proof's, both full-tier reprints. They are the same request, and
//    the second reuses the cached negative — but the *print* side carries
//    `scanning.glare`, which draws an unseeded field on every render
//    (`AGENTS.md` trap 1). With it on, the two sides are two different
//    photographs and no transform could make them equal. So the parity case
//    runs with the stochastic stages off, which is what `parity_render` and
//    friends do for the same reason; the default configuration is measured
//    separately, below, as the difference it is.
//
//  **Cost: minutes**, all of it full-tier exports and full-tier proofs on a
//  24 MP frame, each read back and compared at 24 million pixels — eight
//  exports and eight proofs across the four cases. It skips entirely without
//  the A7 III RAW, and it is deliberate rather than incidental: the
//  alternative is a smaller frame, which is a frame the transform does less to
//  and therefore proves less about. It used to spend a large part of that
//  waiting for the *canvas* to settle, which is time it no longer spends and a
//  dependency it no longer has.

import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

@MainActor
final class SoftProofParityTests: XCTestCase {

    // MARK: - the frame

    /// The A7 III frame — the one §7.4 used, because the transform has to be
    /// doing real work for this to prove anything. A frame that fits in the
    /// destination would be a comparison of two no-ops.
    ///
    /// Copied into a temp directory, never opened in place: a develop writes a
    /// `.spektra.json` sidecar beside the frame, and the checkout's copy is
    /// shared with every other suite (`develop-writes-a-sidecar-copy-the-fixture`).
    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    /// A session with the frame open and developed. Nothing about the canvas
    /// is waited for — see the note at the end of this function.
    private func developed(_ url: URL, stochastic: Bool) async throws -> Session {
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine to warm up", timeout: 120) { session.serviceReady }
        if !stochastic {
            // Off before the develop, so the negative and the print are both
            // deterministic and the two renders below are the same photograph.
            // The order matters: `open` has to have made the session for the
            // params to have somewhere to go, and the develop must not have
            // run yet or the negative is already fixed. `WhiteBalanceTests`
            // sets them in exactly this window for the same reason.
            var p = session.params
            p.grainActive = false
            p.glareActive = false
            session.params = p
        }
        session.solveNow()
        try await waitUntil("the print to land", timeout: 180) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }
        // **No wait for the canvas, deliberately.** The proof used to be
        // bounded by the tier on the canvas, so this had to wait for
        // `canvasIsSettled` before it could ask its question at all — and the
        // wait *was* the caveat. The proof renders its own full-tier source
        // now, so this asserts the absence instead: whatever the canvas is
        // showing, the proof is the file's pixels. If that ever stops being
        // true, the identity cases below fail rather than silently measuring a
        // different picture.
        return session
    }

    // MARK: - the comparison

    private struct Difference {
        var differing = 0
        var maxAbs = 0
        var sum = 0.0
        var total = 0
        var mean: Double { total == 0 ? 0 : sum / Double(total) }
    }

    /// Both images are reduced the same way — drawn into a 16-bit context in
    /// the **file's own** colour space, which for an image already in that
    /// space is a copy — so the comparison cannot invent a difference. That
    /// the reduction is the identity is asserted rather than assumed:
    /// `testTheComparisonReductionIsIdentity`.
    private func compare(_ proof: CGImage, _ file: CGImage, space: CGColorSpace,
                         bits: Int) throws -> Difference {
        XCTAssertEqual(proof.width, file.width, "the proof and the file are different sizes")
        XCTAssertEqual(proof.height, file.height)

        if bits == 16 {
            let a = try bits16(proof, space: space), b = try bits16(file, space: space)
            return difference(a, b, scale: 65535)
        }
        let a = try bits8(proof, space: space), b = try bits8(file, space: space)
        return difference(a, b, scale: 255)
    }

    private func difference(_ a: [UInt16], _ b: [UInt16], scale: Double) -> Difference {
        var d = Difference()
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            var moved = false
            for c in 0..<3 {
                let delta = abs(Int(a[i + c]) - Int(b[i + c]))
                d.sum += Double(delta) / scale
                d.total += 1
                d.maxAbs = max(d.maxAbs, delta)
                if delta != 0 { moved = true }
            }
            if moved { d.differing += 1 }
        }
        return d
    }

    private func context(_ cg: CGImage, _ space: CGColorSpace, bits: Int) -> CGContext? {
        let rowBytes = cg.width * 4 * (bits / 8)
        var info = CGImageAlphaInfo.noneSkipLast.rawValue
        if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        return CGContext(data: nil, width: cg.width, height: cg.height,
                         bitsPerComponent: bits, bytesPerRow: rowBytes, space: space,
                         bitmapInfo: info)
    }

    private func bits16(_ cg: CGImage, space: CGColorSpace) throws -> [UInt16] {
        let ctx = try XCTUnwrap(context(cg, space, bits: 16))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let raw = try XCTUnwrap(ctx.data)
        let p = raw.bindMemory(to: UInt16.self, capacity: cg.width * cg.height * 4)
        return Array(UnsafeBufferPointer(start: p, count: cg.width * cg.height * 4))
    }

    private func bits8(_ cg: CGImage, space: CGColorSpace) throws -> [UInt16] {
        let ctx = try XCTUnwrap(context(cg, space, bits: 8))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let raw = try XCTUnwrap(ctx.data)
        let p = raw.bindMemory(to: UInt8.self, capacity: cg.width * cg.height * 4)
        return (0..<(cg.width * cg.height * 4)).map { UInt16(p[$0]) }
    }

    /// The comparison's own control: the reduction must be a copy, or a
    /// difference could come from the harness rather than from the pictures.
    ///
    /// The proof's `CGImage` carries its pixels in its data provider, so its
    /// bytes are readable without any drawing at all — which makes it the one
    /// image against which the drawn reduction can be checked exactly.
    func testTheComparisonReductionIsIdentity() throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        let src = try XCTUnwrap(renderer.store.makeWritable(width: 4, height: 2))
        var px: [UInt16] = []
        for i in 0..<8 {
            px += [UInt16(1000 * i), UInt16(2000 + i), UInt16(65535 - 3000 * i), 65535]
        }
        px.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 32)
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.rommrgb))
        let cg = try XCTUnwrap(src.makeCGImage(space: space))
        // The proof's own bytes, straight out of its data provider — no
        // drawing, so nothing to be wrong about.
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        let direct: [UInt16] = data.withUnsafeBytes { raw in
            (0..<32).map { raw.load(fromByteOffset: $0 * 2, as: UInt16.self) }
        }
        XCTAssertEqual(direct, px, "the texture did not reach the CGImage's provider unchanged")
        XCTAssertEqual(try bits16(cg, space: space), px,
                       "drawing a 16-bit image into a 16-bit context in its own space is not a copy")
    }

    // MARK: - §7.6

    private struct Case {
        let name: String
        let format: ExportFormat
        let space: ExportColorSpace
        let bits: Int
        /// Whether the file can be identical to the proof at all, and if not,
        /// what stops it.
        let expect: Expectation
        enum Expectation { case identical, requantised, lossy }
    }

    private static let cases: [Case] = [
        Case(name: "P3 TIFF 16-bit", format: .tiff, space: .displayP3,
             bits: 16, expect: .identical),
        Case(name: "sRGB TIFF 16-bit", format: .tiff, space: .sRGB,
             bits: 16, expect: .identical),
        Case(name: "ProPhoto TIFF 16-bit", format: .tiff,
             space: .builtIn(CGColorSpace.rommrgb as String), bits: 16, expect: .identical),
        Case(name: "P3 PNG 8-bit", format: .png, space: .displayP3,
             bits: 8, expect: .requantised),
        Case(name: "P3 JPEG", format: .jpeg, space: .displayP3,
             bits: 8, expect: .lossy),
    ]

    func testTheProofIsTheFile() async throws {
        let url = try frame()
        let session = try await developed(url, stochastic: false)
        let device = session.renderer.device
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-proof-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var report: [String] = []
        for c in Self.cases {
            var recipe = ExportRecipe()
            recipe.name = c.name
            recipe.format = c.format
            recipe.colorSpace = c.space
            recipe.folder = .fixed(path: dir.path)
            recipe.subfolder = ""
            recipe.existing = .overwrite

            let (target, name, _, _) = Exporter.resolveTarget(recipe)
            let context = NamingRule.Context(
                originalName: url.deletingPathExtension().lastPathComponent,
                filmStock: session.params.filmStock, printStock: session.params.printStock,
                pixelSize: .zero, counter: 1, date: Date())
            let outcome = try await Exporter.export(
                session: session, recipe: recipe, context: context,
                sessionID: try XCTUnwrap(session.serviceSessionIDForExport))
            let written = try XCTUnwrap(outcome.urls.first, "\(c.name) wrote nothing")

            // **Read the file back off disk.** Everything below is a statement
            // about bytes ImageIO wrote and something else read, not about a
            // texture the two sides happened to share.
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            let file = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

            // No budget, no size argument, nothing conditional: the proof is
            // the file's pixels at the file's size, and `compare` fails on a
            // size mismatch before it looks at a single value.
            let rendered = await session.softProof(recipe: recipe)
            let proof = try XCTUnwrap(rendered, "\(c.name): no proof")

            XCTAssertFalse(proof.isPlaceholder)
            XCTAssertEqual(proof.target.name, target.name, "\(c.name): the proof is tagged with another space")

            let d = try compare(proof.image, file, space: target, bits: c.bits)
            // Swift's `String(format:)` has no `%s`; the padding is done here.
            report.append("  " + c.name.padding(toLength: 22, withPad: " ", startingAt: 0)
                          + " \(file.width)x\(file.height)".padding(toLength: 12, withPad: " ", startingAt: 0)
                          + " differing \(d.differing) of \(file.width * file.height)"
                          + ", max \(d.maxAbs), mean \(String(format: "%.6f", d.mean)) counts")

            switch c.expect {
            case .identical:
                XCTAssertEqual(d.differing, 0,
                               "\(c.name): \(d.differing) pixels differ, max \(d.maxAbs) counts")
                XCTAssertEqual(d.maxAbs, 0, "\(c.name): max \(d.maxAbs) counts")
            case .requantised:
                // 8 bits of container: the only admissible difference is the
                // requantisation, and it must be bounded by one step of it.
                XCTAssertLessThanOrEqual(d.maxAbs, 1, "\(c.name): more than a requantisation step")
                // And the cause, stated rather than asserted: at 16-bit
                // precision the same file differs from the same proof by the
                // depth of the container and nothing else — bounded by one
                // 8-bit step in 16-bit counts. Without this, "identical" at 8
                // bits could be hiding anything under one step.
                let wide = try compare(proof.image, file, space: target, bits: 16)
                XCTAssertLessThanOrEqual(wide.maxAbs, 257,
                                         "\(c.name): the 8-bit file differs by more than a requantisation")
                XCTAssertGreaterThan(wide.differing, 0,
                                     "\(c.name): a 16-bit proof and an 8-bit file are bit-equal — "
                                     + "which would mean one of them is not what it says")
                report.append("  " + "at 16-bit precision".padding(toLength: 22, withPad: " ", startingAt: 0)
                              + " ".padding(toLength: 12, withPad: " ", startingAt: 0)
                              + " differing \(wide.differing) of \(file.width * file.height)"
                              + ", max \(wide.maxAbs), mean \(String(format: "%.6f", wide.mean)) counts"
                              + "  — the requantisation, and only it")
            case .lossy:
                XCTAssertGreaterThan(d.maxAbs, 0, "\(c.name): a lossy codec came back bit-exact "
                                                  + "— which would mean the file was never encoded")
            }
        }
        print("§7.6 — proof vs file, read back from disk:\n" + report.joined(separator: "\n"))
    }

    /// **The proof is the file's size — always, and including when the recipe
    /// asks for a size of its own.**
    ///
    /// This replaces `testADownscaledProofDiffersByTheDownscale`, whose premise
    /// no longer exists: `softProof` takes no pixel budget and cannot return a
    /// resample, so "a downscaled proof is not the file" is not a case that can
    /// be constructed. What that test protected — that the comparison harness
    /// *can* see a difference, rather than reporting zero for everything — is
    /// carried by the 8-bit and JPEG cases above, each of which asserts
    /// `differing > 0` for exactly that reason.
    ///
    /// The second size is the case the old one could not reach: the proof used
    /// to be sized from the frame's native pixels and the canvas tier, neither
    /// of which knows about the recipe's own output size, so a resized export
    /// was proofed at the wrong size and the page captioned it wrongly.
    func testTheProofIsTheFilesSize() async throws {
        let url = try frame()
        let session = try await developed(url, stochastic: false)
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-proof-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var recipe = ExportRecipe()
        recipe.name = "P3 TIFF 16-bit"
        recipe.format = .tiff
        recipe.colorSpace = .displayP3
        recipe.folder = .fixed(path: dir.path)
        recipe.subfolder = ""
        recipe.existing = .overwrite
        let (target, _, _, _) = Exporter.resolveTarget(recipe)
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: .zero, counter: 1, date: Date())

        for size in [OutputSize.original, .custom(width: 2000, height: 1333)] {
            recipe.outputSize = size
            let outcome = try await Exporter.export(session: session, recipe: recipe, context: context,
                                                    sessionID: try XCTUnwrap(session.serviceSessionIDForExport))
            let written = try XCTUnwrap(outcome.urls.first)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
            let file = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

            let rendered = await session.softProof(recipe: recipe)
            let proof = try XCTUnwrap(rendered, "\(size): no proof")
            XCTAssertEqual(proof.image.width, file.width,
                           "\(size): the proof is not the file's width")
            XCTAssertEqual(proof.image.height, file.height,
                           "\(size): the proof is not the file's height")
            let d = try compare(proof.image, file, space: target, bits: 16)
            XCTAssertEqual(d.differing, 0,
                           "\(size): a full-size proof of a 16-bit TIFF differs by \(d.differing) px")
            print("  \(size) — proof and file agree at \(file.width)x\(file.height), 0 differing")
        }
    }

    /// The configuration the app actually ships in, measured rather than
    /// argued: with the stochastic stages on, the export's reprint and the
    /// proof's are two renders of a stochastic pipeline.
    ///
    /// It used to be the canvas's full tier against the export's reprint. It
    /// is now two `filePixels` calls — the export's and the proof's — which is
    /// the sharper statement: the proof is not merely "the same chain as the
    /// file", it is the same request, and it still comes back different
    /// because the *pipeline* is nondeterministic. That is the whole content
    /// of `AGENTS.md` trap 1, at the one place that can see it.
    ///
    /// This is **not** a transform difference and it is not a defect of the
    /// proof. It is the engine's documented nondeterminism (`AGENTS.md` trap 1)
    /// showing up at the one place that compares two renders of the same
    /// frame — and it is why the parity case above turns it off.
    func testWithTheStochasticStagesOnTheTwoRendersDiffer() async throws {
        let url = try frame()
        let session = try await developed(url, stochastic: true)
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-proof-st-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var recipe = ExportRecipe()
        recipe.name = "P3 TIFF 16-bit"
        recipe.format = .tiff
        recipe.colorSpace = .displayP3
        recipe.folder = .fixed(path: dir.path)
        recipe.subfolder = ""
        recipe.existing = .overwrite
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: .zero, counter: 1, date: Date())
        let outcome = try await Exporter.export(session: session, recipe: recipe, context: context,
                                                sessionID: try XCTUnwrap(session.serviceSessionIDForExport))
        let written = try XCTUnwrap(outcome.urls.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(written as CFURL, nil))
        let file = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rendered = await session.softProof(recipe: recipe)
        let proof = try XCTUnwrap(rendered)
        let (target, _, _, _) = Exporter.resolveTarget(recipe)

        XCTAssertTrue(session.params.grainActive && session.params.glareActive,
                      "the stochastic stages were off, so this measured the parity case by mistake")
        let d = try compare(proof.image, file, space: target, bits: 16)
        print(String(format: "  stochastic ON: differing %d of %d, max %d counts, mean %.4f",
                     d.differing, file.width * file.height, d.maxAbs, d.mean))
        // The claim is only that this configuration is *not* bit-identical —
        // the difference is the engine's documented nondeterminism, measured
        // rather than argued. A zero here would mean the stages are not
        // stochastic, not that the proof is better than it claims.
        XCTAssertGreaterThan(d.maxAbs, 0,
                             "with grain and glare on, two renders came back bit-identical")
    }

    // MARK: - plumbing

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw XCTSkip("timed out waiting for \(what)")
    }
}
