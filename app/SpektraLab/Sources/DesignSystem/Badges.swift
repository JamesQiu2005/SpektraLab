//  Badges.swift — the small marks: CINE, and the honest labels.
//
//  `CinePill` is an accent outline round small capitals. `TagPill` is the
//  label a picture wears when it is not the print:
//  `SCENE` over the viewfinder, which shows the scene and says so
//  (ARCHITECTURE §7.6: no live preview, and nothing reduced passed off as the
//  real thing).

import SwiftUI

/// A cine stock's mark on its card.
struct CinePill: View {
    var body: some View {
        Text("CINE")
            .font(Theme.Font.ui(7.5, .bold))
            .foregroundStyle(Theme.accent)
            .frame(width: 30, height: 12)
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 0.9))
    }
}

/// `SCENE`: what a picture is, said on the picture.
struct TagPill: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.ui(10.5, .semibold)).tracking(1)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// A stock's dot: the film card's colour, on a library tile and beside a
/// stock's name.
struct StockDot: View {
    let color: Color
    var diameter: CGFloat = 7
    /// On a photograph the dot takes a dark edge, so it reads on any picture.
    var onPicture = false
    var body: some View {
        Circle().fill(color)
            .frame(width: diameter, height: diameter)
            .overlay { if onPicture { Circle().stroke(Color.black.opacity(0.5), lineWidth: 1) } }
    }
}
