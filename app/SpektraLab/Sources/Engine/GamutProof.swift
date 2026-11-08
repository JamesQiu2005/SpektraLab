//  GamutProof.swift — a page's Display P3 picture shown as a file in a smaller space holds it (2.2.1).
//
//  `CanvasGamut` says why. Here: the engine's own output transform from Display P3 into sRGB or Adobe RGB
//  (`EngineRouter.proofTransform`, CAM16-UCS gamut compression without its lightness stage, as every page
//  transform is asked) run by `OutputTransformer`'s kernel on the picture the page was about to draw, and
//  drawn tagged with that space.
//
//  - **Asked once a space.** The first picture shown in a space asks the engine for the numbers and is
//    drawn as made meanwhile; when they arrive `ready` changes and every page that drew one draws again,
//    proofed.
//  - **Kept per picture.** A proof is one GPU pass at the size the page draws (a few milliseconds); the
//    last few are kept against the very `CGImage` they were made of, so a page redrawn with the same
//    picture costs nothing, and Edit's live layer, whose picture is new each pass, is proofed per pass.
//  - **The input is redrawn into Display P3 at 16 bits** before the kernel reads it, whatever the decoder
//    tagged it with, so the transform's source space is always the one it was asked for.
//  - Without the engine (a build with `--no-engine`) the picture is shown as made.

import CoreGraphics
import Foundation
import Metal
import Observation
import UIKit

@MainActor
@Observable
final class GamutProof {
    static let shared = GamutProof()

    /// The spaces whose numbers have arrived: read by every proof, so a page drawn before them draws again.
    private(set) var ready: Set<CanvasGamut> = []

    #if SPK_ENGINE
    /// Set once by `AppServices`: the engine whose numbers a proof uses.
    @ObservationIgnored weak var darkroom: EngineRouter?
    @ObservationIgnored private var transformer: OutputTransformer?
    @ObservationIgnored private var setups: [CanvasGamut: OutputTransformer.Setup] = [:]
    @ObservationIgnored private var asked: Set<CanvasGamut> = []
    @ObservationIgnored private var kept: [(source: CGImage, gamut: CanvasGamut, made: CGImage)] = []
    private static let keepCount = 12
    #endif

    /// `image` as a file in `gamut` holds it; the image itself where nothing is to be proofed or cannot be.
    func proofed(_ image: CGImage, _ gamut: CanvasGamut?) -> CGImage {
        guard let gamut, gamut.proofs else { return image }
        #if SPK_ENGINE
        guard ready.contains(gamut) else { ask(gamut); return image }
        if let hit = kept.first(where: { $0.source === image && $0.gamut == gamut }) { return hit.made }
        guard let setup = setups[gamut], let made = try? make(image, setup: setup, gamut: gamut) else { return image }
        kept.insert((image, gamut, made), at: 0)
        if kept.count > Self.keepCount { kept.removeLast(kept.count - Self.keepCount) }
        return made
        #else
        return image
        #endif
    }

    func proofed(_ image: UIImage, _ gamut: CanvasGamut?) -> UIImage {
        guard let gamut, gamut.proofs, let cg = image.cgImage else { return image }
        let made = proofed(cg, gamut)
        return made === cg ? image : UIImage(cgImage: made, scale: image.scale, orientation: image.imageOrientation)
    }

    #if SPK_ENGINE
    private func target(_ gamut: CanvasGamut) -> OutputTransformer.Target {
        switch gamut {
        case .sRGB: .sRGB
        case .adobeRGB: .adobeRGB
        case .displayP3: .displayP3
        case .proPhoto: .proPhoto
        }
    }

    private func ask(_ gamut: CanvasGamut) {
        guard !asked.contains(gamut), let darkroom else { return }
        asked.insert(gamut)
        let target = target(gamut)
        Task { @MainActor in
            do {
                guard let device = darkroom.device, let data = try await darkroom.proofTransform(to: target) else { return }
                if transformer == nil { transformer = try OutputTransformer(device: device) }
                guard let transformer else { return }
                setups[gamut] = try transformer.setup(data)
                ready.insert(gamut)
            } catch {
                asked.remove(gamut)   // asked again by the next picture
            }
        }
    }

    private func make(_ image: CGImage, setup: OutputTransformer.Setup, gamut: CanvasGamut) throws -> CGImage {
        guard let transformer, let device = darkroom?.device else { throw EngineError.failed("no engine for the proof") }
        let w = image.width, h = image.height
        let bytesPerRow = w * 8
        guard w > 0, h > 0, let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: bytesPerRow, space: p3,
                                      bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else {
            throw EngineError.failed("the proof's picture could not be drawn")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw EngineError.resource("no texture for the proof") }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        let t = target(gamut)
        return try transformer.image(texture: texture, width: w, height: h, setup: setup, space: t.colorSpace)
    }
    #endif
}
