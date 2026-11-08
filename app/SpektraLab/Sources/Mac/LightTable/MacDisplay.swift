//  MacDisplay.swift — the display a Mac window is on, as Actual Size needs it (2026-10-24).
//
//  The owner: "A 1:1 size replication should be there as well, but this should take inspiration from how
//  Xcode reads the display and resolution information and handles the 1:1." Xcode's Simulator, at *Physical
//  Size*, draws a device at its real millimetres on whatever display its window is on, from what that
//  display says of itself. So does the table (`MacActualSize`, `LightTableMacMath.swift`):
//
//  - **Which display**: the window's own (`NSWindow.screen`, reached through the Objective-C runtime as
//    `MacScrollZoom.swift` reaches `NSEvent`: Catalyst links AppKit but its headers are not ours), its
//    `NSScreenNumber` the CoreGraphics display. The NSWindow is the one whose content is the UIWindow's
//    size at the window's own scale, the key one first.
//  - **Its size and its mode**, from CoreGraphics, which Catalyst links: `CGDisplayScreenSize` (the panel's
//    millimetres, from its EDID) and `CGDisplayCopyDisplayMode` (the mode's points and its backing pixels).
//    Measured here, 2026-10-24: display 3, an LG HDR 5K, 797.84 × 330.51 mm, 2,560 × 1,080 points over 5,120 × 2,160 pixels (163 ppi).
//  - **The window's own scale**: Mac points a scene point, the NSWindow's content width over the UIWindow's
//    (0.77 under "scaled Catalyst mode", measured, not assumed; `MacMetric.scale` where it cannot be).
//  - Read again when the window moves to another display or a display changes its mode (AppKit's
//    `NSWindowDidChangeScreenNotification`, `NSApplicationDidChangeScreenParametersNotification`), so 1:1
//    stays 1:1 on the display the window is on now.
//
//  No display size is assumed when this reading is unavailable: Actual Size is then disabled.

import CoreGraphics
import ObjectiveC
import UIKit

@MainActor
enum MacDisplay {
    /// The reading for the display `window` is on, or nil where AppKit cannot be reached.
    /// Why the last reading had none (the check's report).
    private(set) static var problem: String?

    static func reading(for window: UIWindow?) -> MacDisplayReading? {
        guard let window, window.bounds.width > 0 else { problem = "no window"; return nil }
        guard let ns = nsWindow(for: window) else { problem = "no AppKit window for \(window.bounds.size): \(nsWindows())"; return nil }
        guard let screen = ns.value(forKey: "screen") as? NSObject,
              let description = screen.value(forKey: "deviceDescription") as? [AnyHashable: Any],
              let number = description["NSScreenNumber"] as? NSNumber else { problem = "no screen number"; return nil }
        let display = CGDirectDisplayID(number.uint32Value)
        let mm = CGDisplayScreenSize(display)
        guard let mode = CGDisplayCopyDisplayMode(display) else { problem = "no display mode"; return nil }
        problem = nil
        // Across: the content's height leaves out the title bar's band, its width does not.
        let content = (ns.value(forKey: "contentLayoutRect") as? NSValue)?.cgRectValue ?? .zero
        let measured = content.width > 0 ? Double(content.width / window.bounds.width) : 0
        // A measure off by more than a few per cent (a window caught mid-resize) is not the scale.
        let macPerScene = measured > 0 && abs(measured / Double(MacMetric.scale) - 1) < 0.05 ? measured : Double(MacMetric.scale)
        return MacDisplayReading(
            displayID: display,
            name: (screen.value(forKey: "localizedName") as? String) ?? "display \(display)",
            builtin: CGDisplayIsBuiltin(display) != 0,
            millimetres: mm,
            points: CGSize(width: mode.width, height: mode.height),
            pixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
            macPointsPerScenePoint: macPerScene,
            drawableScale: Double(window.screen.scale))
    }

    /// Scene points a millimetre on the display `window` is on; nil where it does not know its size.
    static func pointsPerMM(for window: UIWindow?) -> Double? {
        reading(for: window).flatMap(MacActualSize.scenePointsPerMM)
    }

    /// The AppKit window that shows `window`: of the app's visible windows, one whose content is `window`'s
    /// width at Catalyst's scale (its height leaves out the title bar: measured, 1,024 × 736 Mac points for a
    /// 1,330 × 998 scene, 2026-10-24); the key one if several are.
    static func nsWindow(for window: UIWindow) -> NSObject? {
        guard let cls: AnyClass = NSClassFromString("NSApplication"),
              let app = (cls as AnyObject).value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        let size = window.bounds.size
        let matching = windows.filter { w in
            guard (w.value(forKey: "isVisible") as? Bool) == true,
                  let r = (w.value(forKey: "contentLayoutRect") as? NSValue)?.cgRectValue, r.width > 0, size.width > 0 else { return false }
            let kx = Double(r.width / size.width), ky = Double(r.height / size.height)
            return abs(kx / Double(MacMetric.scale) - 1) < 0.05 && ky <= kx + 0.01
        }
        return matching.first { ($0.value(forKey: "isKeyWindow") as? Bool) == true } ?? matching.first
    }

    /// The AppKit window's number, its frame on the screen and its content's place in it (Mac points, y up), for
    /// a check's capture of the window as the display shows it.
    static func windowFacts(for window: UIWindow) -> (number: Int, frame: CGRect, content: CGRect, backing: Double)? {
        guard let ns = nsWindow(for: window),
              let number = (ns.value(forKey: "windowNumber") as? NSNumber)?.intValue,
              let frame = (ns.value(forKey: "frame") as? NSValue)?.cgRectValue,
              let content = (ns.value(forKey: "contentLayoutRect") as? NSValue)?.cgRectValue,
              let backing = (ns.value(forKey: "backingScaleFactor") as? NSNumber)?.doubleValue else { return nil }
        return (number, frame, content, backing)
    }

    /// The app's AppKit windows, as found: their class, whether shown, their content's size.
    static func nsWindows() -> [String] {
        guard let cls: AnyClass = NSClassFromString("NSApplication"),
              let app = (cls as AnyObject).value(forKey: "sharedApplication") as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return ["no NSApplication"] }
        return windows.map { w in
            let r = (w.value(forKey: "contentLayoutRect") as? NSValue)?.cgRectValue ?? .zero
            return "\(type(of: w)) visible \(String(describing: w.value(forKey: "isVisible"))) \(r.size)"
        }
    }

    /// AppKit's own news of a window on another display, or a display changed: `changed` is called on the main actor.
    static func watch(_ changed: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        ["NSWindowDidChangeScreenNotification", "NSApplicationDidChangeScreenParametersNotification",
         "NSWindowDidChangeBackingPropertiesNotification"].map { name in
            NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed() }
            }
        }
    }
}
