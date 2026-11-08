//  LightTableMacMath.swift — the Mac's Light Table arithmetic, with no UIKit (2026-10-24).
//
//  Two things the Mac page needs that a test can hold without a window or a GPU
//  (`tools/lighttable_selftest.swift`):
//
//  - **Actual Size from the display's own size** (`MacActualSize`), the way Xcode's Simulator does its
//    *Physical Size*: the display says its size in millimetres (`CGDisplayScreenSize`, from its EDID) and
//    its mode says its size in points (`CGDisplayModeGetWidth`), so a Mac point is so many millimetres on
//    this display whatever its scaled resolution ("looks like 1,512 × 982" or "more space"); the window
//    under "scaled Catalyst mode" draws a scene point at 0.77 of a Mac point. Scene points a millimetre =
//    (mode points ÷ panel millimetres) ÷ Mac points a scene point. Read along the panel's long side, the
//    side whose millimetres the EDID rounds least. **A display that does not know its size has no 1:1**
//    (a projector, a capture card, an EDID of 0 mm, axes that disagree by more than 5 %): as on the window,
//    no size is claimed that is not known (`MacDisplay.swift`).
//  - **The rail's films** (`LightTableRail`): every film on the table, in the order it was first laid on it
//    (stable: choosing a film brings it to the top of the pile, and must not move its tile), each tile the
//    film as it lies — its picture turned by the film's own angle and fitted, turned, in the tile's box.
//
//  The window's side (which display, its mode, the window's own scale) is `Sources/Mac/LightTable/MacDisplay.swift`.

import CoreGraphics
import Foundation

/// What the Mac knows of the display a window is on.
struct MacDisplayReading: Equatable, Sendable {
    var displayID: UInt32
    var name: String
    var builtin: Bool
    /// The panel's size, mm (`CGDisplayScreenSize`).
    var millimetres: CGSize
    /// The display mode, in Mac points (`CGDisplayModeGetWidth`/`Height`) and in its backing store's pixels.
    var points: CGSize
    var pixels: CGSize
    /// The window's Mac points per scene point: 0.77 under "scaled Catalyst mode", measured from the window.
    var macPointsPerScenePoint: Double
    /// The drawable's pixels per scene point (the window's screen scale).
    var drawableScale: Double
}

enum MacActualSize {
    /// Mac points a millimetre on a display whose mode is `points` and whose panel is `millimetres`; nil where
    /// the display does not know its size. The millimetres are turned to the mode's way up first (a display
    /// turned in System Settings keeps its EDID's way).
    static func macPointsPerMM(points: CGSize, millimetres: CGSize) -> Double? {
        guard points.width > 0, points.height > 0 else { return nil }
        var mm = millimetres
        if (points.width >= points.height) != (mm.width >= mm.height) { mm = CGSize(width: mm.height, height: mm.width) }
        guard mm.width >= 20, mm.height >= 20 else { return nil }
        let x = Double(points.width / mm.width), y = Double(points.height / mm.height)
        // Pixels are square: a size whose two axes disagree is not a real size.
        guard abs(x / y - 1) <= 0.05 else { return nil }
        let long = points.width >= points.height ? x : y
        // From a 100-inch projector (0.25 pt a mm) to a host's panel (20): anything outside is a bad EDID.
        guard long > 0.25, long < 20 else { return nil }
        return long
    }

    /// Scene points a millimetre: what the table's zoom is set to at Actual Size.
    static func scenePointsPerMM(_ r: MacDisplayReading) -> Double? {
        guard r.macPointsPerScenePoint > 0, let k = macPointsPerMM(points: r.points, millimetres: r.millimetres) else { return nil }
        return k / r.macPointsPerScenePoint
    }

    /// The display's backing pixels a millimetre (its "resolution" as the system draws it).
    static func pixelsPerMM(_ r: MacDisplayReading) -> Double? {
        guard let k = macPointsPerMM(points: r.points, millimetres: r.millimetres), r.points.width > 0 else { return nil }
        return k * Double(r.pixels.width / r.points.width)
    }

    /// Millimetres on the display that `drawablePixels` of the window's drawable cover: the check's way back
    /// from a measured picture to the glass.
    static func millimetres(drawablePixels px: Double, _ r: MacDisplayReading) -> Double? {
        guard r.drawableScale > 0, let k = macPointsPerMM(points: r.points, millimetres: r.millimetres) else { return nil }
        return px / r.drawableScale * r.macPointsPerScenePoint / k
    }
}

/// The rail of films at the right of the Mac's Light Table.
enum LightTableRail {
    /// The films on the table, in the order each was first laid on it.
    static func order(_ m: LightTableModel) -> [UUID] { m.items.filter(\.on).map(\.id) }

    /// A film's tile: its picture's size, unturned (`picture`, points), so that turned by `angle` (clockwise on
    /// the screen, radians: the table turns counter-clockwise) the film fits `box` whole; and the turned film's
    /// own box (`extent`), which is the tile's height.
    static func tile(_ it: LightTableItem, box: CGSize) -> (picture: CGSize, angle: Double, extent: CGSize) {
        let e = it.extent
        let k = min(Double(box.width) / max(Double(e.width), 1e-6), Double(box.height) / max(Double(e.height), 1e-6))
        return (CGSize(width: it.w * k, height: it.h * k), -it.rot, CGSize(width: Double(e.width) * k, height: Double(e.height) * k))
    }
}
