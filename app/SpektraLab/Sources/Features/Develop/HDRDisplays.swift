//  HDRDisplays.swift — whether any screen of this Mac can show HDR: the gate every Enable HDR control is behind
//  (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D5).
//
//  "If it is on non-HDR machine we simply hide the HDR toggle throughout the app" (the owner, 2026-11-04). Read
//  once at launch, `UIScreen.main.potentialEDRHeadroom > 1.05` would not do: a Mac's screens are not one, and
//  not fixed: an XDR panel beside an SDR monitor, a display plugged in while the app runs. So
//  here the controls are shown while **any** attached screen's *potential* EDR headroom is over 1.05, and that
//  is read again whenever a screen changes (AppKit's `NSApplicationDidChangeScreenParametersNotification`, a
//  window moving to another display, a scene coming forward), never latched at launch.
//
//  - **Which reading** (both logged — the `hdr screens` line): Catalyst's `UIScreen` is one screen, the main one,
//    and `potentialEDRHeadroom` is UIKit's word for it; AppKit's `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue`
//    is each screen's, reached through the runtime as `MacDisplay` reaches `NSWindow.screen` (Catalyst links
//    AppKit, its headers are not ours). Measured 2026-11-06 on this Mac's built-in XDR panel (a debug build,
//    nothing else attached): both say a potential of 16 and a present 1 (EDR not yet on). They agree on one
//    screen; only AppKit can name the others, so the gate takes AppKit's where it can be read, UIKit's otherwise.
//    Two screens (the LG HDR 5K, an SDR monitor) were not measured.
//  - **What it gates** (`FeatureFlags.screenShowsHDR`, which it sets): the switch under Apply Film Emulation, the
//    paste group, Settings' *Enable HDR by Default*, and every page's HDR picture (`HDRLook.of`). **Not a file's
//    map** (`HDRGainMap.supported`: the system's gate): an export is the same file whichever screen the window
//    was on (D5). A frame's own choice is kept while the controls are hidden.
//  - The canvas's strength is not this: it is the window's own screen's headroom (`HDRScreen`).
//
//  A debug build's `--hdr-screen none` hides HDR on any screen; `--hdr-headroom <x>` makes every screen report
//  `x`, so an SDR display can draw the HDR path.

import Foundation
import Observation
import ObjectiveC
import UIKit

@MainActor @Observable
final class HDRDisplays {
    static let shared = HDRDisplays()

    /// One screen as it was read: its name, its potential and its present EDR headroom (1 = SDR white), and who said.
    struct Reading: Equatable {
        var name: String
        var potential: Double
        var current: Double
        var by: String
    }

    /// Whether the HDR controls are shown: any screen's potential headroom over `threshold`.
    private(set) var showsHDR = false
    private(set) var screens: [Reading] = []
    /// The line: a panel that can go 5 % over SDR white is an HDR screen.
    static let threshold = 1.05

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastSaid = ""

    private init() {}

    /// Read now, and again on every screen change from here on. Called once at launch (`AppServices`).
    func start() {
        guard observers.isEmpty else { read(); return }
        read()
        // UIKit's screen notifications are deprecated for scenes: a scene coming forward, and on the Mac AppKit's own.
        var names = [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification]
        #if targetEnvironment(macCatalyst)
        names += ["NSApplicationDidChangeScreenParametersNotification", "NSWindowDidChangeScreenNotification"].map { Notification.Name($0) }
        #endif
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HDRDisplays.shared.read() }
            }
        }
    }

    /// A debug build's forced headroom (`--hdr-headroom <x>`), every screen's.
    static let forced: Double? = {
        #if DEBUG
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--hdr-headroom"), i + 1 < a.count, let v = Double(a[i + 1]), v >= 1 else { return nil }
        return v
        #else
        return nil
        #endif
    }()

    /// A debug build's `--hdr-screen none`.
    static let hiddenByArgument: Bool = {
        #if DEBUG
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--hdr-screen"), i + 1 < a.count else { return false }
        return a[i + 1] == "none"
        #else
        return false
        #endif
    }()

    func read() {
        var found: [Reading] = []
        #if targetEnvironment(macCatalyst)
        found = Self.appKitScreens()
        #endif
        let ui = UIScreen.main
        let uiReading = Reading(name: "UIScreen.main", potential: max(1, Double(ui.potentialEDRHeadroom)),
                                current: max(1, Double(ui.currentEDRHeadroom)), by: "UIKit")
        if found.isEmpty { found = [uiReading] }
        if let f = Self.forced { found = found.map { Reading(name: $0.name, potential: f, current: f, by: $0.by + " forced") } }
        screens = found
        let shows = !Self.hiddenByArgument && found.contains { $0.potential > Self.threshold }
        if shows != showsHDR { showsHDR = shows }
        FeatureFlags.screenShowsHDR = shows
        // One line a change of what the screens say (both readings: the D5 measurement of which one works).
        let sig = found.map { "\($0.name) \($0.potential)" }.joined(separator: "|") + "|\(uiReading.potential)|\(shows)"
        guard sig != lastSaid else { return }
        lastSaid = sig
        Log.note(.develop, "hdr screens", [
            "shows_hdr": shows,
            "screens": found.map { ["name": $0.name, "potential": $0.potential, "current": $0.current, "by": $0.by] },
            "uikit_main_potential": uiReading.potential, "uikit_main_current": uiReading.current,
            "forced": Self.forced ?? 0, "hidden": Self.hiddenByArgument])
    }

    #if targetEnvironment(macCatalyst)
    /// Every screen AppKit knows (`NSScreen.screens`), with its EDR headroom, potential and now.
    static func appKitScreens() -> [Reading] {
        guard let cls: AnyClass = NSClassFromString("NSScreen"),
              let all = (cls as AnyObject).value(forKey: "screens") as? [NSObject] else { return [] }
        return all.map(reading)
    }

    /// One AppKit screen's reading (`NSScreen`), as `MacDisplay` reaches it.
    static func reading(_ screen: NSObject) -> Reading {
        func value(_ key: String) -> Double {
            guard screen.responds(to: NSSelectorFromString(key)) else { return 1 }
            return max(1, (screen.value(forKey: key) as? NSNumber)?.doubleValue ?? 1)
        }
        return Reading(name: (screen.value(forKey: "localizedName") as? String) ?? "screen",
                       potential: value("maximumPotentialExtendedDynamicRangeColorComponentValue"),
                       current: value("maximumExtendedDynamicRangeColorComponentValue"), by: "AppKit")
    }

    /// The screen `window` is on, as AppKit says (`MacDisplay.nsWindow`): nil where it cannot be reached.
    static func reading(for window: UIWindow) -> Reading? {
        guard let ns = MacDisplay.nsWindow(for: window), let screen = ns.value(forKey: "screen") as? NSObject else { return nil }
        var r = reading(screen)
        if let f = forced { r.potential = f; r.current = f; r.by += " forced" }
        return r
    }
    #endif
}
