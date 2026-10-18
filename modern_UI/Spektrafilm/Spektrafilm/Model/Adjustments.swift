//  Adjustments.swift — Layer 2: adjustments to the print output, client-side.
//
//  These operate on the encoded print output the way a scan of a print is
//  adjusted afterwards (frontend SPEC §3.1). They live entirely in the Metal
//  shader (`Shaders.metal`, `layer2`) and cost < 1 ms; nothing here reaches
//  the service. Order of operations is fixed and matches the shader:
//
//      white balance → exposure/contrast/brightness → highlights/shadows
//      → black/white point → saturation → colour balance → curves → vignette
//
//  Zero is "nothing applied" for every field, so a fresh image reads as the
//  pure simulation, and `enabled = false` bypasses the whole layer.
//
//  The Post-Dev rail shows this layer as three tools — Light, Curve and
//  Colour (`Adjustments.Tool`) — and three things about the model follow
//  from how those tools behave:
//
//  - **Neutral means "applies nothing"**, not "equals the default". A
//    vignette's midpoint with no amount, a zone's hue with no saturation and a
//    parametric split with no amounts move no pixel, so they do not make the
//    grade "edited" (`isNeutral`, `isNeutral(_:)`), and the shader skips every
//    step whose control is at rest (`layer2Tone`).
//  - **Blacks and Whites are views of `blackPoint` and `whitePoint`**, signed
//    both ways from zero. Blacks −50 is the point's 50 (the black crushed, as
//    before); Blacks +50 is a point of −50, which lifts the black — the same
//    formula read the other way. An edit written before the views opens as it
//    was, because the stored numbers did not change meaning.
//  - **Every key may be missing.** A field added later reads as its rest
//    value in a sidecar written before it existed. The synthesized decoder
//    would throw instead, and `Sidecar.load` would then open the frame with
//    none of its settings — every edit on it gone, and gone for good at the
//    next save.

import Foundation
import simd

struct ColorZone: Codable, Equatable, Sendable {
    /// Hue angle in degrees, saturation 0…1 (wheel radius), luminance −1…1.
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    /// A hue with no saturation adds no colour, so it is not an edit.
    var isNeutral: Bool { saturation == 0 && luminance == 0 }

    /// The RGB offset this zone applies, in the shader's units.
    var rgbOffset: SIMD3<Float> {
        let h = hue * .pi / 180
        // Hue on the wheel → unit RGB direction (0° = red, 120° = green, 240° = blue).
        let r = cos(h), g = cos(h - 2 * .pi / 3), b = cos(h + 2 * .pi / 3)
        let s = Float(saturation) * 0.25
        return SIMD3<Float>(Float(r), Float(g), Float(b)) * s
    }

    init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try c.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }
}

struct ColorBalance: Codable, Equatable, Sendable {
    /// Kept, though the Colour section draws only the three zones: an edit
    /// made on the master wheel before keeps its colour, and the section
    /// says so while it is not neutral rather than dropping it.
    var master = ColorZone()
    var shadows = ColorZone()
    var midtones = ColorZone()
    var highlights = ColorZone()
    var isNeutral: Bool { master.isNeutral && shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }

    /// The wheels: master, and Capture One's three zones. `title` is the
    /// English name; the rail asks for its localized one (`Strings.swift`).
    enum Zone: String, CaseIterable, Codable, Sendable, Identifiable {
        case master, shadows, midtones, highlights
        var id: String { rawValue }
        var title: String {
            switch self {
            case .master: "Master"
            case .shadows: "Shadows"
            case .midtones: "Midtones"
            case .highlights: "Highlights"
            }
        }
        /// The three the Colour section draws, darkest first.
        static let drawn: [Zone] = [.shadows, .midtones, .highlights]
    }

    subscript(zone: Zone) -> ColorZone {
        get {
            switch zone {
            case .master: master
            case .shadows: shadows
            case .midtones: midtones
            case .highlights: highlights
            }
        }
        set {
            switch zone {
            case .master: master = newValue
            case .shadows: shadows = newValue
            case .midtones: midtones = newValue
            case .highlights: highlights = newValue
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(ColorZone.self, forKey: .master) ?? ColorZone()
        shadows = try c.decodeIfPresent(ColorZone.self, forKey: .shadows) ?? ColorZone()
        midtones = try c.decodeIfPresent(ColorZone.self, forKey: .midtones) ?? ColorZone()
        highlights = try c.decodeIfPresent(ColorZone.self, forKey: .highlights) ?? ColorZone()
    }
}

struct Vignette: Codable, Equatable, Sendable {
    var amount: Double = 0      // −100…100, negative darkens the corners
    var midpoint: Double = 50   // 0…100, radius at which falloff starts
    /// A midpoint with no amount darkens nothing.
    var isNeutral: Bool { amount == 0 }

    init(amount: Double = 0, midpoint: Double = 50) { self.amount = amount; self.midpoint = midpoint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        midpoint = try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? 50
    }
}

struct Adjustments: Codable, Equatable, Sendable {
    var enabled: Bool = true
    // White balance, post-print (Capture One's model, but as an offset).
    var temperature: Double = 0    // −100…100, blue ↔ amber
    var tint: Double = 0           // −100…100, green ↔ magenta
    // Exposure group (Capture One's four).
    var exposure: Double = 0       // stops, −3…3
    var contrast: Double = 0       // −50…50
    var brightness: Double = 0     // −50…50
    var saturation: Double = 0     // −100…100
    // Tone-region recovery.
    var highlights: Double = 0     // −100…100
    var shadows: Double = 0        // −100…100
    /// Percent of the range taken to black, −50…50. Positive crushes the
    /// black, which is all 1.3 offered (0…50); negative lifts it. Light shows
    /// it as Blacks, with the sign the other way round (`blacks`).
    var blackPoint: Double = 0
    /// Percent of the range taken to white, −50…50. Positive brightens the
    /// white past the paper's; negative dims it. Light's Whites is this number.
    var whitePoint: Double = 0
    var curves = CurveSet()
    var colorBalance = ColorBalance()
    var vignette = Vignette()

    static let `default` = Adjustments()

    init() {}
    init(enabled: Bool) { self.enabled = enabled }

    /// Every key may be missing: an edit written before a field existed reads
    /// as that field at rest. See the note at the top of the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
        whitePoint = try c.decodeIfPresent(Double.self, forKey: .whitePoint) ?? 0
        curves = try c.decodeIfPresent(CurveSet.self, forKey: .curves) ?? CurveSet()
        colorBalance = try c.decodeIfPresent(ColorBalance.self, forKey: .colorBalance) ?? ColorBalance()
        vignette = try c.decodeIfPresent(Vignette.self, forKey: .vignette) ?? Vignette()
    }

    // MARK: Blacks and Whites

    /// Light's Blacks: −50 crushes, +50 lifts. The stored point read the other
    /// way, so that the slider's right is lighter, as every slider in Light is.
    var blacks: Double {
        get { -blackPoint }
        set { blackPoint = -newValue }
    }

    /// Light's Whites: +50 brightens, −50 dims. The stored point as it is.
    var whites: Double {
        get { whitePoint }
        set { whitePoint = newValue }
    }

    // MARK: the three tools

    /// The Post-Dev rail's three sections, each a part of this layer.
    enum Tool: String, CaseIterable, Codable, Sendable, Identifiable {
        case light, curve, colour
        var id: String { rawValue }
    }

    /// Whether `tool` applies nothing.
    func isNeutral(_ tool: Tool) -> Bool {
        switch tool {
        case .light:
            exposure == 0 && contrast == 0 && brightness == 0 && highlights == 0 && shadows == 0
                && blackPoint == 0 && whitePoint == 0 && vignette.isNeutral
        case .curve:
            curves.isIdentity
        case .colour:
            temperature == 0 && tint == 0 && saturation == 0 && colorBalance.isNeutral
        }
    }

    /// Applies nothing at all, whether or not it is switched on.
    var isNeutral: Bool { Tool.allCases.allSatisfy(isNeutral) }

    /// Something to draw: switched on, and not neutral.
    var isActive: Bool { enabled && !isNeutral }

    /// One tool back to rest; the others as they are. A section's Reset.
    mutating func reset(_ tool: Tool) {
        switch tool {
        case .light:
            exposure = 0; contrast = 0; brightness = 0; highlights = 0; shadows = 0
            blackPoint = 0; whitePoint = 0; vignette = Vignette()
        case .curve:
            curves = CurveSet()
        case .colour:
            temperature = 0; tint = 0; saturation = 0; colorBalance = ColorBalance()
        }
    }

    // MARK: the shader's block

    /// The per-frame uniform block the shader reads. Computed on the CPU once
    /// per change, not per pixel.
    var uniforms: Layer2Uniforms {
        // The tone block is `Layer2Uniforms.tone` — the *same* function every
        // mask uses (`Model/Mask.swift`). Temperature and tint become channel
        // gains there, ±100 → roughly ±0.18 on the opposing channels, which
        // is the visual range of a scan white-balance correction rather than
        // a scene one. Sharing it is what makes "+1 stop" mean one stop
        // whether the slider was the global one or a mask's.
        var u = Layer2Uniforms.tone(temperature: temperature, tint: tint, exposure: exposure,
                                    contrast: contrast, brightness: brightness, saturation: saturation,
                                    highlights: highlights, shadows: shadows,
                                    blackPoint: blackPoint, whitePoint: whitePoint)
        u.enabled = enabled ? 1 : 0
        u.cbMaster = colorBalance.master.rgbOffset
        u.cbShadows = colorBalance.shadows.rgbOffset
        u.cbMidtones = colorBalance.midtones.rgbOffset
        u.cbHighlights = colorBalance.highlights.rgbOffset
        u.cbLum = SIMD4<Float>(Float(colorBalance.master.luminance), Float(colorBalance.shadows.luminance),
                               Float(colorBalance.midtones.luminance), Float(colorBalance.highlights.luminance)) * 0.25
        u.vignetteAmount = Float(vignette.amount) / 100
        u.vignetteMidpoint = Float(vignette.midpoint) / 100
        u.curvesActive = curves.isIdentity ? 0 : 1
        return u
    }
}

// MARK: - the control table

/// One slider of Light or Colour: its range, where it rests, how its number is
/// written and how far a key moves it — said once, so the rail, the agent
/// schema and the tests cannot drift apart. The wheels are not here: a zone
/// is three numbers (`ColorBalance.Zone`), and the parametric curve's four
/// amounts are `ParametricCurve`'s.
///
/// Before the table each of these was written at each place that drew or
/// checked the control (the rail's `ScrubSlider` calls, `AgentSchema`'s rows),
/// and they agreed only because nobody had changed one of them yet.
enum Layer2Control: String, CaseIterable, Codable, Sendable, Identifiable {
    case exposure, contrast, brightness, highlights, shadows, whites, blacks, vignette, vignetteMidpoint
    case temperature, tint, saturation

    var id: String { rawValue }

    var tool: Adjustments.Tool {
        switch self {
        case .temperature, .tint, .saturation: .colour
        default: .light
        }
    }

    /// Light's rows, in the order the section draws them.
    static let light: [Layer2Control] = allCases.filter { $0.tool == .light }
    /// Colour's rows, above the wheels.
    static let colour: [Layer2Control] = allCases.filter { $0.tool == .colour }

    /// The English name; the rail asks for its localized one (`Strings.swift`).
    var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .brightness: "Brightness"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .vignette: "Vignette"
        case .vignetteMidpoint: "Midpoint"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .saturation: "Saturation"
        }
    }

    /// The control's travel. Blacks and Whites go both ways from zero; every
    /// other range is the one 1.3 drew.
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -3...3
        case .contrast, .brightness: -50...50
        case .highlights, .shadows, .vignette, .temperature, .tint, .saturation: -100...100
        case .whites, .blacks: -50...50
        case .vignetteMidpoint: 0...100
        }
    }

    /// The value it rests at, and goes back to on a double-click.
    var rest: Double { self == .vignetteMidpoint ? 50 : 0 }

    /// Where the track draws its rest mark: the middle, or nowhere for a
    /// control whose rest is not a "no change" (the midpoint).
    var isCentred: Bool { self != .vignetteMidpoint }

    /// One arrow key's worth. ⌥ is a tenth of it, ⇧ ten times it.
    var step: Double { self == .exposure ? 0.05 : 1 }

    /// The snap ⇧ rounds a drag to: the old rail's numbers.
    var snap: Double {
        switch self {
        case .exposure: 0.25
        case .whites, .blacks, .vignetteMidpoint: 1
        default: 5
        }
    }

    /// "+0.25", "−12", "0", "50".
    func text(_ value: Double) -> String {
        switch self {
        case .exposure: Layer2Control.signed(value, decimals: 2)
        case .vignetteMidpoint: String(format: "%.0f", value)
        default: Layer2Control.signed(value, decimals: 0)
        }
    }

    /// Whether it is away from where it rests. The midpoint alone moves
    /// nothing in the picture, so it never makes Light "edited" by itself.
    func isMoved(in a: Adjustments) -> Bool {
        self == .vignetteMidpoint ? false : a[self] != rest
    }

    /// A signed number with a true minus and no sign on zero: "+12", "−12",
    /// "0" — never "+0" or "-0", which is what `%+.0f` writes near zero.
    static func signed(_ v: Double, decimals: Int) -> String {
        let body = String(format: "%.\(decimals)f", abs(v))
        if Double(body) == 0 { return body }
        return (v < 0 ? "\u{2212}" : "+") + body
    }

    /// The text a person typed into a value field, as a number: a true minus
    /// and a decimal comma both read.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: ",", with: "."))
    }
}

extension Adjustments {
    /// A slider's value; set it here and it is held to the control's range.
    subscript(control: Layer2Control) -> Double {
        get {
            switch control {
            case .exposure: exposure
            case .contrast: contrast
            case .brightness: brightness
            case .highlights: highlights
            case .shadows: shadows
            case .whites: whites
            case .blacks: blacks
            case .vignette: vignette.amount
            case .vignetteMidpoint: vignette.midpoint
            case .temperature: temperature
            case .tint: tint
            case .saturation: saturation
            }
        }
        set {
            let v = min(max(newValue, control.range.lowerBound), control.range.upperBound)
            switch control {
            case .exposure: exposure = v
            case .contrast: contrast = v
            case .brightness: brightness = v
            case .highlights: highlights = v
            case .shadows: shadows = v
            case .whites: whites = v
            case .blacks: blacks = v
            case .vignette: vignette.amount = v
            case .vignetteMidpoint: vignette.midpoint = v
            case .temperature: temperature = v
            case .tint: tint = v
            case .saturation: saturation = v
            }
        }
    }
}

/// Must match `Layer2Uniforms` in Shaders.metal field for field and in order.
struct Layer2Uniforms: Sendable {
    var wbGain = SIMD3<Float>(repeating: 1)
    var exposureGain: Float = 1
    var cbMaster = SIMD3<Float>(repeating: 0)
    var contrast: Float = 0
    var cbShadows = SIMD3<Float>(repeating: 0)
    var brightness: Float = 0
    var cbMidtones = SIMD3<Float>(repeating: 0)
    var saturation: Float = 1
    var cbHighlights = SIMD3<Float>(repeating: 0)
    var highlights: Float = 0
    var cbLum = SIMD4<Float>(repeating: 0)
    var shadows: Float = 0
    var blackPoint: Float = 0
    var whitePoint: Float = 0
    var vignetteAmount: Float = 0
    var vignetteMidpoint: Float = 0.5
    /// Encoded mid-grey (linear 0.18) in the working space — RFC-018 D1's
    /// pivot. See `Layer2Uniforms.tone` for the two constants and why the
    /// default is the ROMM one.
    var midGrey: Float = Layer2Uniforms.proPhotoMidGrey
    var curvesActive: UInt32 = 0
    var enabled: UInt32 = 1
    /// RFC-028: read the source through the Cineon → ProPhoto table first.
    /// Set by the renderer for a Digital Intermediate, never by an edit.
    var inputDecode: UInt32 = 0

    /// `pow(0.18, 1/1.8)` — mid-grey through ROMM γ1.8, the working space's
    /// own curve since RFC-018. The number `layer2Tone` pivots on.
    ///
    /// Kept beside `srgbMidGrey` rather than inlined because the *pair* is the
    /// decision: D1 says the pivot follows the encoding, so a future move to
    /// another working space is a swap of which constant is the default, not a
    /// hunt for literals.
    static let proPhotoMidGrey: Float = 0.3857
    /// `1.055·0.18^(1/2.4) − 0.055` — the same through an sRGB-like curve,
    /// which is what Display P3 has and what this code pivoted on by accident
    /// until RFC-018.
    static let srgbMidGrey: Float = 0.4614
}
