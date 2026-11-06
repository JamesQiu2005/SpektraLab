import XCTest
import CoreImage
import CryptoKit

final class RAWReuseTests: XCTestCase {
    /// `SPK_TEST_RAW` names any local RAW; otherwise the repository's A7 III
    /// fixture, reached through the `tests` link (AGENTS.md trap 26). Decoding
    /// writes no sidecar, so the fixture is read in place.
    private func sample() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["SPK_TEST_RAW"] {
            return URL(fileURLWithPath: path)
        }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("No camera fixture: link tests/ (AGENTS.md trap 26) or set SPK_TEST_RAW")
        }
        return fixture
    }
    private func digest(_ image: CIImage) -> String {
        let scale = 512 / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
        let bounds = scaled.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var data = Data(count: width * height * 16)
        data.withUnsafeMutableBytes { p in
            ImageDecoder.context.render(scaled, toBitmap: p.baseAddress!, rowBytes: width * 16,
                bounds: bounds, format: .RGBAf, colorSpace: ImageDecoder.linearProPhoto)
        }
        return SHA256.hash(data: data).description
    }
    func testReusePreservesBothLooksAndPreviouslyReturnedImages() throws {
        let url = try sample()
        let original = try ImageDecoder.decode(url, settings: DecodeSettings())
        let originalHashes = [digest(original.linear), digest(original.display)]
        let legacyLinear = try ImageDecoder.rawFilter(url, look: .linear, settings: DecodeSettings()).filter
        let legacyDisplay = try ImageDecoder.rawFilter(url, look: .display, settings: DecodeSettings()).filter
        XCTAssertEqual(originalHashes, [digest(try XCTUnwrap(legacyLinear.outputImage)),
                                        digest(try XCTUnwrap(legacyDisplay.outputImage))])
        var settings = DecodeSettings(); settings.whiteBalance = .custom
        settings.temperature = 6100; settings.tint = 18
        let changed = try ImageDecoder.decode(url, settings: settings, reusing: original.rawSource)
        XCTAssertNotNil(original.rawSource)
        XCTAssertTrue(changed.rawSource === original.rawSource, "A white-balance edit must reuse the expensive RAW source")
        let fresh = try ImageDecoder.decode(url, settings: settings)
        XCTAssertEqual(digest(changed.linear), digest(fresh.linear))
        XCTAssertEqual(digest(changed.display), digest(fresh.display))
        XCTAssertEqual([digest(original.linear), digest(original.display)], originalHashes,
                       "An old snapshot must not change when its RAW filter is reused")
        settings.lensCorrection = true
        let lens = try ImageDecoder.decode(url, settings: settings, reusing: changed.rawSource)
        let freshLens = try ImageDecoder.decode(url, settings: settings)
        XCTAssertEqual(digest(lens.linear), digest(freshLens.linear))
        XCTAssertEqual(digest(lens.display), digest(freshLens.display))
        let restored = try ImageDecoder.decode(url, settings: DecodeSettings(), reusing: changed.rawSource)
        XCTAssertEqual([digest(restored.linear), digest(restored.display)], originalHashes,
                       "As-shot must restore the camera's original chromaticity exactly")
        XCTAssertEqual(restored.asShotTemperature, original.asShotTemperature)
        XCTAssertEqual(restored.asShotTint, original.asShotTint)
    }
    func testReuseInvalidatesOnSourceModificationAndPathChange() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try sample()
        let a = dir.appending(path: "a." + source.pathExtension), b = dir.appending(path: "b." + source.pathExtension)
        try FileManager.default.copyItem(at: source, to: a)
        try FileManager.default.copyItem(at: source, to: b)
        let first = try ImageDecoder.decode(a, settings: DecodeSettings())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: a.path)
        let modified = try ImageDecoder.decode(a, settings: DecodeSettings(), reusing: first.rawSource)
        XCTAssertFalse(modified.rawSource === first.rawSource)
        let other = try ImageDecoder.decode(b, settings: DecodeSettings(), reusing: modified.rawSource)
        XCTAssertFalse(other.rawSource === modified.rawSource)
        XCTAssertEqual(other.sourceURL, b)
    }
    func testCancellationDoesNotPoisonTheNextWhiteBalance() throws {
        let url = try sample()
        let original = try ImageDecoder.decode(url, settings: DecodeSettings())
        var settings = DecodeSettings(); settings.whiteBalance = .custom
        settings.temperature = 4200; settings.tint = -14
        var calls = 0
        XCTAssertThrowsError(try ImageDecoder.decode(url, settings: settings, reusing: original.rawSource) {
            calls += 1; if calls == 3 { throw CancellationError() }
        })
        let recovered = try ImageDecoder.decode(url, settings: settings, reusing: original.rawSource)
        let fresh = try ImageDecoder.decode(url, settings: settings)
        XCTAssertEqual(digest(recovered.linear), digest(fresh.linear))
        XCTAssertEqual(digest(recovered.display), digest(fresh.display))
    }
}
