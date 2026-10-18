//  Layer2ModelTests.swift — the grade as data: what an old sidecar reads as,
//  what "neutral" means, Blacks and Whites, and the one control table.
//
//  The picture these numbers make is `RendererTests`' (on the GPU); the
//  curves are `CurveMathTests`'. What is here needs neither.

import CoreGraphics
import XCTest

final class Layer2ModelTests: XCTestCase {

    // MARK: - an edit from 1.3

    /// A sidecar as 1.3.3 wrote it: every 1.3 key, and none of 2.0's — no
    /// `parametric` under `curves`. Values chosen so every block is off its
    /// default: a crushed black, a three-point curve, a master colour.
    static let sidecar133 = #"""
    {"schemaVersion":3,"decoder":"coreimage","state":{"processed":{}},"solvedEV":0.42,
     "adjustments":{"enabled":true,"temperature":-12,"tint":4,"exposure":0.5,"contrast":10,"brightness":-6,
       "saturation":15,"highlights":-30,"shadows":20,"blackPoint":6,"whitePoint":3,
       "curves":{"rgb":{"points":[[0,0],[0.5,0.6],[1,1]]},"luma":{"points":[[0,0],[1,1]]},
                 "red":{"points":[[0,0],[1,1]]},"green":{"points":[[0,0],[1,1]]},"blue":{"points":[[0,0.05],[1,1]]}},
       "colorBalance":{"master":{"hue":200,"saturation":0.2,"luminance":0},
                       "shadows":{"hue":210,"saturation":0.3,"luminance":0.1},
                       "midtones":{"hue":0,"saturation":0,"luminance":0},
                       "highlights":{"hue":40,"saturation":0.15,"luminance":-0.05}},
       "vignette":{"amount":-20,"midpoint":40}}}
    """#

    /// **The 1.3.3 sidecar decodes to the same grade, and so to the same
    /// picture.** Every stored number reads back as itself, the fields 2.0
    /// added read as neutral, and what reaches the shader — the uniform block
    /// and the curve table — is what 1.3 computed from the same numbers.
    ///
    /// **Seen red** with `CurveSet`'s synthesized decoder in place of its own:
    /// the missing `parametric` key threw, the whole sidecar failed to decode,
    /// and the frame would have opened with none of its settings.
    func testA133SidecarDecodesToTheSameGrade() throws {
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(Self.sidecar133.utf8))
        let a = s.adjustments
        XCTAssertEqual(s.solvedEV, 0.42)
        XCTAssertEqual(a.exposure, 0.5); XCTAssertEqual(a.contrast, 10); XCTAssertEqual(a.brightness, -6)
        XCTAssertEqual(a.saturation, 15); XCTAssertEqual(a.highlights, -30); XCTAssertEqual(a.shadows, 20)
        XCTAssertEqual(a.blackPoint, 6); XCTAssertEqual(a.whitePoint, 3)
        XCTAssertEqual(a.temperature, -12); XCTAssertEqual(a.tint, 4)
        XCTAssertEqual(a.curves.rgb.points, [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 1, y: 1)])
        XCTAssertEqual(a.curves.blue.points.first, CGPoint(x: 0, y: 0.05))
        XCTAssertEqual(a.colorBalance.master, ColorZone(hue: 200, saturation: 0.2, luminance: 0),
                       "the master colour, which the rail no longer draws, is kept")
        XCTAssertEqual(a.colorBalance.highlights, ColorZone(hue: 40, saturation: 0.15, luminance: -0.05))
        XCTAssertEqual(a.vignette, Vignette(amount: -20, midpoint: 40))
        XCTAssertTrue(a.curves.parametric.isNeutral, "2.0's parametric curve reads as neutral")

        // What the shader gets: 1.3's arithmetic on 1.3's numbers.
        let u = a.uniforms
        XCTAssertEqual(u.exposureGain, Float(pow(2.0, 0.5)))
        XCTAssertEqual(u.contrast, 0.10); XCTAssertEqual(u.brightness, -0.06); XCTAssertEqual(u.saturation, 1.15)
        XCTAssertEqual(u.highlights, -0.30); XCTAssertEqual(u.shadows, 0.20)
        XCTAssertEqual(u.blackPoint, 0.06); XCTAssertEqual(u.whitePoint, 0.03)
        XCTAssertEqual(u.wbGain, SIMD3<Float>(1 + 0.18 * -0.12, 1 - 0.12 * 0.04, 1 - 0.18 * -0.12))
        XCTAssertEqual(u.cbMaster, ColorZone(hue: 200, saturation: 0.2).rgbOffset)
        XCTAssertEqual(u.vignetteAmount, -0.2); XCTAssertEqual(u.vignetteMidpoint, 0.4)
        XCTAssertEqual(u.midGrey, Layer2Uniforms.proPhotoMidGrey, "the desktop's pivot is ProPhoto's")
        XCTAssertEqual(u.curvesActive, 1)
        // The table is the point curves' own, entry for entry: no parametric
        // curve, no composition.
        let pointTables = CurveChannel.allCases.flatMap { a.curves[$0].table() }
        XCTAssertEqual(a.curves.tables(), pointTables)

        // Written again and read again, it is the same grade.
        let again = try JSONDecoder().decode(Sidecar.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.adjustments, a)
    }

    /// A key missing anywhere in the grade reads as that field at rest, and
    /// the rest of the sidecar is kept. Before 2.0 one missing key threw out
    /// the whole file (`Sidecar.load` then opens the frame with defaults).
    ///
    /// **Seen red** with `Adjustments`' synthesized decoder: the sidecar did
    /// not decode at all.
    func testAMissingKeyReadsAsItsRestAndKeepsTheRest() throws {
        let json = #"""
        {"schemaVersion":3,"solvedEV":1.5,
         "adjustments":{"exposure":0.25,"curves":{"rgb":{"points":[[0,0],[0.4,0.5],[1,1]]}},
                        "colorBalance":{"shadows":{"hue":30}},"vignette":{"amount":-10}}}
        """#
        let s = try JSONDecoder().decode(Sidecar.self, from: Data(json.utf8))
        XCTAssertEqual(s.solvedEV, 1.5)
        let a = s.adjustments
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(a.exposure, 0.25)
        XCTAssertEqual(a.contrast, 0)
        XCTAssertEqual(a.curves.rgb.points.count, 3)
        XCTAssertTrue(a.curves.luma.isIdentity)
        XCTAssertEqual(a.colorBalance.shadows, ColorZone(hue: 30, saturation: 0, luminance: 0))
        XCTAssertEqual(a.vignette, Vignette(amount: -10, midpoint: 50))
        let parametric = try JSONDecoder().decode(ParametricCurve.self, from: Data(#"{"darks":20}"#.utf8))
        XCTAssertEqual(parametric.darks, 20)
        XCTAssertEqual(parametric.splits, [0.25, 0.5, 0.75])
    }

    /// A grade that moves everything, written and read: nothing is lost,
    /// the parametric curve included.
    func testAFullGradeRoundTrips() throws {
        var a = Adjustments()
        a.exposure = -0.4; a.blacks = 12; a.whites = -8
        a.curves.parametric.luma.shadows = 30
        a.curves.parametric.red.setSplit(.midtone, to: 0.42)
        a.curves.green.insert(CGPoint(x: 0.3, y: 0.35))
        a.colorBalance.midtones = ColorZone(hue: 95, saturation: 0.4, luminance: 0.2)
        let back = try JSONDecoder().decode(Adjustments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }

    // MARK: - Blacks and Whites

    /// Light's Blacks is the black point read the other way; Whites is the
    /// white point. Both go both ways from zero: −50…50.
    ///
    /// **Seen red** with Blacks' range at 1.3's 0…50: a Blacks of +20 (a
    /// lifted black) was held at 0.
    func testBlacksAndWhitesAreSignedViewsOfThePoints() {
        var a = Adjustments()
        a.blacks = -8
        XCTAssertEqual(a.blackPoint, 8, "Blacks −8 crushes: the point's 8, as 1.3 drew it")
        a[.blacks] = 20
        XCTAssertEqual(a.blackPoint, -20, "Blacks +20 lifts the black: a point below zero")
        a[.whites] = -15
        XCTAssertEqual(a.whitePoint, -15)
        a[.blacks] = 90
        XCTAssertEqual(a.blacks, 50, "held to its range")
        XCTAssertEqual(Layer2Control.blacks.range, -50...50)
        XCTAssertEqual(Layer2Control.whites.range, -50...50)
        // A 1.3 point is a Blacks of the same size, crushed.
        let old = Adjustments.from133(blackPoint: 6)
        XCTAssertEqual(old.blacks, -6)
    }

    // MARK: - neutral

    /// Neutral is "applies nothing": a midpoint with no vignette, a hue with
    /// no saturation, a split with no amounts move no pixel, so they do not
    /// make the grade edited. A real change does, in its own tool only.
    func testNeutralMeansAppliesNothing() {
        var n = Adjustments()
        XCTAssertTrue(n.isNeutral); XCTAssertFalse(n.isActive)
        n.vignette.midpoint = 20
        n.colorBalance.shadows.hue = 200
        n.curves.parametric.rgb.setSplit(.midtone, to: 0.4)
        XCTAssertTrue(n.isNeutral, "settings that move no pixel are not an edit")
        XCTAssertEqual(n.uniforms.curvesActive, 0, "a split alone does not switch the curves on")
        n.exposure = 0.1
        XCTAssertFalse(n.isNeutral(.light)); XCTAssertTrue(n.isNeutral(.curve)); XCTAssertTrue(n.isNeutral(.colour))
        n.enabled = false
        XCTAssertFalse(n.isActive, "switched off, it is not drawn")
        XCTAssertFalse(n.isNeutral, "and it still holds what it holds")
    }

    /// A section's Reset is that section's: Light keeps the curve and the
    /// colour, and so on; the three together are the whole grade.
    func testAToolsResetIsThatTool() {
        var a = Adjustments()
        a.exposure = 1; a.vignette = Vignette(amount: -30, midpoint: 30)
        a.curves.parametric.rgb.lights = 25
        a.saturation = 10; a.colorBalance.master.saturation = 0.2
        a.reset(.light)
        XCTAssertTrue(a.isNeutral(.light))
        XCTAssertEqual(a.vignette, Vignette())
        XCTAssertEqual(a.curves.parametric.rgb.lights, 25)
        XCTAssertEqual(a.saturation, 10)
        a.reset(.curve); a.reset(.colour)
        XCTAssertEqual(a, Adjustments(), "the three resets are the whole grade")
    }

    // MARK: - the control table

    /// The agent schema's ranges are the rail's: read from the one table, so
    /// a range changed in one place cannot leave the other behind.
    func testTheSchemaTakesItsRangesFromTheControlTable() throws {
        let rows = Dictionary(uniqueKeysWithValues: AgentSchema.fields.map { ($0.path, $0) })
        let paths: [(String, Layer2Control)] = [
            ("adjustments.exposure", .exposure), ("adjustments.contrast", .contrast),
            ("adjustments.brightness", .brightness), ("adjustments.highlights", .highlights),
            ("adjustments.shadows", .shadows), ("adjustments.blackPoint", .blacks),
            ("adjustments.whitePoint", .whites), ("adjustments.vignette.amount", .vignette),
            ("adjustments.vignette.midpoint", .vignetteMidpoint), ("adjustments.temperature", .temperature),
            ("adjustments.tint", .tint), ("adjustments.saturation", .saturation),
        ]
        for (path, control) in paths {
            guard case .number(let r) = try XCTUnwrap(rows[path], path).kind else { return XCTFail("\(path) is not a number") }
            XCTAssertEqual(r, control.range, path)
        }
        // Every control rests inside its range, and says its number one way.
        for c in Layer2Control.allCases { XCTAssertTrue(c.range.contains(c.rest), "\(c)") }
        XCTAssertEqual(Layer2Control.exposure.text(0.25), "+0.25")
        XCTAssertEqual(Layer2Control.contrast.text(-12), "\u{2212}12")
        XCTAssertEqual(Layer2Control.contrast.text(-0.3), "0", "no −0")
        XCTAssertEqual(Layer2Control.vignetteMidpoint.text(50), "50")
        XCTAssertEqual(Layer2Control.parse("\u{2212}12"), -12)
        XCTAssertEqual(Layer2Control.parse("0,5"), 0.5)
    }
}

private extension Adjustments {
    /// A grade as 1.3 stored a black point.
    static func from133(blackPoint: Double) -> Adjustments {
        var a = Adjustments(); a.blackPoint = blackPoint; return a
    }
}
