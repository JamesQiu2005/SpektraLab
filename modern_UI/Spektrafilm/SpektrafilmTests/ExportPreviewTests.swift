//  ExportPreviewTests.swift — reading the preview a TIFF carries beside its
//  picture.
//
//  The page shows the file's own preview once an export has written one, and
//  the way to get that wrong is **silent**: `CGImageSourceCreateThumbnailAtIndex`
//  does not find a TIFF's second page, and instead returns a downscale of the
//  full picture at the same cost as if there were no preview at all. A
//  thumbnail call therefore looks like it worked and shows you the wrong
//  thing — so the test that matters is not "did it return an image" but "did
//  it return the one on page 1".
//
//  The two pages are given different colours so that question has an answer.
//  A size check would not do: a downscale of page 0 is the *right size* to be
//  the preview and is still the wrong picture.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ExportPreviewTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appending(path: "spk-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func image(_ w: Int, _ h: Int, _ grey: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: grey, green: grey, blue: grey, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// A TIFF of `pages` as greys, in the order given.
    private func writeTIFF(_ pages: [CGFloat], width: Int = 400, height: Int = 300) throws -> URL {
        let url = scratch.appending(path: "pages-\(pages.count)-\(pages.first ?? 0).tif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                   UTType.tiff.identifier as CFString,
                                                   pages.count, nil)!
        for grey in pages { CGImageDestinationAddImage(dest, image(width, height, grey), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func centre(_ image: CGImage) -> CGFloat {
        var px: [UInt8] = [0, 0, 0, 0]
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2,
                                   width: image.width, height: image.height))
        return CGFloat(px[0]) / 255
    }

    func testTheSecondPageIsWhatComesBack() throws {
        // Page 0 is black, page 1 is white — so "which one came back" is a
        // question the pixels answer.
        let url = try writeTIFF([0.0, 1.0])
        let found = try XCTUnwrap(ExportPage.embeddedPreview(of: url))
        XCTAssertEqual(centre(found), 1.0, accuracy: 0.02,
                       "the preview is page 1, not page 0 and not a downscale of it")
    }

    /// The trap, stated as its own case: a reader that had gone through
    /// `CGImageSourceCreateThumbnailAtIndex` returns page 0, resized to look
    /// plausibly like a preview.
    func testThePreviewIsNotTheFullPictureResized() throws {
        let url = try writeTIFF([0.0, 1.0])
        let found = try XCTUnwrap(ExportPage.embeddedPreview(of: url))
        XCTAssertGreaterThan(centre(found), 0.5,
                             "a downscale of page 0 is the wrong picture, whatever size it is")
    }

    func testAFileWithOneImageHasNoPreview() throws {
        XCTAssertNil(ExportPage.embeddedPreview(of: try writeTIFF([0.5])))
    }

    /// And a JPEG has no second page either, which is what makes the pane keep
    /// the render for every format but TIFF without the page having to know
    /// which formats those are.
    func testAJPEGHasNoPreview() throws {
        let url = scratch.appending(path: "one.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image(200, 150, 0.4), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertNil(ExportPage.embeddedPreview(of: url))
    }

    func testSomethingThatIsNotAnImageHasNoPreview() {
        let url = scratch.appending(path: "not-an-image.txt")
        try? Data("this is not a picture".utf8).write(to: url)
        XCTAssertNil(ExportPage.embeddedPreview(of: url))
    }
}
