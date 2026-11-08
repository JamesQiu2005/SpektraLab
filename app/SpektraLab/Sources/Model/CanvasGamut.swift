//  CanvasGamut.swift — the space a page shows its picture in (2.2.1, the owner: "one switch of the canvas
//  色域 — ProPhoto, which is the current one, sRGB, Adobe RGB and Display P3").
//
//  A page's picture is made once, in Display P3 at 16 bits: the working space (ProPhoto RGB) compressed
//  into the widest space a Mac's display shows (`ENGINE-WIRING.md` §6.1). Showing it "in sRGB" or "in
//  Adobe RGB" is a **proof**: the same picture put through the engine's own output transform from
//  Display P3 into that space — CAM16-UCS gamut compression, then the space's curve — and drawn tagged
//  with it, so the page shows what a file in that space holds (`GamutProof`). ProPhoto RGB and Display
//  P3 are the picture as it is made: ProPhoto holds all of P3, and the page is P3 already, so on a P3
//  display the two look the same; the choice says which file space the person is judging for.
//
//  - **Develop's canvas** follows the setting (`AppSettings.canvasGamut`, the "···" menu's *Canvas
//    Colour Space*).
//  - **The Export page's preview** follows the recipe's colour space, so switching a recipe from
//    Display P3 to sRGB shows the sRGB file's colours before it is written.
//  - Everything else (the library's grid, the strips' cards) shows the picture as made.

import SwiftUI

enum CanvasGamut: String, CaseIterable, Identifiable, Sendable {
    case proPhoto = "ProPhoto RGB"
    case displayP3 = "Display P3"
    case adobeRGB = "Adobe RGB"
    case sRGB = "sRGB"

    var id: String { rawValue }

    /// Its name, as the export recipe's colour spaces are named.
    var title: String {
        switch self {
        case .proPhoto: L("ProPhoto RGB")
        case .displayP3: L("Display P3")
        case .adobeRGB: L("Adobe RGB")
        case .sRGB: L("sRGB")
        }
    }

    /// Whether the page's picture must be put through a proof to show this space: only the two
    /// spaces smaller than the Display P3 picture the page is made in.
    var proofs: Bool { self == .adobeRGB || self == .sRGB }

    init(_ colour: ExportRecipe.Colour) {
        switch colour {
        case .sRGB: self = .sRGB
        case .adobeRGB: self = .adobeRGB
        case .displayP3: self = .displayP3
        case .proPhoto: self = .proPhoto
        }
    }
}

private struct GamutProofKey: EnvironmentKey { static let defaultValue: CanvasGamut? = nil }

extension EnvironmentValues {
    /// The space the pictures under this view are proofed into (`FramePicture`, Edit's live layer, the
    /// zoom's detail); nil, or a space that does not proof, shows them as made.
    var gamutProof: CanvasGamut? {
        get { self[GamutProofKey.self] }
        set { self[GamutProofKey.self] = newValue }
    }
}
