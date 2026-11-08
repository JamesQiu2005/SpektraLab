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
        var how: String {
            "RAW \(facts.decoderVersion) [\(facts.treatment.rawValue); baseline=\(facts.baselineExposureEV); shadow=\(facts.appliedShadowBias)]"
        }
    }

    static func prepare(_ url: URL, settings: DecodeSettings, longEdge: Int?) -> Prepared? {
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
        if settings.rawExposureTreatment.keepsSourceReference {
            // Preserve the per-file reference once, inside this decoder. In
            // particular do not add baseline, EXIF bias or ISO after decode.
            // `source-reference.2` adds its one stop here (`sourceOffsetEV`).
            filter.baselineExposure = baseline
            filter.exposure = Float(settings.rawExposureTreatment.sourceOffsetEV)
            filter.shadowBias = 0
        }
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.isGamutMappingEnabled = false
        filter.localToneMapAmount = 0
        filter.extendedDynamicRangeAmount = 0
        filter.isLensCorrectionEnabled = settings.lensCorrection
        switch settings.whiteBalance {
        case .asShot: break
        case .custom:
            filter.neutralTemperature = Float(settings.temperature)
            filter.neutralTint = Float(settings.tint)
        default:
            if let kelvin = settings.whiteBalance.kelvin { filter.neutralTemperature = Float(kelvin) }
        }
        facts.appliedExposureEV = Double(filter.exposure)
        facts.appliedShadowBias = Double(filter.shadowBias)
        guard let image = filter.outputImage else { return nil }
        return Prepared(image: scaled(image, toLongEdge: longEdge), asShot: asShot, facts: facts)
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
