//  SettingsPresetsTests.swift — saved settings-clipboard presets (1.3.6).
//
//  A preset is a saved clip: applying it must be indistinguishable from
//  pasting the clip it was saved from, and its file must never cost the user
//  their presets. Every store here is in a temporary directory, and the
//  session's clipboard boxes come from a throwaway defaults suite (trap 24).

import XCTest

@MainActor
final class SettingsPresetsTests: XCTestCase {

    private func tempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appending(path: "settings-presets.json")
    }

    /// A frame whose settings differ from a new frame's in every group.
    private func source() -> Sidecar {
        var s = Sidecar()
        s.decode.whiteBalance = .custom
        s.decode.temperature = 3400
        s.decode.tint = 12
        s.decode.lensCorrection = true
        s.params.filmStock = "kodak_gold_200"
        s.params.printStock = "fujifilm_crystal_archive_typeii"
        s.params.exposureCompensationEV = 1.5
        s.params.autoExposure = false
        s.params.printBrightnessStops = 0.5
        s.params.yFilterShift = 0.2
        s.params.grainActive = false
        s.params.effects.grain = 1.4
        s.params.printEffects = false
        s.params.preflashExposure = 0.01
        s.params.sceneLatitude.highlightPullBack = 2
        s.params.sceneLatitude.active = true
        s.params.sceneLatitude.highlightKnee = 0.75
        s.adjustments.exposure = 1
        s.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        s.solvedEV = 1.23
        s.state = .processed
        s.source = Sidecar.Source(path: "/Users/someone/private/DSC0001.ARW", volumeID: 1, inode: 2, size: 3)
        return s
    }

    private func target() -> Sidecar {
        var t = Sidecar()
        t.solvedEV = 0.4
        t.decode.temperature = 5100
        t.decode.tint = -3
        return t
    }

    // MARK: - a preset is its clip

    /// Applying a preset writes exactly what pasting the clip would, for each
    /// group alone and for all of them, although the preset keeps only the
    /// fields its groups own.
    func testAPresetAppliesExactlyLikeItsClip() {
        let s = source(), t = target()
        var sets = ClipboardGroup.allCases.map { Set([$0]) }
        sets.append(Set(ClipboardGroup.allCases))
        sets.append([.filmAndPaper, .exposure, .whiteBalance])
        for groups in sets {
            let preset = SettingsPreset(name: "p", groups: groups, from: s)
            let clip = SettingsClip(groups: groups, settings: s, sourceName: "src")
            XCTAssertEqual(preset.clip.applied(to: t), clip.applied(to: t),
                           "groups \(groups.map(\.rawValue).sorted())")
        }
    }

    /// The preset file carries no photograph: not its path, crop, grade,
    /// report or state.
    func testAPresetKeepsOnlyTheOwnedFields() {
        let p = SettingsPreset(name: "p", groups: Set(ClipboardGroup.allCases), from: source())
        XCTAssertNil(p.settings.source)
        XCTAssertEqual(p.settings.geometry, Sidecar().geometry)
        XCTAssertEqual(p.settings.adjustments, Sidecar().adjustments)
        XCTAssertFalse(p.settings.decode.lensCorrection)
        XCTAssertNil(p.settings.solvedEV)
        XCTAssertEqual(p.settings.state, Sidecar().state)
        // and the source's fitted curve, which a paste never carries either
        XCTAssertNotEqual(p.settings.params.sceneLatitude.highlightKnee, 0.75)
    }

    // MARK: - the store

    func testTheStoreRoundTrips() throws {
        let url = try tempURL()
        let store = SettingsPresetStore(url: url)
        XCTAssertTrue(store.presets.isEmpty)
        let a = SettingsPreset(name: "Warm", groups: [.whiteBalance, .exposure], from: source())
        XCTAssertTrue(store.add(a))
        store.add(SettingsPreset(name: "Film", groups: [.filmAndPaper], from: source()))
        store.rename(a.id, to: "  Warm tungsten ")
        let again = SettingsPresetStore(url: url)
        XCTAssertEqual(again.presets.map(\.name), ["Warm tungsten", "Film"])
        XCTAssertEqual(again.presets[0].groups, [.whiteBalance, .exposure])
        XCTAssertEqual(again.presets[0].settings, store.presets[0].settings)
        again.remove(a.id)
        XCTAssertEqual(SettingsPresetStore(url: url).presets.map(\.name), ["Film"])
    }

    /// A blank rename is refused rather than leaving a row with no name.
    func testABlankRenameKeepsTheName() throws {
        let store = SettingsPresetStore(url: try tempURL())
        let a = SettingsPreset(name: "Keep", groups: [.exposure], from: source())
        store.add(a)
        store.rename(a.id, to: "   ")
        XCTAssertEqual(store.presets.first?.name, "Keep")
    }

    /// Update keeps the name and the place, and takes the new settings.
    func testUpdateKeepsTheNameAndPlace() throws {
        let store = SettingsPresetStore(url: try tempURL())
        let a = SettingsPreset(name: "A", groups: [.exposure], from: Sidecar())
        store.add(a)
        store.add(SettingsPreset(name: "B", groups: [.exposure], from: Sidecar()))
        store.replace(a.id, with: SettingsPreset(name: "ignored", groups: [.filmAndPaper, .exposure], from: source()))
        XCTAssertEqual(store.presets.map(\.name), ["A", "B"])
        XCTAssertEqual(store.presets[0].id, a.id)
        XCTAssertEqual(store.presets[0].groups, [.filmAndPaper, .exposure])
        XCTAssertEqual(store.presets[0].settings.params.filmStock, "kodak_gold_200")
    }

    /// A file that cannot be read is reported and left alone: saving is
    /// refused until it is fixed, so a typo cannot cost every preset.
    func testAnUnreadableFileIsReportedAndNeverOverwritten() throws {
        let url = try tempURL()
        let garbage = Data("[{\"name\": \"half-written\"".utf8)
        try garbage.write(to: url)
        let store = SettingsPresetStore(url: url)
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.add(SettingsPreset(name: "x", groups: [.exposure], from: source())))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    /// A group a later build adds is dropped, not fatal; a missing name is
    /// given one.
    func testDecodingIsLenient() throws {
        let url = try tempURL()
        let json = """
        [{"groups": ["exposure", "someFutureGroup"], "settings": {}}]
        """
        try Data(json.utf8).write(to: url)
        let store = SettingsPresetStore(url: url)
        XCTAssertNil(store.problem)
        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(store.presets[0].groups, [.exposure])
        XCTAssertFalse(store.presets[0].name.isEmpty)
    }

    func testNextNameSkipsTakenNames() throws {
        let store = SettingsPresetStore(url: try tempURL())
        let first = store.nextName()
        store.add(SettingsPreset(name: first, groups: [.exposure], from: Sidecar()))
        XCTAssertNotEqual(store.nextName(), first)
    }

    // MARK: - through a session

    private func session() -> Session {
        let suite = "spk-presets-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Session(clipboardDefaults: defaults)
    }

    private func openFrame(in session: Session) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-presets-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Sidecar.useStore(at: dir.appending(path: "sidecars"))
        addTeardownBlock { Sidecar.useStore(at: nil); try? FileManager.default.removeItem(at: dir) }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let url = dir.appending(path: "a.png")
        try Exporter.write(try XCTUnwrap(ctx.makeImage()), to: url, format: .png)
        session.open(urls: [url])
        session.select(url)
        let end = Date().addingTimeInterval(20)
        while session.decoded?.sourceURL != url {
            if Date() > end { XCTFail("the frame did not decode"); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return url
    }

    func testSaveIsOffWithNoFrameOrNoGroup() async throws {
        let s = session()
        XCTAssertFalse(s.canSavePreset, "no frame is open")
        XCTAssertNil(s.presetFromOpenFrame(name: "x"))
        _ = try await openFrame(in: s)
        s.clipboardGroups = []
        XCTAssertFalse(s.canSavePreset, "no group is ticked")
        XCTAssertNil(s.presetFromOpenFrame(name: "x"))
        s.clipboardGroups = [.exposure]
        XCTAssertTrue(s.canSavePreset)
        XCTAssertEqual(s.presetFromOpenFrame(name: "x")?.groups, [.exposure])
        s.flushSave(); await s.client.stop()
    }

    /// Applying goes through the paste: the open frame takes it live and
    /// undoably, and a batch export holding the frame blocks it (trap 34).
    func testApplyingIsAPasteAndABatchExportBlocksIt() async throws {
        let s = session()
        _ = try await openFrame(in: s)
        var look = Sidecar()
        look.params.exposureCompensationEV = 1.25
        look.params.printBrightnessStops = -0.5
        let preset = SettingsPreset(name: "Bright", groups: [.exposure], from: look)
        let before = s.sidecar

        s.batchExporting = true
        XCTAssertFalse(s.canApplyPreset)
        s.applyPreset(preset)
        XCTAssertEqual(s.sidecar.params.exposureCompensationEV, before.params.exposureCompensationEV)
        s.batchExporting = false

        s.applyPreset(preset)
        // The paste's own side effects (the film edge resolving its camera on
        // the next print) are the session's, so compare what the group owns.
        let want = preset.clip.applied(to: before)
        XCTAssertEqual(s.sidecar.params.printBrightnessStops, want.params.printBrightnessStops)
        XCTAssertEqual(s.sidecar.params.autoExposure, want.params.autoExposure)
        XCTAssertEqual(s.sidecar.params.exposureCompensationEV, 1.25)
        XCTAssertEqual(s.sidecar.params.filmStock, before.params.filmStock, "an unticked group is untouched")
        s.undo()
        XCTAssertEqual(s.sidecar.params.exposureCompensationEV, before.params.exposureCompensationEV)
        s.flushSave(); await s.client.stop()
    }
}
