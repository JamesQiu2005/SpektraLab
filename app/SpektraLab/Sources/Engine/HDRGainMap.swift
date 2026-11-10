//  HDRGainMap.swift — an ISO 21496-1 gain map's container: its codes, its metadata, and its attachment to a file
//  (HDR port, 2026-11-06).
//
//  The file stays today's: the SDR picture an export writes, **its pixels unchanged**, with a gain map beside
//  it that a screen with headroom applies (`rfc/audits/hdr-density-2026-11-03`).
//
//  The container — the shapes a map is held in (`Map`, `Plane`, `Attachment`), its code against H, Apple's
//  HDRToneMap metadata, `attach` and the read-backs: the canvas's colour space is
//  taken from ImageIO's decode of a 4 × 4 gain-mapped HEIF made with them (`HDRRendition.hdrSpace`), and a
//  slide's ratio map is held in them (`HDRGain`).
//
//  **The export's map** (the export round, D8, 2026-11-06): `exportAttachment` (in
//  HDRGain.swift, beside a slide's: this file is the container alone, so the writer's checks compile it bare), the
//  grain-aware gain at full size (`HDRRendition.codes`, the canvas's own kernels: the screen shows what the
//  file holds) of **the picture the file is written from** — after Layer 2's Light, Curve and Colour and the
//  crop, so the map and its base are one picture — through the curve of the session that
//  developed it (`HDRSessionCurve`, the export's own render's answer: `EngineHost.deliver`). How a file
//  carries it is `HDRContainer`'s (RFC-046 + Adobe's `hdrgm`, `HDRUltraHDR`). What it does not do:
//  - **Full size only.** No ¼ / ½ map (`hdr_gain_plane` / `hdr_gain_codes` over blocks) and no subsample
//    switch: the owner ruled full size.
//  - **No named curve, no harness curve.** No shipped `A_H4` file is read for an export: the Mac ships none
//    (D1), and its checks export real frames with
//    their own Enable HDR (`MacExportHDRCheck`).
//  - **Not the screen's gate** (D5): a frame with Enable HDR on exports its map whatever screen the window is on.
//
//  - **Written as the 10-22 research measured it**: `CGImageDestinationAddAuxiliaryDataInfo(kCGImageAuxiliaryDataTypeISOGainMap)`
//    after the image, an 8-bit mono map, and Apple's HDRToneMap metadata — Version 1, BaseHeadroom 0,
//    AlternateHeadroom log2 H (HDRCapacityMax), GainMapMin 0, GainMapMax log2 H, Gamma 1, both offsets 0
//    (an offset would lift a film's blacks), BaseColorIsWorkingColor True. JPEG and HEIC; PNG and TIFF are
//    refused (ImageIO drops a map on PNG silently, measured 10-22).
//  - **Not ImageIO's own encode** (`kCGImageDestinationEncodeRequest`…): it tone-maps its own base, and the
//    base must be the export's pixels.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

enum HDRGainMap {
    enum Failure: Error, CustomStringConvertible {
        case format(String)
        case gpu(String)
        case write(String)
        var description: String {
            switch self {
            case .format(let s): "no gain map in \(s): JPEG and HEIC only"
            case .gpu(let s): "the gain map could not be made: \(s)"
            case .write(let s): "the gain map was not written: \(s)"
            }
        }
    }

    /// Whether this system writes and reads gain maps at all: ImageIO's gain-map key is macOS 15 (Mac Catalyst 18;
    /// the Mac's floor is Catalyst 18, so on a Mac it is always true).
    ///
    /// **The Mac's split** (D5, 2026-11-06): one gate holding the screen too
    /// (`FeatureFlags.screenShowsHDR`) would let an SDR screen export no map. A Mac's screens come and go while it
    /// runs — an SDR external monitor beside an XDR panel — and a file's map must not depend on which one the
    /// window was on. So this is the system's gate only (files, a slide's stretch: `HDRGain.isSlide`), and the
    /// screen's is `FeatureFlags.screenShowsHDR` (controls, the canvas: `HDRLook.of`, `HDRDisplays`).
    static var supported: Bool {
        if #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) { return true }
        return false
    }



    /// log2 gain at the map's resolution, as Float: the checks' measure (`plane`), never what an export holds.
    struct Plane: Sendable {
        var width: Int
        var height: Int
        var subsample: Int
        var log2Gain: [Float]

        /// The map's size for a picture: a block per `subsample` pixels a side, the last ones partial.
        static func size(width: Int, height: Int, subsample: Int) -> (Int, Int) {
            ((width + subsample - 1) / subsample, (height + subsample - 1) / subsample)
        }
    }

    /// The map as the file takes it: one 8-bit code a block, row-major, `width` bytes a row —
    /// log2 gain over log2 H, 0 … 255 (Gamma 1, GainMapMin 0, GainMapMax log2 H).
    struct Map: Sendable {
        var width: Int
        var height: Int
        var subsample: Int
        var codes: Data
    }

    /// What is attached to the file: the map and the headroom H it is encoded against.
    struct Attachment: Sendable {
        var map: Map
        var headroom: Double
    }

    // MARK: the container

    /// log2 H as the codes are scaled to it (an H of 1 is held a hair above, so nothing divides by 0).
    static func top(_ headroom: Double) -> Double { log2(max(headroom, 1.0001)) }

    /// One map value's 8-bit code against H.
    static func code(_ log2Gain: Double, headroom: Double) -> UInt8 {
        UInt8((min(1, max(0, log2Gain / top(headroom))) * 255).rounded())
    }

    /// A Float plane's codes, in Swift: the checks' reference for the kernel's own (`map(of:)`).
    static func map(from plane: Plane, headroom: Double) -> Map {
        Map(width: plane.width, height: plane.height, subsample: plane.subsample,
            codes: Data(plane.log2Gain.map { code(Double($0), headroom: headroom) }))
    }

    /// Apple's HDRToneMap metadata for a map encoded against H, its codes read with `gamma` (1: log2 gain
    /// linear in the code, every export's since 11-03; the camera layout's shared map has its own, `HDRContainer`).
    static func metadata(headroom: Double, gamma: Double = 1) -> CGMutableImageMetadata {
        let ns = "http://ns.apple.com/HDRToneMap/1.0/" as CFString, prefix = "HDRToneMap" as CFString
        let meta = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        CGImageMetadataRegisterNamespaceForPrefix(meta, ns, prefix, &error)
        func tag(_ name: String, _ v: CFTypeRef, _ t: CGImageMetadataType = .default) -> CGImageMetadataTag {
            CGImageMetadataTagCreate(ns, prefix, name as CFString, t, v)!
        }
        func set(_ name: String, _ v: CFTypeRef, _ t: CGImageMetadataType = .default) {
            CGImageMetadataSetTagWithPath(meta, nil, "HDRToneMap:\(name)" as CFString, tag(name, v, t))
        }
        let top = String(format: "%.6f", log2(max(headroom, 1)))
        set("Version", "1" as CFString)
        set("BaseHeadroom", "0.000000" as CFString)
        set("AlternateHeadroom", top as CFString)
        set("BaseColorIsWorkingColor", "True" as CFString)
        let fields: [String: CGImageMetadataTag] = [
            "GainMapMin": tag("GainMapMin", "0.000000" as CFString), "GainMapMax": tag("GainMapMax", top as CFString),
            "Gamma": tag("Gamma", String(format: "%.6f", gamma) as CFString), "BaseOffset": tag("BaseOffset", "0.000000" as CFString),
            "AlternateOffset": tag("AlternateOffset", "0.000000" as CFString)]
        let channel = CGImageMetadataTagCreate(ns, prefix, "ChannelMetadata" as CFString, .structure, fields as CFDictionary)!
        set("ChannelMetadata", [channel] as CFArray, .arrayOrdered)
        return meta
    }

    /// The map added to a destination the picture was already added to (`ExportWriter.write`'s `gainMap`).
    /// ImageIO's ISO gain map is macOS 15 (Catalyst 18); before, it is refused (the build's deployment floor is lower).
    static func attach(_ a: Attachment, to destination: CGImageDestination, gamma: Double = 1) throws {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) else { throw Failure.write("ISO gain maps need iOS 18") }
        let m = a.map
        guard m.codes.count == m.width * m.height else { throw Failure.write("\(m.codes.count) codes for a \(m.width) × \(m.height) map") }
        let description: [CFString: Any] = [kCGImagePropertyWidth: m.width, kCGImagePropertyHeight: m.height,
                                            kCGImagePropertyBytesPerRow: m.width,
                                            kCGImagePropertyPixelFormat: kCVPixelFormatType_OneComponent8]
        let info: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: m.codes as CFData,
                                     kCGImageAuxiliaryDataInfoDataDescription: description,
                                     kCGImageAuxiliaryDataInfoMetadata: metadata(headroom: a.headroom, gamma: gamma)]
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, info as CFDictionary)
    }

    /// Whether a written file carries an ISO gain map.
    static func present(in source: CGImageSource) -> Bool {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    }

    /// A written file's map, as its description gives it: width × height. Nil without one.
    static func size(in source: CGImageSource) -> (width: Int, height: Int)? {
        guard #available(iOS 18.0, macOS 15.0, macCatalyst 18.0, *),
              let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any],
              let d = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any],
              let w = d[kCGImagePropertyWidth] as? Int, let h = d[kCGImagePropertyHeight] as? Int else { return nil }
        return (w, h)
    }

    #if DEBUG
    /// A debug build's witness of each export's map as it was meant (before any layout recoded it), with the
    /// file it went into: the HDR export check (`MacExportHDRCheck`) compares what a reader decodes to it.
    nonisolated(unsafe) static var exportWitness: ((URL, Attachment) -> Void)?
    #endif
}

extension ExportRecipe.Format {
    /// Whether a file of this format can carry a gain map: JPEG and HEIF. ImageIO drops a map from PNG
    /// (measured 10-22) and TIFF has none, so an Enable HDR frame exported as either is today's file.
    var carriesGainMap: Bool { self == .jpeg || self == .heif }
}
