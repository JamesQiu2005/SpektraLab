//  Layer2Picture.swift — the develop page's picture with Edit's layer on it, live.
//
//  Drawn by `DevelopCanvas` where the frame carries Light, Curve or Colour: the
//  picture beneath (`base`, the develop as the page draws it anyway) and over
//  it the same picture through the page's pass (`Layer2Live.shown`), laid out
//  exactly as the develop is — so zoom, pan and the compare split need nothing
//  of their own. It tells the pass the size it draws at: the size
//  `FramePicture` decodes for the same place.
//
//  It is an ordinary image, not a Metal layer: the snapshot harness captures it
//  as it captures any page, and there a page's picture is made on the spot
//  (`Layer2Live.renderedNow`).

import SwiftUI
import UIKit

struct Layer2Picture<Base: View>: View {
    let live: Layer2Live
    /// The long edge it is drawn at, in points.
    let pointSize: CGFloat
    @ViewBuilder let base: () -> Base

    @Environment(\.displayScale) private var scale
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.gamutProof) private var gamutProof

    /// `FramePicture`'s size for the same place: the screen's pixels, in steps of 64.
    private var maxPixel: Int { max(64, Int((pointSize * scale / 64).rounded(.up)) * 64) }

    var body: some View {
        let px = maxPixel
        let shown = live.shown ?? (isSnapshot ? live.renderedNow(maxPixel: px) : nil)
        ZStack {
            base()
            if let shown {
                Image(uiImage: UIImage(cgImage: GamutProof.shared.proofed(shown, gamutProof))).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            }
        }
        .onAppear { live.display(maxPixel: px) }
        .onChange(of: px) { _, now in live.display(maxPixel: now) }
        .onDisappear { live.display(maxPixel: nil) }
    }
}
