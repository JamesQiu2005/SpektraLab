//  SpkIcon.swift — the interface's glyphs, by what they mean.
//
//  The drawings draw their own stroke icons (`gen.py` and `gen_flow.py`,
//  `ic_*`: 1.6 pt strokes in a 22 pt box), and the app draws those same
//  strokes: `tools/gen_icons.py` runs the drawings' functions and writes their
//  geometry to `DrawnIcons.swift`, so a glyph here is the drawing's own and
//  not a system symbol that resembles it. A glyph the drawings never drew
//  (`warning`, and the front camera's turn, which is the Camera app's own)
//  falls back to its SF Symbol, and so does the camera: the owner's word of
//  2026-10-17 is that the light table's camera, the system's `camera`, is the
//  one camera in the app, so the drawings' own is no longer drawn.
//
//  One list, so both halves of the app show the same glyph for the same thing.
//  A glyph is decoration next to a word or inside a labelled button: it is
//  hidden from VoiceOver, and the control that holds it carries the name.

import SwiftUI

enum SpkIcon: String {
    // navigation and chrome
    case back = "chevron.left"
    case chevron = "chevron.right"
    case chevronDown = "chevron.down"
    case close = "xmark"
    /// Three dots in a row: the library's menu.
    case more = "ellipsis"
    /// Three dots in a column.
    case moreVertical = "ellipsis.vertical"
    /// The check on a picked tile.
    case check = "checkmark"
    /// The check in a ticked box.
    case tick = "checkmark.square"
    /// The check beside a chosen menu row.
    case menuCheck = "checkmark.circle"
    /// The check on a finished stage, in Exporting.
    case stepCheck = "checkmark.circle.fill"
    case search = "magnifyingglass"
    // library and frame actions
    case camera = "camera"
    case importPhotos = "photo.badge.plus"
    case share = "square.and.arrow.up"
    case info = "info.circle"
    case copy = "square.on.square"
    case paste = "doc.on.clipboard"
    case heart = "heart"
    case heartFilled = "heart.fill"
    case trash = "trash"
    case reset = "arrow.counterclockwise"
    case gear = "gearshape"
    case grid = "square.grid.3x3"
    case develop = "slider.horizontal.3"
    /// Two half frames on one piece of film: the half-frame pair (design/pair v2).
    case pair = "rectangle.split.2x1"
    case compare = "square.righthalf.filled"
    case stop = "stop.fill"
    // sources
    case photos = "photo.on.rectangle"
    case folder = "folder"
    case folderLink = "folder.badge.plus"
    case copyIn = "square.and.arrow.down.on.square"
    case save = "square.and.arrow.down"
    case disk = "externaldrive"
    case diskOff = "externaldrive.badge.xmark"
    case cloud = "icloud"
    case alert = "exclamationmark.circle"
    /// The same, as a library tile's badge draws it.
    case alertSmall = "exclamationmark.circle.fill"
    case warning = "exclamationmark.triangle"
    // shoot
    case flashOff = "bolt.slash"
    case flashOn = "bolt"
    case flipCamera = "arrow.triangle.2.circlepath"
    case focus = "viewfinder"
    case aperture = "camera.aperture"
    case temperature = "thermometer.medium"
    case loupe = "plus.magnifyingglass"
    case wbCloud = "cloud"
    case wbSun = "sun.max"
    case wbFluorescent = "light.strip.2"
    case wbBulb = "lightbulb"
    // frame
    case crop = "crop"
    case rotate = "rotate.left"
    case flip = "arrow.left.and.right.righttriangle.left.righttriangle.right"
    case orientation = "rectangle.portrait.rotate"
    /// Film Edge: a frame between two rows of holes.
    case filmEdge = "film"

    /// The drawing's own glyph. Nil only where the drawings never drew one.
    var drawn: DrawnIcon? {
        switch self {
        case .more: .dots
        case .moreVertical: .dotsVertical
        // The system's symbol, as the light table and the develop page set it.
        case .warning, .camera: nil
        default: DrawnIcon(rawValue: String(describing: self))
        }
    }
}

extension Image {
    /// The system's symbol for a glyph: the fallback `Icon` uses, and nothing else should.
    init(_ icon: SpkIcon) { self.init(systemName: icon.rawValue) }
}

// MARK: - the drawings' geometry

/// One painted shape of a drawn glyph, in the drawing's own 22 pt box centred
/// on (0, 0). `DrawnIcons.swift` is a list of these, written by
/// `tools/gen_icons.py`.
struct DrawnIconLayer: Sendable {
    enum Segment: Sendable {
        case m(CGFloat, CGFloat)
        case l(CGFloat, CGFloat)
        /// Two control points, then the end.
        case c(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case z
    }
    enum Shape: Sendable {
        case path([Segment])
        /// x, y, width, height.
        case ellipse(CGFloat, CGFloat, CGFloat, CGFloat)
        /// x, y, width, height, corner radius.
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
    }
    enum Paint: Sendable {
        case fill
        case stroke(CGFloat, CGLineCap, CGLineJoin, dash: [CGFloat] = [])
    }
    enum Ink: Sendable {
        /// The colour the caller gives the glyph.
        case current
        /// What the glyph sits on: a knob's inside, a stacked frame's face.
        case ground
        case fixed(UInt32)
    }

    let shape: Shape
    let paint: Paint
    let ink: Ink
    let opacity: Double

    init(_ shape: Shape, _ paint: Paint, _ ink: Ink, opacity: Double = 1) {
        self.shape = shape; self.paint = paint; self.ink = ink; self.opacity = opacity
    }

    var path: Path {
        switch shape {
        case .ellipse(let x, let y, let w, let h):
            return Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
        case .rect(let x, let y, let w, let h, let r):
            // SVG's `rx` is a circular corner, not SwiftUI's continuous one.
            return Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .circular)
        case .path(let segments):
            var p = Path()
            for s in segments {
                switch s {
                case .m(let x, let y): p.move(to: CGPoint(x: x, y: y))
                case .l(let x, let y): p.addLine(to: CGPoint(x: x, y: y))
                case .c(let x1, let y1, let x2, let y2, let x, let y):
                    p.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
                case .z: p.closeSubpath()
                }
            }
            return p
        }
    }
}

/// A drawn glyph at `size` (the drawing's box is 22). It takes `size` in a
/// layout and draws a little past it, as the drawings do: a bulb's rays and
/// the flash's stroke reach outside the box.
struct DrawnGlyph: View {
    let icon: DrawnIcon
    var size: CGFloat = 22
    var color: Color = Theme.text
    var ground: Color = Theme.card

    var body: some View {
        Canvas { ctx, canvas in
            ctx.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            ctx.scaleBy(x: size / 22, y: size / 22)
            for layer in icon.layers {
                let ink: Color
                switch layer.ink {
                case .current: ink = color
                case .ground: ink = ground
                case .fixed(let hex): ink = Color(hex: hex)
                }
                let shading = GraphicsContext.Shading.color(ink.opacity(layer.opacity))
                switch layer.paint {
                case .fill:
                    ctx.fill(layer.path, with: shading)
                case .stroke(let width, let cap, let join, let dash):
                    ctx.stroke(layer.path, with: shading,
                               style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: join, dash: dash))
                }
            }
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A glyph at the drawings' weight: `size` is the box the drawing gives it
/// (22, or 22 times the drawing's own scale where it draws one smaller).
struct Icon: View {
    let icon: SpkIcon
    var size: CGFloat = 22
    var color: Color = Theme.text
    /// What a glyph's knob or stacked face is filled with: the disc it sits on.
    var ground: Color = Theme.card
    /// Only for a glyph the drawings do not draw, which is set as a symbol.
    var weight: SwiftUI.Font.Weight = .regular

    init(_ icon: SpkIcon, size: CGFloat = 22, color: Color = Theme.text, ground: Color = Theme.card,
         weight: SwiftUI.Font.Weight = .regular) {
        self.icon = icon; self.size = size; self.color = color; self.ground = ground; self.weight = weight
    }

    var body: some View {
        if let drawn = icon.drawn {
            DrawnGlyph(icon: drawn, size: size, color: color, ground: ground)
        } else {
            Image(icon)
                .font(.system(size: size * 0.82, weight: weight))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// `ic_develop`: two slider bars with a knob on each — the develop page.
struct DevelopGlyph: View {
    var color: Color = Theme.text
    var knobFill: Color = Theme.card
    var body: some View { Icon(.develop, color: color, ground: knobFill) }
}

/// `ic_compare`: before and after, in one frame — an outline whose right half
/// is filled. The desktop's `BeforeAfterIcon` says the same thing at its size.
struct CompareGlyph: View {
    var color: Color = Theme.text
    var body: some View { Icon(.compare, color: color) }
}

/// The front camera's turn, as the Camera app handles it (the owner,
/// 2026-10-09: "see how Apple handles it"): not one glyph lit and unlit but
/// two — a person in a frame that lies across, or in one that stands — each
/// with two arrows turning round it. The one shown is the frame a tap gives,
/// as the control beside it shows Expand or Shrink.
///
/// Apple's own two are symbols the system keeps to itself
/// (`person.crop.rectangle.landscape.rotate`, `…portrait.rotate`: an app that
/// asks for them by name gets nothing). What any app may draw is the same
/// frame and arrows without the person (`rectangle.landscape.rotate`,
/// `rectangle.portrait.rotate`), and a person (`person.fill`). So the person
/// is set in here, shoulders running into the frame's foot as Apple's do.
/// The sizes are shares of the frame symbol's point size, measured off the
/// symbols: the frame's clear inside is 0.63 by 0.45 of it, the stroke 0.075.
struct FrameTurnGlyph: View {
    /// The frame a tap gives lies across (a landscape photo); false, it stands.
    let across: Bool
    var color: Color = Theme.text
    /// The frame symbol's point size: its ink is about 1.2 times this each way.
    var size: CGFloat = 19

    var body: some View {
        ZStack {
            Image(systemName: across ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                .font(.system(size: size))
            Image(systemName: "person.fill")
                .font(.system(size: size * (across ? 0.51 : 0.60)))
                .offset(y: size * (across ? 0.045 : 0.078))
        }
        .foregroundStyle(color)
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
