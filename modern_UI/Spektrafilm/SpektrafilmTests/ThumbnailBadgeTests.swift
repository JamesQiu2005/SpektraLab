//  ThumbnailBadgeTests.swift — R3.3's guard: a thumbnail cell draws nothing
//  in its bottom-trailing corner.
//
//  The state pip was removed four times and readded three; every removal was
//  an untested deletion, which is how the dot survived. This test renders the
//  real cell (not a grep of its source) for a frame whose state used to draw
//  a dot — `.processed`, the filled circle — and requires the bottom-right
//  12×12 pt of the render to hold no near-white pixel. Put the badge back and
//  this goes red: that is what makes it a guard rather than a snapshot.
//
//  A note on the frame: wrapping the cell in `.frame(width: 120, …)` would
//  centre its natural 157.5 pt-wide (3:2 of `thumbHeight`) placeholder inside
//  a 120 pt window and push the `.bottomTrailing` anchor — where the pip
//  lives — *off* the rendered canvas, so the guard could not fire. The height
//  is pinned by the cell's own `frame(height: thumbHeight)`; the corner that
//  used to carry the pip is therefore the render's bottom-right corner, and
//  that is what is scanned.

import SwiftUI
import XCTest

@MainActor
final class ThumbnailBadgeTests: XCTestCase {

    /// A `.processed` frame with `.none` framing is the read that used to
    /// draw the filled pip: unhidden whenever the cell was not the open
    /// frame. Rendered at scale 2 so a 6 pt dot is 12 px across and cannot
    /// hide in a 24 px scan.
    func testProcessedCellDrawsNothingInTheBottomTrailingCorner() throws {
        let frame = Frame(id: URL(fileURLWithPath: "/tmp/thumbnail-badge-guard.nef"))
        let cell = FilmstripCell(frame: frame, framing: .none, state: .processed)
            .background(Theme.card)

        let renderer = ImageRenderer(content: cell)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            XCTFail("ImageRenderer produced no CGImage; the guard cannot run")
            return
        }

        let region: CGFloat = 12          // pt, the corner a 6 pt pip plus its 4 pt padding lived in
        let side = Int(region * 2)        // px at scale 2
        guard image.width >= side, image.height >= side else {
            XCTFail("rendered image \(image.width)×\(image.height) is smaller than the scan region; the guard cannot run")
            return
        }

        let bytes = rgbaBytes(of: image)
        let nearWhite = anyNearWhite(in: bytes,
                                     x0: image.width - side, y0: image.height - side,
                                     width: side, height: side, rowBytes: image.width * 4)
        XCTAssertFalse(nearWhite,
                       "the bottom-right corner of a processed thumbnail draws a near-white pip")
    }

    // MARK: - pixel reading

    /// Copy the image into a known RGBA (premultiplied, 8-bit) buffer so the
    /// scan does not depend on the format `ImageRenderer` happens to pick.
    private func rgbaBytes(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ptr = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: w * h * 4))
    }

    /// True if any pixel in the region has max(r, g, b) ≥ 0.85. Alpha is byte
    /// 3 in this buffer and is deliberately not consulted — near-white dots
    /// are white on *all* channels.
    private func anyNearWhite(in bytes: [UInt8], x0: Int, y0: Int, width: Int, height: Int, rowBytes: Int) -> Bool {
        for y in y0 ..< y0 + height {
            for x in x0 ..< x0 + width {
                let i = y * rowBytes + x * 4
                let r = Double(bytes[i]) / 255.0
                let g = Double(bytes[i + 1]) / 255.0
                let b = Double(bytes[i + 2]) / 255.0
                if max(r, max(g, b)) >= 0.85 { return true }
            }
        }
        return false
    }
}