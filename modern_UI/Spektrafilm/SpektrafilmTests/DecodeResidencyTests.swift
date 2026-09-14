import CoreImage
import XCTest

@MainActor
final class DecodeResidencyTests: XCTestCase {
    private func image(_ name: String, size: CGSize,
                       lifetime: DecodeLifetime = DecodeLifetime()) -> DecodedImage {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        let ci = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(origin: .zero, size: size))
        return DecodedImage(linear: ci, display: ci, pixelSize: size, isRAW: true,
                            sourceURL: url, asShotTemperature: 5500, asShotTint: 0,
                            lifetime: lifetime)
    }

    /// **Seen red** by skipping `clear()` in `adopt`: the arena held two
    /// entries and 2.7 MB instead of one entry and 1.8 MB.
    func testResidencyKeepsOneDecodeAndAccountsOnlyThatDecode() {
        let arena = MemoryArena()
        let residency = DecodeResidency(arena: arena)
        let firstKey = DecodeKey(url: URL(fileURLWithPath: "/tmp/first"), settings: DecodeSettings())
        let secondKey = DecodeKey(url: URL(fileURLWithPath: "/tmp/second"), settings: DecodeSettings())
        var first: DecodedImage? = image("first", size: CGSize(width: 100, height: 100))
        weak let firstLifetime = first?.lifetime

        residency.adopt(first!, for: firstKey)
        first = nil
        XCTAssertNotNil(firstLifetime, "the resident decode was released too early")

        let second = image("second", size: CGSize(width: 200, height: 100))
        residency.adopt(second, for: secondKey)

        XCTAssertNil(firstLifetime, "adopting a new decode retained the old one")
        XCTAssertEqual(DecodeResidency.capacity, 1)
        XCTAssertEqual(residency.key, secondKey)
        XCTAssertEqual(residency.accountedBytes, 1_800_000)
        XCTAssertEqual(arena.breakdown().first { $0.kind == "decode" }?.count, 1)
        XCTAssertEqual(arena.totalBytes, 1_800_000)

        residency.clear()
        XCTAssertNil(residency.image)
        XCTAssertEqual(arena.totalBytes, 0)
    }

    func testLeaseReleaseDropsTheQueuedImageReference() {
        let arena = MemoryArena()
        let residency = DecodeResidency(arena: arena)
        let key = DecodeKey(url: URL(fileURLWithPath: "/tmp/lease"), settings: DecodeSettings())
        var decoded: DecodedImage? = image("lease", size: CGSize(width: 100, height: 100))
        weak let lifetime = decoded?.lifetime

        let lease = residency.adopt(decoded!, for: key)
        decoded = nil
        residency.clear()
        XCTAssertNotNil(lifetime, "the lease did not retain the queued image")

        lease.release()
        XCTAssertNil(lifetime, "release left the queued image retained")
    }

    func testLeaseBelongsToTheCurrentKeyAndIsOneShot() {
        let arena = MemoryArena()
        let residency = DecodeResidency(arena: arena)
        let key = DecodeKey(url: URL(fileURLWithPath: "/tmp/current"), settings: DecodeSettings())
        let other = DecodeKey(url: URL(fileURLWithPath: "/tmp/other"), settings: DecodeSettings())
        let decoded = image("current", size: CGSize(width: 10, height: 10))
        residency.adopt(decoded, for: key)

        XCTAssertNil(residency.lease(for: other))
        let lease = try! XCTUnwrap(residency.lease(for: key))
        XCTAssertNotNil(lease.take())
        XCTAssertNil(lease.take(), "a lease handed out the same image twice")
    }
}
