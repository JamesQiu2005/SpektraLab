//  EnlargerFilterTests.swift — the Enlarger's two filters move the print.
//
//  They did not, for anyone to see: the wire's shifts are -1…1 and the engine
//  adds them to a filter pack of about 55 / 65 CC, so the whole slider was one
//  CC — a twentieth of a stop. Wired, tested for "not equal", and invisible.
//  These measure the *end* of each slider against the neutral print.

import Metal
import XCTest

@MainActor
final class EnlargerFilterTests: XCTestCase {
    func testTheEndsOfBothFiltersAreACastAPersonCanSee() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/_smoke_1mp.tif")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "the fixture is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "frame.tif")
        try FileManager.default.copyItem(at: source, to: url)
        addTeardownBlock { Sidecar.remove(for: url) }
        let suite = "spk-filter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let session = Session(clipboardDefaults: defaults)
        session.open(urls: [url])
        let frame = try XCTUnwrap(session.selection)
        session.requestPrint()

        func landed() async throws {
            let before = session.rendersLanded
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if session.rendersLanded > before, session.frameStates[frame] == .processed, !session.busy { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("no print landed")
        }
        func rgb() throws -> (r: Double, g: Double, b: Double) {
            let t = try XCTUnwrap(session.renderer.live)
            let bytes = t.rgba16Bytes()
            try XCTSkipIf(bytes.isEmpty, "the print is not a 16-bit texture")
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            bytes.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt16.self)
                for i in stride(from: 0, to: t.width * t.height, by: 31) {
                    r += Double(p[4 * i]); g += Double(p[4 * i + 1]); b += Double(p[4 * i + 2]); n += 1
                }
            }
            return (r / n, g / n, b / n)
        }
        func print(yellow: Double, magenta: Double) async throws -> (r: Double, g: Double, b: Double) {
            session.setEnlarger(.yellow, yellow)
            session.setEnlarger(.magenta, magenta)
            try await landed()
            return try rgb()
        }

        try await landed()
        let neutral = try rgb()
        // In stops of the print's own (display-encoded) values: a tenth is a
        // cast anyone sees side by side, and the old ends were under 0.01.
        func blueOverRed(_ c: (r: Double, g: Double, b: Double)) -> Double { log2((c.b / c.r) / (neutral.b / neutral.r)) }
        func greenOverMagenta(_ c: (r: Double, g: Double, b: Double)) -> Double {
            log2((c.g / ((c.r + c.b) / 2)) / (neutral.g / ((neutral.r + neutral.b) / 2)))
        }
        let yellowEnd = try await print(yellow: 1, magenta: 0)
        let blueEnd = try await print(yellow: -1, magenta: 0)
        XCTAssertGreaterThan(blueOverRed(yellowEnd), 0.2, "Yellow at its end: the print goes blue")
        XCTAssertLessThan(blueOverRed(blueEnd), -0.2, "and at the other end, yellow")
        let magentaEnd = try await print(yellow: 0, magenta: 1)
        let greenEnd = try await print(yellow: 0, magenta: -1)
        XCTAssertGreaterThan(greenOverMagenta(magentaEnd), 0.12, "Magenta at its end: the print goes green")
        XCTAssertLessThan(greenOverMagenta(greenEnd), -0.12, "and at the other end, magenta")
        // Half way is about half of it: the slider is a control, not a switch.
        let half = try await print(yellow: 0.5, magenta: 0)
        XCTAssertEqual(blueOverRed(half) / blueOverRed(yellowEnd), 0.5, accuracy: 0.15)
    }
}
