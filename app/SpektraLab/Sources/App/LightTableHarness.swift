//  LightTableHarness.swift — the light table's fixed scene, for the snapshot harness.
//
//  **The fixed scene.** The demo library's frames are bundled pictures with no film edge, so the
//  harness gives copies of them — in memory, the library untouched — the formats the table must
//  size: a bare 135 frame (36 × 24), the upright street frame turned 30°, a 135 strip, a 6 × 7
//  frame filed, a 6 × 9 frame by its Film Format (84 × 56) lying over the 135 strip, an XPan strip
//  and a half frame's strip. A film edge not yet developed is the film drawn from its geometry
//  round the preview (`LightTableFrames`); a real library's frames come as they are.
//
//  `LightTableSnapshots` puts the scene in the snapshot harness (`LT1`…`LT4`), drawn offscreen
//  by the renderer (`LightTableStill`): the snapshot window is captured by `drawHierarchy`, which
//  does not see a Metal layer.

import ImageIO
import Metal
import SwiftUI
import UIKit

enum LightTableHarness {
    /// The scene's frames: the demo library's given the formats the table must size, or a real
    /// library's first eight as they are.
    @MainActor static func frames(_ library: [LibraryFrame]) -> [LibraryFrame] {
        guard library.contains(where: \.isDemo) else { return Array(library.prefix(8)) }
        // The demo frames say 6,000 × 4,000 whatever their bundled picture's shape (most are 320 px
        // thumbnails, some upright): each copy is given its picture's own shape, 6,000 px on its long
        // edge, so a frame is sized as its picture is and nothing is stretched.
        func named(_ picture: String) -> LibraryFrame? {
            guard var f = library.first(where: { $0.picture == .sample(picture) }) else { return nil }
            if let url = ThumbnailStore.url(for: f.picture), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
                let k = 6000.0 / Double(max(w, h))
                f.originalSize = PixelSize(width: Int((Double(w) * k).rounded()), height: Int((Double(h) * k).rounded()))
                f.previewSize = f.originalSize.scaled(toLongEdge: 2400)
            }
            return f
        }
        func edge(_ f: LibraryFrame?, _ format: FilmEdgeFormat, _ view: FilmEdgeView) -> LibraryFrame? {
            guard var f else { return nil }
            f.edit.filmEdge.active = true
            f.edit.filmEdge.format = format
            f.edit.filmEdge.mode = view
            f.edit.filmEdge.turn = format.defaultTurn(pictureAspect: f.originalSize.aspect)
            return f
        }
        var sixByNine = named("t8.jpg")
        sixByNine?.edit.params.filmFormatMM = 84
        return [
            named("bund.jpg"),                          // a bare 135 frame: 36 × 24
            named("street.jpg"),                        // upright: 24 × 36, turned 30°
            edge(named("t3.jpg"), .f135, .strip),       // a 135 strip
            edge(named("t7.jpg"), .f6x7, .filed),       // 6 × 7, filed
            sixByNine,                                  // 6 × 9 by its Film Format: 84 × 56
            edge(named("t5.jpg"), .xpan, .strip),       // XPan, a strip
            edge(named("t6.jpg"), .half, .strip),       // a half frame's strip
        ].compactMap { $0 }
    }

    /// The scene laid out: every frame put down where the table places it, the street frame turned
    /// 30°, the 6 × 9 frame laid half over the 135 strip.
    @MainActor static func lay(_ c: LightTableController, _ frames: [LibraryFrame]) {
        c.add(frames.map(\.id))
        if frames.count > 1 { c.turn(frames[1].id, byRadians: 30 * LightTable.deg) }
        if frames.count > 4, let strip = c.model.item(frames[2].id), let big = c.model.item(frames[4].id) {
            c.move(big.id, by: CGVector(dx: strip.x + 18 - big.x, dy: strip.y - 14 - big.y))
        }
        c.select(nil)
    }

    /// The scene's state: chosen, zoomed, the loupe on the 135 strip's edge.
    @MainActor static func state(_ c: LightTableController, _ name: String, _ frames: [LibraryFrame]) {
        guard frames.count > 3 else { return }
        let strip = frames[2].id
        switch name {
        case "selected":
            c.select(frames[3].id)
        case "zoom":
            if let it = c.model.item(strip) { c.zoom(to: 3, around: c.viewport.toScreen(it.centre)) }
        case "loupe":
            if let it = c.model.item(strip) {
                c.loupe(at: c.viewport.toScreen(CGPoint(x: it.x - it.lying.width / 2 + 3, y: it.y + it.lying.height / 2 - 4)))
            }
        default:
            break
        }
    }

    /// A controller over the scene, its table kept in memory only.
    @MainActor static func controller(_ library: [LibraryFrame], bodySeed: Int) -> (LightTableController, [LibraryFrame]) {
        let frames = frames(library)
        let c = LightTableController(frames: frames, bodySeed: bodySeed, store: LightTableStore(url: nil))
        c.darkDesk = false          // the website's white desk: the stills are held against its own
        return (c, frames)
    }

    /// The chosen film's ring drawn over a still, as the page lays it over the view.
    @MainActor static func ringed(_ image: CGImage, _ c: LightTableController, scale: Double) -> CGImage {
        guard let ring = c.ring,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: ring.centre.x, y: ring.centre.y)
        ctx.rotate(by: ring.angle)
        ctx.setStrokeColor(UIColor(Theme.accent).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -ring.size.width / 2, y: -ring.size.height / 2, width: ring.size.width, height: ring.size.height),
                           cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
        return ctx.makeImage() ?? image
    }
}

// MARK: - in the snapshot harness

enum LightTableSnapshots {
    @MainActor static var pages: [SnapshotPage] {
        [("LT1", "fit", "Light table, fitted"), ("LT2", "selected", "Light table, one film chosen"),
         ("LT3", "zoom", "Light table, zoomed 3×"), ("LT4", "loupe", "Light table, the loupe")].map { id, state, title in
            SnapshotPage(id, title) { model in LightTableSnapshotPage(state: state).appEnvironment(model) }
        }
    }
}

private struct LightTableSnapshotPage: View {
    let state: String
    @Environment(AppServices.self) private var model
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.913, green: 0.913, blue: 0.922)
                if let image { Image(decorative: image, scale: 2).resizable() }
            }
            .onAppear {
                let (c, frames) = LightTableHarness.controller(model.library.frames, bodySeed: model.settings.bodySeed)
                _ = c.still(size: geo.size, scale: 2)
                LightTableHarness.lay(c, frames)
                LightTableHarness.state(c, state, frames)
                image = c.still(size: geo.size, scale: 2).map { LightTableHarness.ringed($0, c, scale: 2) }
                c.close()
            }
        }
        .ignoresSafeArea()
    }
}
