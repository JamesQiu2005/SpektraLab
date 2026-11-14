//  LensResolver.swift — who corrects a photograph's lens, and with what: resolved once per open, and handed to every
//  place its file is decoded.
//
//  A frame's 镜头校正 is part of its edit (`DecodeSettings`: `lensCorrection` on or off, `lensProfile` automatic or a
//  database lens, 畸变 `lensDistortion`, 光衰减 `lensLightFalloff`, 隐藏畸变区域 `lensHideDistortedAreas`). What it
//  *does* depends on things the edit does not hold — whether macOS has a profile for the lens and really applies it,
//  whether the file carries its own, what the app's lens database knows — so it is resolved (`LensResolution`), and
//  every decode of the file (`RawExposure.prepare`, `DigitalDecode.image`, through `LensCorrection.prepare`) and
//  every key of its pixels (`LensCorrection.word`, `DevelopStamp`, `MaskMadeOn`) reads the same answer from here.
//
//  **Automatic, in order**: Core Image, where it says it supports the lens *and* its correction was seen to change
//  the picture (`CoreImageVerdicts`: a user's Canon EOS R6 Mark II with the RF 45mm F1.2 STM was not changed by the
//  switch in 2.3.2, so `isLensCorrectionSupported` alone is not believed); else the file's own parameters (a Sony
//  ARW's, a DNG's OpcodeList3: `LensProfileReader`); else a database lens whose recorded EXIF name is the frame's
//  (`LensDatabase.Match.exif` — never `.name` or `.similar`, which are only offered); else nobody. A file that is
//  already corrected (an Apple ProRAW, any linear DNG with no profile of its own to apply) gets nothing and no
//  recommendation. **A chosen lens** is the database's profile of it for this frame, for any camera: Core Image's own
//  correction is then off, and the app's step applies it.
//
//  **Once per open, and cheap everywhere else.** The full answer needs the file's EXIF, the database (an actor) and,
//  the first time a camera, lens and focal length are seen, a measurement of Core Image (two draft decodes, 0.3–2 s on
//  this Mac). `resolve` makes it, off the main actor, when a page opens a frame (`OpenFrameSession.resolveLens`) and
//  before an export renders one; it is kept for the session by file and choice. `current` is what a decode or a key
//  asks, on any thread, at any rate (a library's stamps are compared frame by frame): the kept answer where there is
//  one, else a *provisional* one that is exactly what 2.4.0's first stages did — Core Image where the filter says it
//  supports the lens (decided at the decode, which has the filter open), else the file's own, else nobody; its word
//  by the file's name and a DNG's opcodes alone. A chosen lens is resolved there and then (a read-only query of the
//  database file, a few milliseconds, once). So a frame never opened since launch is developed as it always was, and
//  re-develops when it is opened only where the answer is another picture.
//
//  **The amounts** are the decode's, applied on top of the kept answer at every ask (a slider's drag never waits on a
//  resolution). They do something only where the app corrects: 畸变 scales the distortion (0: the uncorrected
//  geometry, bit for bit — the step is then not installed), 隐藏畸变区域 zooms out the empty corners, 光衰减 would scale
//  a database profile's vignette — not live in this build: Adobe's gain did not verify on this Mac's wide-open samples
//  (`lightFalloffVerified`).
//  The word names each one that is not at rest and adjustable, so moving one re-develops, and moving one that does
//  nothing (any amount under Core Image) does not.

import CoreImage
import Foundation

/// A frame's lens correction as resolved: who corrects, with which profile, what its controls can do, and why.
struct LensResolution: Equatable, Sendable {
    enum Corrector: String, Sendable {
        case coreImage = "core-image"
        /// The app, from the file's own parameters (a Sony ARW's, a DNG's OpcodeList3).
        case embedded = "embedded"
        /// The app, from a lens of the database (chosen, or automatic's exact EXIF match).
        case database = "database"
        case nobody = "nobody"
    }

    /// Why, for the panel's line under the profile (English; the panel looks it up as it shows it).
    enum Why: String, Sendable {
        case off = "Lens Correction is off"
        case notRAW = "Only a RAW file's lens is corrected"
        case alreadyCorrected = "This file is already corrected"
        case coreImage = "macOS corrects this lens"
        case coreImageUnresolved = "macOS's correction, where it has one"
        case coreImageChangesNothing = "macOS's profile for this lens changes nothing"
        case embedded = "The file's own lens parameters"
        case exif = "The lens database's profile of this lens"
        case chosen = "The chosen profile"
        case chosenMissing = "The chosen lens is not in the lens database"
        case noProfile = "macOS has no profile for this lens"
        case profileWithoutDistortion = "The profile has no distortion model"
        var text: String { rawValue }
    }

    /// What the frame's choice resolved to, before its amounts: kept by file and choice (`LensResolver`).
    struct Base: Equatable, Sendable {
        var corrector: LensResolution.Corrector
        var why: Why
        /// The profile the app's step applies (`embedded`, `database`), at full strength. Nil where it is read at the
        /// decode (a provisional answer's) or where the app does not correct.
        var profile: LensProfile? = nil
        /// The database lens (chosen, or matched).
        var lens: LensDatabase.Lens? = nil
        /// What the word names the correction by: "" for Core Image and nobody (so their keys are what they were),
        /// `LensProfile.Source` for the file's own, `LensDatabase.Resolved.word` for a database lens.
        var source: String = ""
        /// Whether the profile has a vignette the app may apply (a database lens's, and not where the DNG's own
        /// OpcodeList1/2 already has Core Image apply one).
        var lightFalloffAvailable = false
        /// Whether Core Image said it supports the lens (where it was asked).
        var coreImageSupported: Bool? = nil
        /// Made by `resolve` (or a chosen lens's query): the whole answer. False: provisional, today's rule.
        var settled = false
    }

    var base: Base
    /// The decode's own fields.
    var on: Bool
    var distortion: Double
    var lightFalloff: Double
    var hideDistortedAreas: Bool
    /// Whether the file's black is repaired at its decode (`RawBlack.found`): not the lens's, but the other answer a
    /// RAW's decode takes per file, carried with this one so that every key of its pixels and the decode read the same
    /// (`EngineHost.Request.lens`, `DecodeAsk.lens`). False for every file the repair does not find.
    var rawBlack = false

    var corrector: Corrector { on ? base.corrector : .nobody }
    var why: Why { on ? base.why : .off }
    var lens: LensDatabase.Lens? { base.lens }
    var settled: Bool { base.settled }

    /// Whether the app's step corrects this frame (so the amounts are live).
    var appCorrects: Bool { on && (base.corrector == .embedded || base.corrector == .database) }
    /// 畸变 and 隐藏畸变区域 are live: the app corrects, and its profile has a distortion (a provisional Sony answer is
    /// taken to: its parameters are read at the decode).
    var adjustsDistortion: Bool { appCorrects && (base.profile.map { $0.distortion != nil } ?? (base.corrector == .embedded)) }
    var adjustsHideDistortedAreas: Bool { adjustsDistortion }
    /// 光衰减 is live: a database lens whose profile has a vignette the app may apply.
    var adjustsLightFalloff: Bool { on && base.corrector == .database && base.lightFalloffAvailable }

    /// The word of everything that moves the picture's geometry: who corrects with what, 畸变 and 隐藏畸变区域 where
    /// they are live. "" where Core Image or nobody corrects; for the file's own at rest, what 2.4.0's first stage
    /// wrote (`|lens=sony-embedded.1`), so a mask made then is not marked (`MaskMadeOn.lens`).
    var geometryWord: String {
        guard on, !base.source.isEmpty else { return "" }
        var w = "|lens=" + base.source
        if adjustsDistortion, distortion != DecodeSettings.defaultLensDistortion { w += ",d=" + DecodeSettings.amountWord(distortion) }
        if adjustsHideDistortedAreas, !hideDistortedAreas { w += ",hide=0" }
        return w
    }
    /// What every key of the frame's pixels adds (`LensCorrection.word`): the geometry's word and 光衰减 where it is live,
    /// and the black repair's where the file is found (`RawBlack`) — "" for every other file, so their keys are what they were.
    var word: String {
        var w = geometryWord
        if adjustsLightFalloff, lightFalloff != DecodeSettings.defaultLensLightFalloff { w += ",v=" + DecodeSettings.amountWord(lightFalloff) }
        if rawBlack { w += "|black=" + RawBlack.version }
        return w
    }

    /// The amounts the app's step is handed: shares of 0–1, the CA off (not built: Core Image's decode shows none),
    /// the light falloff the database's only.
    var amounts: LensCorrection.Amounts {
        LensCorrection.Amounts(distortion: adjustsDistortion ? distortion / 100 : 1,
                               vignetting: base.corrector == .database ? (adjustsLightFalloff ? lightFalloff / 100 : 0) : 1,
                               chromaticAberration: false,
                               hideDistortedAreas: adjustsHideDistortedAreas ? hideDistortedAreas : true)
    }

    /// `profile` with only the terms the amounts leave something to do: nil where nothing would change (畸变 0 and no
    /// light falloff), so the step is not installed and the decode is the uncorrected one bit for bit.
    static func step(_ profile: LensProfile, _ a: LensCorrection.Amounts) -> LensProfile? {
        var p = profile
        p.redScale = nil; p.blueScale = nil
        if a.distortion <= 0 { p.distortion = nil }
        if a.vignetting <= 0 { p.vignetting = nil }
        return p.corrects ? p : nil
    }

    init(base: Base, decode: DecodeSettings) {
        self.base = base
        on = decode.lensCorrection
        distortion = decode.lensDistortion
        lightFalloff = decode.lensLightFalloff
        hideDistortedAreas = decode.lensHideDistortedAreas
    }

    static func off(_ decode: DecodeSettings, isRAW: Bool) -> LensResolution {
        var d = decode
        if !isRAW { d.lensCorrection = false }
        return LensResolution(base: Base(corrector: .nobody, why: isRAW ? .off : .notRAW, settled: true), decode: d)
    }
}

enum LensResolver {
    // MARK: where it reads

    /// The app's lens database (`LensDatabase.file(in:)` under the app's storage), set at launch by the app's model;
    /// nil in a check that has none, which then resolves no database lens.
    static var database: LensDatabase? { configured.withLock { $0.database } }
    static var databaseFile: URL? { configured.withLock { $0.database?.url } }

    /// Sets the database and where `CoreImageVerdicts` keeps its verdicts (`LensProfiles/` beside the database).
    static func configure(database: LensDatabase?, verdicts: URL? = nil) {
        configured.withLock { $0 = (database, verdicts) }
        CoreImageVerdicts.load(from: verdicts ?? database.map { $0.url.deletingLastPathComponent().appendingPathComponent("core-image-verdicts.json") })
        forgetAll()
    }
    private static let configured = Locked<(database: LensDatabase?, verdicts: URL?)>((nil, nil))

    // MARK: the kept answers

    /// One answer a file and a choice: `path|auto`, `path|lens=<key>`.
    private static let kept = Locked<[String: LensResolution.Base]>([:])
    private static func keptKey(_ url: URL, _ pick: DecodeSettings.LensPick?) -> String {
        url.standardizedFileURL.path + (pick.map { "|lens=" + $0.key } ?? "|auto")
    }

    /// Every kept answer dropped: the database changed (a profile installed or removed), or the checks start over.
    static func forgetAll() { kept.withLock { $0.removeAll() } }

    /// An answer put where `current` finds it: what `resolve` does, and a check's injection.
    static func keep(_ base: LensResolution.Base, for url: URL, pick: DecodeSettings.LensPick?) {
        kept.withLock { $0[keptKey(url, pick)] = base }
    }

    // MARK: asking

    /// The answer for `decode` of the file at `url` now — on any thread, without waiting: the kept one, else the
    /// provisional rule (`fileName` stands for a file that is away). A chosen lens is resolved here once.
    static func current(_ url: URL?, fileName: String? = nil, decode: DecodeSettings, isRAW: Bool = true) -> LensResolution {
        var r = lensNow(url, fileName: fileName, decode: decode, isRAW: isRAW)
        r.rawBlack = isRAW && RawBlack.found(url)
        return r
    }

    private static func lensNow(_ url: URL?, fileName: String?, decode: DecodeSettings, isRAW: Bool) -> LensResolution {
        guard isRAW, decode.lensCorrection else { return .off(decode, isRAW: isRAW) }
        if let url, let base = kept.withLock({ $0[keptKey(url, decode.lensProfile)] }) {
            return LensResolution(base: base, decode: decode)
        }
        if let pick = decode.lensProfile {
            guard let url else {
                // A file that is away: named by its lens, so its keys do not move when it is back.
                return LensResolution(base: .init(corrector: .database, why: .chosen, source: LensProfile.Source.file.rawValue + ":" + pick.key),
                                      decode: decode)
            }
            let base = chosen(pick, url: url)
            keep(base, for: url, pick: pick)
            return LensResolution(base: base, decode: decode)
        }
        return LensResolution(base: provisional(url, fileName: fileName), decode: decode)
    }

    /// The whole answer for `decode` of `url`, kept for the session: what a page asks when it opens a frame. Off the
    /// main actor; the first time a camera, lens and focal length are seen, Core Image is measured (`measure`: false
    /// leaves that for later and answers provisionally where it would be needed).
    static func resolve(_ url: URL, decode: DecodeSettings, isRAW: Bool = true, measure: Bool = true) async -> LensResolution {
        var r = await lensResolved(url, decode: decode, isRAW: isRAW, measure: measure)
        r.rawBlack = isRAW && RawBlack.found(url)
        return r
    }

    private static func lensResolved(_ url: URL, decode: DecodeSettings, isRAW: Bool, measure: Bool) async -> LensResolution {
        guard isRAW, decode.lensCorrection else { return .off(decode, isRAW: isRAW) }
        if let base = kept.withLock({ $0[keptKey(url, decode.lensProfile)] }), base.settled {
            return LensResolution(base: base, decode: decode)
        }
        // A chosen lens: the database's profile, read now (`current` keeps it).
        if decode.lensProfile != nil { return current(url, decode: decode) }
        let base = await automatic(url, measure: measure)
        if base.settled { keep(base, for: url, pick: nil) }
        return LensResolution(base: base, decode: decode)
    }

    /// The lenses the panel's popup recommends for `url`, best first (`LensDatabase.recommended`): none for a file that
    /// is already corrected, nor where there is no database.
    static func recommended(for url: URL, isRAW: Bool = true) async -> [LensDatabase.Recommendation] {
        guard isRAW, let database, !alreadyCorrected(url) else { return [] }
        return (try? await database.recommended(for: LensDatabase.Frame.read(url, isRAW: isRAW))) ?? []
    }

    // MARK: the rules

    /// Today's rule, without the filter: the file's own where its name says it is a Sony's, or a DNG's OpcodeList3 has a
    /// vignette and no warp (what Core Image's support is); else Core Image's or nobody's, decided at the decode.
    static func provisional(_ url: URL?, fileName: String? = nil) -> LensResolution.Base {
        let ext = (url?.pathExtension ?? (fileName as NSString?)?.pathExtension ?? "").lowercased()
        if LensCorrection.sonyExtensions.contains(ext) {
            return .init(corrector: .embedded, why: .embedded, source: LensProfile.Source.sonyEmbedded.rawValue)
        }
        if ext == "dng", let url, let p = LensCorrection.profile(url), p.distortion == nil, p.vignetting != nil {
            return .init(corrector: .embedded, why: .embedded, profile: p, source: LensProfile.Source.dngOpcodes.rawValue)
        }
        return .init(corrector: .coreImage, why: .coreImageUnresolved)
    }

    /// A chosen lens's answer: its profile for this frame from the database file (read-only, `LensDatabase.profileNow`),
    /// the vignette kept where the file's own OpcodeList1/2 does not already have Core Image apply one.
    static func chosen(_ pick: DecodeSettings.LensPick, url: URL) -> LensResolution.Base {
        guard let file = databaseFile else { return .init(corrector: .nobody, why: .chosenMissing, settled: true) }
        let frame = facts(url)
        guard let made = LensDatabase.profileNow(file: file, lens: pick.key, for: frame, terms: LCP.Terms(vignetting: true)) else {
            return .init(corrector: .nobody, why: .chosenMissing, settled: true)
        }
        return database(made, why: .chosen, url: url)
    }

    /// Whether a database profile's light falloff (Adobe's vignette model) may be applied. **Not verified, so off**:
    /// 光衰减 is never live in this build. Measured 2026-11-13 on the four wide-open samples Adobe has a profile of
    /// (`tools/lens_profile_selftest`, the light falloff case: the log2 luminance of the frame's plain patches against
    /// r²): the FE 24-70mm F2.8 GM II at f/2.8 is flattened (−0.44 → −0.06 stop); the FE 35mm F1.8 at f/1.8 is
    /// over-corrected on one frame (−0.55 → +0.44) and not flattened on the other (−6.97 → −5.97, the room's own light),
    /// and Adobe's gain is under 1 at its centre (0.994); the Sigma 28-105mm F2.8 on a Lumix S1 II has two plain patches
    /// and is over-corrected (−2.10 → +0.41, a profile measured on a Sony body). One of four, against a bar of two.
    nonisolated(unsafe) static var lightFalloffVerified = false

    private static func database(_ made: LensDatabase.Resolved, why: LensResolution.Why, url: URL) -> LensResolution.Base {
        var profile = made.profile
        let falloff = lightFalloffVerified && profile.vignetting != nil && !LensCorrection.vignettesItself(url)
        if !falloff { profile.vignetting = nil }
        return .init(corrector: profile.corrects ? .database : .nobody, why: profile.corrects ? why : .profileWithoutDistortion,
                     profile: profile, lens: made.lens,
                     source: made.word, lightFalloffAvailable: falloff, settled: true)
    }

    /// Automatic's order (the file's header comment). `frame`: the file's facts (its EXIF, by default; a check hands
    /// a camera and lens no sample is of).
    static func automatic(_ url: URL, frame given: LensDatabase.Frame? = nil, measure: Bool) async -> LensResolution.Base {
        if alreadyCorrected(url) { return .init(corrector: .nobody, why: .alreadyCorrected, settled: true) }
        let frame = given ?? facts(url)
        guard let verdict = CoreImageVerdicts.lookup(frame) ?? (measure ? CoreImageVerdicts.measure(url, frame) : nil) else {
            return provisional(url)
        }
        if verdict.supported && verdict.corrects {
            return .init(corrector: .coreImage, why: .coreImage, coreImageSupported: true, settled: true)
        }
        if let own = LensCorrection.profile(url), own.corrects {
            return .init(corrector: .embedded, why: .embedded, profile: own,
                         source: own.source.rawValue,
                         coreImageSupported: verdict.supported, settled: true)
        }
        if let database, let match = (try? await database.recommended(for: frame))?.first(where: { $0.match == .exif }),
           let made = try? await database.profile(lens: match.lens.key, for: frame, terms: LCP.Terms(vignetting: true)),
           Self.database(made, why: .exif, url: url).corrector == .database {
            var base = Self.database(made, why: .exif, url: url)
            base.coreImageSupported = verdict.supported
            return base
        }
        return .init(corrector: .nobody, why: verdict.supported ? .coreImageChangesNothing : .noProfile,
                     coreImageSupported: verdict.supported, settled: true)
    }

    /// The file's EXIF facts, kept by path for the session (`LensDatabase.Frame.read`, ImageIO, no RAW filter).
    static func facts(_ url: URL) -> LensDatabase.Frame {
        let key = url.standardizedFileURL.path
        if let f = frames.withLock({ $0[key] }) { return f }
        let f = LensDatabase.Frame.read(url)
        if FileManager.default.isReadableFile(atPath: key) { frames.withLock { $0[key] = f } }
        return f
    }
    private static let frames = Locked<[String: LensDatabase.Frame]>([:])

    /// Whether `url` is a file whose lens is already corrected: a DNG whose raw image is linear (an Apple ProRAW, any
    /// demosaiced DNG) and carries no opcode of its own for the app to apply. Kept by path.
    static func alreadyCorrected(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng" else { return false }
        let key = url.standardizedFileURL.path
        if let kept = linear.withLock({ $0[key] }) { return kept }
        guard let tiff = LensProfileReader.tiff(url) else { return false }
        let isLinear = tiff.ifds.contains { ifd in
            (ifd.entries[0xFE].flatMap(tiff.uint) ?? 0) == 0 && ifd.entries[0x106].flatMap(tiff.uint) == 34892
        }
        let found = isLinear && LensCorrection.profile(url) == nil
        linear.withLock { $0[key] = found }
        return found
    }
    private static let linear = Locked<[String: Bool]>([:])
}

// MARK: - Core Image, measured

/// Whether Core Image's lens correction really changes a camera's picture with a lens at a focal length: its
/// `isLensCorrectionSupported`, and — where it says yes — two draft decodes of the file, on and off, compared. Kept by
/// (make, model, lens, focal length) for this macOS (`LensProfiles/core-image-verdicts.json`; another system's are
/// dropped, its RAW decoder being another), so a camera and lens is measured once, whichever of its files is opened.
///
/// Measured 2026-11-13 on `RAW_decode_tests` (draft mode, scale factor 1/8, both decodes scaled to 384 px): every file
/// Core Image supports moves by 7–40 % of its mean level (Nikon Z6 III 0.075, Canon R6 III 0.40, Leica Q3 0.22, Fuji
/// GFX100RF 0.25, Lumix S1 0.17, S1 II 0.26); every file it does not is bit-identical (0). The bar is 0.2 %. The RAW
/// filter's scale factor is used here only (the October audit's extent fault moves both decodes alike): 0.3–1.3 s a
/// verdict on this loaded Mac, against 0.4–1.9 s at full size.
enum CoreImageVerdicts {
    struct Verdict: Codable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey { case supported = "supported", corrects = "corrects", difference = "difference" }
        var supported: Bool
        /// Supported and seen to change the picture.
        var corrects: Bool
        /// The mean absolute difference over the mean level (0 where not measured).
        var difference: Double
    }
    static let bar = 0.002

    static func key(_ f: LensDatabase.Frame) -> String {
        [f.make, f.model, f.lens, f.focal.map { String(format: "%.1f", $0) } ?? ""].joined(separator: "|")
    }

    private struct Store: Codable {
        enum CodingKeys: String, CodingKey { case system = "system", verdicts = "verdicts" }
        var system: String
        var verdicts: [String: Verdict]
    }
    private static let system = ProcessInfo.processInfo.operatingSystemVersionString
    private static let store = Locked<(file: URL?, verdicts: [String: Verdict])>((nil, [:]))

    /// Reads the kept verdicts of this system from `file` (nil: none kept, nothing written).
    static func load(from file: URL?) {
        var verdicts: [String: Verdict] = [:]
        if let file, let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Store.self, from: data), s.system == system {
            verdicts = s.verdicts
        }
        store.withLock { $0 = (file, verdicts) }
    }

    static func lookup(_ f: LensDatabase.Frame) -> Verdict? { store.withLock { $0.verdicts[key(f)] } }

    /// Keeps `v` for `f`'s camera, lens and focal length, and writes the file where there is one.
    static func record(_ v: Verdict, for f: LensDatabase.Frame) {
        let (file, all) = store.withLock { s -> (URL?, [String: Verdict]) in s.verdicts[key(f)] = v; return (s.file, s.verdicts) }
        guard let file, let data = try? JSONEncoder().encode(Store(system: system, verdicts: all)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Measures `url` (heavy: never on the main thread) and keeps the verdict for `f`. Nil: the file cannot be read.
    static func measure(_ url: URL, _ f: LensDatabase.Frame) -> Verdict? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        guard filter.isLensCorrectionSupported else {
            let v = Verdict(supported: false, corrects: false, difference: 0)
            record(v, for: f)
            return v
        }
        guard let off = draft(url, on: false), let on = draft(url, on: true) else { return nil }
        let d = difference(off, on)
        let v = Verdict(supported: true, corrects: d > bar, difference: d)
        record(v, for: f)
        return v
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    private static func draft(_ url: URL, on: Bool) -> (px: [Float], w: Int, h: Int)? {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        f.isDraftModeEnabled = true
        f.scaleFactor = 0.125
        f.isLensCorrectionEnabled = on
        guard var image = f.outputImage else { return nil }
        let e = image.extent.integral
        guard e.width > 0, e.height > 0 else { return nil }
        image = image.transformed(by: .init(translationX: -e.origin.x, y: -e.origin.y))
        let small = RawExposure.scaled(image, toLongEdge: 384)
        let box = small.extent.integral
        let w = Int(box.width), h = Int(box.height)
        guard w > 0, h > 0 else { return nil }
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16, bounds: box, format: .RGBAf, colorSpace: nil)
        return (px, w, h)
    }

    /// Mean |a − b| over their common pixels' colour, over a's mean level. Sizes that differ are a change.
    static func difference(_ a: (px: [Float], w: Int, h: Int), _ b: (px: [Float], w: Int, h: Int)) -> Double {
        guard a.w == b.w, a.h == b.h else { return 1 }
        var d = 0.0, m = 0.0
        for i in 0..<a.px.count where i % 4 != 3 { d += Double(abs(a.px[i] - b.px[i])); m += Double(abs(a.px[i])) }
        return d / max(m, 1e-9)
    }
}
