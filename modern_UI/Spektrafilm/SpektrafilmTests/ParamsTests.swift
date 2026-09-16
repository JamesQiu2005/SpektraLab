import XCTest

final class ParamsTests: XCTestCase {
    func testDeltaIsEmptyForEqualParams() {
        let (d, l) = FilmParams.default.delta(from: .default)
        XCTAssertTrue(d.isEmpty); XCTAssertTrue(l.isEmpty)
    }

    func testPrintSliderRoutesToPrintLayer() {
        var p = FilmParams.default
        p.printBrightnessStops = 1
        let (d, l) = p.delta(from: .default)
        XCTAssertEqual(l, [.print])
        XCTAssertEqual(d["print_exposure"]?.doubleValue ?? 0, 0.5, accuracy: 1e-9, "brighter by one stop = half the enlarger exposure")
    }

    func testShootFieldsRouteToShootLayer() {
        var p = FilmParams.default
        p.grainActive = false
        p.filmFormatMM = 56
        let (d, l) = p.delta(from: .default)
        XCTAssertEqual(l, [.shoot])
        XCTAssertEqual(Set(d.keys), ["grain_active", "grain_sublayers_active", "film_format_mm"])
    }

    func testFilmChangeInvalidatesBothLayers() {
        var p = FilmParams.default
        p.filmStock = "kodak_vision3_250d"
        XCTAssertEqual(p.delta(from: .default).layers, [.shoot, .print])
    }

    func testWireNamesMatchTheServiceSchema() {
        // The names the Python schema declares (service/schema.py). A rename
        // there must be mirrored here or the delta is rejected at runtime.
        let known: Set<String> = ["film_stock", "print_stock", "exposure_compensation_ev", "film_format_mm",
                                  "grain_active", "grain_sublayers_active", "halation_active", "print_exposure",
                                  "y_filter_shift", "m_filter_shift", "glare_active", "scan_film",
                                  // RFC-015 §3. Shoot layer; absent from a legacy
                                  // frame's delta, which is why this list holds
                                  // the name and `wire` only carries it when set.
                                  "auto_exposure_method",
                                  // The AE Method pill's `Custom` — the meter
                                  // switched off. Declared by the engine all
                                  // along (`camera.auto_exposure`) and never
                                  // sent until the 2026-09-17 rework, which is
                                  // why `Custom` needed no new field.
                                  "auto_exposure"]
        XCTAssertEqual(Set(FilmParams.default.wire.map(\.name)), known)
    }

    /// `Custom` is `auto_exposure = false` and nothing else, and the four
    /// intents are the flag **plus** the method — so turning the meter off and
    /// on again comes back to the intent it had.
    func testAEMethodIsTheFlagAndTheMethod() {
        var p = FilmParams.default
        XCTAssertEqual(AEMethod.of(p), .metered(.balanced))

        AEMethod.custom.apply(to: &p)
        XCTAssertFalse(p.autoExposure)
        XCTAssertEqual(p.autoExposureMethod, "balanced", "Custom must not forget the intent")
        XCTAssertEqual(AEMethod.of(p), .custom)
        XCTAssertEqual(p.delta(from: .default).delta["auto_exposure"], .bool(false))
        XCTAssertNil(p.delta(from: .default).delta["auto_exposure_method"],
                     "turning the meter off is not a change of intent")

        AEMethod.metered(.protectHighlights).apply(to: &p)
        XCTAssertTrue(p.autoExposure)
        XCTAssertEqual(p.autoExposureMethod, "protect_highlights")

        // A sidecar written before the method existed: the engine's own
        // `center_weighted`, which the menu does not offer.
        AEMethod.legacy.apply(to: &p)
        XCTAssertNil(p.autoExposureMethod)
        XCTAssertEqual(AEMethod.of(p), .legacy)
        XCTAssertFalse(AEMethod.offered.contains(.legacy))
    }

    /// The physical frame: the user says a type, a side and a length, and the
    /// engine gets a **long edge**.
    func testTheFrameDerivesTheEngineSLongEdge() {
        let m = Session.filmFormatMM
        // 135, short side 24, on a 3:2 photograph — the drawing's own row, and
        // it has to come out at the 36 the old single-number Format sent.
        XCTAssertEqual(m(.short, 24, 3.0 / 2.0), 36, accuracy: 1e-9)
        // Side = Long passes straight through, whatever the photograph is.
        XCTAssertEqual(m(.long, 36, 3.0 / 2.0), 36, accuracy: 1e-9)
        XCTAssertEqual(m(.long, 36, 1.0), 36, accuracy: 1e-9)
        // **The whole reason there are three controls.** One `120` entry, one
        // 56 mm short side, and 645 / 6×6 / 6×7 each come out right because
        // the photograph's own aspect is what closes the gap.
        XCTAssertEqual(m(.short, 56, 1.0), 56, accuracy: 1e-9)          // 6×6
        XCTAssertEqual(m(.short, 56, 7.0 / 6.0), 65.333, accuracy: 0.01) // 6×7
        XCTAssertEqual(m(.short, 56, 4.0 / 3.0), 74.666, accuracy: 0.01) // 6×8
        // An aspect below 1 is a portrait photograph, which is the same frame
        // turned round — not a shorter long edge.
        XCTAssertEqual(m(.short, 24, 0.5), 24, accuracy: 1e-9)
        // And the service's range is a range: 200 is the ceiling, 4 the floor.
        XCTAssertEqual(m(.short, 56, 20), 200, accuracy: 1e-9)
        XCTAssertEqual(m(.long, 1, 1), 4, accuracy: 1e-9)
    }

    /// Every preset lands inside the service's 4…200 on an ordinary
    /// photograph, on either side.
    func testEveryFilmFrameIsWithinTheServiceRange() {
        for f in FilmFrame.all {
            for side in FilmSide.allCases {
                let mm = Session.filmFormatMM(side: side, sideLengthMM: f.side(side),
                                              aspect: 3.0 / 2.0)
                XCTAssertTrue((4...200).contains(mm), "\(f.id) \(side.rawValue) → \(mm)")
            }
        }
        XCTAssertEqual(FilmFrame.named("135").short, 24)
        XCTAssertEqual(FilmFrame.named("nonsense").id, FilmFrame.custom.id,
                       "an unknown id is Custom, not a crash")
    }

    /// Display only, and it has to survive the round trip a typed value makes.
    func testSideUnitsConvert() {
        XCTAssertEqual(SideUnit.mm.fromMM(24), 24, accuracy: 1e-9)
        XCTAssertEqual(SideUnit.cm.fromMM(56), 5.6, accuracy: 1e-9)
        XCTAssertEqual(SideUnit.inch.fromMM(25.4), 1, accuracy: 1e-9)
        for u in SideUnit.allCases {
            XCTAssertEqual(u.toMM(u.fromMM(56)), 56, accuracy: 1e-9, u.rawValue)
        }
        // Three decimals on inches, because 135 is 0.945 in and at one decimal
        // every still format reads as the same film.
        XCTAssertGreaterThan(SideUnit.inch.decimals, SideUnit.mm.decimals)
    }

    func testParamValueJSON() throws {
        let enc = try JSONEncoder().encode(["a": ParamValue.double(1.5), "b": .bool(true), "c": .string("x")])
        let dec = try JSONDecoder().decode([String: ParamValue].self, from: enc)
        XCTAssertEqual(dec["a"], .double(1.5)); XCTAssertEqual(dec["b"], .bool(true)); XCTAssertEqual(dec["c"], .string("x"))
    }

    func testSidecarRoundTrip() throws {
        var s = Sidecar()
        s.params.yFilterShift = 0.3
        s.adjustments.curves.rgb.insert(CGPoint(x: 0.4, y: 0.5))
        s.geometry.crop = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(back, s)
    }
}
