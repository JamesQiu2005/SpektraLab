//  SettingsClipboardTests.swift — RFC-027's paste semantics, with no window,
//  no engine and no file: `SettingsClip.applied(to:)` is Sidecar in, Sidecar
//  out, and everything a paste *means* is decided there.

import XCTest

final class SettingsClipboardTests: XCTestCase {

    // MARK: - the model, walked

    /// Every stored leaf of a value, by its model name, as text. A struct is
    /// walked into; anything else (an enum, an optional, an array) is a leaf.
    private func leaves(_ value: Any, _ prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            guard let name = child.label else { continue }
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            let m = Mirror(reflecting: child.value)
            if m.displayStyle == .struct, !(child.value is CGSize), !(child.value is CGPoint),
               !(child.value is UUID) {
                out.merge(leaves(child.value, path)) { a, _ in a }
            } else {
                out[path] = String(describing: child.value)
            }
        }
        return out
    }

    private func owned(_ path: String, by prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + ".")
    }

    private func owners(of path: String) -> [String] {
        ClipboardGroup.allCases.filter { g in g.paths.contains { owned(path, by: $0) } }.map(\.rawValue)
            + ClipboardGroup.notCopied.keys.filter { owned(path, by: $0) }.map { "notCopied:\($0)" }
    }

    /// **The parity check.** A field added to the sidecar is either copied by
    /// one group or listed as not copied, with a reason. Unowned, a paste
    /// would silently leave it behind; owned twice, two boxes would fight
    /// over it.
    func testEveryStoredFieldHasExactlyOneOwner() {
        var s = Sidecar()
        s.solvedEV = 0          // an optional is a leaf either way; set so it reads plainly
        for path in leaves(s).keys.sorted() {
            let o = owners(of: path)
            XCTAssertEqual(o.count, 1, "\(path) is owned by \(o.isEmpty ? "nothing" : o.joined(separator: ", "))")
        }
    }

    /// And the reverse: every declared path names a real field, so a rename
    /// cannot leave a group owning nothing.
    func testEveryDeclaredPathNamesAStoredField() {
        let paths = Set(leaves(Sidecar()).keys)
        for g in ClipboardGroup.allCases {
            for p in g.paths {
                XCTAssertTrue(paths.contains { owned($0, by: p) }, "\(g.rawValue) declares \(p), which is not a field")
            }
        }
        for p in ClipboardGroup.notCopied.keys {
            XCTAssertTrue(paths.contains { owned($0, by: p) }, "notCopied declares \(p), which is not a field")
        }
    }

    // MARK: - a source that differs everywhere

    /// A frame whose every setting differs from a new frame's.
    private func source() -> Sidecar {
        var s = Sidecar()
        s.decode.whiteBalance = .custom
        s.decode.temperature = 3400
        s.decode.tint = 12
        s.decode.lensCorrection = true
        var p = FilmParams()
        p.filmStock = "kodak_gold_200"
        p.printStock = "fujifilm_crystal_archive_typeii"
        p.scanFilm = true
        p.extendedDynamicRange = true
        p.exposureCompensationEV = 1.5
        p.autoExposureMethod = "protect_highlights"
        p.autoExposure = false
        p.filmFormatMM = 60
        p.filmFrame = "120"
        p.filmSide = FilmSide.long.rawValue
        p.sideLengthMM = 56
        p.grainActive = false
        p.halationActive = false
        p.glareActive = false
        p.printBrightnessStops = 0.5
        p.yFilterShift = 0.2
        p.mFilterShift = -0.1
        p.preflashExposure = 0.01
        p.printEffects = false
        p.contrastMask.active = true
        p.contrastMask.highlights = 1.5
        p.effects.grain = 1.4
        p.effects.halation = 2
        p.sceneLatitude.highlightPullBack = 2
        p.sceneLatitude.shadowPullBack = 1
        p.sceneLatitude.highlightPercentile = 99
        // The source's own fit: what must never be pasted.
        p.sceneLatitude.active = true
        p.sceneLatitude.highlightKnee = 0.75
        p.sceneLatitude.highlightRoom = 1.25
        p.sceneLatitude.shadowKnee = -1.5
        p.sceneLatitude.shadowRoom = 0.5
        s.params = p
        s.adjustments.exposure = 1
        s.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        s.masks = [EditMask.make(.linearGradient)]
        s.solvedEV = 1.23
        s.state = .processed
        return s
    }

    private func target() -> Sidecar {
        var t = Sidecar()
        t.solvedEV = 0.4
        t.decode.temperature = 5100     // this frame's own As Shot numbers
        t.decode.tint = -3
        return t
    }

    private func changed(_ a: Sidecar, _ b: Sidecar) -> Set<String> {
        let la = leaves(a), lb = leaves(b)
        return Set(la.keys.filter { la[$0] != lb[$0] })
    }

    // MARK: - each group writes its own fields and no others

    func testEachGroupAloneChangesOnlyItsOwnFields() {
        let t = target()
        for g in ClipboardGroup.allCases {
            let out = SettingsClip(groups: [g], settings: source(), sourceName: "src").applied(to: t)
            let diff = changed(out, t)
            XCTAssertFalse(diff.isEmpty, "\(g.rawValue) pasted nothing")
            // The one field outside a group a paste may touch: Exposure clears
            // the report of the old meter.
            let allowed = g == .exposure ? ["solvedEV"] : []
            for path in diff where !g.paths.contains(where: { owned(path, by: $0) }) && !allowed.contains(path) {
                XCTFail("pasting \(g.rawValue) changed \(path), which it does not own")
            }
        }
    }

    func testNoGroupsChangesNothing() {
        let t = target()
        XCTAssertEqual(SettingsClip(groups: [], settings: source(), sourceName: "src").applied(to: t), t)
    }

    func testAllGroupsLeaveTheFrameItsCropGradeLensAndState() {
        let t = target()
        let out = SettingsClip(groups: Set(ClipboardGroup.allCases), settings: source(), sourceName: "src").applied(to: t)
        XCTAssertEqual(out.geometry, t.geometry)
        XCTAssertEqual(out.adjustments, t.adjustments)
        XCTAssertEqual(out.decode.lensCorrection, t.decode.lensCorrection)
        XCTAssertEqual(out.state, t.state)
    }

    // MARK: - settings, not solved numbers

    func testAsShotWhiteBalancePastesTheWordNotTheSourcesKelvin() {
        var s = source()
        s.decode.whiteBalance = .asShot
        s.decode.temperature = 3400      // the *source* camera's
        let out = SettingsClip(groups: [.whiteBalance], settings: s, sourceName: "src").applied(to: target())
        XCTAssertEqual(out.decode.whiteBalance, .asShot)
        XCTAssertEqual(out.decode.temperature, 5100, "As Shot carried the source camera's Kelvin")
        XCTAssertEqual(out.decode.tint, -3)
        XCTAssertEqual(out.params.yFilterShift, 0.2)
    }

    func testACustomWhiteBalancePastesItsNumbers() {
        let out = SettingsClip(groups: [.whiteBalance], settings: source(), sourceName: "src").applied(to: target())
        XCTAssertEqual(out.decode.whiteBalance, .custom)
        XCTAssertEqual(out.decode.temperature, 3400)
        XCTAssertEqual(out.decode.tint, 12)
    }

    func testExposureClearsTheReportOnlyWhenTheMeterChanges() {
        let changedMeter = SettingsClip(groups: [.exposure], settings: source(), sourceName: "src").applied(to: target())
        XCTAssertNil(changedMeter.solvedEV, "the old meter's report survived a change of meter")
        XCTAssertEqual(changedMeter.params.exposureCompensationEV, 1.5)

        var sameMeter = source()
        sameMeter.params.autoExposure = true
        sameMeter.params.autoExposureMethod = FilmParams().autoExposureMethod
        let kept = SettingsClip(groups: [.exposure], settings: sameMeter, sourceName: "src").applied(to: target())
        XCTAssertEqual(kept.solvedEV, 0.4, "the report was dropped although the meter is the same")
    }

    /// The defect behind "high-contrast photos blow out": the source's fitted
    /// curve is its own histogram, and must not be pasted.
    func testScenePlacementPastesTheIntentAndNeverTheCurve() {
        let out = SettingsClip(groups: [.scenePlacement], settings: source(), sourceName: "src").applied(to: target())
        let l = out.params.sceneLatitude
        XCTAssertEqual(l.highlightPullBack, 2)
        XCTAssertEqual(l.shadowPullBack, 1)
        XCTAssertEqual(l.highlightPercentile, 99)
        let identity = SceneLatitudeSettings()
        XCTAssertFalse(l.active, "the source's curve was pasted as active")
        XCTAssertEqual(l.highlightKnee, identity.highlightKnee)
        XCTAssertEqual(l.highlightRoom, identity.highlightRoom)
        XCTAssertEqual(l.shadowKnee, identity.shadowKnee)
        XCTAssertEqual(l.shadowRoom, identity.shadowRoom)
        XCTAssertTrue(out.placementNeedsFit)
    }

    func testAPlacementWithNoPullBackNeedsNoFit() {
        var s = source()
        s.params.sceneLatitude = SceneLatitudeSettings()
        var t = target()
        t.params.sceneLatitude.active = true
        t.params.sceneLatitude.highlightPullBack = 3
        let out = SettingsClip(groups: [.scenePlacement], settings: s, sourceName: "src").applied(to: t)
        XCTAssertEqual(out.params.sceneLatitude, SceneLatitudeSettings())
        XCTAssertFalse(out.placementNeedsFit)
    }

    func testFilmAndPaperKeepsASlideFilmScanned() {
        var s = source()
        s.params.filmStock = "fujifilm_provia_100f"
        s.params.scanFilm = true
        let out = SettingsClip(groups: [.filmAndPaper], settings: s, sourceName: "src").applied(to: target())
        XCTAssertEqual(out.params.filmStock, "fujifilm_provia_100f")
        XCTAssertTrue(out.params.scanFilm)
    }

    // MARK: - the flag on disk

    func testPlacementNeedsFitRoundTripsAndDefaultsToFalse() throws {
        var s = Sidecar()
        s.placementNeedsFit = true
        let back = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.placementNeedsFit)

        let plain = try JSONEncoder().encode(Sidecar())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("placementNeedsFit"),
                       "a sidecar with nothing pending grew a field")
        XCTAssertFalse(try JSONDecoder().decode(Sidecar.self, from: plain).placementNeedsFit)
    }
}
