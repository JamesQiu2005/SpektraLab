// decode.swift -- decode a RAW the way ImageDecoder.swift does for the engine:
// CIRAWFilter with Apple's tone rendering off, rendered to float32 linear
// ProPhoto, top row first.  Writes <out>.f32 (H*W*3 float32) and prints "W H".
import Foundation
import CoreImage
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: decode <in> <out.f32> [longEdge]\n".data(using:.utf8)!); exit(2) }
let url = URL(fileURLWithPath: args[1])
let outPath = args[2]
let longEdge = args.count > 3 ? Double(args[3])! : 0.0

let linearProPhoto: CGColorSpace = {
    let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
    let black: [CGFloat] = [0, 0, 0]
    let gamma: [CGFloat] = [1, 1, 1]
    let primaries: [CGFloat] = [
        0.7976749, 0.2880402, 0.0000000,
        0.1351917, 0.7118741, 0.0000000,
        0.0313534, 0.0000857, 0.8252100,
    ]
    return d50.withUnsafeBufferPointer { wp in black.withUnsafeBufferPointer { bp in
        gamma.withUnsafeBufferPointer { gp in primaries.withUnsafeBufferPointer { mp in
            CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!, blackPoint: bp.baseAddress,
                         gamma: gp.baseAddress!, matrix: mp.baseAddress)!
        }}}}
}()
let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

guard let filter = CIRAWFilter(imageURL: url) else { FileHandle.standardError.write("no RAW decoder\n".data(using:.utf8)!); exit(1) }
filter.isDraftModeEnabled = false
filter.isLensCorrectionEnabled = false
// The `.linear` look, verbatim from ImageDecoder.rawFilter.
filter.boostAmount = 0
filter.boostShadowAmount = 0
filter.isGamutMappingEnabled = false
filter.localToneMapAmount = 0
filter.extendedDynamicRangeAmount = 0
guard var image = filter.outputImage else { FileHandle.standardError.write("no output image\n".data(using:.utf8)!); exit(1) }

let full = image.extent
if longEdge > 0 {
    let s = longEdge / Double(max(full.width, full.height))
    if s < 1.0 {
        let sc = CIFilter(name: "CILanczosScaleTransform")!
        sc.setValue(image, forKey: kCIInputImageKey)
        sc.setValue(NSNumber(value: s), forKey: kCIInputScaleKey)
        sc.setValue(NSNumber(value: 1.0), forKey: kCIInputAspectRatioKey)
        image = sc.outputImage!
    }
}
let r = image.extent.integral
let w = Int(r.width), h = Int(r.height)
let placed = image.transformed(by: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))

let ctx = CIContext(options: [.workingColorSpace: linearP3, .cacheIntermediates: false,
                              .outputPremultiplied: false, .useSoftwareRenderer: false])
var rgba = [Float](repeating: 0, count: w * h * 4)
rgba.withUnsafeMutableBytes { buf in
    ctx.render(placed, toBitmap: buf.baseAddress!, rowBytes: w * 16,
               bounds: CGRect(x: 0, y: 0, width: w, height: h),
               format: .RGBAf, colorSpace: linearProPhoto)
}
var rgb = [Float](repeating: 0, count: w * h * 3)
for i in 0..<(w * h) { rgb[3*i] = rgba[4*i]; rgb[3*i+1] = rgba[4*i+1]; rgb[3*i+2] = rgba[4*i+2] }
let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
try! data.write(to: URL(fileURLWithPath: outPath))
print("\(w) \(h)")
