//  DigitalDecode.swift — a frame with Apply Film Emulation off: Apple's own decode, cut, and nothing else.
//
//  The owner, 2026-10-21: "just a on / off switch under film exposure called 'apply film emulation', and
//  if that's toggled off, we simply grey out any film-related features in both develop and edit and the
//  photos goes back to apple stock decode" — "we're already a very good photo editor".
//
//  - **Apple's stock decode**: a RAW through `CIRAWFilter` as Apple sets it (its boost, its tone map, its
//    gamut mapping), with only the frame's white balance and Settings' lens correction asked of it; a
//    JPEG or HEIC as its file is, turned upright. Not the engine's linear decode (`RawExposure`), which
//    is made for the film and looks flat without one.
//  - **Cut by the frame's own geometry** (`HostCut`: crop, straighten, turns, flips, Vertical and
//    Horizontal), as the host cuts a film edge's frame, then scaled to the job's canvas.
//  - **Handed over as the engine hands its result**: ProPhoto RGB in its own curve (ROMM: 16× below
//    1/512, 1/1.8 above), 16 bits — what `OutputTransform` reads. So the canvas, Edit, the kept develop,
//    the zoom's full render and an export take it as they take a film's, and the engine never runs.

import CoreImage
import Foundation
import Metal

enum DigitalDecode {
    /// The decoder as a word, for a develop's stamp: Apple's decode changes with the system.
    static let word = "apple " + ProcessInfo.processInfo.operatingSystemVersionString

    /// The file as Apple decodes it, upright: nil where it cannot be read.
    static func image(_ url: URL, isRAW: Bool, decode: DecodeSettings) -> CIImage? {
        guard isRAW else { return CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) }
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = decode.lensCorrection }
        switch decode.whiteBalance {
        case .asShot: break
        case .custom:
            filter.neutralTemperature = Float(decode.temperature)
            filter.neutralTint = Float(decode.tint)
        default:
            if let kelvin = decode.whiteBalance.kelvin { filter.neutralTemperature = Float(kelvin) }
        }
        return filter.outputImage
    }

    #if SPK_ENGINE
    /// The frame, cut by `geometry` and scaled to `canvas`, in the engine's result's encoding.
    static func render(_ url: URL, isRAW: Bool, decode: DecodeSettings, geometry: Geometry, canvas: PixelSize,
                       device: MTLDevice) throws -> RenderedPixels {
        guard let decoded = image(url, isRAW: isRAW, decode: decode) else {
            throw EngineError.failed("Apple's decoder could not read \(url.lastPathComponent)")
        }
        let whole = decoded.extent.integral
        let upright = decoded.transformed(by: .init(translationX: -whole.origin.x, y: -whole.origin.y))
        var cut = geometry.isIdentity ? upright : HostCut.image(upright, by: geometry)
        let box = cut.extent.integral
        cut = cut.transformed(by: .init(translationX: -box.origin.x, y: -box.origin.y))
        let w = max(1, canvas.width), h = max(1, canvas.height)
        // To the canvas exactly: one Lanczos pass, its aspect set so both edges land.
        if box.width > 0, box.height > 0, (Int(box.width) != w || Int(box.height) != h),
           let scale = CIFilter(name: "CILanczosScaleTransform") {
            let sy = CGFloat(h) / box.height, sx = CGFloat(w) / box.width
            scale.setValue(cut.clampedToExtent(), forKey: kCIInputImageKey)
            scale.setValue(sy, forKey: kCIInputScaleKey)
            scale.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
            if let out = scale.outputImage { cut = out }
        }
        cut = cut.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))

        let align = max(device.minimumLinearTextureAlignment(for: .rgba16Unorm), 8)
        let rowBytes = (w * 8 + align - 1) / align * align
        guard let buffer = device.makeBuffer(length: rowBytes * h, options: .storageModeShared) else {
            throw EngineError.resource("no \((rowBytes * h) >> 20) MB for Apple's decode")
        }
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .highQualityDownsample: true])
        // First row the picture's top, as the engine's result is; about four megapixels a band, each in its
        // own pool (`FrameDecoder.render`): Core Image's y runs upward, so band b (rows r0..<r1) is the
        // image's rows h-r1..<h-r0.
        let romm = CGColorSpace(name: CGColorSpace.rommrgb)!
        let bands = max(1, Int((Double(w) * Double(h) / 4_000_000).rounded(.up)))
        for b in 0..<bands {
            autoreleasepool {
                let r0 = h * b / bands, r1 = h * (b + 1) / bands
                context.render(cut, toBitmap: buffer.contents() + r0 * rowBytes, rowBytes: rowBytes,
                               bounds: CGRect(x: 0, y: h - r1, width: w, height: r1 - r0), format: .RGBA16, colorSpace: romm)
            }
        }
        context.clearCaches()
        let base = buffer.contents().assumingMemoryBound(to: UInt16.self)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        #if targetEnvironment(simulator)
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d), let queue = device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw EngineError.resource("no texture for Apple's decode")
        }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #else
        d.storageMode = .shared
        guard let texture = buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else {
            throw EngineError.resource("no texture for Apple's decode")
        }
        #endif
        return RenderedPixels(texture: texture, rgba16: UnsafePointer(base), size: PixelSize(width: w, height: h),
                              rowStridePixels: rowBytes / 8, keep: buffer)
    }
    #endif
}
