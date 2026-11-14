//  LensCorrection.swift — who corrects a RAW's lens, and the word every kept picture of it is keyed by.
//
//  A frame's Lens Correction (`DecodeSettings.lensCorrection`) is asked of the RAW filter in the two places a RAW
//  is decoded (`RawExposure.prepare`, the engine's linear decode; `DigitalDecode.image`, Apple's stock decode), and
//  every tier — proxy, live, full, export — goes through one of them. `prepare` is what both call:
//
//  - **Core Image**, where it can (`isLensCorrectionSupported`): exactly as before, so a Nikon, Canon, Fuji,
//    Panasonic or Leica frame's pixels do not move by a bit;
//  - **the app**, where Core Image cannot and the file carries a profile the app reads (`LensProfileReader`: a
//    Sony ARW's own parameters; a DNG's OpcodeList3 FixVignetteRadial alone), applied in linear light inside the
//    RAW filter (`CIRAWFilter.linearSpaceFilter`) by `LensProfile.apply`;
//  - **nobody** otherwise (Apple ProRAW, already corrected; a Ricoh GR's DNG, whose OpcodeList1 Core Image applies
//    by itself; an Olympus E-300);
//  - **a lens from the database** (Adobe's measured profile resolved for the frame by `LensDatabase.profile(lens:for:)`),
//    chosen or matched by its EXIF name, for any camera, Core Image's among them: Core Image's own correction is then
//    off and the app's step applies the profile, in both decodes.
//
//  Which of these a frame gets, with which amounts, is resolved once per open (`LensResolver`, `LensResolution`); a
//  decode asks the resolver, so every decode of a file — the canvas's tiers, an export, Apple's stock decode, the
//  subject finder, the neutral pick, a pair's and a double's pictures — is corrected alike.
//
//  **The word.** A kept develop, a RAW proxy, a strip's card or a full render made before 2.4.0 of a Sony frame with
//  Lens Correction on is a picture nobody corrected, under a key that says "lens". `word` is added to every such
//  key for a frame the app now corrects, so none of them is reused. It is the resolution's (`LensResolution.word`):
//  for a frame not resolved yet, decided from the file's name and, for a DNG, its OpcodeList3 — never by opening the
//  RAW filter, which costs tens of milliseconds a file and is asked of every frame of a library when its stamps are
//  compared. A Sony ARW is the app's whatever its tags (measured: no
//  Sony body's ARW is supported by Core Image's lens correction on macOS 15–27); one that carries no parameters is
//  developed again once, for nothing, which is the cheap side of being wrong.

import CoreImage
import Foundation

enum LensCorrection {
    enum Corrector: String, Sendable {
        case coreImage = "Core Image"
        case app = "the app's embedded reader"
        case nobody = "nobody"
        case database = "the lens database"
    }

    /// The amounts the app's step is handed (distortion and light falloff 0–1, CA and "hide distorted areas" on or
    /// off): the frame's 畸变, 光衰减 and 隐藏畸变区域 where they are live (`LensResolution.amounts`).
    struct Amounts: Equatable, Sendable {
        var distortion = 1.0
        var vignetting = 1.0
        var chromaticAberration = true
        var hideDistortedAreas = true
    }

    /// Asks `filter` for the frame's correction as resolved (`LensResolver.current` of `url` and `decode`, unless the
    /// caller hands its own `resolution`), and says who makes it. Core Image's flag is set as the callers set it before
    /// (`coreImageAlways`: the engine's decode sets it whatever the support, Apple's stock decode only where it is
    /// supported) — on, except where the app's step replaces a correction Core Image supports (a database lens; the
    /// file's own where Core Image's was seen to change nothing). The app's step is the filter's linear-space filter.
    ///
    /// A provisional answer (`LensResolution.Base.settled` false) is 2.4.0's first rule, decided here where the filter
    /// is open: Core Image where it is supported, else the file's own profile, else nobody.
    @discardableResult
    static func prepare(_ filter: CIRAWFilter, url: URL, decode: DecodeSettings, coreImageAlways: Bool,
                        resolution: LensResolution? = nil) -> Corrector {
        let r = resolution ?? LensResolver.current(url, decode: decode)
        applied.withLock { $0[url.standardizedFileURL.path] = r.word }
        let supported = filter.isLensCorrectionSupported
        func coreImage(_ on: Bool) { if coreImageAlways || supported { filter.isLensCorrectionEnabled = on } }
        guard r.on else { coreImage(false); return .nobody }
        switch (r.base.corrector, r.settled) {
        case (.database, _):
            coreImage(false)
            guard let p = r.base.profile, install(p, on: filter, amounts: r.amounts) else { return .nobody }
            return .database
        case (.embedded, true):
            // Where Core Image supports the lens and was seen to change nothing, its flag goes off with the app's step on.
            coreImage(!supported)
            guard let p = r.base.profile, install(p, on: filter, amounts: r.amounts) else { return .nobody }
            return .app
        case (.coreImage, true):
            coreImage(true)
            return .coreImage
        case (.nobody, true):
            coreImage(true)
            return .nobody
        default:
            coreImage(true)
            if supported { return .coreImage }
            guard let p = r.base.profile ?? profile(url), install(p, on: filter, amounts: r.amounts) else { return .nobody }
            return .app
        }
    }

    /// The word (`LensResolution.word`) of the answer the last decode of each file was made with, by path: what a check
    /// holds a develop's key to (`MacLensCheck`, the race: a picture is never kept under a key that does not name the
    /// corrector it was decoded with).
    static let applied = Locked<[String: String]>([:])

    /// Installs the step of `profile` at `amounts`; false (nothing installed) where the amounts leave it nothing to do.
    private static func install(_ profile: LensProfile, on filter: CIRAWFilter, amounts: Amounts) -> Bool {
        guard let profile = LensResolution.step(profile, amounts) else { return false }
        let step = LensProfileFilter()
        step.profile = profile
        step.distortionAmount = amounts.distortion
        step.vignettingAmount = amounts.vignetting
        step.chromaticAberration = amounts.chromaticAberration
        step.hideDistortedAreas = amounts.hideDistortedAreas
        filter.linearSpaceFilter = step
        return true
    }

    /// Whether `url` is a DNG whose OpcodeList1 or 2 has a FixVignetteRadial, which Core Image applies by itself (kept
    /// by path for the session).
    static func vignettesItself(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng" else { return false }
        let key = url.standardizedFileURL.path
        if let kept = vignettes.withLock({ $0[key] }) { return kept }
        guard let tiff = LensProfileReader.tiff(url) else { return false }
        let found = tiff.ifds.contains { ifd in
            [0xC740, 0xC741].contains { tag in
                ifd.entries[tag].flatMap(tiff.bytes).map { LensProfileReader.opcodes($0).vignette != nil } ?? false
            }
        }
        vignettes.withLock { $0[key] = found }
        return found
    }
    private static let vignettes = Locked<[String: Bool]>([:])

    /// The profile the app reads from `url`, kept by path for the session (a file that cannot be read is not kept,
    /// so a volume that comes back is read again).
    static func profile(_ url: URL) -> LensProfile? {
        let key = url.standardizedFileURL.path
        if let kept = profiles.withLock({ $0[key] }) { return kept }
        guard FileManager.default.isReadableFile(atPath: key) else { return nil }
        let read = LensProfileReader.profile(url)
        profiles.withLock { $0[key] = .some(read) }
        return read
    }
    private static let profiles = Locked<[String: LensProfile?]>([:])

    // MARK: the word

    /// The extensions of Sony's RAW files.
    static let sonyExtensions = DecodeSettings.sonyRAWExtensions

    /// What is added to a RAW's keys for its lens correction (`LensResolution.word`): "" where Core Image corrects or
    /// nobody does and no amount is live, so those keys are what they always were. `source` is the file the frame is
    /// decoded from, where it is known; `fileName` the frame's own name (an original that is away keeps its word).
    static func word(source: URL?, fileName: String? = nil, decode: DecodeSettings, isRAW: Bool = true) -> String {
        LensResolver.current(source, fileName: fileName, decode: decode, isRAW: isRAW).word
    }

    /// The geometry's part of it (`LensResolution.geometryWord`): what a mask's `MaskMadeOn` and `SubjectFinder`'s
    /// geometry are held to — every field that moves the picture's pixels, but the light falloff.
    static func geometryWord(source: URL?, fileName: String? = nil, decode: DecodeSettings, isRAW: Bool = true) -> String {
        LensResolver.current(source, fileName: fileName, decode: decode, isRAW: isRAW).geometryWord
    }
}

extension DecodeSettings {
    /// `pixelsKey` with the lens word of `source` (`LensCorrection.word`): what every key of a RAW's pixels is made
    /// from, where the file is known.
    func pixelsKey(source: URL?, fileName: String? = nil) -> String {
        pixelsKey + LensCorrection.word(source: source, fileName: fileName, decode: self)
    }

    /// The same, from an answer already taken (`lens`, a request's: `EngineHost.Request.lens`), where there is one.
    func pixelsKey(source: URL?, lens: LensResolution?) -> String {
        guard let lens else { return pixelsKey(source: source) }
        return pixelsKey + lens.word
    }
}

/// A value behind a lock, for the profile cache (decodes run on many threads).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
