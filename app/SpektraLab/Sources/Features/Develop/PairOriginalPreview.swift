import CoreImage
import UIKit

/// A bounded composition of the two source previews, before film and Layer 2.
/// The rendered canvas supplies its gates so Original never shifts the piece
/// or substitutes the pair's graded thumbnail. Empty film has no source pixels.
@MainActor enum PairOriginalPreview {
    #if DEBUG
    /// Observes the actual canvas task in the simulator integration check.
    static var onCanvasReady: ((UUID, UIImage?) -> Void)?
    #endif
    static func key(pair: HalfFramePair, frames: HalfFramePair.Frames,
                    rects: [HalfFramePair.Side: CGRect]?, aspect: CGFloat) -> String {
        var words = [pair.guideKey, String(describing: aspect)]
        for side in HalfFramePair.Side.allCases {
            words.append(String(describing: rects?[side]))
            if let frame = frames[side] { words.append(String(describing: frame.originalPicture ?? frame.picture)) }
        }
        return words.joined(separator: "|")
    }

    static func make(pair: HalfFramePair, frames: HalfFramePair.Frames,
                     rects: [HalfFramePair.Side: CGRect]?, aspect: CGFloat,
                     maxPixel: Int = 1600) async -> UIImage? {
        guard let rects, aspect > 0, aspect.isFinite else { return nil }
        let width = max(1, Int(CGFloat(maxPixel) * min(1, aspect)))
        let height = max(1, Int(CGFloat(maxPixel) / max(1, aspect)))
        let size = CGSize(width: width, height: height)
        var canvas = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var filled = false
        for side in HalfFramePair.Side.allCases {
            guard let hole = pair[side] else { continue }
            // A missing occupied source is unavailable, not a partly original
            // pair. Loading failure leaves the processed image on screen.
            guard let frame = frames[side], let rect = rects[side],
                  let shown = await PictureLoading.picture(frame.originalPicture ?? frame.picture, maxPixel: maxPixel),
                  !Task.isCancelled, let cg = shown.cgImage else { return nil }
            let source = CGSize(width: frame.developSize.width, height: frame.developSize.height)
            let framed = HalfFramePair.turned(hole.geometry.outputSize(for: source), by: hole.placement)
            let box = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                             width: rect.width * size.width, height: rect.height * size.height)
            let image = PiecePlacer.place(CIImage(cgImage: cg), cut: hole.geometry,
                            quarterTurns: hole.placement.quarterTurns, window: pair.window(hole, of: framed), size: box.size)
            canvas = image.transformed(by: .init(translationX: box.minX, y: size.height - box.maxY)).composited(over: canvas)
            filled = true
        }
        guard filled, !Task.isCancelled, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        guard let image = context.createCGImage(canvas, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: space) else { return nil }
        return UIImage(cgImage: image)
    }
}
