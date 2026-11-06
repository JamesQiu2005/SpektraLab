//  CanvasPreviewSpaceTests.swift — 1.3.6's canvas preview space: the canvas
//  shown through an export's conversion, its ground re-encoded for the tag,
//  and the choice persisted through an injected defaults suite.

import XCTest
import CoreGraphics
import Metal

@MainActor
final class CanvasPreviewSpaceTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "canvas-preview-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testTheChoiceRoundTripsThroughAnInjectedSuite() {
        let d = suite()
        XCTAssertEqual(CanvasPreviewSpace.stored(in: d), .proPhoto, "the default is today's canvas")
        for space in CanvasPreviewSpace.allCases {
            CanvasPreviewSpace.store(space, in: d)
            XCTAssertEqual(CanvasPreviewSpace.stored(in: d), space)
        }
        d.set("nonsense", forKey: CanvasPreviewSpace.key)
        XCTAssertEqual(CanvasPreviewSpace.stored(in: d), .proPhoto)
    }

    /// AGENTS.md trap 27: the letterbox is painted by the GPU into a drawable
    /// tagged with the preview space, so its value must be the drawing's sRGB
    /// 0x5F **re-encoded for that tag**. Read through ColorSync back to sRGB,
    /// every space's value must land on 0x5F — the window margin's grey.
    func testTheGroundFollowsTheTag() throws {
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        for space in CanvasPreviewSpace.allCases {
            let g = CGFloat(space.groundValue)
            let c = try XCTUnwrap(CGColor(colorSpace: space.colorSpace, components: [g, g, g, 1]))
            let back = try XCTUnwrap(c.converted(to: sRGB, intent: .relativeColorimetric, options: nil))
            let comps = try XCTUnwrap(back.components)
            for k in 0..<3 {
                XCTAssertEqual(Double(comps[k]) * 255, 0x5F, accuracy: 0.5,
                               "\(space.title): the ground reads \(comps[k] * 255) in sRGB, not 0x5F")
            }
        }
    }

    // MARK: - the canvas is the export

    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout (AGENTS.md trap 26)")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func waitUntil(_ what: String, timeout: Double, _ c: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !c() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func maxDifference(_ a: MTLTexture, _ b: MTLTexture) -> (maxAbs: Int, differing: Int) {
        let da = a.rgba16Bytes(), db = b.rgba16Bytes()
        var maxAbs = 0, differing = 0
        da.withUnsafeBytes { ra in db.withUnsafeBytes { rb in
            let pa = ra.bindMemory(to: UInt16.self), pb = rb.bindMemory(to: UInt16.self)
            for i in stride(from: 0, to: min(pa.count, pb.count), by: 4) {
                var moved = false
                for c in 0..<3 {
                    let d = abs(Int(pa[i + c]) - Int(pb[i + c]))
                    maxAbs = max(maxAbs, d)
                    if d != 0 { moved = true }
                }
                if moved { differing += 1 }
            }
        } }
        return (maxAbs, differing)
    }

    /// With the canvas previewing Display P3 and the stochastic stages off,
    /// the texture the canvas draws is the P3 export's pixels — the same
    /// kernel, the same setup, the same full render. The control first: the
    /// unconverted canvas must *differ* from the export, or the comparison
    /// could not see anything.
    func testThePreviewCanvasIsTheExport() async throws {
        let url = try frame()
        let session = Session()
        session.open(urls: [url])
        try await waitUntil("the decode", timeout: 120) { session.decoded != nil }
        try await waitUntil("the engine", timeout: 120) { session.serviceReady }
        var p = session.params
        p.grainActive = false
        p.glareActive = false
        session.params = p
        session.solveNow()
        try await waitUntil("the print", timeout: 180) {
            session.serviceSessionIDForExport != nil && session.frameStates[url] == .processed && !session.busy
        }
        try await waitUntil("the full render on the canvas", timeout: 180) {
            session.canvasIsSettled && session.renderer.showsFullRender
        }

        var recipe = ExportRecipe()
        recipe.format = .tiff
        recipe.colorSpace = .displayP3
        let sid = try XCTUnwrap(session.serviceSessionIDForExport)
        let export = try await Exporter.filePixels(session: session, recipe: recipe, sessionID: sid)

        // Control: the working-space canvas is not the P3 file.
        let plain = try XCTUnwrap(session.renderer.canvasTexturesNow().shown)
        XCTAssertEqual(plain.width, export.pixels.w)
        XCTAssertEqual(plain.height, export.pixels.h)
        let control = maxDifference(plain, export.texture)
        XCTAssertGreaterThan(control.differing, 0, "the unconverted canvas already equals the P3 file — the comparison cannot see")

        let d = suite()
        session.setCanvasPreviewSpace(.displayP3, defaults: d)
        try await waitUntil("the preview setup", timeout: 30) { session.renderer.previewSetup != nil }
        XCTAssertEqual(CanvasPreviewSpace.stored(in: d), .displayP3)
        XCTAssertEqual(session.renderer.displaySpace?.name, CGColorSpace.displayP3)

        let previewed = try XCTUnwrap(session.renderer.canvasTexturesNow().shown)
        let diff = maxDifference(previewed, export.texture)
        print("canvas preview vs P3 export: \(diff.differing) pixels differ, max \(diff.maxAbs) counts "
              + "(control, unconverted: \(control.differing), max \(control.maxAbs))")
        XCTAssertEqual(diff.maxAbs, 0, "the P3 canvas preview is not the P3 export's pixels")

        // Back to ProPhoto: no conversion, the working space's tag and ground.
        session.setCanvasPreviewSpace(.proPhoto, defaults: d)
        XCTAssertNil(session.renderer.previewSetup)
        XCTAssertEqual(session.renderer.displaySpace?.name, ImageDecoder.workingSpace?.name)
        XCTAssertEqual(session.renderer.groundValue, CanvasGround.value)
        session.flushSave()
        await session.client.stop()
    }
}
