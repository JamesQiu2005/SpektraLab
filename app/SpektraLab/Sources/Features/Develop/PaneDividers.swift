//  PaneDividers.swift — the develop page's shell on a Mac (the owner, 2026-10-24).
//
//  The owner's redesign of the develop page is "for mac and window": the column's header has one Crop where
//  the Library and Share were ("we don't need fast sharing"). The crop is made in the page, not on a page that pops up (`InlineCrop`), and the column and the
//  filmstrip are as wide and as tall as they are dragged (`PaneDividers`, `DividerGrip`), from today's
//  sizes up: "the current width should be the narrowest width".
//  Marked in place as "Mac change ".

import SwiftUI
import UIKit

/// A crop made in the develop page rather than on a page of its own (the owner: "we don't need another
/// page that pops up"): the column's controls are the crop's, and the crop is over the picture, until
/// Done or Cancel (`AppRouter.show`, `CropScreen(inline:)`). The crop page's own model, gestures and
/// controls; only where they stand differs.
struct InlineCrop: Equatable {
    let frameID: LibraryFrame.ID
    let target: CropTarget
    /// Counts the header's Crop pressed while the crop is open: each finishes it as Done does, as a
    /// tool left in Capture One or Photos keeps its crop.
    var finishes = 0
}

/// Where the inline crop's two parts stand in the develop page, which it covers whole: the controls in
/// the column under its header, the crop where the picture is.
struct CropPlacement: Equatable {
    /// The column, at the window's left.
    var columnWidth: CGFloat = 0
    /// The column's header, which stays: the controls start under it.
    var columnTop: CGFloat = 0
    /// The picture side's bar, which stays: the crop starts under it.
    var pictureTop: CGFloat = 0
}

// MARK: - the column's width and the filmstrip's height

/// The column's width and the filmstrip's height as the person dragged them, kept across launches.
/// Each is stored as dragged and fitted to the window where it is used, so a window made smaller and
/// larger again gives the width back. Written when a drag ends, not at every step of it.
@MainActor @Observable
final class PaneDividers {
    static let shared = PaneDividers()

    static let columnKey = "pad.columnWidth"
    static let filmstripKey = "pad.filmstripHeight"
    /// The narrowest column is today's, the host's width (`WindowLayout.columnWidth`).
    static let minColumn = WindowLayout.columnWidth
    /// The lowest filmstrip is today's (`BrowserFilmstrip.height`).
    static let minFilmstrip = BrowserFilmstrip.height
    /// The tallest filmstrip: tiles about three times today's, and never more than this share of the
    /// picture side, so the picture stays the page.
    static let maxFilmstrip: CGFloat = 240
    static let maxFilmstripShare: CGFloat = 0.4

    var columnWidth: CGFloat
    var filmstripHeight: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults`: the app's own; a check hands in a suite of its own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let column = defaults.double(forKey: Self.columnKey), strip = defaults.double(forKey: Self.filmstripKey)
        columnWidth = max(column > 0 ? CGFloat(column) : Self.minColumn, Self.minColumn)
        filmstripHeight = max(strip > 0 ? CGFloat(strip) : Self.minFilmstrip, Self.minFilmstrip)
    }

    /// The widths a column may take in a page `width` wide: from today's up to as wide as the picture
    /// side beside it — the picture is never the narrower of the two.
    static func columnRange(in width: CGFloat) -> ClosedRange<CGFloat> {
        minColumn...max(minColumn, ((width - 1) / 2).rounded(.down))
    }

    /// The column's width in a page `width` wide.
    func column(in width: CGFloat) -> CGFloat { columnWidth.clamped(to: Self.columnRange(in: width)) }

    /// The heights a filmstrip may take under a picture side `height` tall (its bar included).
    static func filmstripRange(in height: CGFloat) -> ClosedRange<CGFloat> {
        minFilmstrip...max(minFilmstrip, min(maxFilmstrip, (height * maxFilmstripShare).rounded(.down)))
    }

    /// The filmstrip's height under a picture side `height` tall.
    func filmstrip(in height: CGFloat) -> CGFloat { filmstripHeight.clamped(to: Self.filmstripRange(in: height)) }

    /// A drag ended: what it left is kept.
    func save() {
        defaults.set(Double(columnWidth), forKey: Self.columnKey)
        defaults.set(Double(filmstripHeight), forKey: Self.filmstripKey)
    }
}

/// The grip on a dividing line: 10 pt across it, drawn as nothing until the pointer is over it (then a
/// line, and on the Mac the resize cursor) or it is dragged. `grows`: +1 where a drag right or down makes
/// the value larger, −1 where left or up does. VoiceOver adjusts it in steps.
struct DividerGrip: View {
    enum Way { case sideways, upAndDown }
    let way: Way
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    let grows: CGFloat
    let label: String
    let set: (CGFloat) -> Void
    let ended: () -> Void

    @State private var base: CGFloat?
    @State private var hot = false

    static let reach: CGFloat = 10

    var body: some View {
        let sideways = way == .sideways
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                if hot || base != nil {
                    Rectangle().fill(Theme.dim.opacity(0.8))
                        .frame(width: sideways ? 3 : nil, height: sideways ? nil : 3)
                        .allowsHitTesting(false)
                }
            }
            // In the window's space: the grip moves with the line it drags.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = base ?? value
                    if base == nil { base = start }
                    let travel = sideways ? v.translation.width : v.translation.height
                    set((start + grows * travel).rounded().clamped(to: range))
                    MacCursor.resize(sideways: sideways)
                }
                .onEnded { _ in
                    base = nil
                    if !hot { MacCursor.arrow() }
                    ended()
                })
            .onContinuousHover { phase in
                switch phase {
                case .active: hot = true; MacCursor.resize(sideways: sideways)
                case .ended: hot = false; if base == nil { MacCursor.arrow() }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(String(Int(value)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set((value + 24).clamped(to: range))
                case .decrement: set((value - 24).clamped(to: range))
                @unknown default: return
                }
                ended()
            }
    }
}

/// The Mac's modifier keys as they are now, held or not, outside any event: AppKit's class property
/// `NSEvent.modifierFlags`, through the runtime as `MacCursor` reaches `NSCursor`. For a SwiftUI drag,
/// whose value carries no modifiers (the crop's ⌘-drag line, 2026-10-25). Nothing held on a window.
enum MacKeys {
    static var command: Bool { flags & (1 << 20) != 0 }        // NSEventModifierFlagCommand

    private static var flags: UInt {
        guard let cls: AnyClass = NSClassFromString("NSEvent"),
              let method = class_getClassMethod(cls, NSSelectorFromString("modifierFlags")) else { return 0 }
        typealias Get = @convention(c) (AnyClass, Selector) -> UInt
        return unsafeBitCast(method_getImplementation(method), to: Get.self)(cls, NSSelectorFromString("modifierFlags"))
    }
}

/// The Mac's resize cursors over a grip. UIKit has none (its pointer shapes are the window's), so AppKit's
/// own `NSCursor`, through the Objective-C runtime as `MacScrollMonitor` reaches `NSEvent`; set again at
/// every move of the pointer over the grip, since UIKit sets its own as the pointer moves. Nothing on a window.
enum MacCursor {
    static func resize(sideways: Bool) { set(sideways ? "resizeLeftRightCursor" : "resizeUpDownCursor") }
    static func arrow() { set("arrowCursor") }
    /// Over the Mac's colour wheel's disc (`MacColourWheel.swift`, 2026-10-24).
    static func crosshair() { set("crosshairCursor") }

    private static func set(_ name: String) {
        guard let cls = NSClassFromString("NSCursor") else { return }
        let sel = NSSelectorFromString(name)
        guard (cls as AnyObject).responds(to: sel),
              let cursor = (cls as AnyObject).perform(sel)?.takeUnretainedValue() else { return }
        _ = cursor.perform(NSSelectorFromString("set"))
    }
}
