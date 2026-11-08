//  EditTool.swift — the page's two surfaces, Edit's tools, and a visit's clock.
//
//  design/v5 §1: one frame, one edit record, two surfaces — `Develop | Edit`
//  in the top bar. Since 2026-10-19 Edit's band has three tools where it had
//  five: Adjust · EngineRouter · Crop. Adjust (调整) is Layer 2 (`Adjustments`),
//  live on the finished print, laid out as Litti's flow (the owner: "a full
//  mimic of Litti's UX flow … kept in the existing UI"): a strip of tiles, each
//  a control, and a tile opens its control in place of the strip with its own
//  bar — 🗑 the tool back to zero, ↶ Undo, its name, ✓ back to the strip.
//  EngineRouter is the engine's own controls, each a job, arranged as Adjust is
//  since 2026-10-22 — three tiles, Enlarger · Decode · Effects (`DarkroomPage`);
//  Crop is today's page. Those two stay in the band beside Adjust rather than
//  becoming its tiles: they are not live.
//
//  No UIKit: `tools/layer2_selftest.swift` compiles this.

import Foundation

/// Which surface the develop page shows (`OpenFrameSession.surface`).
enum DevelopSurface: String, CaseIterable, Codable, Sendable, Identifiable {
    case develop, edit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .develop: L("Develop")
        case .edit: L("Edit")
        }
    }
}

/// Edit's tools, in the band's order.
enum EditTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case adjust, darkroom, crop
    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: L("Adjust")
        case .darkroom: L("Darkroom")
        case .crop: L("Crop")
        }
    }

    /// Whether moving its controls is live (no job) or a develop (design/v5 §3.1).
    var isLive: Bool { self == .adjust }
}

/// Adjust's tiles, in the strip's order: Litti's list (亮度 对比度 色调 HSL 通道
/// 色轮 鲜艳度 饱和度 色温 曲线, without its 褪色), then Vignette, which Layer 2
/// had and Litti's list has not. Each is a part of `Adjustments`: what it holds
/// is `isNeutral(in:)`, and its 🗑 is `reset(_:)`.
enum AdjustTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case brightness, contrast, tone, hsl, channel, wheels, vibrance, saturation, temperature, curve, vignette
    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightness: L("Brightness")
        case .contrast: L("Contrast")
        case .tone: L("Tone")
        case .hsl: "HSL"
        case .channel: L("Channels")
        case .wheels: L("Colour Wheels")
        case .vibrance: L("Vibrance")
        case .saturation: L("Saturation")
        case .temperature: L("Temperature")
        case .curve: L("Curve")
        case .vignette: L("Vignette")
        }
    }

    /// The tile's glyph: Apple's own symbol where one says it.
    var symbol: String {
        switch self {
        case .brightness: "sun.max"
        case .contrast: "circle.lefthalf.filled"
        case .tone: "circle.lefthalf.striped.horizontal"
        case .hsl: "paintpalette"
        case .channel: "line.3.horizontal.decrease"
        case .wheels: "circle.grid.3x3"
        case .vibrance: "drop.halffull"
        case .saturation: "rainbow"
        case .temperature: "thermometer.medium"
        case .curve: "point.topleft.down.to.point.bottomright.curvepath"
        case .vignette: "circle.dashed.inset.filled"
        }
    }

    /// The group of Layer 2 it is part of: Copy Settings', the log's and the status line's word.
    var group: Adjustments.Tool {
        switch self {
        case .brightness, .contrast, .tone, .vignette: .light
        case .curve: .curve
        case .hsl, .channel, .wheels, .vibrance, .saturation, .temperature: .colour
        }
    }

    /// The sliders it shows; HSL, the channel mixer, the wheels and the curve
    /// draw their own. Exposure sits beside Brightness: Litti has no Exposure,
    /// and Layer 2 had it.
    var controls: [Layer2Control] {
        switch self {
        case .brightness: [.brightness, .exposure]
        case .contrast: [.contrast]
        case .tone: [.highlights, .shadows, .whites, .blacks]
        case .vibrance: [.vibrance]
        case .saturation: [.saturation]
        case .temperature: [.temperature, .tint]
        case .vignette: [.vignette, .vignetteMidpoint]
        case .hsl, .channel, .wheels, .curve: []
        }
    }

    /// Whether it applies nothing to `a`.
    func isNeutral(in a: Adjustments) -> Bool {
        switch self {
        case .hsl: a.hsl.isNeutral
        case .channel: a.channelMixer.isNeutral
        case .wheels: a.colorBalance.isNeutral
        case .curve: a.curves.isIdentity
        case .vignette: a.vignette.isNeutral
        default: controls.allSatisfy { !$0.isMoved(in: a) }
        }
    }

    /// Whether its 🗑 would change anything: a vignette's midpoint alone draws
    /// nothing, and is still the tool's to put back.
    func isAtRest(in a: Adjustments) -> Bool {
        var b = a
        reset(&b)
        return b == a
    }

    /// The tool's 🗑: everything it holds back to rest, the rest of the layer as it is.
    func reset(_ a: inout Adjustments) {
        switch self {
        case .hsl: a.hsl = HSLSet()
        case .channel: a.channelMixer = ChannelMixer()
        case .wheels: a.colorBalance = ColorBalance()
        case .curve: a.curves = CurveSet()
        case .vignette: a.vignette = Vignette()
        default: for control in controls { a[control] = control.rest }
        }
    }
}

/// The Colour Wheels' pad: a square of 11 × 11 dots, its centre no change. A
/// direction is a hue (red to the right, yellow up and to the right, as the
/// shader's circle turns), and the ring a dot is on — its distance out, as a
/// square counts it — is how strong: (ring / 5)², so the inner rings are fine
/// steps and the edge is the colour balance's full strength.
enum ColourPad {
    static let rings = 5

    /// The zone a dot sets: `x` to the right, `y` up, each −5…5. The zone's
    /// luminance is its own slider's, and is kept.
    static func zone(x: Int, y: Int, keeping luminance: Double = 0) -> ColorZone {
        let ring = max(abs(x), abs(y))
        guard ring > 0 else { return ColorZone(hue: 0, saturation: 0, luminance: luminance) }
        var hue = atan2(Double(y), Double(x)) * 180 / .pi
        if hue < 0 { hue += 360 }
        let s = Double(ring) / Double(rings)
        return ColorZone(hue: hue, saturation: s * s, luminance: luminance)
    }

    /// Where a zone's knob sits, in dots from the centre (x right, y up). Not
    /// on a dot unless a dot set it: an edit from the old wheel shows where it
    /// is, and moves only when a finger moves it.
    static func position(of zone: ColorZone) -> (x: Double, y: Double) {
        guard zone.saturation > 0 else { return (0, 0) }
        let ring = Double(rings) * min(zone.saturation, 1).squareRoot()
        let a = zone.hue * .pi / 180
        let cx = cos(a), cy = sin(a)
        let m = max(abs(cx), abs(cy))
        return (cx / m * ring, cy / m * ring)
    }

    /// The dot nearest a point given in dots from the centre (x right, y up), held to the pad.
    static func snap(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
        (min(max(Int(x.rounded()), -rings), rings), min(max(Int(y.rounded()), -rings), rings))
    }
}

/// How long a visit to the develop page has spent on each surface, for its
/// line in the log (`Log.developVisit`): the surface it is on, since when, and
/// what the surfaces it left took.
struct SurfaceClock: Equatable, Sendable {
    private(set) var surface: DevelopSurface
    private var since: Date
    private var spent: [DevelopSurface: Double] = [:]

    init(on surface: DevelopSurface, at date: Date) {
        self.surface = surface
        since = date
    }

    /// The page shows `next` from `date` on. The same surface again is no change.
    mutating func show(_ next: DevelopSurface, at date: Date) {
        guard next != surface else { return }
        spent[surface, default: 0] += max(0, date.timeIntervalSince(since))
        surface = next
        since = date
    }

    /// Seconds on each surface, the one it is on counted to `date`.
    func seconds(at date: Date) -> [DevelopSurface: Double] {
        var out = spent
        out[surface, default: 0] += max(0, date.timeIntervalSince(since))
        return out
    }

    /// As the log writes it: every surface by name, to a tenth of a second.
    func logged(at date: Date) -> [String: Double] {
        let s = seconds(at: date)
        return Dictionary(uniqueKeysWithValues: DevelopSurface.allCases.map { ($0.rawValue, ((s[$0] ?? 0) * 10).rounded() / 10) })
    }
}

/// Page-session navigation only. No photograph settings or cross-launch defaults.
enum DevelopStep: String, CaseIterable, Identifiable, Sendable {
    case filmAndPaper, format
    var id: String { rawValue }
    var title: String { self == .filmAndPaper ? L("Film & Paper") : L("Format", as: "the develop tab") }
}

/// Edit › EngineRouter's tiles, in the strip's order. **Arranged as Adjust is** (the
/// owner, 2026-10-22: "The way 暗房 is arranged is officially gonna be the same as
/// that in 调整"): a strip of tiles, a tile's controls in the strip's place, and
/// its bar — 🗑 · ↶ · its name · ✓ — in the page's bar's place. Three tiles where
/// there were four rows, and two since 2026-10-24, when Decode moved to Develop ›
/// Film & Paper with Film Exposure and its own curve, in place of Scene Placement
/// (`DecodeSection`):
///
/// - **Enlarger** as it was: the papers, Colour · Brightness · Pre-flash. Pre-flash
///   has no tile of its own (the owner, 2026-10-20: "The preflash or 预闪 should be
///   deleted in darkroom, and rests all in the enlarger").
/// - **Decode**: White Balance, and **Scene Placement**, moved in from a row of its
///   own — the decode is where what is solved before the film goes (the owner: "with
///   future pre-calculation effects other than scene placement also placed here").
/// - **Effects**: Grain · Halation · Glare · Couplers, as pro-control's Effects has
///   them, without Scene Placement.
///
/// Each one's parameters, ranges and Copy Settings groups are as they were; a
/// tile's 🗑 is its `scopes`, every one of them, as one step of the page's Undo.
enum DarkroomPage: String, CaseIterable, Identifiable, Sendable {
    case enlarger, effects
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enlarger: L("Enlarger")
        case .effects: L("Effects")
        }
    }

    /// The tile's glyph, Apple's own: an enlarger is a lamp head over its baseboard;
    /// the decode is the camera's file; the effects are what the materials add.
    var symbol: String {
        switch self {
        case .enlarger: "lamp.desk"
        case .effects: "sparkles"
        }
    }

    /// What the tile's 🗑 puts back, and what its dot says is moved.
    var scopes: [PageResetScope] {
        switch self {
        case .enlarger: [.enlarger, .preflash]
        case .effects: [.effects]
        }
    }
}

struct DevelopPageNavigation: Equatable, Sendable {
    var surface: DevelopSurface = .develop
    var step: DevelopStep = .filmAndPaper
    // The first Edit tool; remembered for this page session.
    var tool: EditTool = .adjust
    var panelFolded = false
    /// The EngineRouter tile open in place of its strip; nil shows the strip.
    var darkroom: DarkroomPage?
    /// The Adjust tile open in place of the strip; nil shows the strip.
    var adjust: AdjustTool?
    /// Film & Paper's Decode: the part its chips show (`DecodeSection`).
    var decodeTool: DecodeTool = .exposure

    static func isAvailable(_ tool: EditTool) -> Bool { true }

    mutating func show(_ surface: DevelopSurface) {
        self.surface = surface
        // Keep the step, tool, nested destination and fold through a switch.
    }
    mutating func select(_ step: DevelopStep) {
        if surface == .develop, self.step == step { panelFolded.toggle() }
        else { self.step = step; panelFolded = false }
    }
    mutating func select(_ tool: EditTool) {
        guard Self.isAvailable(tool) else { return }
        // Adjust or EngineRouter again with a tile open is back to its strip, as a tab
        // bar's tab tapped again goes back to its root; on the strip it folds, as every tool does.
        if surface == .edit, self.tool == tool, tool == .adjust, adjust != nil { adjust = nil; panelFolded = false }
        else if surface == .edit, self.tool == tool, tool == .darkroom, darkroom != nil { darkroom = nil; panelFolded = false }
        else if surface == .edit, self.tool == tool { panelFolded.toggle() }
        else { self.tool = tool; panelFolded = false }
    }
    /// A EngineRouter tile tapped: its controls in place of the strip, the panel unfolded.
    mutating func open(_ page: DarkroomPage) {
        tool = .darkroom
        darkroom = page
        panelFolded = false
    }
    /// The EngineRouter tile's ✓: back to its strip.
    mutating func closeDarkroom() { darkroom = nil }
    /// A tile tapped: its control in place of the strip, the panel unfolded.
    mutating func open(_ tool: AdjustTool) {
        self.tool = .adjust
        adjust = tool
        panelFolded = false
    }
    /// ✓: back to the strip.
    mutating func closeAdjust() { adjust = nil }
}

/// Decode's three parts, in its chips' order.
enum DecodeTool: String, CaseIterable, Identifiable, Sendable {
    case exposure, whiteBalance, curve
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposure: L("Exposure")
        case .whiteBalance: L("White Balance")
        case .curve: L("Curve")
        }
    }
    /// What its ↺ puts back.
    var scope: PageResetScope {
        switch self {
        case .exposure: .filmExposure
        case .whiteBalance: .decode
        case .curve: .sceneCurve
        }
    }
    /// The film's own: nothing to move with Apply Film Emulation off.
    var isFilms: Bool { self != .whiteBalance }
}
