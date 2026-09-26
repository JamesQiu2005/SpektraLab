import XCTest

/// The v4 frontend's model: Print Effects on the wire, the Tone Mask's curve,
/// the section layout store and the Latitude readout.
@MainActor
final class FrontendV4Tests: XCTestCase {

    // MARK: Print Effects

    /// Off sends no glare, no pre-flash and no mask — and forgets none of them.
    func testPrintEffectsGatesThePrintStageAndForgetsNothing() {
        var p = FilmParams.default
        p.preflashExposure = 0.01
        p.contrastMask.active = true
        p.contrastMask.highlights = 1
        p.printEffects = false
        let wire = Dictionary(uniqueKeysWithValues: p.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(wire["glare_active"], .bool(false))
        XCTAssertEqual(wire["preflash_exposure"], .double(0))
        XCTAssertEqual(wire["contrast_mask_active"], .bool(false))
        XCTAssertEqual(wire["contrast_mask_highlights"], .double(1), "the amount stays on the wire; the switch gates it")
        // The colour transformation is untouched.
        XCTAssertEqual(wire["print_stock"], .string(p.printStock))
        XCTAssertEqual(wire["halation_active"], .bool(true), "halation is the film's, not the print's")

        p.printEffects = true
        let back = Dictionary(uniqueKeysWithValues: p.wire.map { ($0.name, $0.value) })
        XCTAssertEqual(back["glare_active"], .bool(true))
        XCTAssertEqual(back["preflash_exposure"], .double(0.01))
        XCTAssertEqual(back["contrast_mask_active"], .bool(true))
    }

    /// A sidecar from before the switch reads as on, and the default wire is
    /// what it was: the gate is a no-op until someone turns it off.
    func testPrintEffectsDefaultsOnForLegacyFrames() throws {
        var legacy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(FilmParams.default)) as! [String: Any]
        legacy.removeValue(forKey: "printEffects")
        let decoded = try JSONDecoder().decode(FilmParams.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.printEffects)
        XCTAssertEqual(decoded, .default)
    }

    // MARK: the Tone Mask's curve

    /// The engine's calibration (`contrast_mask.cpp`): an amount of N stops
    /// moves a base `reach` stops past the core by exactly N, on both sides.
    /// If the engine's constants change and this port does not, this fails.
    func testToneMaskCurveMatchesTheEngineCalibration() {
        var m = ContrastMaskSettings()
        m.core = 1
        for amount in [0.25, 1.0, 2.0, 3.0] {
            m.highlights = amount; m.shadows = amount
            let lift = ToneMaskCurve.delta(atBase: -m.core - ToneMaskCurve.reach, m)
            let hold = ToneMaskCurve.delta(atBase: m.core + ToneMaskCurve.reach, m)
            XCTAssertEqual(lift, amount, accuracy: 1e-9, "highlights \(amount)")
            XCTAssertEqual(hold, -amount, accuracy: 1e-9, "shadows \(amount)")
        }
        // The core is untouched, and a side at 0 is off.
        m.highlights = 2; m.shadows = 0
        XCTAssertEqual(ToneMaskCurve.delta(atBase: 0.5, m), 0)
        XCTAssertEqual(ToneMaskCurve.delta(atBase: 5, m), 0)
        XCTAssertGreaterThan(ToneMaskCurve.delta(atBase: -5, m), 0)
    }

    // MARK: the section layout store

    private func freshDefaults() -> UserDefaults {
        let name = "FrontendV4Tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A height persists, is clamped to a header and one row at least, and
    /// nil returns the section to its own height.
    func testSectionHeightsPersistAndClamp() {
        let d = freshDefaults()
        let store = SectionLayoutStore(defaults: d)
        store.set(10, for: "film")
        XCTAssertEqual(store.height("film"), Theme.Metric.headerHeight + SectionLayoutStore.minContent)
        store.set(400, for: "film")
        XCTAssertEqual(SectionLayoutStore(defaults: d).height("film"), 400, "a new store reads it back")
        store.set(nil, for: "film")
        XCTAssertNil(SectionLayoutStore(defaults: d).height("film"))
    }

    /// Reset All Layout clears heights, open states and panel widths, and
    /// leaves every other preference alone.
    func testResetAllLayoutClearsLayoutAndNothingElse() {
        let d = freshDefaults()
        d.set(333.0, forKey: SectionLayoutStore.keyPrefix + "latitude")
        d.set(false, forKey: Session.uiKey + "section.film")
        d.set(300.0, forKey: PanelWidthStore.keyPrefix + "editor.left")
        d.set(true, forKey: Session.decoupleEffectsKey)
        let widths = PanelWidthStore(name: "editor.left", range: Theme.Metric.leftPanelRange, defaults: d)
        XCTAssertEqual(widths.width, 300)

        SectionLayoutStore.resetAllLayout(defaults: d)

        XCTAssertNil(d.object(forKey: SectionLayoutStore.keyPrefix + "latitude"))
        XCTAssertNil(d.object(forKey: Session.uiKey + "section.film"))
        XCTAssertNil(d.object(forKey: PanelWidthStore.keyPrefix + "editor.left"))
        XCTAssertEqual(widths.width, Theme.Metric.leftPanelRange.standard, "the live width follows the reset")
        XCTAssertEqual(d.object(forKey: Session.decoupleEffectsKey) as? Bool, true, "not a layout preference")
    }

    // MARK: the Latitude readout

    private func reply(placed: [Double]?) throws -> SceneLatitudeResponse {
        var fractions = [Double](repeating: 0, count: 128)
        fractions[64] = 0.5      // 0 … +0.25 stops: inside
        fractions[80] = 0.3      // +4 … +4.25: above the highlight boundary
        fractions[40] = 0.2      // −6 … −5.75: below the shadow boundary
        let ramp = stride(from: -12.0, through: 12.0, by: 0.25).map { $0 }
        let y = ramp.map { 0.7 / (1 + exp(-1.2 * $0)) }
        let side: [String: Any] = ["on": false, "pull_back": 0, "minimum_pull_back": 1,
                                   "scene_extreme_ev": 4, "medium_boundary_ev": 2.25,
                                   "landing_ev": 4, "slope_at_extreme": 0.1]
        var hist: [String: Any] = ["lo_ev": -16, "hi_ev": 16, "fractions": fractions]
        if let placed { hist["placed_fractions"] = placed }
        let json: [String: Any] = [
            "medium": ["shadow_ev": -4.1, "highlight_ev": 2.25, "latitude_stops": 6.35,
                       "y_black": y.first!, "y_white": 0.7, "ramp_ev": ramp, "ramp_y": y],
            "scene": ["norm": "power", "samples": 1000, "p0_1": -6, "p1": -6, "p50": 0, "p99": 4, "p99_9": 4,
                      "histogram": hist],
            "suggested": ["highlight_pull_back": 2, "shadow_pull_back": 2, "margin_used": 0.25, "valid": true],
            "fit": ["valid": true, "issues": [], "warnings": [], "highlight": side, "shadow": side],
        ]
        return try JSONDecoder().decode(SceneLatitudeResponse.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    /// The shares are counted on the placed histogram when there is one — the
    /// graph shows where Scene Placement lands the frame, not where it started.
    func testLatitudeReadoutCountsThePlacedFrame() throws {
        let r = LatitudeReadout(try reply(placed: nil))
        XCTAssertEqual(r.below, 0.2, accuracy: 1e-12)
        XCTAssertEqual(r.within, 0.5, accuracy: 1e-12)
        XCTAssertEqual(r.above, 0.3, accuracy: 1e-12)

        var placed = [Double](repeating: 0, count: 128)
        placed[64] = 0.5; placed[70] = 0.3; placed[40] = 0.2   // the top pulled to +1.5
        let p = LatitudeReadout(try reply(placed: placed))
        XCTAssertEqual(p.above, 0, accuracy: 1e-12)
        XCTAssertEqual(p.within, 0.8, accuracy: 1e-12)

        // The band is lightness per stop, over its peak. L* is a cube root of
        // Y, so on this logistic ramp its steepest point sits below mid-grey,
        // not at it: the peak (1) is inside the full-separation span, which
        // holds mid-grey, and far out the band is dark.
        let core = try XCTUnwrap(p.core)
        XCTAssertTrue(core.contains(0))
        let grid = stride(from: -8.0, through: 8.0, by: 0.05).map { ($0, LatitudePlot.strength(at: $0, p.separation)) }
        let peak = try XCTUnwrap(grid.max { $0.1 < $1.1 })
        XCTAssertEqual(peak.1, 1, accuracy: 0.02)
        XCTAssertTrue(core.contains(peak.0))
        XCTAssertGreaterThan(LatitudePlot.strength(at: 0, p.separation), 0.5)
        XCTAssertLessThan(LatitudePlot.strength(at: -8, p.separation), 0.1)
    }
}
