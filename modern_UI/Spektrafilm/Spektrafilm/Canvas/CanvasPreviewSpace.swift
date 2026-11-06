//  CanvasPreviewSpace.swift — which space the canvas shows the picture in (1.3.6).
//
//  The canvas draws the ProPhoto working space and lets ColorSync clip it for
//  the display (the 2026-09-13 decision, `Renderer.swift`'s header). An export
//  to Display P3 or sRGB goes through the CAM16 output transform instead, which
//  rolls saturated colour in rather than clipping it — so an export could look
//  blander than the canvas it was judged on. Users reported exactly that.
//
//  This is the switch that lets the canvas show the export's conversion: pick
//  a space and the canvas runs the same `outputTransform` kernel, with the same
//  setup, that a recipe in that space runs (`Renderer.setPreview`). ProPhoto
//  RGB is today's canvas and stays the default — nothing changes for anyone
//  who does not touch it.

import CoreGraphics
import Foundation

enum CanvasPreviewSpace: String, CaseIterable, Identifiable, Sendable {
    case proPhoto, adobeRGB, displayP3, sRGB

    var id: String { rawValue }

    /// The engine's name for the space — what `ColourManagement.setup` and the
    /// session's `workingSpaceName` speak.
    var engineName: String {
        switch self {
        case .proPhoto: "ProPhoto RGB"
        case .adobeRGB: "Adobe RGB (1998)"
        case .displayP3: "Display P3"
        case .sRGB: "sRGB"
        }
    }

    var colorSpace: CGColorSpace {
        switch self {
        case .proPhoto: CGColorSpace(name: CGColorSpace.rommrgb)!
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    /// The menu's name for it. Colour-space names are not translated.
    var title: String { engineName }

    /// The top bar's pill: the same name, shortened only where it is long.
    var shortTitle: String {
        switch self {
        case .proPhoto: "ProPhoto"
        case .adobeRGB: "Adobe RGB"
        case .displayP3: "P3"
        case .sRGB: "sRGB"
        }
    }

    // MARK: persistence

    nonisolated static let key = "ui2.canvasPreviewSpace"

    /// The stored choice, read from `defaults` — injectable so a test reads a
    /// throwaway suite rather than the shared store (AGENTS.md trap 24).
    nonisolated static func stored(in defaults: UserDefaults) -> CanvasPreviewSpace {
        defaults.string(forKey: key).flatMap(CanvasPreviewSpace.init(rawValue:)) ?? .proPhoto
    }

    nonisolated static func store(_ space: CanvasPreviewSpace, in defaults: UserDefaults) {
        defaults.set(space.rawValue, forKey: key)
    }

    // MARK: the ground

    /// The letterbox grey **encoded for this space** (AGENTS.md trap 27).
    ///
    /// The drawing's ground is sRGB `0x5F`; the drawable is tagged with this
    /// space while previewing it, so the GPU has to write that grey's linear
    /// light through this space's transfer function. sRGB and Display P3 share
    /// sRGB's curve, so for both it is the literal `0x5F/255`; Adobe RGB is
    /// γ 563/256; ProPhoto is `CanvasGround.value`, derived the same way.
    var groundValue: Float {
        let encoded = 0x5F / 255.0
        let linear = encoded <= 0.040449936 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        switch self {
        case .sRGB, .displayP3: return Float(encoded)
        case .adobeRGB: return Float(pow(linear, 256.0 / 563.0))
        case .proPhoto: return CanvasGround.value
        }
    }
}
