//  Adjustments.swift — Layer 2: the scan of the print, adjusted afterwards.
//
//  The desktop's (`Model/Adjustments.swift`, desktop `df355fa`, the
//  maintainer's; UPSTREAM.md), and on the host it is Edit's Light, Curve and
//  Colour (design/v5 §2). It works on the finished print's encoded values in
//  the GPU (`Layer2Kernel`), **never in the engine**: nothing here is a film,
//  a paper or a wire field, so moving one of these never develops anything
//  (AGENTS.md: the material model is untouched). The order is fixed and is
//  the shader's:
//
//      white balance → exposure/contrast/brightness → highlights/shadows
//      → black/white point → saturation → vibrance → HSL → channel mixer
//      → colour balance → curves → vignette
//
//  Zero is "nothing applied" for every field. Vibrance, HSL and the channel
//  mixer are the host's own (Edit's 调整 strip, 2026-10-19), not the desktop's:
//  an edit without them reads them at zero, and an edit that leaves them at
//  zero is written without their keys, so a record from before them is
//  written again byte for byte and keeps its `key`. The desktop's names are kept
//  (`blackPoint`, `whitePoint`, `colorBalance`) so an edit travels between the
//  two; the host shows the black and white points as Lightroom's Blacks and
//  Whites (`blacks`, `whites`).

import CryptoKit
import Foundation
import simd

struct ColorZone: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case hue = "hue", saturation = "saturation", luminance = "luminance" }
    /// Hue angle in degrees, saturation 0…1 (wheel radius), luminance −1…1.
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
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
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case master = "master", shadows = "shadows", midtones = "midtones", highlights = "highlights"
    }
    var master = ColorZone()
    var shadows = ColorZone()
    var midtones = ColorZone()
    var highlights = ColorZone()
    var isNeutral: Bool { master.isNeutral && shadows.isNeutral && midtones.isNeutral && highlights.isNeutral }

    /// The wheels: master, and Capture One's three zones.
    enum Zone: String, CaseIterable, Codable, Sendable, Identifiable {
        case master = "master", shadows = "shadows", midtones = "midtones", highlights = "highlights"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .master: L("Master")
            case .shadows: L("Shadows")
            case .midtones: L("Midtones")
            case .highlights: L("Highlights")
            }
        }
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
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case amount = "amount", midpoint = "midpoint" }
    var amount: Double = 0      // −100…100, negative darkens the corners
    var midpoint: Double = 50   // 0…100, radius at which falloff starts
    var isNeutral: Bool { amount == 0 }

    init(amount: Double = 0, midpoint: Double = 50) { self.amount = amount; self.midpoint = midpoint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        midpoint = try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? 50
    }
}

/// HSL's eight colours, Lightroom's: each is a hue on the colour circle the
/// shader measures (red 0°, yellow 60°, green 120°, aqua 180°, blue 240°,
/// magenta 300°), and a pixel between two of them takes from both.
enum HSLHue: String, CaseIterable, Codable, Sendable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: String { rawValue }

    /// Where the colour sits on the circle, in degrees.
    var centre: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }

    var title: String {
        switch self {
        case .red: L("Red")
        case .orange: L("Orange")
        case .yellow: L("Yellow")
        case .green: L("Green")
        case .aqua: L("Aqua")
        case .blue: L("Blue")
        case .purple: L("Purple")
        case .magenta: L("Magenta")
        }
    }

    /// Its place in the shader's two four-wide rows.
    var index: Int { HSLHue.allCases.firstIndex(of: self) ?? 0 }
}

/// One of HSL's colours moved: its hue, saturation and luminance, −100…100 each.
struct HSLBand: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case hue = "hue", saturation = "saturation", luminance = "luminance" }
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }

    init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        luminance = try c.decodeIfPresent(Double.self, forKey: .luminance) ?? 0
    }

    /// The three sliders, in the order the tool shows them.
    enum Component: String, CaseIterable, Codable, Sendable, Identifiable {
        case hue, saturation, luminance
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hue: L("Hue")
            case .saturation: L("Saturation")
            case .luminance: L("Luminance")
            }
        }
    }

    subscript(component: Component) -> Double {
        get {
            switch component {
            case .hue: hue
            case .saturation: saturation
            case .luminance: luminance
            }
        }
        set {
            let v = min(max(newValue, HSLSet.range.lowerBound), HSLSet.range.upperBound)
            switch component {
            case .hue: hue = v
            case .saturation: saturation = v
            case .luminance: luminance = v
            }
        }
    }
}

/// HSL: each of the eight colours with its own hue, saturation and luminance.
struct HSLSet: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case red = "red", orange = "orange", yellow = "yellow", green = "green", aqua = "aqua", blue = "blue",
            purple = "purple", magenta = "magenta"
    }
    var red = HSLBand(), orange = HSLBand(), yellow = HSLBand(), green = HSLBand()
    var aqua = HSLBand(), blue = HSLBand(), purple = HSLBand(), magenta = HSLBand()

    static let range: ClosedRange<Double> = -100...100
    /// How far ±100 turns a colour's hue, in degrees: a third of the way to
    /// the next primary, so red reaches magenta-red one way and orange the other.
    static let hueReach: Double = 30

    var isNeutral: Bool { HSLHue.allCases.allSatisfy { self[$0].isNeutral } }

    /// The colours that are moved, in the circle's order.
    var changed: [HSLHue] { HSLHue.allCases.filter { !self[$0].isNeutral } }

    subscript(hue: HSLHue) -> HSLBand {
        get {
            switch hue {
            case .red: red
            case .orange: orange
            case .yellow: yellow
            case .green: green
            case .aqua: aqua
            case .blue: blue
            case .purple: purple
            case .magenta: magenta
            }
        }
        set {
            switch hue {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    init() {}

    /// Every key may be missing: a colour not written is unmoved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(HSLBand.self, forKey: .red) ?? HSLBand()
        orange = try c.decodeIfPresent(HSLBand.self, forKey: .orange) ?? HSLBand()
        yellow = try c.decodeIfPresent(HSLBand.self, forKey: .yellow) ?? HSLBand()
        green = try c.decodeIfPresent(HSLBand.self, forKey: .green) ?? HSLBand()
        aqua = try c.decodeIfPresent(HSLBand.self, forKey: .aqua) ?? HSLBand()
        blue = try c.decodeIfPresent(HSLBand.self, forKey: .blue) ?? HSLBand()
        purple = try c.decodeIfPresent(HSLBand.self, forKey: .purple) ?? HSLBand()
        magenta = try c.decodeIfPresent(HSLBand.self, forKey: .magenta) ?? HSLBand()
    }
}

/// One output channel of the channel mixer: how much of each input it takes,
/// as an offset in percent from the channel itself (−100…100 each). Zero is
/// the channel as it was: red out is all of red in, none of green or blue.
struct MixerRow: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case red = "red", green = "green", blue = "blue" }
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var isNeutral: Bool { red == 0 && green == 0 && blue == 0 }

    init(red: Double = 0, green: Double = 0, blue: Double = 0) { self.red = red; self.green = green; self.blue = blue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
    }

    subscript(input: ChannelMixer.Channel) -> Double {
        get {
            switch input {
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            let v = min(max(newValue, ChannelMixer.range.lowerBound), ChannelMixer.range.upperBound)
            switch input {
            case .red: red = v
            case .green: green = v
            case .blue: blue = v
            }
        }
    }
}

/// 通道: the channel mixer. Each output channel is a sum of the three inputs.
struct ChannelMixer: Codable, Equatable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case red = "red", green = "green", blue = "blue" }
    var red = MixerRow()
    var green = MixerRow()
    var blue = MixerRow()

    static let range: ClosedRange<Double> = -100...100

    enum Channel: String, CaseIterable, Codable, Sendable, Identifiable {
        case red, green, blue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .red: L("Red")
            case .green: L("Green")
            case .blue: L("Blue")
            }
        }
        /// Its place in a pixel: red 0, green 1, blue 2.
        var index: Int { Channel.allCases.firstIndex(of: self) ?? 0 }
    }

    var isNeutral: Bool { red.isNeutral && green.isNeutral && blue.isNeutral }

    subscript(output: Channel) -> MixerRow {
        get {
            switch output {
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch output {
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    /// An output channel's row of the matrix the shader multiplies by: the
    /// identity's row, plus the offsets.
    func row(_ output: Channel) -> SIMD3<Float> {
        var r = SIMD3<Float>(Float(self[output].red), Float(self[output].green), Float(self[output].blue)) / 100
        r[output.index] += 1
        return r
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = try c.decodeIfPresent(MixerRow.self, forKey: .red) ?? MixerRow()
        green = try c.decodeIfPresent(MixerRow.self, forKey: .green) ?? MixerRow()
        blue = try c.decodeIfPresent(MixerRow.self, forKey: .blue) ?? MixerRow()
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
    /// Percent of the range taken to black (the desktop's 0…50). The host's
    /// Blacks is its negative, and goes below zero too: a negative black
    /// point lifts the black — the same formula, read the other way.
    var blackPoint: Double = 0
    /// Percent of the range taken to white (the desktop's 0…50). The host's
    /// Whites is the same number; below zero it dims the white.
    var whitePoint: Double = 0
    var curves = CurveSet()
    var colorBalance = ColorBalance()
    var vignette = Vignette()
    // The host's own (Edit's 调整 strip): written only while they move something.
    /// Saturation that spares what is already saturated: −100…100.
    var vibrance: Double = 0
    var hsl = HSLSet()
    var channelMixer = ChannelMixer()

    static let `default` = Adjustments()

    private enum CodingKeys: String, CodingKey {
        case enabled = "enabled", temperature = "temperature", tint = "tint", exposure = "exposure",
            contrast = "contrast", brightness = "brightness", saturation = "saturation", highlights = "highlights",
            shadows = "shadows"
        case blackPoint = "blackPoint", whitePoint = "whitePoint", curves = "curves", colorBalance = "colorBalance",
            vignette = "vignette", vibrance = "vibrance", hsl = "hsl", channelMixer = "channelMixer"
    }

    init() {}
    init(enabled: Bool) { self.enabled = enabled }

    /// Every key may be missing: an edit written before a field was there
    /// reads as that field at zero.
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
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        hsl = try c.decodeIfPresent(HSLSet.self, forKey: .hsl) ?? HSLSet()
        channelMixer = try c.decodeIfPresent(ChannelMixer.self, forKey: .channelMixer) ?? ChannelMixer()
    }

    /// The desktop's fields always, as they were written before; vibrance, HSL
    /// and the channel mixer only where they move something. An edit that never
    /// used them is written as it was, to the byte, and so keeps its `key` (the
    /// name of its edited copies on disk).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(blackPoint, forKey: .blackPoint)
        try c.encode(whitePoint, forKey: .whitePoint)
        try c.encode(curves, forKey: .curves)
        try c.encode(colorBalance, forKey: .colorBalance)
        try c.encode(vignette, forKey: .vignette)
        if vibrance != 0 { try c.encode(vibrance, forKey: .vibrance) }
        if !hsl.isNeutral { try c.encode(hsl, forKey: .hsl) }
        if !channelMixer.isNeutral { try c.encode(channelMixer, forKey: .channelMixer) }
    }

    // MARK: Lightroom's names for the two points

    /// Light's Blacks: −50 crushes, +50 lifts.
    var blacks: Double {
        get { -blackPoint }
        set { blackPoint = -newValue }
    }

    /// Light's Whites: +50 brightens, −50 dims.
    var whites: Double {
        get { whitePoint }
        set { whitePoint = newValue }
    }

    // MARK: the three tools

    /// The three of Edit's tools that are this layer (design/v5 §2).
    enum Tool: String, CaseIterable, Codable, Sendable, Identifiable {
        case light, curve, colour
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: L("Light")
            case .curve: L("Curve")
            case .colour: L("Colour")
            }
        }
    }

    /// Whether `tool` applies nothing. A vignette's midpoint with no amount, a
    /// zone's hue with no saturation and a parametric split with no amounts
    /// apply nothing either.
    func isNeutral(_ tool: Tool) -> Bool {
        switch tool {
        case .light:
            exposure == 0 && contrast == 0 && brightness == 0 && highlights == 0 && shadows == 0
                && blackPoint == 0 && whitePoint == 0 && vignette.isNeutral
        case .curve:
            curves.isIdentity
        case .colour:
            temperature == 0 && tint == 0 && saturation == 0 && colorBalance.isNeutral
                && vibrance == 0 && hsl.isNeutral && channelMixer.isNeutral
        }
    }

    /// Applies nothing at all, whether or not it is switched on.
    var isNeutral: Bool { Tool.allCases.allSatisfy(isNeutral) }

    /// Something to draw: switched on, and not neutral. A neutral layer is
    /// never run — the page and every export are the developed picture,
    /// exactly as before there was a Layer 2.
    var isActive: Bool { enabled && !isNeutral }

    /// The tools that apply something, in the tool row's order.
    var changedTools: [Tool] { Tool.allCases.filter { !isNeutral($0) } }

    /// One tool back to zero; the others as they are.
    mutating func reset(_ tool: Tool) {
        switch tool {
        case .light:
            exposure = 0; contrast = 0; brightness = 0; highlights = 0; shadows = 0
            blackPoint = 0; whitePoint = 0; vignette = Vignette()
        case .curve:
            curves = CurveSet()
        case .colour:
            temperature = 0; tint = 0; saturation = 0; colorBalance = ColorBalance()
            vibrance = 0; hsl = HSLSet(); channelMixer = ChannelMixer()
        }
    }

    /// `tool`'s settings taken from `other`, and nothing else: a paste of one group.
    mutating func take(_ tool: Tool, from other: Adjustments) {
        switch tool {
        case .light:
            exposure = other.exposure; contrast = other.contrast; brightness = other.brightness
            highlights = other.highlights; shadows = other.shadows
            blackPoint = other.blackPoint; whitePoint = other.whitePoint; vignette = other.vignette
        case .curve:
            curves = other.curves
        case .colour:
            temperature = other.temperature; tint = other.tint; saturation = other.saturation
            colorBalance = other.colorBalance
            vibrance = other.vibrance; hsl = other.hsl; channelMixer = other.channelMixer
        }
    }

    /// What `tool` holds, as Copy Settings says it under the group's name:
    /// "Exposure +0.25  ·  Contrast +12", "RGB  ·  R", "Temperature +6  ·  Shadows".
    func summary(_ tool: Tool) -> String {
        var parts: [String] = []
        switch tool {
        case .light, .colour:
            for control in Layer2Control.allCases where control.tool == tool && control.isMoved(in: self) {
                parts.append(control.title + " " + control.text(self[control]))
            }
            if tool == .colour {
                if !hsl.isNeutral { parts.append("HSL") }
                if !channelMixer.isNeutral { parts.append(L("Channels")) }
                for zone in ColorBalance.Zone.allCases where !colorBalance[zone].isNeutral { parts.append(zone.title) }
            }
        case .curve:
            parts = curves.changedChannels.map(\.tab)
        }
        return parts.isEmpty ? L("None") : parts.joined(separator: " · ")
    }

    /// A word for what this layer draws, for a cache and a file's name: equal
    /// for two layers that draw the same, "neutral" for one that draws nothing.
    var key: String {
        guard isActive else { return "neutral" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the log's names

    /// A setting's name in the develop visit's record (`Log.developVisit`):
    /// `path` is its place in this struct's JSON ("exposure", "vignette.amount",
    /// "curves.parametric.rgb.shadows", "colorBalance.shadows.hue"), and the
    /// name is under Edit's tool ("edit.light.exposure", "edit.curve.rgb.shadows",
    /// "edit.colour.shadows.hue", "edit.colour.hsl.blue.luminance",
    /// "edit.colour.channel.red.green"). HSL and the channel mixer are not
    /// written while neutral, so the first move of one is named by its group
    /// alone ("edit.colour.hsl"). The log is English.
    static func logName(_ path: String) -> String {
        let parts = path.split(separator: ".").map(String.init)
        guard let head = parts.first else { return "edit" }
        let rest = parts.dropFirst()
        switch head {
        case "exposure", "contrast", "brightness", "highlights", "shadows": return "edit.light." + head
        case "blackPoint": return "edit.light.blacks"
        case "whitePoint": return "edit.light.whites"
        case "vignette": return rest.first == "midpoint" ? "edit.light.vignette.midpoint" : "edit.light.vignette"
        case "temperature", "tint", "saturation", "vibrance": return "edit.colour." + head
        case "colorBalance": return (["edit.colour"] + rest).joined(separator: ".")
        case "hsl": return (["edit.colour.hsl"] + rest).joined(separator: ".")
        case "channelMixer": return (["edit.colour.channel"] + rest).joined(separator: ".")
        case "curves":
            if rest.first == "parametric" { return (["edit.curve"] + rest.dropFirst()).joined(separator: ".") }
            return (["edit.curve"] + rest).joined(separator: ".")
        default: return "edit." + path
        }
    }

    // MARK: the shader's block

    /// The per-frame uniform block the shader reads. Computed on the CPU once
    /// per change, not per pixel. `midGrey` is the encoded mid-grey of the
    /// space the values are in: on the host the picture is Display P3
    /// (`Layer2Uniforms.displayMidGrey`).
    func uniforms(midGrey: Float = Layer2Uniforms.displayMidGrey) -> Layer2Uniforms {
        var u = Layer2Uniforms.tone(temperature: temperature, tint: tint, exposure: exposure,
                                    contrast: contrast, brightness: brightness, saturation: saturation,
                                    highlights: highlights, shadows: shadows,
                                    blackPoint: blackPoint, whitePoint: whitePoint, midGrey: midGrey)
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
        u.vibrance = Float(vibrance) / 100
        if !hsl.isNeutral {
            u.hslActive = 1
            let k = Float(HSLSet.hueReach * .pi / 180) / 100
            func row(_ hues: ArraySlice<HSLHue>, _ value: (HSLBand) -> Double, _ scale: Float) -> SIMD4<Float> {
                let v = hues.map { Float(value(hsl[$0])) * scale }
                return SIMD4<Float>(v[0], v[1], v[2], v[3])
            }
            let all = HSLHue.allCases
            let first = all[0..<4], second = all[4..<8]
            u.hslHue0 = row(first, \.hue, k); u.hslHue1 = row(second, \.hue, k)
            u.hslSat0 = row(first, \.saturation, 0.01); u.hslSat1 = row(second, \.saturation, 0.01)
            u.hslLum0 = row(first, \.luminance, 0.01); u.hslLum1 = row(second, \.luminance, 0.01)
        }
        if !channelMixer.isNeutral {
            u.mixerActive = 1
            u.mixR = channelMixer.row(.red); u.mixG = channelMixer.row(.green); u.mixB = channelMixer.row(.blue)
        }
        return u
    }
}

/// One slider of Light or Colour: its name, its range, how its number is
/// written, and where it lives in `Adjustments` — so the panels, the clipboard's
/// line and the log say each control the same way. The wheels are not here:
/// a zone is three numbers (`ColorBalance.Zone`).
enum Layer2Control: String, CaseIterable, Codable, Sendable, Identifiable {
    case exposure, contrast, brightness, highlights, shadows, whites, blacks, vignette, vignetteMidpoint
    case temperature, tint, saturation, vibrance

    var id: String { rawValue }

    var tool: Adjustments.Tool {
        switch self {
        case .temperature, .tint, .saturation, .vibrance: .colour
        default: .light
        }
    }

    var title: String {
        switch self {
        case .exposure: L("Exposure")
        case .contrast: L("Contrast")
        case .brightness: L("Brightness")
        case .highlights: L("Highlights")
        case .shadows: L("Shadows")
        case .whites: L("Whites")
        case .blacks: L("Blacks")
        case .vignette: L("Vignette")
        case .vignetteMidpoint: L("Midpoint")
        case .temperature: L("Temperature")
        case .tint: L("Tint")
        case .saturation: L("Saturation")
        case .vibrance: L("Vibrance")
        }
    }

    /// The control's travel. The desktop's ranges, but for Blacks and Whites,
    /// which go both ways on the host (`Adjustments.blackPoint`).
    var range: ClosedRange<Double> {
        switch self {
        case .exposure: -3...3
        case .contrast, .brightness: -50...50
        case .highlights, .shadows, .vignette, .temperature, .tint, .saturation, .vibrance: -100...100
        case .whites, .blacks: -50...50
        case .vignetteMidpoint: 0...100
        }
    }

    /// Where zero is drawn: the middle of the track, or its left end (the midpoint).
    var isCentred: Bool { self != .vignetteMidpoint }

    /// The value it rests at, and goes back to on a double-tap.
    var rest: Double { self == .vignetteMidpoint ? 50 : 0 }

    /// "+0.25", "−12", "50".
    func text(_ value: Double) -> String {
        switch self {
        case .exposure: Fmt.signed(value, decimals: 2)
        case .vignetteMidpoint: String(format: "%.0f", value)
        default: Fmt.signed(value, decimals: 0)
        }
    }

    /// Whether it is away from where it rests. The midpoint alone moves nothing
    /// in the picture, so it never makes Light "edited" by itself.
    func isMoved(in a: Adjustments) -> Bool {
        self == .vignetteMidpoint ? false : a[self] != rest
    }

    /// The log's name for it (`Adjustments.logName`).
    var logName: String {
        switch self {
        case .whites: "edit.light.whites"
        case .blacks: "edit.light.blacks"
        case .vignette: "edit.light.vignette"
        case .vignetteMidpoint: "edit.light.vignette.midpoint"
        case .temperature, .tint, .saturation, .vibrance: "edit.colour." + rawValue
        default: "edit.light." + rawValue
        }
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
            case .vibrance: vibrance
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
            case .vibrance: vibrance = v
            }
        }
    }
}

/// Must match `Layer2Uniforms` in `Layer2Kernel`'s source field for field and
/// in order. A `SIMD3<Float>` is 16 bytes in Swift as a `float3` is in Metal,
/// so each float after one starts a new 16 (the self-test pins every offset).
struct Layer2Uniforms: Equatable, Sendable {
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
    /// Encoded mid-grey (linear 0.18) in the space the values are in: the tone
    /// regions' pivot (the desktop's RFC-018 D1).
    var midGrey: Float = Layer2Uniforms.displayMidGrey
    var curvesActive: UInt32 = 0
    var enabled: UInt32 = 1
    // The host's own steps, after saturation (`Layer2Kernel`, step 5).
    /// Vibrance, −1…1; zero is not run.
    var vibrance: Float = 0
    /// Whether HSL and the channel mixer run at all: a neutral one leaves its input to the bit.
    var hslActive: UInt32 = 0
    var mixerActive: UInt32 = 0
    var pad: Float = 0
    /// HSL's eight colours in two rows of four (red, orange, yellow, green; aqua,
    /// blue, purple, magenta): the hue turn in radians, the saturation and the
    /// luminance as −1…1.
    var hslHue0 = SIMD4<Float>(repeating: 0)
    var hslHue1 = SIMD4<Float>(repeating: 0)
    var hslSat0 = SIMD4<Float>(repeating: 0)
    var hslSat1 = SIMD4<Float>(repeating: 0)
    var hslLum0 = SIMD4<Float>(repeating: 0)
    var hslLum1 = SIMD4<Float>(repeating: 0)
    /// The channel mixer's matrix, a row an output channel (the identity at rest).
    var mixR = SIMD3<Float>(1, 0, 0)
    var mixG = SIMD3<Float>(0, 1, 0)
    var mixB = SIMD3<Float>(0, 0, 1)

    /// `pow(0.18, 1/1.8)`: mid-grey through ROMM γ1.8, the desktop's working
    /// space, where its canvas grades.
    static let proPhotoMidGrey: Float = 0.3857
    /// `1.055·0.18^(1/2.4) − 0.055`: the same through an sRGB-like curve, which
    /// is Display P3's.
    static let srgbMidGrey: Float = 0.4614
    /// **The host's pivot.** The picture Layer 2 adjusts on the host is the
    /// develop as the page shows it and as the library keeps it — Display P3,
    /// encoded with the sRGB curve (`DevelopedPicture`, `OutputTransformer`) —
    /// not the engine's ProPhoto working space the desktop's canvas holds. The
    /// pivot follows the encoding (D1), so here it is P3's mid-grey: with the
    /// desktop's ROMM number the tone regions would split three-quarters of a
    /// stop low.
    static let displayMidGrey: Float = srgbMidGrey

    /// The tone block: white balance, exposure, contrast, brightness,
    /// highlights, shadows, the two points, saturation — the desktop's
    /// arithmetic, with the pivot named.
    static func tone(temperature: Double, tint: Double, exposure: Double, contrast: Double,
                     brightness: Double, saturation: Double, highlights: Double, shadows: Double,
                     blackPoint: Double, whitePoint: Double, midGrey: Float = displayMidGrey) -> Layer2Uniforms {
        var u = Layer2Uniforms()
        u.enabled = 1
        let t = Float(temperature) / 100, g = Float(tint) / 100
        u.wbGain = SIMD3<Float>(1 + 0.18 * t, 1 - 0.12 * g, 1 - 0.18 * t)
        u.exposureGain = Float(pow(2.0, exposure))
        u.contrast = Float(contrast) / 100
        u.brightness = Float(brightness) / 100
        u.saturation = 1 + Float(saturation) / 100
        u.highlights = Float(highlights) / 100
        u.shadows = Float(shadows) / 100
        u.blackPoint = Float(blackPoint) / 100
        u.whitePoint = Float(whitePoint) / 100
        u.midGrey = midGrey
        return u
    }
}
