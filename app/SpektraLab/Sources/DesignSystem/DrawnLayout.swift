//  DrawnLayout.swift — placing a view where the drawing places it.
//
//  The pages are built from `gen.py` and `gen_flow.py`, whose every element is
//  a number: `t(x, y, s, …)` puts a line of text with its *baseline* at y, a
//  rect has its top at y, an icon its centre. A stack of paddings only
//  approximates those numbers (a line box is taller than the type in it), so a
//  part that has to sit where the drawing puts it is placed the drawing's way: a
//  `DrawnBand` is a strip of the page whose children say where their baseline,
//  top or centre goes, measured from the band's top. Widths still flex — a
//  child is pinned to a leading or trailing margin, never to x = 393 — so a
//  wider host keeps the drawing's margins and type and gains width.
//
//  The develop page, Crop and the export sheets are laid out with it, and so
//  are the shared parts whose insides the drawings fix: the sheet header and
//  the ruler row.

import SwiftUI

/// A strip of the page `height` tall whose children are placed with
/// `baseline(_:)`, `top(_:)` or `centreY(_:)`, measured from its top. As wide
/// as it is offered, or `width` when the drawing fixes it (a card, a pill).
struct DrawnBand<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        DrawnBandLayout(width: width, height: height) { content() }
    }
}

/// Places each child by its own top and leading guides, from the band's
/// origin. A `ZStack` would do the same until a child reached above the band
/// (a 44 pt tap target around a 26 pt capsule): the stack then grows upward
/// and every other child moves down with it.
struct DrawnBandLayout: Layout {
    var width: CGFloat?
    var height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width ?? proposal.replacingUnspecifiedDimensions().width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let offer = ProposedViewSize(width: bounds.width, height: bounds.height)
        for view in subviews {
            let d = view.dimensions(in: offer)
            view.place(at: CGPoint(x: bounds.minX - d[.leading], y: bounds.minY - d[.top]),
                       anchor: .topLeading, proposal: offer)
        }
    }
}

extension View {
    /// The drawings' `t(x, y, …)`: this view's first text baseline at `y`.
    func baseline(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[.firstTextBaseline] - y }
    }

    /// This view's top edge at `y`.
    func top(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[.top] - y }
    }

    /// This view's vertical centre at `y`: an icon's `cy`, a button's centre.
    func centreY(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[VerticalAlignment.center] - y }
    }

    /// This view's leading edge at `x` from the band's leading edge.
    func leading(_ x: CGFloat) -> some View {
        alignmentGuide(.leading) { $0[.leading] - x }
    }

    /// This view's horizontal centre at `x` from the band's leading edge.
    func centreX(_ x: CGFloat) -> some View {
        alignmentGuide(.leading) { $0[HorizontalAlignment.center] - x }
    }

    /// Pinned to the trailing margin: this view's trailing edge `inset` in
    /// from the band's trailing edge (the drawings' `W - inset`, `"end"`).
    func trailingInset(_ inset: CGFloat) -> some View {
        frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, inset)
    }
}

/// A line of the drawings' type: a size, a weight, a colour.
///
/// A fixed string the drawing has measured is set at its own width. A line
/// whose words come from the data — a stock's name, a file's, a disk's — is
/// `fit`: given a frame by its caller, it is set smaller (to three quarters)
/// rather than leave it, because no text may leave its frame and none is cut.
struct DrawnText: View {
    let text: String
    var size: CGFloat
    var weight: Font.Weight = .medium
    var color: Color = Theme.text
    var fit = false

    init(_ text: String, _ size: CGFloat, _ weight: Font.Weight = .medium, _ color: Color = Theme.text,
         fit: Bool = false) {
        self.text = text; self.size = size; self.weight = weight; self.color = color; self.fit = fit
    }

    var body: some View {
        let line = Text(text).font(Theme.Font.ui(size, weight)).foregroundStyle(color).lineLimit(1)
        if fit {
            line.minimumScaleFactor(0.75)
        } else {
            line.fixedSize()
        }
    }
}

extension View {
    /// A `fit` line's frame: from `leading` to `trailing` in from the band's
    /// edges, left-aligned. The band offers its whole width; this takes it in.
    func spanning(leading: CGFloat, trailing: CGFloat) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).padding(.leading, leading).padding(.trailing, trailing)
    }
}
