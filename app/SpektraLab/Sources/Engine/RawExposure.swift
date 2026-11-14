// One RAW source recipe. Parameter readback and pixels use the same filter;
// EXIF exposure/ISO are provenance, never a second gain. Shared with the
// simulator qualification harness so the tested decode is the shipped one.
import CoreImage
import Foundation
import ImageIO

enum RawExposure {
    struct Prepared {
        var image: CIImage
        var asShot: (temperature: Double, tint: Double)
        var facts: RawExposureFacts
        /// The decode's own pixels before it is made smaller: what Core Image holds while it makes the picture,
        /// and what a scaled picture is rendered in bands of (`FrameDecoder.rawBandSourcePixels`).
        var sourcePixels: Double
        /// The black repair's pedestal as `how` names it (`RawBlack`): "" for every file it does not repair.
        var black = ""
        var how: String {
            "RAW \(facts.decoderVersion) [\(facts.treatment.rawValue); baseline=\(facts.baselineExposureEV); shadow=\(facts.appliedShadowBias)\(black)]"
        }
    }

    /// `lens`: the frame's lens correction as resolved; nil asks the resolver (`LensResolver.current`), as every decode does.
    /// It also says whether the file's black is repaired (`LensResolution.rawBlack`, `RawBlack`): a found file's pedestal
    /// is added to Core Image's linear output, before anything reads the pixels.
    static func prepare(_ url: URL, settings: DecodeSettings, longEdge: Int?, lens: LensResolution? = nil) -> Prepared? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let asShot = (Double(filter.neutralTemperature), Double(filter.neutralTint))
        let baseline = filter.baselineExposure
        guard baseline.isFinite else { return nil }
        let exif = filter.properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func number(_ key: CFString) -> Double? { (exif[key as String] as? NSNumber)?.doubleValue }
        var facts = RawExposureFacts(sourcePath: url.standardizedFileURL.path,
            treatment: settings.rawExposureTreatment, decoderVersion: filter.decoderVersion.rawValue,
            baselineExposureEV: Double(baseline), initialExposureEV: Double(filter.exposure),
            initialShadowBias: Double(filter.shadowBias), appliedExposureEV: Double(filter.exposure),
            appliedShadowBias: Double(filter.shadowBias), captureBiasEV: number(kCGImagePropertyExifExposureBiasValue),
            captureISO: (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue,
            captureSeconds: number(kCGImagePropertyExifExposureTime), captureFNumber: number(kCGImagePropertyExifFNumber))
        recipe(filter, settings: settings)
        // The frame's lens correction as resolved (`LensResolver`): Core Image's where it really corrects (the flag set as
        // it always was, so those frames' pixels do not move); the app's step of the file's own or a database profile.
        let resolution = lens ?? LensResolver.current(url, decode: settings)
        LensCorrection.prepare(filter, url: url, decode: settings, coreImageAlways: true, resolution: resolution)
        whiteBalance(filter, settings: settings)
        facts.appliedExposureEV = Double(filter.exposure)
        facts.appliedShadowBias = Double(filter.shadowBias)
        guard var image = filter.outputImage else { return nil }
        let whole = image.extent.integral
        // A file whose deep shadows Core Image leaves below zero (`RawBlack`): its pedestal, and its shadows' colour faded to
        // neutral where the clamp destroyed it, in linear light, before the scale and everything after it. Nothing is done
        // to any other file, whose decode is what it was bit for bit.
        var how = ""
        if resolution.rawBlack {
            let pedestal = RawBlack.pedestal(url, settings: settings)
            if !pedestal.isZero {
                image = RawBlack.repair(pedestal, to: image)
                how = " black=" + pedestal.text + (RawBlack.fades ? ",neutral" : "")
            }
        }
        var prepared = Prepared(image: scaled(image, toLongEdge: longEdge), asShot: asShot, facts: facts,
                                sourcePixels: Double(whole.width) * Double(whole.height))
        prepared.black = how
        return prepared
    }

    /// The engine's recipe on `filter`, but the lens and the white balance: the file's own exposure reference kept,
    /// Apple's boosts, gamut mapping, local tone map and extended range off. Shared with `RawBlack`'s measurement.
    static func recipe(_ filter: CIRAWFilter, settings: DecodeSettings) {
        if settings.rawExposureTreatment.keepsSourceReference {
            // Preserve the per-file reference once, inside this decoder. In
            // particular do not add baseline, EXIF bias or ISO after decode.
            // `source-reference.2` adds its one stop here (`sourceOffsetEV`).
            filter.baselineExposure = filter.baselineExposure
            filter.exposure = Float(settings.rawExposureTreatment.sourceOffsetEV)
            filter.shadowBias = 0
        }
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0
    }

    /// The frame's white balance on `filter`: as shot, a preset's kelvin, or the custom temperature and tint.
    static func whiteBalance(_ filter: CIRAWFilter, settings: DecodeSettings) {
        switch settings.whiteBalance {
        case .asShot: break
        case .custom:
            filter.neutralTemperature = Float(settings.temperature)
            filter.neutralTint = Float(settings.tint)
        default:
            if let kelvin = settings.whiteBalance.kelvin { filter.neutralTemperature = Float(kelvin) }
        }
    }

    /// Same bounded, clamped Lanczos recipe as FrameDecoder; never use RAW
    /// scaleFactor (the RAW 9 extent fault is recorded in the October audit).
    static func scaled(_ image: CIImage, toLongEdge longEdge: Int?) -> CIImage {
        let whole = image.extent.integral
        let long = max(whole.width, whole.height)
        guard let longEdge, long > CGFloat(longEdge), let scale = CIFilter(name: "CILanczosScaleTransform") else { return image }
        let k = CGFloat(longEdge) / long
        scale.setValue(image.transformed(by: .init(translationX: -whole.origin.x, y: -whole.origin.y)).clampedToExtent(), forKey: kCIInputImageKey)
        scale.setValue(k, forKey: kCIInputScaleKey)
        scale.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let out = scale.outputImage else { return image }
        return out.cropped(to: CGRect(x: 0, y: 0, width: (whole.width * k).rounded(), height: (whole.height * k).rounded()))
    }
}
