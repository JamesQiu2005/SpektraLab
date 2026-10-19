//  RetainedEditsTests.swift — a frame's settings are its sidecar, and every
//  cache in front of them is only a faster way to show them.
//
//  A 1.3.3 user opened many frames, went back to earlier ones, and found the
//  adjustments gone. The sidecars were intact. What had gone was every
//  *picture* of them, and every place that showed one fell back to the
//  undeveloped frame instead of making the picture again:
//
//  * the canvas: a developed frame whose print had left the caches (eight
//    frames in RAM, a write-back queue that drops, a disk cache that evicts)
//    opened onto its bare decode and stayed there;
//  * the filmstrip: a developed thumbnail lived only in a RAM cache that every
//    `open(urls:)` cleared and that evicts it first, so the strip showed the
//    camera's own preview;
//  * undo: one history for the whole session, so ⌘Z on one frame applied
//    another frame's earlier settings to it and saved them.

import ImageIO
import XCTest

@MainActor
final class RetainedEditsTests: XCTestCase {

    // MARK: fixtures

    /// Empty files with an openable extension: enough for anything that is
    /// only URLs and sidecars.
    private func emptyFrames(_ count: Int = 3) throws -> (Session, [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-retained-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<count {
            try Data().write(to: dir.appending(path: String(format: "frame-%02d.png", i)))
        }
        let suite = "spk-retained-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let session = Session(clipboardDefaults: defaults)
        session.open(urls: [dir])
        XCTAssertEqual(session.frames.count, count)
        let urls = session.frames.map(\.id)
        addTeardownBlock { urls.forEach { Sidecar.remove(for: $0) } }
        return (session, urls)
    }

    /// Two copies of the 1 MP smoke frame in a temporary folder — never the
    /// checkout's own file, because a develop writes a sidecar.
    private func smokeFrames() throws -> (URL, URL) {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "the 1 MP smoke frame is not in this checkout")
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-retained-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = dir.appending(path: "first.tif")
        let second = dir.appending(path: "second.tif")
        try FileManager.default.copyItem(at: source, to: first)
        try FileManager.default.copyItem(at: source, to: second)
        addTeardownBlock {
            Sidecar.remove(for: first); Sidecar.remove(for: second)
            try? FileManager.default.removeItem(at: dir)
        }
        return (first, second)
    }

    private func diagnostics(version: String? = nil) throws -> Diagnostics {
        let name = "spk-retained-diag-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        let d = Diagnostics(defaults: defaults)
        if let version { d.noteCapabilities(json: nil, version: version) }
        return d
    }

    private func store() throws -> DiskCacheStore {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "spk-retained-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try DiskCacheStore(root: root)
    }

    private func waitUntil(_ what: String, timeout: Double = 90,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    /// Open `url` alone, wait for the engine, and develop it with an edit the
    /// print can be told apart by.
    private func developed(_ url: URL, diagnostics d: Diagnostics,
                           store: DiskCacheStore?) async throws -> Session {
        let s = Session(diagnostics: d, diskCache: store)
        s.open(urls: [url])
        try await waitUntil("the frame to decode") { s.decoded != nil }
        try await waitUntil("the engine to warm up") { s.serviceReady }
        var p = s.params
        p.printBrightnessStops = 0.75
        s.params = p
        try await waitUntil("the print to land") {
            s.frameStates[url] == .processed && !s.busy && s.renderer.store.print(for: url) != nil
                && s.scheduler.sent == p
        }
        s.flushSave()
        return s
    }

    /// Mean absolute difference per channel, 0…255, of two pictures drawn
    /// pixel for pixel at the first one's size.
    ///
    /// Not at a small size: a JPEG-backed picture drawn small is decoded by
    /// ImageIO at a reduced scale, which measures the decoder rather than
    /// the picture (9.3 against 2.9 at full size, on the same two images).
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = a.width, h = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return bytes
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0.0, n = 0.0
        for i in stride(from: 0, to: pa.count, by: 4) {
            for c in 0..<3 { sum += abs(Double(pa[i + c]) - Double(pb[i + c])); n += 1 }
        }
        return sum / n
    }

    // MARK: undo

    /// ⌘Z undoes *this* frame's last change, never another frame's.
    ///
    /// The history was one array for the session. Edit frame A, move to frame
    /// B, press ⌘Z, and B was given A's earlier settings — and saved with
    /// them, so B's own edits were gone from its sidecar.
    func testUndoStaysWithTheFrameItWasTakenOn() throws {
        let (s, urls) = try emptyFrames()
        var own = Sidecar()
        own.params.printBrightnessStops = 1.5
        try own.save(for: urls[1])

        s.click(urls[0])
        var p = s.params
        p.printBrightnessStops = -1
        s.params = p
        XCTAssertTrue(s.canUndo)

        s.click(urls[1])
        XCTAssertEqual(s.params.printBrightnessStops, 1.5, "frame B did not open with its own settings")
        XCTAssertFalse(s.canUndo, "frame B offers to undo a change made to frame A")
        s.undo()
        s.flushSave()
        XCTAssertEqual(s.params.printBrightnessStops, 1.5, "⌘Z on frame B applied frame A's history to it")
        XCTAssertEqual(Sidecar.load(for: urls[1])?.params.printBrightnessStops, 1.5,
                       "frame B's sidecar was overwritten by another frame's undo")

        // And A's history is still A's when the person comes back to it.
        s.click(urls[0])
        XCTAssertTrue(s.canUndo, "coming back to frame A lost its history")
        s.undo()
        XCTAssertEqual(s.params.printBrightnessStops, FilmParams.default.printBrightnessStops)
    }

    // MARK: the canvas

    /// A developed frame whose print is in no cache develops again from its
    /// sidecar — it does not stop at the undeveloped decode.
    ///
    /// The store here holds the frame's decode and not its print, which is
    /// what a write-back that dropped the print, or an eviction, leaves: the
    /// display-cache shortcut answered, the open ended there, and the frame
    /// stayed undeveloped until the person touched a control.
    ///
    /// And for the second that takes, the canvas holds the frame's developed
    /// picture rather than putting the bare decode up — that intermediate is
    /// the very picture the report described.
    func testADevelopedFrameWhosePrintIsGoneIsDevelopedAgain() async throws {
        let (url, _) = try smokeFrames()
        let disk = try store()
        let firstDiagnostics = try diagnostics()
        let first = try await developed(url, diagnostics: firstDiagnostics, store: disk)
        let saved = try XCTUnwrap(Sidecar.load(for: url))
        XCTAssertEqual(saved.state, .processed)
        try await waitUntil("the developed picture on disk", timeout: 10) {
            DevelopedThumbnails.image(for: url) != nil
        }
        _ = first

        let second = Session(diagnostics: try diagnostics(version: firstDiagnostics.engineVersion),
                             diskCache: disk)
        second.open(urls: [url])
        XCTAssertNotNil(second.renderer.live, "the frame opened onto nothing rather than its developed picture")
        var sawBareDecode = false
        try await waitUntil("the print to be made again from the sidecar", timeout: 60) {
            if let live = second.renderer.live, let original = second.renderer.original,
               (live as AnyObject) === (original as AnyObject) { sawBareDecode = true }
            return second.renderer.store.print(for: url) != nil
        }
        XCTAssertEqual(second.scheduler.sent, saved.params, "the print was not made from the frame's own settings")
        XCTAssertEqual(second.frameStates[url], .processed)
        XCTAssertFalse(sawBareDecode, "the bare decode stood on the canvas while the print was made again")
    }

    // MARK: the filmstrip

    /// A developed thumbnail survives the thumbnail cache being emptied —
    /// which every `open(urls:)` does, and which eviction does one frame at a
    /// time.
    func testADevelopedThumbnailOutlivesTheThumbnailCache() async throws {
        let (url, _) = try smokeFrames()
        let landed = expectation(forNotification: .thumbnailUpdated, object: url)
        let s = try await developed(url, diagnostics: try diagnostics(), store: nil)
        await fulfillment(of: [landed], timeout: 10)
        try await waitUntil("the developed picture on disk", timeout: 10) {
            DevelopedThumbnails.image(for: url) != nil
        }
        let shownDeveloped = await ThumbnailCache.shared.thumbnail(for: url)
        let developedThumb = try XCTUnwrap(shownDeveloped)
        ThumbnailCache.shared.clear()
        let shownAfterClear = await ThumbnailCache.shared.thumbnail(for: url)
        let afterClear = try XCTUnwrap(shownAfterClear)
        let camera = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ] as CFDictionary)
        })
        XCTAssertGreaterThan(meanDifference(developedThumb, camera), 12,
                             "the edit does not change the thumbnail enough to test this")
        // A 320 px JPEG of a grainy print: about 3 levels of noise, no drift.
        XCTAssertLessThan(meanDifference(afterClear, developedThumb), 5,
                          "after the cache was emptied the strip showed the camera's preview, not the developed frame")
        _ = s
    }

    /// The picture on disk answers only for the file it was made of, and
    /// only while the frame's sidecar says it was developed.
    func testADevelopedPictureIsShownOnlyForTheFrameItWasMadeOf() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-retained-pic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let frame = dir.appending(path: "frame.png")
        try Data(repeating: 7, count: 64).write(to: frame)
        addTeardownBlock { Sidecar.remove(for: frame); DevelopedThumbnails.remove(for: frame) }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        DevelopedThumbnails.store(try XCTUnwrap(ctx.makeImage()), for: frame)

        XCTAssertNil(DevelopedThumbnails.image(for: frame), "shown for a frame with no settings")
        var sidecar = Sidecar()
        try sidecar.save(for: frame)
        XCTAssertNil(DevelopedThumbnails.image(for: frame), "shown for a frame never developed")
        sidecar.state = .processed
        try sidecar.save(for: frame)
        XCTAssertNotNil(DevelopedThumbnails.image(for: frame), "not shown for the developed frame it was made of")

        try Data(repeating: 9, count: 128).write(to: frame)
        XCTAssertNil(DevelopedThumbnails.image(for: frame), "shown for a different file at the same path")

        DevelopedThumbnails.remove(for: frame)
        let left = try FileManager.default.contentsOfDirectory(atPath: DevelopedThumbnails.directory.path)
            .filter { $0.hasPrefix("frame.png-") }
        XCTAssertEqual(left, [], "remove left a picture of the frame")
    }

    // MARK: resets

    /// Film ⋯ → Reset All Settings to the RAW Decode leaves the frame as if
    /// it had never been opened — its decode on the canvas, not a develop at
    /// the defaults, and the camera's picture in the strip — and one ⌘Z puts
    /// every setting back and develops it.
    func testResetToDecodeLeavesTheFrameAsIfNeverOpened() async throws {
        let (url, _) = try smokeFrames()
        let s = try await developed(url, diagnostics: try diagnostics(), store: nil)
        try await waitUntil("the developed picture on disk", timeout: 10) {
            DevelopedThumbnails.image(for: url) != nil
        }
        XCTAssertTrue(s.canResetToDecode)

        s.resetToDecode()
        XCTAssertEqual(s.selection, url, "the reset left the frame")
        XCTAssertEqual(s.params.printBrightnessStops, FilmParams.default.printBrightnessStops)
        XCTAssertEqual(s.frameStates[url], .unprocessed)
        XCTAssertNil(s.renderer.store.print(for: url), "the old print is still the frame's")
        try await waitUntil("the decode on the canvas") {
            guard let live = s.renderer.live, let original = s.renderer.original else { return false }
            return (live as AnyObject) === (original as AnyObject) && !s.busy
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(s.renderer.store.print(for: url), "the reset frame was developed at the defaults")
        XCTAssertEqual(Sidecar.load(for: url)?.state ?? .unprocessed, .unprocessed)
        try await waitUntil("the developed picture to leave the disk", timeout: 5) {
            !FileManager.default.fileExists(atPath: DevelopedThumbnails.url(for: url).path)
        }
        let shown = await ThumbnailCache.shared.thumbnail(for: url)
        let camera = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ] as CFDictionary)
        })
        XCTAssertLessThan(meanDifference(try XCTUnwrap(shown), camera), 3,
                          "the strip still shows the reset frame developed")

        XCTAssertTrue(s.canUndo, "the reset cannot be undone")
        s.undo()
        XCTAssertEqual(s.params.printBrightnessStops, 0.75, "⌘Z did not bring the settings back")
        try await waitUntil("the print to land again") {
            s.renderer.store.print(for: url) != nil && s.frameStates[url] == .processed && !s.busy
        }
        s.flushSave()
        XCTAssertEqual(Sidecar.load(for: url)?.params.printBrightnessStops, 0.75)

        // The filmstrip's Reset to Defaults on the frame on the canvas is the
        // same reset. It used to reset the film and the adjustments, which
        // developed the frame again at the defaults.
        s.resetToDefaults(url)
        XCTAssertEqual(s.frameStates[url], .unprocessed, "the filmstrip reset left the frame developed")
        XCTAssertNil(s.renderer.store.print(for: url))
        XCTAssertEqual(Sidecar.load(for: url)?.state ?? .unprocessed, .unprocessed)
    }

    /// The filmstrip's Reset to Defaults on a frame off the canvas takes its
    /// developed picture with it. Left in the RAM cache, the strip went on
    /// showing the reset frame developed.
    func testResettingAFrameOffTheCanvasForgetsItsDevelopedPicture() async throws {
        let (url, other) = try smokeFrames()
        let s = Session(diagnostics: try diagnostics(), diskCache: nil)
        s.open(urls: [url, other])
        s.click(url)
        try await waitUntil("the frame to decode") { s.decoded != nil }
        try await waitUntil("the engine to warm up") { s.serviceReady && !s.busy }
        let landed = expectation(forNotification: .thumbnailUpdated, object: url)
        var p = s.params
        p.printBrightnessStops = 0.75
        s.params = p
        try await waitUntil("the print to land") {
            s.frameStates[url] == .processed && !s.busy && s.renderer.store.print(for: url) != nil
        }
        await fulfillment(of: [landed], timeout: 10)
        try await waitUntil("the developed picture on disk", timeout: 10) {
            DevelopedThumbnails.image(for: url) != nil
        }
        s.click(other)

        s.resetSettings(of: url)
        XCTAssertEqual(s.frameStates[url], .unprocessed)
        // At once, not a turn later: the strip asks the moment it is told.
        XCTAssertFalse(DevelopedThumbnails.isDeveloped(url), "the strip can still read the reset frame as developed")
        let shown = await ThumbnailCache.shared.thumbnail(for: url)
        let camera = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ] as CFDictionary)
        })
        XCTAssertLessThan(meanDifference(try XCTUnwrap(shown), camera), 3,
                          "the strip still shows the reset frame developed")
    }

    /// A frame with no settings opens onto its decode, even with a print of
    /// it at exactly the settings a fresh open has on disk.
    ///
    /// The disk print is keyed by the settings, and a frame reset to nothing
    /// has the settings a develop at the defaults had — on a camera's 3:2 RAW
    /// exactly, film format and film-edge seeds included. So the filmstrip's
    /// reset opened onto the old develop rather than the frame. Built from
    /// the key rather than from a develop, so it does not depend on the
    /// fixture's shape or on the engine.
    func testAFrameWithNoSettingsOpensOntoItsDecodeNotACachedPrint() async throws {
        let (url, _) = try smokeFrames()
        let disk = try store()
        // What a fresh open looks the print up under: the settings `select`
        // seeds, and the engine version boot publishes.
        let probeDiagnostics = try diagnostics()
        let probe = Session(diagnostics: probeDiagnostics, diskCache: nil)
        probe.open(urls: [url])
        let params = probe.params
        let previewLongEdge = probe.previewLongEdge
        try await waitUntil("the engine to warm up") { probe.serviceReady }
        let version = try XCTUnwrap(probeDiagnostics.engineVersion)
        Sidecar.remove(for: url)
        let key = Session.printCacheKey(url: url, params: params, tier: .live,
                                        previewLongEdge: previewLongEdge, engineVersion: version)
        let (w, h) = (16, 12)
        try await disk.store(key: key, data: Data(repeating: 0x7f, count: w * h * 8), width: w, height: h,
                             sourceWidth: 1224, sourceHeight: 816, format: "rgba16Unorm", costMs: 500)

        let fresh = Session(diagnostics: try diagnostics(version: version), diskCache: disk)
        fresh.open(urls: [url])
        try await waitUntil("the open to end") {
            fresh.renderer.store.print(for: url) != nil || (fresh.decoded != nil && !fresh.busy)
        }
        XCTAssertNil(fresh.renderer.store.print(for: url), "a frame with no settings opened onto a print")
        XCTAssertEqual(fresh.frameStates[url], .unprocessed)
        _ = probe
    }
}
