//  AppBackground.swift — the page's ground chosen in Settings › Appearance (背景), one for Dark and one for
//  Light, and the grounds the other surfaces take from it.
//
//  "customizable background color only". The
//  ground is the page's colour (`Theme.background`); the panel, the card, the plot, the rule, the field, the
//  wall, the Latitude meter's outside and an off switch's track are **derived from it** (`Theme.ground`),
//  so the hierarchy still reads at any ground rather than fixed values that clash with it:
//  - each keeps the step in lightness it has from the default ground (OKLab L), and its tint relative
//    to the ground's (OKLab a, b), so a warm ground has warm cards and a blue-grey one blue-grey cards;
//  - a surface on the far side of the ground — darker in Dark (the panel, the wall), lighter in Light (the
//    plot) — keeps its *ratio* of the room left towards black or white instead, so at a black ground
//    the panel is black too, not a clipped negative;
//  - at the default ground every surface is its old value, to the bit (the derivation is not run).
//  Text, the accent, selection and the film's own colours do not follow: a chosen ground is kept on its
//  mode's side (`clamp`: Dark no lighter than OKLab L 0.45, Light no darker than 0.80), so the text keeps
//  its contrast.
//
//  Kept as `ui.background.dark` / `ui.background.light` ("#RRGGBB", absent for the default). The colour
//  providers read the chosen grounds from here (`chosen`) on whatever thread draws; a change bumps a trait
//  of every window (`AppGroundTrait`), which UIKit and SwiftUI take as a change of colour appearance, so
//  every page redraws at once, its state kept. An reference device never reads any of this (`Theme.tone`).

import SwiftUI
import UIKit
import os

enum AppBackground {
    static let darkKey = "ui.background.dark"
    static let lightKey = "ui.background.light"
    /// The default grounds: the Mac's and the window's dark blue-grey and its light (`Theme.background`).
    static let darkDefault: UInt32 = 0x1A1D22
    static let lightDefault: UInt32 = 0xE8EAED

    /// The ground for a mode: the chosen one, or the default.
    static func ground(light: Bool) -> UInt32 {
        let c = chosen.withLock { $0 }
        return (light ? c.light : c.dark) ?? (light ? lightDefault : darkDefault)
    }

    /// The picker's few grounds for a mode, its default first: Dark's black (the reference device's), a neutral
    /// graphite, a deeper blue and a warm brown; Light's near white, paper, a cool grey-blue and a mid grey.
    static func presets(light: Bool) -> [UInt32] {
        light ? [lightDefault, 0xF5F5F4, 0xEEEAE3, 0xE3E8EF, 0xD9DADB]
              : [darkDefault, 0x000000, 0x1C1C1E, 0x232A33, 0x241F1B]
    }

    /// Whether a mode's ground is the default.
    static func isDefault(light: Bool) -> Bool {
        let c = chosen.withLock { $0 }
        return (light ? c.light : c.dark) == nil
    }

    /// Chooses a mode's ground (`nil`: back to the default): kept on its mode's side, saved, and every
    /// window redrawn. Returns what was kept.
    @MainActor @discardableResult
    static func choose(_ hex: UInt32?, light: Bool, defaults: UserDefaults = .standard) -> UInt32? {
        let kept = hex.map { clamp($0, light: light) }.flatMap { $0 == (light ? lightDefault : darkDefault) ? nil : $0 }
        chosen.withLock { if light { $0.light = kept } else { $0.dark = kept } }
        let key = light ? lightKey : darkKey
        if let kept { defaults.set(hexString(kept), forKey: key) } else { defaults.removeObject(forKey: key) }
        redraw()
        return kept
    }

    /// Read again from `defaults` (a value written elsewhere: a drive step, a test's suite).
    @MainActor static func reload(_ defaults: UserDefaults = .standard) {
        let read = Grounds(defaults)
        guard read != chosen.withLock({ $0 }) else { return }
        chosen.withLock { $0 = read }
        redraw()
    }

    // MARK: the chosen grounds

    struct Grounds: Equatable {
        var dark: UInt32?
        var light: UInt32?
        init(dark: UInt32? = nil, light: UInt32? = nil) { self.dark = dark; self.light = light }
        init(_ defaults: UserDefaults) {
            dark = defaults.string(forKey: AppBackground.darkKey).flatMap(AppBackground.hex(from:))
            light = defaults.string(forKey: AppBackground.lightKey).flatMap(AppBackground.hex(from:))
        }
    }

    /// Read by the colour providers wherever they run; written on the main thread.
    static let chosen = OSAllocatedUnfairLock(initialState: Grounds(.standard))

    /// Every window's colours asked again: a new value of `AppGroundTrait` on each scene.
    @MainActor private static func redraw() {
        generation += 1
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.traitOverrides[AppGroundTrait.self] = generation
        }
    }
    @MainActor private static var generation = 0

    // MARK: hex

    /// "#1A1D22".
    static func hexString(_ v: UInt32) -> String { String(format: "#%06X", v & 0xFFFFFF) }

    /// "#1a1d22", "1A1D22" or "#abc" to a value; nil for anything else.
    static func hex(from text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }

    /// A `Color`'s sRGB value (what a colour picker hands back).
    static func hex(of color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let ui = UIColor(color)
        let srgb = ui.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        if let c = srgb?.components, c.count >= 3 { r = c[0]; g = c[1]; b = c[2] } else { ui.getRed(&r, green: &g, blue: &b, alpha: &a) }
        func byte(_ x: CGFloat) -> UInt32 { UInt32((min(max(x, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    // MARK: the derivation

    /// Dark's ground no lighter than this, Light's no darker (OKLab L): the text's contrast holds.
    static let darkMaxL = 0.45
    static let lightMinL = 0.80

    /// `hex` kept on its mode's side: its lightness brought within the mode's bound, its hue and chroma kept.
    static func clamp(_ hex: UInt32, light: Bool) -> UInt32 {
        var c = OKLab(hex)
        if light ? c.L >= lightMinL : c.L <= darkMaxL { return hex }
        c.L = light ? lightMinL : darkMaxL
        return c.hex
    }

    /// A surface's colour on the ground `ground`, from its value `token` on the default ground `standard`.
    static func derive(_ token: UInt32, standard: UInt32, ground: UInt32, light: Bool) -> UInt32 {
        guard ground != standard else { return token }
        let t = OKLab(token), b0 = OKLab(standard), b = OKLab(ground)
        let step = t.L - b0.L
        var out = OKLab(L: 0, a: b.a + (t.a - b0.a), b: b.b + (t.b - b0.b))
        if !light, step < 0 {
            out.L = b0.L > 0 ? b.L * t.L / b0.L : b.L               // darker in Dark: its share of the ground
        } else if light, step > 0 {
            out.L = 1 - (1 - b.L) * (1 - t.L) / max(1 - b0.L, 1e-6) // lighter in Light: its share of the room to white
        } else {
            out.L = b.L + step                                       // the step the default has
        }
        out.L = min(max(out.L, 0), 1)
        return out.hex
    }

    /// Björn Ottosson's OKLab, from and to sRGB.
    struct OKLab {
        var L: Double, a: Double, b: Double

        init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

        init(_ hex: UInt32) {
            func lin(_ v: UInt32) -> Double {
                let c = Double(v & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let r = lin(hex >> 16), g = lin(hex >> 8), bl = lin(hex)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
            L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
            a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        }

        var hex: UInt32 {
            let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
            let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
            let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
            let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
            func enc(_ c: Double) -> UInt32 {
                let x = min(max(c, 0), 1)
                let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
                return UInt32((v * 255).rounded())
            }
            return enc(r) << 16 | enc(g) << 8 | enc(bl)
        }
    }
}

/// A trait whose only job is to change when a ground is chosen: UIKit takes it as a change of colour
/// appearance and asks every dynamic colour again, SwiftUI's with them (`AppBackground.redraw`).
struct AppGroundTrait: UITraitDefinition {
    static let defaultValue = 0
    static let affectsColorAppearance = true
    static let name = "SpektraLabGround"
}
