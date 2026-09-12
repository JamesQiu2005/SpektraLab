//  FrontendPolicyTests.swift — the pure decisions added with the polish pass.
//
//  These are not coverage for its own sake. Each one pins a rule whose wrong
//  value is invisible in a screenshot: whether a frame gets a native render at
//  all, whether two files share a sidecar, and whether a resident render is
//  still the truth.

import Metal
import XCTest

@MainActor
final class FrontendPolicyTests: XCTestCase {

    /// When a frame gets a native render: whenever it is bigger than the
    /// preview resolution, and not otherwise. A 1600 px frame has nothing to
    /// gain from a 2560 px render of itself, and the engine never upscales.
    ///
    /// This is all that is left of the zoom ladder (2026-09-12). Zoom used to
    /// pick the resolution; now the *frame* does, the edit settling is what
    /// starts the render, and the zoom readout means native pixels either way.
    func testTheNativeRenderPolicy() {
        XCTAssertTrue(Session.wantsFullRender(frameLongEdge: 8256, previewEdge: 2560))
        XCTAssertFalse(Session.wantsFullRender(frameLongEdge: 1600, previewEdge: 2560))
        XCTAssertFalse(Session.wantsFullRender(frameLongEdge: 2560, previewEdge: 2560),
                       "a frame exactly at the preview resolution is already its own pixels")
        XCTAssertTrue(Session.wantsFullRender(frameLongEdge: 2561, previewEdge: 2560))
        // The setting *is* the threshold, which is what makes it worth having:
        // raising it past the frame turns the native render off.
        XCTAssertFalse(Session.wantsFullRender(frameLongEdge: 3000, previewEdge: 3400))
        XCTAssertTrue(Session.wantsFullRender(frameLongEdge: 3000, previewEdge: 2560))
    }

    /// The setting: what a fresh install gets, and the range it is clamped to
    /// at both ends. The clamp matters because the value crosses the wire,
    /// where the engine's own range check would reject it as a user error.
    func testThePreviewResolutionDefaultsAndClamps() {
        XCTAssertEqual(Session.defaultPreviewEdge, 2560)
        XCTAssertEqual(Session.previewEdgeRange, 800...8192)
        let session = Session()
        let original = session.previewLongEdge
        addTeardownBlock { UserDefaults.standard.set(original, forKey: Session.previewEdgeKey) }
        XCTAssertEqual(session.previewLongEdge, Session.defaultPreviewEdge,
                       "a fresh install does not start at the default")
        session.setPreviewLongEdge(100)
        XCTAssertEqual(session.previewLongEdge, 800, "the floor did not clamp")
        session.setPreviewLongEdge(99_999)
        XCTAssertEqual(session.previewLongEdge, 8192, "the ceiling did not clamp")
    }

    /// The label, and everything that reads it, is measured against the
    /// **native** frame however small the texture on screen is.
    ///
    /// DSC03710 decodes to 6000 × 4000 and the canvas holds a 2560 px preview
    /// of it. Measuring the zoom against that texture made Fit read 109 % on a
    /// large window, where the honest answer is ~29 %, and made "100 %" mean a
    /// third of the frame's pixels per device pixel.
    func testTheZoomLabelIsMeasuredAgainstTheNativeFrame() async throws {
        let url = try rawFrame("A7m3/DSC03710.ARW")
        let session = Session()
        session.open(urls: [url])
        // The decode is all this needs: the native size comes from it, and no
        // develop is required to know how big the frame is.
        try await waitUntil("the frame to decode", timeout: 120) { session.decoded != nil }
        let native = try XCTUnwrap(session.decoded?.pixelSize)
        XCTAssertEqual(native.width, 6000, accuracy: 1, "not the frame this test is about")
        XCTAssertEqual(native.height, 4000, accuracy: 1)
        // The texture on the canvas is a tier; the size the viewport is
        // expressed against is the frame — which is the whole of D4.
        let texture = try XCTUnwrap(session.renderer.live)
        XCTAssertLessThan(CGFloat(texture.width), native.width, "the canvas is holding the frame itself")
        XCTAssertEqual(session.renderer.sourceSize?.width ?? 0, native.width,
                       "the viewport is expressed against the texture, not the frame")

        // A canvas of 1200 × 800 points at 2 device pixels per point.
        var vp = session.renderer.viewport
        vp.viewport = CGSize(width: 1200, height: 800)
        vp.backingScale = 2
        session.renderer.viewport = vp

        session.zoomToFit()
        // Fitted: 1200 points of 6000 native px, at 2 device px per point, is
        // 0.4 — device px over native px, which is what the label means.
        let fitted = 1200 * 2 / native.width
        XCTAssertEqual(Double(session.zoomPercent), Double(fitted * 100), accuracy: 1,
                       "Fit is measured against the texture, not the frame")

        session.zoomTo(fraction: 1.0)
        XCTAssertEqual(session.zoomPercent, 100)
        let onScreen = session.renderer.viewport.image.width * session.renderer.viewport.scale * 2
        XCTAssertEqual(Double(onScreen), Double(native.width), accuracy: 1,
                       "100 % is not one native pixel per device pixel")
    }

    /// The native-render slot is a cache keyed on **data**: the frame it
    /// belongs to and the parameters it was made from. Nothing else may be
    /// served — another frame's render, or one made from a grade the user has
    /// since changed, is a different picture. The undo case is the reason the
    /// key is the parameters rather than "whatever arrived last": a slider
    /// dragged back to where it started makes the resident render correct
    /// again, and `applyRender` shows it rather than re-rendering.
    func testTheNativeRenderSlotAnswersOnlyMatchingParameters() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let store = TextureStore(device: device)
        let a = URL(fileURLWithPath: "/tmp/a.NEF"), b = URL(fileURLWithPath: "/tmp/b.NEF")
        let tex = try XCTUnwrap(store.makeWritable(width: 8, height: 8))
        store.setFullRender(tex, stamp: "s1", for: a)

        XCTAssertTrue(store.fullRender(for: a, stamp: "s1") === tex)
        XCTAssertNil(store.fullRender(for: b, stamp: "s1"), "another frame's render was served")
        XCTAssertNil(store.fullRender(for: a, stamp: "s2"),
                     "a render the grade moved on from was served")

        store.dropFullRender()
        XCTAssertNil(store.fullRender(for: a, stamp: "s1"), "the dropped render came back")
    }

    /// The stamp is what makes validity a question about data. Two different
    /// parameter sets must not collide, and one set must be stable.
    func testPrintStampDistinguishesParameters() {
        var p = FilmParams.default
        let base = Session.printStamp(p)
        XCTAssertEqual(base, Session.printStamp(FilmParams.default))
        p.printBrightnessStops += 0.5
        XCTAssertNotEqual(base, Session.printStamp(p))
    }

    /// HANDOFF §3.2: `a.NEF` and `a.tif` in one folder must not share
    /// `a.spektra.json`.
    func testSidecarNamesKeepTheExtension() {
        let dir = URL(fileURLWithPath: "/tmp/photos")
        let nef = Sidecar.url(for: dir.appending(path: "a.NEF"))
        let tif = Sidecar.url(for: dir.appending(path: "a.tif"))
        XCTAssertEqual(nef.lastPathComponent, "a.NEF.spektra.json")
        XCTAssertNotEqual(nef, tif)
        XCTAssertEqual(Sidecar.legacyURL(for: dir.appending(path: "a.NEF")).lastPathComponent,
                       "a.spektra.json")
    }

    // MARK: - helpers

    /// A camera frame, copied out of the checkout: opening one writes a
    /// sidecar beside it, and the checkout's copy is shared with every other
    /// suite (see `develop-writes-a-sidecar-copy-the-fixture`).
    private func rawFrame(_ relativePath: String) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/\(relativePath)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "\(relativePath) is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func waitUntil(_ what: String, timeout: Double = 30,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
