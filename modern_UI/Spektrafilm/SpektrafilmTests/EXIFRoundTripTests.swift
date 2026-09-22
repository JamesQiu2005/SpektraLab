import CoreGraphics
import ImageIO
import XCTest
import UniformTypeIdentifiers

@MainActor
final class EXIFRoundTripTests: XCTestCase {
    private func image() -> CGImage {
        let data = Data(repeating: 127, count: 4 * 4 * 4)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    private func writeSource(_ url: URL, exif: [CFString: Any]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(), [
            kCGImagePropertyExifDictionary: exif
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testSourceEXIFIsCopiedUnchangedToFinishedExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spk-exif-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.tif")
        let output = directory.appendingPathComponent("output.tif")
        let expected: [CFString: Any] = [
            kCGImagePropertyExifISOSpeedRatings: [400],
            kCGImagePropertyExifExposureTime: 1.0 / 125.0,
            kCGImagePropertyExifFNumber: 2.8,
            kCGImagePropertyExifLensModel: "Example 50mm",
            kCGImagePropertyExifDateTimeOriginal: "2026:09:22 12:34:56"
        ]
        try writeSource(source, exif: expected)

        let sourceImage = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil)
            as? [CFString: Any])
        let sourceReadback = try XCTUnwrap(sourceProperties[kCGImagePropertyExifDictionary]
            as? [CFString: Any])
        let carried = try XCTUnwrap(ImageDecoder.sourceEXIF(from: source))
        XCTAssertTrue((carried as NSDictionary).isEqual(to: sourceReadback),
                      "the import side channel changed the source EXIF")

        try Exporter.write(image(), to: output, format: .tiff, sourceEXIF: carried)
        let result = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil)
            as? [CFString: Any])
        let exported = try XCTUnwrap(properties[kCGImagePropertyExifDictionary]
            as? [CFString: Any])
        XCTAssertTrue((exported as NSDictionary).isEqual(to: sourceReadback),
                      "the export modified or dropped source EXIF")
    }
}
