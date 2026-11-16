//  WatermarkParts.swift — the parts every watermark view shares: the mid-grey checkerboard a mark is shown on (so its
//  transparency is seen: #6F6F6E / #8A8A88), and a mark's thumbnail on it.

import SwiftUI
import UIKit

/// The checkerboard under a mark: two mid greys, `cell` points a square. The same in Light and Dark Mode: a white
/// mark and a black one both read on it.
struct WatermarkCheckerboard: View {
    var cell: CGFloat = 6

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0x6F / 255, green: 0x6F / 255, blue: 0x6E / 255)))
            let light = Color(red: 0x8A / 255, green: 0x8A / 255, blue: 0x88 / 255)
            let cols = Int((size.width / cell).rounded(.up)), rows = Int((size.height / cell).rounded(.up))
            var path = Path()
            for r in 0..<max(rows, 0) {
                for c in 0..<max(cols, 0) where (r + c) % 2 == 1 {
                    path.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(path, with: .color(light))
        }
        .accessibilityHidden(true)
    }
}

/// A mark's thumbnail on the checkerboard, fitted; a question mark where the library no longer has it.
struct WatermarkThumbnail: View {
    let mark: UUID
    var cell: CGFloat = 6
    @Environment(AppServices.self) private var model

    var body: some View {
        let store = model.watermarks
        ZStack {
            WatermarkCheckerboard(cell: cell)
            if let image = store.thumbnails[mark] {
                Image(uiImage: UIImage(cgImage: image)).resizable().interpolation(.high).scaledToFit().padding(2)
            } else if store.mark(mark) == nil {
                Image(systemName: "questionmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .task(id: mark) { await store.loadThumbnail(mark) }
    }
}
