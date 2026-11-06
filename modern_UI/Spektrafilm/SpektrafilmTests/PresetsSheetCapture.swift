//  PresetsSheetCapture.swift — pictures of the Presets sheet, for review.
//
//  Not a check: it runs only when `SPK_CAPTURE_DIR` is set (pass it to
//  xcodebuild as `TEST_RUNNER_SPK_CAPTURE_DIR=<dir>`) and writes the sheet in
//  English and in Chinese at the 130 % interface scale. Rendered through
//  `cacheDisplay` — the sheet has no Metal layer, so that is the sheet as
//  drawn. The language and scale are set and restored around the capture.

import AppKit
import SwiftUI
import XCTest

@MainActor
final class PresetsSheetCapture: XCTestCase {

    func testCaptureThePresetsSheet() async throws {
        guard let out = ProcessInfo.processInfo.environment["SPK_CAPTURE_DIR"] else {
            throw XCTSkip("Set SPK_CAPTURE_DIR to write the Presets sheet captures")
        }
        let dir = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let work = FileManager.default.temporaryDirectory.appending(path: "spk-presets-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        Sidecar.useStore(at: work.appending(path: "sidecars"))
        defer { Sidecar.useStore(at: nil); try? FileManager.default.removeItem(at: work) }

        let suite = "spk-presets-capture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = Session(clipboardDefaults: defaults)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let frame = work.appending(path: "DSC03710.png")
        try Exporter.write(try XCTUnwrap(ctx.makeImage()), to: frame, format: .png)
        session.open(urls: [frame]); session.select(frame)
        let end = Date().addingTimeInterval(20)
        while session.decoded == nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }

        let store = SettingsPresetStore(url: work.appending(path: "settings-presets.json"))
        var warm = Sidecar(); warm.params.filmStock = "kodak_gold_200"
        store.add(SettingsPreset(name: "Gold 200 street", groups: [.filmAndPaper, .exposure, .whiteBalance], from: warm))
        store.add(SettingsPreset(name: "测试 1", groups: [.filmEffects], from: Sidecar()))

        let previousLanguage = Localization.shared.language
        let previousScale = InterfaceScaleStore.shared.scale
        defer {
            Localization.shared.language = previousLanguage
            InterfaceScaleStore.shared.scale = previousScale
        }
        InterfaceScaleStore.shared.scale = .large
        for (language, name) in [(LanguageSetting.english, "presets-sheet-en"),
                                 (LanguageSetting.simplifiedChinese, "presets-sheet-zh")] {
            Localization.shared.language = language
            let host = NSHostingView(rootView: PresetsSheet(session: session, store: store) {}
                .environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: dir.appending(path: "\(name).png"))
        }
        session.flushSave(); await session.client.stop()
    }
}
