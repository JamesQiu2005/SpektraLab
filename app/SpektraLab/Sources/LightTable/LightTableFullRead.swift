//  LightTableFullRead.swift — a film's full-size render kept on disk, read at the size the table needs.
//
//  2026-10-24 (the owner: "it's ok to use full-resolution onto the Light Table under a certain size"). A
//  film shown larger than its kept develop, or a frame with none (the Mac makes frames on demand and
//  develops none as they arrive), is read from its full-size render (`FullRender`, `.spkfull`) where one is
//  kept: the same file the develop page's zoom and an export at Full read (`LightTableSteps.choose`).
//
//  - **Never the whole bitmap.** The render is read as the develop page's zoom reads it (`FullDetail`):
//    the tiles a part touches, from the half size where the picture is read at half or less, made the
//    size asked in one pass on the GPU — out of the engine's working space into Display P3, Edit's Light,
//    Curve and Colour laid on as the library's tile has them (`Layer2Copies`). Here a band of rows at a
//    time, each read at most `bandBytes` of the file (32 MB): a 45 MP render read at the table's ceiling
//    (`LightTableSizing.sourceCeiling`, 4,224 px) holds one band and the picture asked, never its 380 MB.
//  - **A read is a use**: the render is the one used most recently in its book (`onRead`, the renders'
//    own limit, `WorkingCopies.fullLimit`).
//  - Edit's crop is not cut here, as the table's kept develop is drawn uncut (`LightTableFrames.source`).

import CoreGraphics
import Foundation

/// A film's full render on disk, as the table asks for it: which file, of which edit, with Edit's layer.
struct LightTableFullRef: Equatable, @unchecked Sendable {
    let url: URL
    let stamp: String
    let adjustments: Adjustments
    /// The file's size, for the book.
    let bytes: Int64
    /// The picture's long edge as the render has it (after the host's turn).
    let longEdge: Int
    /// Names the picture exactly: a new render or a new layer is a new texture.
    let key: String
    #if SPK_ENGINE
    /// The pass that reads it (`FullDetail.shared`), made once on the main actor before any ref is.
    let pass: FullDetail
    #endif

    #if SPK_ENGINE
    init(url: URL, stamp: String, adjustments: Adjustments, bytes: Int64, longEdge: Int, pass: FullDetail) {
        self.url = url; self.stamp = stamp; self.adjustments = adjustments; self.bytes = bytes; self.longEdge = longEdge
        self.pass = pass
        let layer = (try? JSONEncoder().encode(adjustments)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        key = url.lastPathComponent + "|" + layer
    }
    #endif

    static func == (a: Self, b: Self) -> Bool { a.url == b.url && a.stamp == b.stamp && a.adjustments == b.adjustments }
}

enum LightTableFullRead {
    /// The most of the file one band reads.
    static let bandBytes = 32 << 20

    /// A render was read: it is the one used most recently (`WorkingCopies.noteFull`). Set by the app.
    @MainActor static var onRead: ((URL, Int64) -> Void)?

    /// The render's picture with its long edge `edge` at most (never enlarged), 8 bits a channel in
    /// Display P3. Any thread but the main one's work; nil where the file is gone or of another edit.
    static func image(_ ref: LightTableFullRef, edge: Int) -> CGImage? {
        #if SPK_ENGINE
        guard let reader = FullRender.Reader(ref.url, stamp: ref.stamp) else { return nil }
        let (fw, fh) = reader.header.finished
        let k = min(1, Double(edge) / Double(max(fw, fh, 1)))
        let ow = max(1, Int((Double(fw) * k).rounded())), oh = max(1, Int((Double(fh) * k).rounded()))
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // A band of output rows reads `rows × step` rows of the level the pass reads (the half size from a
        // step of 2), the whole width of it.
        let step = Double(fw) / Double(ow)
        let level = step >= 2 ? 2.0 : 1.0
        let rowCost = Double(fw) / level * 8 * step / level
        let rows = max(16, Int(Double(bandBytes) / max(rowCost, 1)))
        var y = 0
        while y < oh {
            let n = min(rows, oh - y)
            let rect = CGRect(x: 0, y: Double(y) / Double(oh), width: 1, height: Double(n) / Double(oh))
            guard let band = try? ref.pass.render(reader, rect: rect, pixels: PixelSize(width: ow, height: n),
                                                  adjustments: ref.adjustments) else { return nil }
            // Core Graphics counts rows from the bottom.
            ctx.draw(band, in: CGRect(x: 0, y: oh - y - n, width: ow, height: n))
            y += n
        }
        let url = ref.url, bytes = ref.bytes
        Task { @MainActor in onRead?(url, bytes) }
        return ctx.makeImage()
        #else
        return nil
        #endif
    }
}
