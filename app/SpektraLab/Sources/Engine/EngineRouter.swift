//  EngineRouter.swift — the app's side of the engine: which engine runs, and what a job hands it.
//
//  One object, made once (`AppServices`), on the main actor. It decides which
//  `DevelopEngine` the scheduler drives, and it is the only thing in the app
//  that knows there may be a real one:
//
//  - **the engine itself** (`SpkEngine`, where this build links it —
//    `SPK_ENGINE`, `gen_project.py`) for a library of the user's own pictures:
//    created once on the app's own Metal device, for the app's life;
//  - **the simulation** (`SimulatedEngine`) for the drawings' own library —
//    the snapshot harness, `--demo`, a simulator opened on the demo frames —
//    whose pictures SpektraLab has already developed and which must never be
//    developed again (a print of a print), and wherever the engine is not
//    linked.
//
//  **A host does not fall back quietly.** If the engine should be running
//  and is not — it was not built into this app, or it refused to start (the
//  math probe refuses kernels built with fast math, on purpose: AGENTS.md) —
//  the simulation stands in so the pages still work, `failure` says why in
//  the app's words, and Settings and the status line show it.
//
//  A job's answers — its file, its decode, its whole wire — are captured here
//  when the job is submitted (`prepare`), because the engine asks for them on
//  its own queue (`EngineHost`).
//
//  **A double exposure (RFC-048) is handed over as a pair is**: a piece the
//  host composes from its photographs' own files — their light added, not
//  placed (`DoubleDevelop.swift`) — and the whole's wire, one frame, one date.
//  Its stamp and source word are the piece's key and the look's; its export,
//  its strip's cards and its press-and-hold of one exposure alone
//  (`prepareAlone`) are composed the same way; and what its open decodes is
//  told to the scheduler before the job is planned (`composition(of:)`). It is
//  never a picture under a pair's hole, and neither is a pair an exposure.

import CoreGraphics
import Foundation
import UIKit
import os
#if SPK_ENGINE
import Metal
#endif

@MainActor
final class EngineRouter {
    enum Purpose: Sendable {
        /// The develop page's canvas: the picture goes to the page.
        case canvas
        /// A frame's own develop — a shot's, an import's: the picture is kept.
        case keep
    }

    /// The engine every render goes to.
    let engine: any DevelopEngine
    /// Why the engine is not running where it should be; nil when it runs, and
    /// where a simulation is what was asked for.
    let failure: String?
    /// The commit the engine's sources were built at ("24edcf8 2026-10-04").
    let commit: String

    var makesPictures: Bool { engine.makesPictures }

    /// A develop page's picture has landed.
    var onCanvas: ((_ frame: UUID, _ image: UIImage, _ stamp: String) -> Void)?
    /// Enable HDR's curve of the session that made a develop page's next picture (`stamp`), or the engine's
    /// refusal: it comes just before that picture (`onCanvas`).
    var onHDRCurve: ((_ frame: UUID, _ answer: HDRSessionCurve.Answer, _ stamp: String) -> Void)?
    /// A frame's develop has been written.
    var onKept: ((_ frame: UUID, _ picture: DevelopedPicture) -> Void)?
    /// A RAW's own white balance, read at its decode.
    var onAsShot: ((_ frame: UUID, _ temperature: Double, _ tint: Double) -> Void)?
    var onRawExposure: ((_ frame: UUID, _ facts: RawExposureFacts) -> Void)?
    /// The engine's meter has read one picture of a half-frame pair alone:
    /// which pair, which hole (0 the first), the stops it chose, and what the
    /// reading is for (`HalfFramePair.meterKey`). Kept in the pair, so the
    /// picture is read once.
    var onMetered: ((_ pair: UUID, _ index: Int, _ ev: Double, _ key: String) -> Void)?
    /// The engine's meter has read one exposure of a double exposure alone
    /// (RFC-048 §4): which double, which exposure, the stops it chose, and
    /// what the reading is for (`DoubleExposure.meterKey`). The model keeps it
    /// in the double (`DoubleExposure.keep(reading:of:for:)`), so the picture
    /// is read once and does not pump while it is moved.
    var onDoubleMetered: ((_ double: UUID, _ position: DoubleExposure.Position, _ ev: Double, _ key: String) -> Void)?
    /// The engine has said where a half-frame pair's two frames are on the
    /// strip it has just developed for the develop page: each gate's
    /// rectangle, normalised to the canvas with a top-left origin, the first
    /// frame's first. It comes before that develop's picture (`onCanvas`).
    var onGates: ((_ pair: UUID, _ rects: [CGRect]) -> Void)?
    /// The host's body, for a film edge that has none of its own yet
    /// (`AppSettings.bodySeed`).
    var bodySeed: () -> Int = { 1 }
    /// Settings' *Crop re-maps the frame* (`AppSettings.cropRemapsFrame`): whether a photo's crop is
    /// the frame its Film Format describes, said on the wire as `film_format_mm`
    /// (`FrameEdit.wireFilmFormatMM`).
    var cropIsFrame: () -> Bool = { false }
    /// The library's frames by id: a half-frame pair names the two frames on
    /// it, and is developed from their files.
    var frames: (LibraryFrame.ID) -> LibraryFrame? = { _ in nil }
    /// Originals that stay in Photos, brought here while they are worked on.
    /// Nil where nothing is: a test, a service with no library.
    var originals: Originals?

    private let log = Logger(subsystem: "com.spektralab.mac", category: "engine")
    /// The last Enable HDR curve the log was told of (`said`).
    private var lastHDRCurve = ""

    /// Whether a canvas develop of `edit` asks for Enable HDR's curve with its picture: where the page draws that
    /// picture's HDR (`HDRLook.of`: the switch on, the film applied, a system that writes maps, a screen that shows
    /// HDR). Then the curve is carried with the picture it is of, and follows the edit step by step. Anywhere else
    /// the page asks for it alone once the edit settles, and when the switch is turned on (`OpenFrameSession.askCurve`).
    /// The 2026-11-06 review: asked with every develop, a print-side step (Print Exposure, a filter) re-probes the
    /// medium — the probe's key holds them — and an Endura step's live render took 9.5–10.6 ms more (23 ms, +43 %)
    /// on every Mac, an HDR screen or not, for a curve nothing drew.
    static func curveWithDevelop(_ edit: FrameEdit) -> Bool {
        edit.hdr && edit.appliesFilm && HDRGainMap.supported && FeatureFlags.screenShowsHDR
    }

    /// Enable HDR's curve of the session the page's canvas keeps open on `frameID`, asked alone (`spk_session_hdr_curve`
    /// on the engine's queue: no render). Nil where there is none to ask: no engine, or no session on that frame.
    /// After the page's settled `spk_scene_latitude` it is that call's cached medium (0.3 ms).
    func hdrCurve(_ frameID: UUID, headroom: Double = HDRSessionCurve.headroom) async -> HDRSessionCurve.Answer? {
        #if SPK_ENGINE
        guard let spk, let answer = await spk.hdrCurve(frameID: frameID, request: HDRSessionCurve.request(headroom: headroom)) else { return nil }
        said(frameID, answer)
        return answer
        #else
        return nil
        #endif
    }

    /// One log line a change of curve, never one a slider's develop.
    private func said(_ frame: UUID, _ answer: HDRSessionCurve.Answer) {
        let line: String
        switch answer {
        case .curve(let c): line = frame.uuidString + c.curve.name
        case .refused(let why): line = frame.uuidString + why
        }
        guard line != lastHDRCurve else { return }
        lastHDRCurve = line
        switch answer {
        case .curve(let c): Log.note(.develop, "hdr curve", c.said.merging(["frame": frame.uuidString]) { a, _ in a })
        case .refused(let why): Log.note(.develop, "hdr curve refused", ["frame": frame.uuidString, "why": why])
        }
    }
    #if SPK_ENGINE
    private let host: EngineHost?
    private let spk: SpkEngine?
    #endif

    /// `wantsEngine`: the library is the user's own, so its frames are to be
    /// developed. `simulatedSpeed` is the snapshot harness's knob.
    init(wantsEngine: Bool, simulatedSpeed: Double = 1) {
        var failure: String?
        #if SPK_ENGINE
        var host: EngineHost?, spk: SpkEngine?
        var commit = ""
        if wantsEngine {
            let resources = Bundle.main.resourceURL?.appendingPathComponent("EngineResources", isDirectory: true)
            // The kernels: `spektralab.metallib`, built with safe math by tools/build_engine_mac.sh
            // (the engine refuses a fast-math library).
            let haveKernels = resources.map { r in
                FileManager.default.fileExists(atPath: r.appendingPathComponent("spektralab.metallib").path)
            } ?? false
            if let resources, haveKernels,
               let device = MTLCreateSystemDefaultDevice() {
                let made = EngineHost(device: device)
                do {
                    let engine = try SpkEngine(resources: resources.path, device: device, source: made)
                    made.engine = engine
                    host = made
                    spk = engine
                    commit = ((try? String(contentsOf: resources.appendingPathComponent("ENGINE-COMMIT.txt"), encoding: .utf8)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    // The engine's own words go to the log; they may name a profile.
                    if case EngineError.failed(let m) = error { Logger(subsystem: "com.spektralab.mac", category: "engine").error("the engine did not start: \(m, privacy: .public)") }
                    failure = "The engine did not start on this device."
                }
            } else {
                failure = "The engine's resources are not in this app."
            }
        }
        self.host = host
        self.spk = spk
        self.commit = commit
        engine = spk ?? SimulatedEngine(speed: simulatedSpeed)
        #else
        if wantsEngine { failure = "This app was built without the engine." }
        commit = ""
        engine = SimulatedEngine(speed: simulatedSpeed)
        #endif
        self.failure = failure

        #if SPK_ENGINE
        host?.onDelivery = { [weak self] delivery in
            Task { @MainActor in self?.landed(delivery) }
        }
        #endif
    }

    /// The engine's identity in a develop's stamp: its effect versions — two
    /// engines that differ there render different pictures from the same
    /// settings — and the commit its sources were built at.
    var identity: String { engine.effectVersions + "|" + commit }

    /// The frame shows no develop of its own, or one its edit no longer makes: its preview is owed
    /// (2026-11-05: one test for Export's cells, the Light Table's films and a paste's tiles). Whether
    /// the original can be read now is not asked: a frame pasted onto while its disk is away is owed
    /// all the same (it is developed when asked once the disk is back, `prepare` refusing meanwhile).
    func needsDevelop(_ frame: LibraryFrame) -> Bool {
        guard let kept = frame.shownDevelop else { return true }
        guard let stamp = stamp(frame, edit: frame.edit, longEdge: frame.previewDevelopLongEdge(frame.edit), evenAway: true) else { return false }
        return kept.stamp != stamp
    }

    /// What a develop of `edit` at this size would be stamped, or nil where no
    /// picture is made or the frame has nothing to develop from (`evenAway`: an
    /// original that is away now still has the stamp a develop of it would have).
    func stamp(_ frame: LibraryFrame, edit: FrameEdit, longEdge: Int, evenAway: Bool = false) -> String? {
        if let double = frame.double { return stamp(double, item: frame, look: edit, longEdge: longEdge) }
        if let pair = frame.pair { return stamp(pair, frames: held(by: pair), look: edit, longEdge: longEdge) }
        guard makesPictures, !frame.isDemo, evenAway || frame.developSource != nil else { return nil }
        return DevelopStamp.of(wire: wire(frame, edit: edit, longEdge: longEdge), cut: edit.hostCut(source: frame.originalSize),
                               turns: edit.hostTurns(source: frame.originalSize),
                               decode: edit.decode, isRAW: frame.developsFromRAW, longEdge: longEdge, engine: identity,
                               origin: frame.stampOrigin,
                               lens: LensCorrection.word(source: frame.developSource, fileName: frame.fileName, decode: edit.decode,
                                                         isRAW: frame.developsFromRAW))
    }

    // MARK: an original that stays in Photos

    /// The frames whose own files a develop of `frame` reads: itself — or,
    /// for a half-frame pair, the frames on it; for a double exposure, its
    /// photographs, bottom first.
    func sources(of frame: LibraryFrame) -> [LibraryFrame] {
        if let double = frame.double {
            let frames = held(by: double)
            return DoubleExposure.Position.allCases.compactMap { frames[$0] }
        }
        guard let pair = frame.pair else { return [frame] }
        let frames = held(by: pair)
        return HalfFramePair.Side.allCases.compactMap { frames[$0] }
    }

    /// Whether a develop of `frame` would read an original that stays in
    /// Photos and is not here: it is to be brought first (`bring`).
    func isAway(_ frame: LibraryFrame) -> Bool {
        guard let originals else { return false }
        return sources(of: frame).contains { originals.isAway($0) }
    }

    /// Whether a develop of `edit` at the frame's preview size — a page's, a
    /// card's, the queue's — has to bring the original first: it is away, and
    /// the RAW's proxy is not here to stand for it (`RawProxy`). Only an
    /// export, or a job larger than the preview, needs the original itself.
    func needsBringing(_ frame: LibraryFrame, edit: FrameEdit) -> Bool {
        isAway(frame) && !hasProxy(frame, decode: edit.decode, longEdge: frame.previewDevelopLongEdge(edit))
    }

    // MARK: a RAW's proxy

    /// The proxy a job of `frame` at its preview size reads or makes, decoded
    /// with `decode`: nil for anything but a RAW photograph developed from its
    /// own file, and where nothing is kept on disk. `longEdge` is the job's
    /// decode (`LibraryFrame.previewDevelopLongEdge`: a cropped frame's is
    /// larger than its preview); nil is the frame's own edit's.
    func proxy(_ frame: LibraryFrame, decode: DecodeSettings, longEdge: Int? = nil, lens: LensResolution? = nil) -> RawProxy.Ask? {
        let edge = longEdge ?? frame.previewDevelopLongEdge(frame.edit)
        guard frame.developsFromRAW, !frame.isComposite, edge > 0,
              let folder = originals?.copies.proxyFolder, let source = frame.developSource else { return nil }
        return RawProxy.Ask(url: folder.appendingPathComponent(RawProxy.fileName(source: source, decode: decode, longEdge: edge, lens: lens)),
                            longEdge: edge)
    }

    /// A RAW photograph's 镜头校正 as it is answered now, for a request to carry (`EngineHost.Request.lens`); nil for
    /// anything else (a piece's pictures carry their own: `PieceAsk.resolvingLens`).
    func lensNow(_ frame: LibraryFrame, decode: DecodeSettings) -> LensResolution? {
        guard frame.developsFromRAW, !frame.isComposite, let source = frame.developSource else { return nil }
        return LensResolver.current(source, fileName: frame.fileName, decode: decode)
    }

    /// The proxies `frames` name now: each one's file and decode as its edit stands, at its preview size
    /// (`proxy`). What the working copies' book asks before a proxy may go (`WorkingCopies.proxyNames`).
    func proxyNames(of frames: some Sequence<LibraryFrame>) -> Set<String> {
        Set(frames.compactMap { proxy($0, decode: $0.edit.decode)?.url.lastPathComponent })
    }

    /// The size a preview-size job's open is priced by (`RenderJob.original`):
    /// the proxy's where it is here — what is read is it, not the RAW — and
    /// otherwise the original's (`decodeSize`), which the first decode reads
    /// and makes the proxy from.
    func openSize(_ frame: LibraryFrame, edit: FrameEdit) -> PixelSize {
        let edge = frame.previewDevelopLongEdge(edit)
        guard hasProxy(frame, decode: edit.decode, longEdge: edge) else { return decodeSize(frame) }
        return edge == frame.previewSize.longEdge ? frame.previewSize : frame.originalSize.scaled(toLongEdge: edge)
    }

    /// Whether a preview-size job's open of `frame` decodes a RAW file itself (`RenderJob.rawDecode`): a RAW
    /// among what it reads, and no proxy here to stand for it — a first open, priced as the RAW's decode.
    func decodesRAW(_ frame: LibraryFrame, edit: FrameEdit) -> Bool {
        guard sources(of: frame).contains(where: \.developsFromRAW) else { return false }
        return !hasProxy(frame, decode: edit.decode, longEdge: frame.previewDevelopLongEdge(edit))
    }

    /// Whether `frame`'s proxy for `decode` (at `longEdge`, nil: its own edit's) is here to read.
    func hasProxy(_ frame: LibraryFrame, decode: DecodeSettings, longEdge: Int? = nil) -> Bool {
        guard let ask = proxy(frame, decode: decode, longEdge: longEdge), let copies = originals?.copies else { return false }
        return copies.hasProxy(ask.url)
    }

    /// Everything a develop of `frame` reads, here: each original that stays
    /// in Photos is fetched into the working copies where its copy is not
    /// (`Originals.bring`). `.here` when all of it is; otherwise what the
    /// first one that is not came to.
    func bring(_ frame: LibraryFrame, asked: Bool) async -> Originals.Brought {
        guard let originals else { return .here }
        for source in sources(of: frame) {
            let brought = await originals.bring(source, asked: asked)
            if brought != .here { return brought }
        }
        return .here
    }

    /// Every RAW a develop of `frame` reads — itself, or the frames of a
    /// half-frame pair — held to its file (`Originals.holdToItsFile`): its
    /// size as the decoder that will open it gives it. Whether any moved;
    /// whoever planned from the frame reads it again then.
    func holdToItsFile(_ frame: LibraryFrame) async -> Bool {
        guard let originals else { return false }
        var moved = false
        for source in sources(of: frame) {
            if await originals.holdToItsFile(source.id) { moved = true }
        }
        return moved
    }

    /// Whether the file a job would be handed is there to hand: a frame read
    /// in place from Photos has one only while its working copy is here.
    private func isHere(_ frame: LibraryFrame) -> Bool {
        guard frame.readsFromPhotos else { return true }
        return originals?.copies.has(frame.id, named: frame.fileName) ?? FileManager.default.fileExists(atPath: frame.workingCopy.path)
    }

    /// The whole wire for a develop of `edit` on `frame`: the edit's own
    /// words, and the frame's side of a film edge and a date (`FilmWire`).
    private func wire(_ frame: LibraryFrame, edit: FrameEdit, longEdge: Int?) -> [String: ParamValue] {
        // Apply Film Emulation off: no engine, and nothing of the film in what the picture is.
        // A piece made of frames is always the film's: its light is added, or laid, before the engine.
        guard edit.appliesFilm || frame.isComposite else {
            // 应用胶片模拟 off: the 场景 layers are the host's (`SceneLayerHost`, RFC-052 §6.5), on the decode cut by the
            // frame's whole geometry; their stamp names them here, so a layer's change is another picture.
            var digital = Self.digitalWire(edit)
            if let ask = sceneAsk(frame, edit: edit, longEdge: longEdge, cut: edit.geometry) { digital["scene_layers"] = .string(ask.stamp) }
            return digital
        }
        var wire = edit.engineWire(previewLongEdge: longEdge, film: FilmWire(frame: frame, edit: edit, bodySeed: bodySeed()))
        if !frame.isComposite { holdFilmFormat(&wire, frame: frame, edit: edit) }
        // PRD-E's 场景 layers: the stamp of the set, only where one acts (`SceneLayerWire`).
        if !frame.isComposite, let ask = sceneAsk(frame, edit: edit, longEdge: longEdge, cut: edit.hostCut(source: frame.originalSize)) {
            wire["scene_layers"] = .string(ask.stamp)
        }
        return wire
    }

    /// A photograph's 场景 layers for a develop whose decode is `longEdge` long (nil: the original's size) and which
    /// the host cuts by `cut` before the engine (`FrameEdit.hostCut`, or an export's whole cut): nil where no layer
    /// acts. The decode's size is the original's at that long edge, as `FrameDecoder` makes it.
    /// With 应用胶片模拟 off the same ask is the host's (`EngineHost.digital`): its layers and planes, its matrix unused
    /// there (the host maps the cut frame to S itself, `MaskFrame.finished`).
    func sceneAsk(_ frame: LibraryFrame, edit: FrameEdit, longEdge: Int?, cut: Geometry?) -> SceneLayerWire.Ask? {
        guard !frame.isComposite, edit.layers != nil else { return nil }
        let decode = longEdge.map { frame.originalSize.scaled(toLongEdge: $0) } ?? frame.originalSize
        return SceneLayerWire.ask(edit.layers, source: frame.originalSize, hostCut: cut, decode: decode)
    }

    /// `film_format_mm` as this frame's crop says it, where Settings makes the crop the frame
    /// (`FrameEdit.wireFilmFormatMM`); untouched otherwise. The develop page, a card and an export
    /// all go through here, so they are developed at the same pitch.
    private func holdFilmFormat(_ wire: inout [String: ParamValue], frame: LibraryFrame, edit: FrameEdit) {
        let mm = edit.wireFilmFormatMM(photo: frame.originalSize, cropIsFrame: cropIsFrame())
        if mm != edit.params.filmFormatMM { wire["film_format_mm"] = .double(mm) }
    }

    /// What a frame with Apply Film Emulation off is made of, in a stamp's words: Apple's decoder and the cut.
    static func digitalWire(_ edit: FrameEdit) -> [String: ParamValue] {
        ["film_emulation": .bool(false), "digital_decoder": .string(DigitalDecode.word),
         "digital_cut": .string(edit.geometry.cutKey)]
    }

    /// What the pixels a develop of `edit` starts from are made of, as a word:
    /// the file, its decode and the host's own cut of it. A job whose word is
    /// not the one before it opens the frame again (`SpkEngine`) and is priced
    /// as that (`OpenFrameSession.submit`). Nil where nothing is opened.
    func sourceKey(_ frame: LibraryFrame, edit: FrameEdit, longEdge: Int?) -> String? {
        if let double = frame.double { return sourceKey(double, look: edit, longEdge: longEdge) }
        if let pair = frame.pair { return sourceKey(pair, frames: held(by: pair), look: edit, longEdge: longEdge) }
        #if SPK_ENGINE
        guard host != nil, let source = frame.developSource else { return nil }
        return EngineHost.Request.sourceKey(source: source, isRAW: frame.developsFromRAW, decode: edit.decode,
                                            longEdge: longEdge, cut: edit.hostCut(source: frame.originalSize))
        #else
        return nil
        #endif
    }

    /// Hand the engine's host everything `job` will ask for: the frame's file,
    /// its decode and its whole wire, as they are now. False when the frame
    /// has nothing to develop from (a demo picture, an original that is away,
    /// one that stays in Photos and has not been brought: `bring`): the job is
    /// then not to be submitted. `longEdge` is the decode's size for a job
    /// below the full tier — its canvas — and nil for a full-size one.
    @discardableResult
    func prepare(_ job: RenderJob, frame: LibraryFrame, edit: FrameEdit, purpose: Purpose, longEdge: Int?) -> Bool {
        // A double exposure: the frame is its two photographs' light, added by the host (RFC-048).
        if let double = frame.double {
            return prepare(job, double: double, item: frame, look: edit, purpose: purpose, longEdge: longEdge)
        }
        // A half-frame pair: the frame is a piece the host composes from its two frames' files.
        if let pair = frame.pair {
            return prepare(job, pair: pair, frames: held(by: pair), look: edit, purpose: purpose, longEdge: longEdge)
        }
        #if SPK_ENGINE
        guard let host else { return true }       // the simulation asks for nothing
        // A job at the preview size reads the RAW's proxy where it is here, the original or not.
        // Apple's decode reads the file itself: a proxy is the engine's decode.
        // 镜头校正 taken once (`LensResolver.current`): the stamp, the proxy's name and the decode all name this answer,
        // whatever settles while the job waits (`EngineHost.Request.lens`).
        let lens = lensNow(frame, decode: edit.decode)
        let proxy = edit.appliesFilm ? longEdge.flatMap { edge in self.proxy(frame, decode: edit.decode, longEdge: edge, lens: lens).flatMap { edge <= $0.longEdge ? $0 : nil } } : nil
        guard let source = frame.developSource,
              isHere(frame) || proxy.map({ originals?.copies.hasProxy($0.url) ?? false }) == true else { return false }
        let wire = wire(frame, edit: edit, longEdge: longEdge)
        let cut = edit.hostCut(source: frame.originalSize)
        let turns = edit.hostTurns(source: frame.originalSize)
        let stamp = DevelopStamp.of(wire: wire, cut: cut, turns: turns, decode: edit.decode, isRAW: frame.developsFromRAW,
                                    longEdge: longEdge ?? frame.originalSize.longEdge, engine: identity,
                                    origin: frame.stampOrigin, lens: lens?.word ?? "")
        var request = EngineHost.Request(frameID: frame.id, source: source, isRAW: frame.developsFromRAW,
                                         decode: edit.decode, longEdge: longEdge, cut: cut, wire: wire, turnsAfter: turns,
                                         stamp: stamp, purpose: purpose == .canvas ? .canvas : .keep, proxy: proxy)
        request.lens = lens
        // The 场景 layers the wire names, captured with the rest (`wire` put their stamp in it).
        request.sceneLayers = sceneAsk(frame, edit: edit, longEdge: longEdge, cut: cut)
        if !edit.appliesFilm { request.digital = cut ?? edit.geometry }
        // The page's canvas asks for Enable HDR's curve with a develop where its HDR is drawn (`curveWithDevelop`);
        // otherwise the page asks once the edit settles (`OpenFrameSession.askCurve`), not with every develop.
        if purpose == .canvas, Self.curveWithDevelop(edit) { request.hdrCurve = HDRSessionCurve.request(for: edit) }
        host.register(job.id, request)
        return true
        #else
        return true
        #endif
    }

    // MARK: a half-frame pair

    /// The size a job's decode is priced by (`RenderJob.original`): the
    /// frame's original — or, for a pair, the larger of its two frames', which
    /// are decoded one at a time (`FrameDecoder.decode(_:meter:)`).
    func decodeSize(_ frame: LibraryFrame) -> PixelSize {
        // A double exposure's two decodes are priced one by one, by the scheduler (`composition`); this is the larger.
        if let double = frame.double {
            return held(by: double).values.map(\.originalSize).max { $0.megapixels < $1.megapixels } ?? frame.originalSize
        }
        guard let pair = frame.pair else { return frame.originalSize }
        return held(by: pair).values.map(\.originalSize).max { $0.megapixels < $1.megapixels } ?? frame.originalSize
    }

    /// 镜头校正 resolved for every file a develop of `frame` reads (`LensResolver.resolve`: itself, or a pair's or a
    /// double's photographs), off the main actor: what a page asks once it has opened a frame, and an export before it
    /// renders one. Whether any of their words moved — the picture is another, and is developed again. Every RAW of
    /// them is also measured for the black repair (`RawBlack.resolve`, once a file), whether its lens is corrected or not.
    func resolveLens(_ frame: LibraryFrame, measure: Bool = true) async -> Bool {
        let asks: [(URL, String, DecodeSettings)] = sources(of: frame).compactMap { f in
            guard f.developsFromRAW, let url = f.developSource else { return nil }
            return (url, f.fileName, f.edit.decode)
        }
        guard !asks.isEmpty else { return false }
        return await Task.detached(priority: .utility) {
            var moved = false
            for (url, name, decode) in asks {
                let before = LensResolver.current(url, fileName: name, decode: decode).word
                RawBlack.resolve(url, decode: decode)
                let after = decode.lensCorrection ? await LensResolver.resolve(url, decode: decode, measure: measure).word
                    : LensResolver.current(url, fileName: name, decode: decode).word
                if before != after { moved = true }
            }
            return moved
        }.value
    }

    /// The file an export's metadata is read from, and whether there is
    /// anything to export at all: a photograph's own file — or, for a pair,
    /// its first frame's, and only while both holes hold a frame the library
    /// still has with a file to read (the desktop's answer B9: a pair with an
    /// empty hole is not exported).
    func exportSource(_ frame: LibraryFrame) -> URL? {
        if let double = frame.double {
            // Its bottom photograph's file, while both exposures hold a photograph the library has with a
            // file to read: a double with an empty layer is not exported, as a pair with an empty hole is not.
            let frames = held(by: double)
            guard double.isFilled, DoubleExposure.Position.allCases.allSatisfy({ frames[$0]?.developSource != nil }) else { return nil }
            return frames[.bottom]?.developSource
        }
        guard let pair = frame.pair else { return frame.isDemo ? nil : frame.developSource ?? frame.picture.fileURL }
        let frames = held(by: pair)
        guard pair.isFilled, HalfFramePair.Side.allCases.allSatisfy({ frames[$0]?.developSource != nil }) else { return nil }
        return frames[.left]?.developSource
    }

    /// The frames a pair's holes hold, as the library has them now: a hole
    /// whose frame has gone from the library is an empty one.
    func held(by pair: HalfFramePair) -> HalfFramePair.Frames {
        var held: HalfFramePair.Frames = [:]
        for side in HalfFramePair.Side.allCases {
            // Never a piece made of frames: no pair, and no double exposure, under a hole (PRD 2 §9).
            if let id = pair[side]?.frame, let frame = frames(id), !frame.isComposite { held[side] = frame }
        }
        return held
    }

    /// The whole wire for a develop of a pair's piece under `look`
    /// (`FrameEdit.pairWire`): the film's own words for the edge print, the
    /// first frame's f-number, each frame's own date — **of a frame that is
    /// there and that the back printed on** (`HalfFramePair.Hole.dated`): a
    /// frame switched off is handed over with no text, as an empty hole is.
    private func wire(_ pair: HalfFramePair, frames: HalfFramePair.Frames, look: FrameEdit, longEdge: Int?) -> [String: ParamValue] {
        let first = frames[.left] ?? frames[.right]
        func date(_ side: HalfFramePair.Side) -> String {
            guard pair[side]?.dated == true, let frame = frames[side] else { return "" }
            return FilmEdgeResolver.dateText(look.dateBack, frame: frame)
        }
        let film = FilmWire(edgeText: StockCatalog.shared.stock(look.params.filmStock)?.edgeText(gauge: look.filmEdge.format.gauge) ?? "",
                            fNumber: first.map { ShootingLine.fNumber($0.exposure) } ?? 0,
                            dateText: date(.left), bodySeed: bodySeed())
        return look.pairWire(pair, previewLongEdge: longEdge, film: film, secondDate: date(.right))
    }

    /// A pair's frames that print as their own, as a develop of `piece` is
    /// cut together from them (`HalfFramePair.printLayers`) — **of a frame
    /// whose picture is on the piece**: a hole whose frame has gone from the
    /// library is bare film, and bare film prints as the film does.
    private func layers(_ pair: HalfFramePair, piece: PieceAsk, look: FrameEdit) -> [PrintLayer] {
        pair.printLayers(look: look.params).filter { layer in piece.pictures.contains { $0.index == layer.index } }
    }

    /// How many more prints of its negative a develop of `edit` on this item
    /// makes, for pricing the job (`RenderJob.printLayers`): a half-frame
    /// pair's frames that print as their own. None for a photograph.
    func printLayers(_ frame: LibraryFrame, edit: FrameEdit) -> Int {
        guard let kept = frame.pair else { return 0 }
        let frames = held(by: kept)
        let pair = kept.mirrored(frames)
        return layers(pair, piece: pair.piece(frames, look: edit, longEdge: frame.previewSize.longEdge), look: edit).count
    }

    /// What a develop of a pair's piece at this size would be stamped, or nil
    /// where no picture is made or neither frame has anything to develop from.
    /// A frame's own print is part of it: not on the wire, and another picture.
    func stamp(_ pair: HalfFramePair, frames: HalfFramePair.Frames, look: FrameEdit, longEdge: Int) -> String? {
        guard makesPictures else { return nil }
        let pair = pair.mirrored(frames)
        let piece = pair.piece(frames, look: look, longEdge: longEdge)
        guard !piece.pictures.isEmpty else { return nil }
        return DevelopStamp.of(wire: wire(pair, frames: frames, look: look, longEdge: longEdge), decode: DecodeSettings(),
                               isRAW: false, longEdge: longEdge, engine: identity, piece: piece.key,
                               prints: layers(pair, piece: piece, look: look).map(\.key))
    }

    /// What the pixels a develop of a pair's piece starts from are made of, as
    /// a word (`PieceAsk.key`). Nil where nothing is opened.
    func sourceKey(_ pair: HalfFramePair, frames: HalfFramePair.Frames, look: FrameEdit, longEdge: Int?) -> String? {
        #if SPK_ENGINE
        guard host != nil else { return nil }
        let piece = pair.mirrored(frames).piece(frames, look: look, longEdge: longEdge)
        return piece.pictures.isEmpty ? nil : piece.key
        #else
        return nil
        #endif
    }

    /// Hand the engine's host everything a **half-frame pair's** job will ask
    /// for: the piece — each picture's file, decode, cut and place under its
    /// hole, and how it is exposed — and the pair's whole wire, as they are
    /// now. `job.frameID` is the pair's own id. False when neither frame has
    /// anything to develop from: the job is then not to be submitted.
    ///
    /// The decode and cut of each hole are read again from its frame
    /// (`HalfFramePair.mirrored`): the shot stays the frame's. A picture whose
    /// meter has not read yet is read inside the job, and the reading comes
    /// back through `onMetered`.
    ///
    /// The wire is the film's print. A frame that prints as its own goes
    /// beside it (`Request.layers`): the job prints the same negative again
    /// for it, and the host cuts that print in along the frame's hole.
    @discardableResult
    func prepare(_ job: RenderJob, pair: HalfFramePair, frames: HalfFramePair.Frames, look: FrameEdit,
                 purpose: Purpose, longEdge: Int?) -> Bool {
        #if SPK_ENGINE
        guard let host else { return true }       // the simulation asks for nothing
        // A frame on it that stays in Photos and has not been brought: a hole would fail the whole piece.
        guard frames.values.allSatisfy({ !$0.original.isAvailable || isHere($0) }) else { return false }
        let pair = pair.mirrored(frames)
        let piece = pair.piece(frames, look: look, longEdge: longEdge).resolvingLens()
        guard let first = piece.pictures.first else { return false }
        let wire = wire(pair, frames: frames, look: look, longEdge: longEdge)
        let own = layers(pair, piece: piece, look: look)
        let stamp = DevelopStamp.of(wire: wire, decode: DecodeSettings(), isRAW: false, longEdge: longEdge ?? piece.size.longEdge,
                                    engine: identity, piece: piece.key, prints: own.map(\.key))
        var request = EngineHost.Request(frameID: job.frameID, source: first.url, isRAW: false, decode: DecodeSettings(),
                                         longEdge: longEdge, cut: nil, wire: wire, turnsAfter: 0, stamp: stamp,
                                         purpose: purpose == .canvas ? .canvas : .keep, piece: piece, layers: own,
                                         stripPixels: pair.piece(frames, look: look, longEdge: StockPreviewSize.openLongEdge).key)
        // A pair's page has Enable HDR as a photograph's has (a pair is a frame to develop like any other).
        if purpose == .canvas, Self.curveWithDevelop(look) { request.hdrCurve = HDRSessionCurve.request(for: look) }
        host.register(job.id, request)
        return true
        #else
        return true
        #endif
    }

    // MARK: a double exposure (RFC-048)

    /// The whole wire for a develop of a double exposure's piece under `look`
    /// (`FrameEdit.doubleWire`): the film's own words for the edge print, and
    /// **one date, the bottom exposure's** (PRD 2 §8.4) — its photograph's
    /// capture date and shooting data, under the whole's Date Back — and its
    /// f-number. With the bottom's layer empty, the top's: the photograph that
    /// is there sets the frame, as it sets its shape (`DoubleExposure.frameAspect`).
    func wire(_ double: DoubleExposure, item: LibraryFrame, frames: DoubleExposure.Frames, look: FrameEdit,
              longEdge: Int?) -> [String: ParamValue] {
        let bottom = frames[.bottom] ?? frames[.top] ?? item
        return look.doubleWire(previewLongEdge: longEdge, film: FilmWire(frame: bottom, edit: look, bodySeed: bodySeed()))
    }

    /// What a develop of a double exposure at this size would be stamped, or
    /// nil where no picture is made or neither photograph has anything to
    /// develop from. The piece's key is in it — each photograph, its decode
    /// and cut, its window, flip and turn, how it is exposed — and the host's
    /// turn of the canvas; the readings are not (RFC-047 §5.2).
    func stamp(_ double: DoubleExposure, item: LibraryFrame, look: FrameEdit, longEdge: Int) -> String? {
        guard makesPictures else { return nil }
        let frames = held(by: double)
        let made = double.mirrored(frames)
        let piece = made.piece(frames, look: look, longEdge: longEdge)
        guard !piece.pictures.isEmpty, let shape = made.pieceFrame(made.framed(frames), look: look, longEdge: longEdge) else { return nil }
        return DevelopStamp.of(wire: wire(made, item: item, frames: frames, look: look, longEdge: longEdge), turns: shape.turnsAfter,
                               decode: DecodeSettings(), isRAW: false, longEdge: longEdge, engine: identity, piece: piece.key)
    }

    /// What the pixels a develop of a double exposure's piece starts from are
    /// made of, as a word (`PieceAsk.key`). Nil where nothing is opened.
    func sourceKey(_ double: DoubleExposure, look: FrameEdit, longEdge: Int?) -> String? {
        #if SPK_ENGINE
        guard host != nil else { return nil }
        let frames = held(by: double)
        let piece = double.mirrored(frames).piece(frames, look: look, longEdge: longEdge)
        return piece.pictures.isEmpty ? nil : piece.key
        #else
        return nil
        #endif
    }

    /// Hand the engine's host everything a **double exposure's** job will ask
    /// for: the piece — each exposure's photograph, decode, cut and place over
    /// the frame, how it is exposed, both added — and the whole's wire, as they
    /// are now. `job.frameID` is the double's own id. False when neither
    /// photograph has anything to develop from: the job is then not to be
    /// submitted.
    ///
    /// Each exposure's decode and cut are read again from its photograph
    /// (`DoubleExposure.mirrored`): the shot stays the photograph's. An
    /// exposure whose meter has not read yet is read inside the job, and the
    /// reading comes back through `onDoubleMetered`. What the job's open holds
    /// is told to the scheduler before it is planned (`composition`).
    @discardableResult
    func prepare(_ job: RenderJob, double: DoubleExposure, item: LibraryFrame, look: FrameEdit,
                 purpose: Purpose, longEdge: Int?) -> Bool {
        #if SPK_ENGINE
        guard let host else { return true }       // the simulation asks for nothing
        let frames = held(by: double)
        // A photograph on it that stays in Photos and has not been brought: a layer would fail the whole piece.
        guard frames.values.allSatisfy({ !$0.original.isAvailable || isHere($0) }) else { return false }
        let made = double.mirrored(frames)
        let piece = made.piece(frames, look: look, longEdge: longEdge).resolvingLens()
        guard let first = piece.pictures.first, let shape = made.pieceFrame(made.framed(frames), look: look, longEdge: longEdge) else {
            return false
        }
        let wire = wire(made, item: item, frames: frames, look: look, longEdge: longEdge)
        let stamp = DevelopStamp.of(wire: wire, turns: shape.turnsAfter, decode: DecodeSettings(), isRAW: false,
                                    longEdge: longEdge ?? piece.size.longEdge, engine: identity, piece: piece.key)
        // The strip's cards compose the same piece without the film edge and the date (`doubleCardPlan`):
        // only where that is these pixels — no film edge, or one that cuts and turns nothing — is the
        // page's own decode made the strip's (`DoubleExposure.stripPixels`, `EngineHost.feedStrip`).
        host.register(job.id, EngineHost.Request(frameID: job.frameID, source: first.url, isRAW: false, decode: DecodeSettings(),
                                                 longEdge: longEdge, cut: nil, wire: wire, turnsAfter: shape.turnsAfter, stamp: stamp,
                                                 purpose: purpose == .canvas ? .canvas : .keep, piece: piece,
                                                 stripPixels: made.stripPixels(frames, look: look)))
        note(job, piece: piece, frames: frames)
        return true
        #else
        return true
        #endif
    }

    /// **One exposure of a double alone**, as it would develop by itself (PRD 2
    /// D12, RFC-048 §6): a render of the same look with a one-picture ask
    /// (`DoubleExposure.alone`), for the darkroom's press-and-hold
    /// (`DoubleAlone`, RFC-050 §2). The page submits it as a canvas job of
    /// `aloneSession(double, position)`, and the engine develops it **one-shot**
    /// (`EngineHost.leavesEditingAlone`, phase-2 review): its session is opened
    /// for the job and released at its end, so the page's open session — the
    /// double composed, its negative cached — stays the engine's one editing
    /// session and the page's next edit still reprints from it. The page takes
    /// the picture with `takeAlone` once the job has ended, caches it by
    /// `aloneStamp`, and cancels the job when the finger lifts or the page
    /// closes. False where there is nothing to develop from.
    @discardableResult
    func prepareAlone(_ job: RenderJob, item: LibraryFrame, position: DoubleExposure.Position, look: FrameEdit,
                      longEdge: Int?) -> Bool {
        #if SPK_ENGINE
        guard let host, let double = item.double else { return false }
        let frames = held(by: double)
        guard let frame = frames[position], !frame.original.isAvailable || isHere(frame) else { return false }
        let made = double.mirrored(frames)
        let piece = made.alone(position, frames: frames, look: look, longEdge: longEdge).resolvingLens()
        guard let first = piece.pictures.first, let shape = made.pieceFrame(made.framed(frames), look: look, longEdge: longEdge) else {
            return false
        }
        let wire = wire(made, item: item, frames: frames, look: look, longEdge: longEdge)
        let stamp = DevelopStamp.of(wire: wire, turns: shape.turnsAfter, decode: DecodeSettings(), isRAW: false,
                                    longEdge: longEdge ?? piece.size.longEdge, engine: identity, piece: piece.key)
        host.register(job.id, EngineHost.Request(frameID: job.frameID, source: first.url, isRAW: false, decode: DecodeSettings(),
                                                 longEdge: longEdge, cut: nil, wire: wire, turnsAfter: shape.turnsAfter, stamp: stamp,
                                                 purpose: .alone, piece: piece))
        note(job, piece: piece, frames: frames)
        return true
        #else
        return false
        #endif
    }

    /// What an exposure alone would be stamped: the page's cache key for it. Nil where none is made.
    func aloneStamp(_ item: LibraryFrame, position: DoubleExposure.Position, look: FrameEdit, longEdge: Int) -> String? {
        guard makesPictures, let double = item.double else { return nil }
        let frames = held(by: double)
        let made = double.mirrored(frames)
        let piece = made.alone(position, frames: frames, look: look, longEdge: longEdge)
        guard !piece.pictures.isEmpty, let shape = made.pieceFrame(made.framed(frames), look: look, longEdge: longEdge) else { return nil }
        return DevelopStamp.of(wire: wire(made, item: item, frames: frames, look: look, longEdge: longEdge), turns: shape.turnsAfter,
                               decode: DecodeSettings(), isRAW: false, longEdge: longEdge, engine: identity, piece: piece.key)
    }

    /// The engine session an exposure's alone render is developed in: one of
    /// its own, never the double's, named from the double and the position so
    /// the same hold finds the same session. Not a library frame's id.
    nonisolated static func aloneSession(_ double: UUID, _ position: DoubleExposure.Position) -> UUID {
        var bytes = double.uuid
        // The last byte turned by the position (and one more, so the bottom is not the double itself).
        bytes.15 ^= UInt8(0xA0 | (position.rawValue + 1))
        return UUID(uuid: bytes)
    }

    /// An exposure alone's picture, once its job has ended (`prepareAlone`):
    /// nil for one that never reached its delivery.
    func takeAlone(_ jobID: UUID) -> CGImage? {
        #if SPK_ENGINE
        return host?.takeCard(jobID)
        #else
        return nil
        #endif
    }

    // MARK: what a composed open holds, for the scheduler

    #if SPK_ENGINE
    /// What each prepared job of a double exposure decodes, until the
    /// scheduler takes it (`composition(of:)`, when the job is submitted).
    private var composed: [UUID: RenderJob.Composition] = [:]

    /// A double's job: **each exposure's decode, priced one at a time**, and
    /// the scratch band beside the piece (RFC-048 §5), each by what its
    /// decoder holds (`RenderJob.Composition.decode`): at the full tier the
    /// size it is made at (`PieceAsk.longEdge`) where ImageIO reduces it, the
    /// photograph's own where Core Image decodes a RAW whole and scales it
    /// after; below it, the photograph's original — the decoder may hold it
    /// while it makes the small one, as `RenderJob.original` says of a photograph.
    private func note(_ job: RenderJob, piece: PieceAsk, frames: DoubleExposure.Frames) {
        guard piece.adds else { return }
        var decodes: [PixelSize] = []
        for p in piece.pictures {
            guard let position = DoubleExposure.Position(rawValue: p.index), let photo = frames[position] else { continue }
            decodes.append(RenderJob.Composition.decode(tier: job.tier, own: photo.developSize, original: photo.originalSize,
                                                        longEdge: p.longEdge, isRAW: p.isRAW))
        }
        composed[job.id] = RenderJob.Composition(decodes: decodes,
                                                 scratchBytes: UInt64(PieceAdder.scratchBytes(width: piece.size.width, height: piece.size.height)),
                                                 raw: piece.pictures.contains { $0.isRAW })
    }
    #endif

    /// What a job's open composes, for the scheduler's price of it (`RenderScheduler.composition`):
    /// asked once, when the job is submitted, and then forgotten here. Nil for anything but a double's.
    func composition(of jobID: UUID) -> RenderJob.Composition? {
        #if SPK_ENGINE
        return composed.removeValue(forKey: jobID)
        #else
        return nil
        #endif
    }

    // MARK: Develop's strips

    /// What a card of a frame is rendered from (`StockPreviews`), for an edit
    /// that is already the card's (`StockPreviewRules.edit`).
    struct CardPlan: Equatable, Sendable {
        /// The card's key (`StockPreviewKey`): its file's name, its place in memory.
        var key: String
        /// Eight hex of what the frame's pixels are read from — its file and
        /// size — which names its cards' files (`StorageTidy.cardFile`).
        var source: String
        /// What the strip's one decode is of (`EngineHost.Request.sourceKey`):
        /// a card with another opens another decode.
        var strip: String
        /// The same without its size (`EngineHost.Request.pixelsKey`): the
        /// page's own decode of these pixels can be made the strip's.
        var pixels: String
        var wire: [String: ParamValue]
        /// The film's framing, cut by the host before the engine, and the
        /// quarter turns its canvas is given after — the page's own
        /// (`FrameEdit.hostCut`, `hostTurns`); nil and 0 when the engine cuts
        /// the photo's crop itself, as the page's develop does.
        var cut: Geometry?
        var turns: Int
        var decodeLongEdge: Int
        var opens: PixelSize
        var canvas: PixelSize
        var piece: PieceAsk? = nil
        var layers: [PrintLayer] = []
        /// 镜头校正 as `key`, `strip` and `pixels` name it: the card's decode is made with it (`prepareCard`).
        var lens: LensResolution? = nil
    }

    /// A card's plan, or nil where no card can be made here: no engine, a
    /// missing source, or an unreadable pair composition.
    ///
    /// **The frame is opened so that the engine meters what the page's develop
    /// meters**: the picture's cut at 1,600 px on its long edge — the meter's
    /// own size — and never larger than the page decodes it, which is what the
    /// page's session meters when the cut is small. Opened smaller, a card would
    /// be metered smaller (AGENTS.md).
    func cardPlan(_ frame: LibraryFrame, edit: FrameEdit) -> CardPlan? {
        guard makesPictures else { return nil }
        if let double = frame.double { return doubleCardPlan(double, item: frame, edit: edit) }
        if let pair = frame.pair { return pairCardPlan(pair, edit: edit) }
        guard let source = frame.developSource else { return nil }
        let original = frame.originalSize
        guard original.width > 0, original.height > 0 else { return nil }
        // The film and the date are Format's, drawn round the page's develop: a card is the picture.
        var wire = edit.engineWire(previewLongEdge: StockPreviewSize.renderLongEdge, film: nil)
        holdFilmFormat(&wire, frame: frame, edit: edit)
        // The picture's cut in the original's pixels: the film's framing, cut by the host and turned
        // as the page's develop cuts and turns it — so the page's own decode can be the strip's — or
        // the photo's crop, which the engine makes.
        let gate = edit.pictureGeometry(source: original).gateSize(for: CGSize(width: original.width, height: original.height))
        let cut = edit.hostCut(source: original)
        let fraction = max(Double(max(gate.width, gate.height)) / Double(original.longEdge), 0.05)
        let decodeLongEdge = min(max(frame.previewSize.longEdge, StockPreviewSize.openLongEdge),
                                 Int((Double(StockPreviewSize.openLongEdge) / fraction).rounded(.up)))
        let decoded = original.scaled(toLongEdge: decodeLongEdge)
        let k = Double(decoded.longEdge) / Double(original.longEdge)
        let inDecode = PixelSize(width: max(1, Int((gate.width * k).rounded())), height: max(1, Int((gate.height * k).rounded())))
        let sourceWord = ImportService.stampWord(source) + " \(original.width)x\(original.height)" + (frame.stampOrigin.map { " " + $0 } ?? "")
        let lens = lensNow(frame, decode: edit.decode)
        let decodeWord = frame.developsFromRAW ? edit.decode.pixelsKey(source: source, lens: lens) : ""
        var strip = "", pixels = ""
        #if SPK_ENGINE
        strip = EngineHost.Request.sourceKey(source: source, isRAW: frame.developsFromRAW, decode: edit.decode,
                                             longEdge: decodeLongEdge, cut: cut, lens: lens)
        pixels = EngineHost.Request.pixelsKey(source: source, isRAW: frame.developsFromRAW, decode: edit.decode, cut: cut, lens: lens)
        #endif
        let turns = edit.hostTurns(source: original)
        return CardPlan(key: StockPreviewKey.of(wire: wire, decode: decodeWord, cut: cut.map { $0.cutKey + " turned \(turns)" },
                                                source: sourceWord, engine: identity),
                        source: StockPreviewKey.tag(sourceWord), strip: strip, pixels: pixels, wire: wire, cut: cut, turns: turns,
                        // A perspective alone is cut by the host at the decode's own size (`hostCut`).
                        decodeLongEdge: decodeLongEdge, opens: cut == nil || !edit.filmEdge.effective ? decoded : inDecode,
                        canvas: inDecode.scaled(toLongEdge: StockPreviewSize.renderLongEdge), lens: lens)
    }

    /// Cards develop the composed piece, including each source's exposure,
    /// placement and own print. The edge/date belong to Format, as on a photo.
    private func pairCardPlan(_ kept: HalfFramePair, edit: FrameEdit) -> CardPlan? {
        let frames = held(by: kept)
        let pair = kept.mirrored(frames)
        var look = edit
        look.filmEdge.active = false; look.dateBack.active = false
        let piece = pair.piece(frames, look: look, longEdge: StockPreviewSize.openLongEdge).resolvingLens()
        guard !piece.pictures.isEmpty else { return nil }
        var wire = wire(pair, frames: frames, look: look, longEdge: StockPreviewSize.renderLongEdge)
        // Keep the strip's fixed 1 mm spacing and physical pitch in the
        // source piece; omit only the rendered border/date, not the layout.
        wire["overscan_active"] = .bool(false)
        wire["date_imprint_active"] = .bool(false)
        let own = layers(pair, piece: piece, look: look)
        let source = piece.key + frames.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "|\($0.key.rawValue):\($0.value.stampOrigin ?? "")" }.joined()
        let key = StockPreviewKey.of(wire: wire, decode: "", cut: nil,
                                    source: source + own.map(\.key).joined(separator: "|"), engine: identity)
        return CardPlan(key: key, source: StockPreviewKey.tag(source), strip: piece.key, pixels: piece.key,
                        wire: wire, cut: nil, turns: 0, decodeLongEdge: StockPreviewSize.openLongEdge,
                        opens: piece.size, canvas: piece.size.scaled(toLongEdge: StockPreviewSize.renderLongEdge),
                        piece: piece, layers: own)
    }

    /// A double exposure's cards develop its composed piece — both exposures'
    /// light, each one's placement and exposure — through each card's film and
    /// paper; the film edge and the date are Format's, as on a photograph.
    private func doubleCardPlan(_ kept: DoubleExposure, item: LibraryFrame, edit: FrameEdit) -> CardPlan? {
        let frames = held(by: kept)
        let double = kept.mirrored(frames)
        var look = edit
        look.filmEdge.active = false; look.dateBack.active = false
        let piece = double.piece(frames, look: look, longEdge: StockPreviewSize.openLongEdge).resolvingLens()
        guard !piece.pictures.isEmpty else { return nil }
        let wire = wire(double, item: item, frames: frames, look: look, longEdge: StockPreviewSize.renderLongEdge)
        let source = piece.key + frames.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "|\($0.key.rawValue):\($0.value.stampOrigin ?? "")" }.joined()
        let key = StockPreviewKey.of(wire: wire, decode: "", cut: nil, source: source, engine: identity)
        return CardPlan(key: key, source: StockPreviewKey.tag(source), strip: piece.key, pixels: piece.key,
                        wire: wire, cut: nil, turns: 0, decodeLongEdge: StockPreviewSize.openLongEdge,
                        opens: piece.size, canvas: piece.size.scaled(toLongEdge: StockPreviewSize.renderLongEdge),
                        piece: piece)
    }

    /// The strip of `frame` would take the page's own decode of the same
    /// pixels, made its size, rather than decode them again (`EngineHost`):
    /// told before the page's develop runs, and nil when the strip has gone.
    /// A 48 MP ProRAW's decode for a strip took 6.2 s in the simulator, after
    /// the page's own of the same file.
    func feedStrip(_ source: StripSource?, frame: LibraryFrame.ID, plan: CardPlan?) {
        #if SPK_ENGINE
        guard let host else { return }
        if let source, let plan, !plan.strip.isEmpty {
            host.feed(EngineHost.Feed(source: source, pixels: plan.pixels, word: plan.strip, longEdge: plan.decodeLongEdge,
                                      size: plan.opens), for: frame)
        } else {
            host.feed(nil, for: frame)
        }
        #endif
    }

    /// Hand the engine's host what a card's job will ask for. `decodes`: the
    /// job was priced to decode the strip's picture; one that was not and finds
    /// it given back fails, and is asked for again priced to (`StockPreviews`).
    /// False where nothing can be handed: the job is then not to be submitted.
    @discardableResult
    func prepareCard(_ job: RenderJob, frame: LibraryFrame, edit: FrameEdit, plan: CardPlan, strip: StripSource, decodes: Bool) -> Bool {
        #if SPK_ENGINE
        if let piece = plan.piece {
            guard let host, let first = piece.pictures.first,
                  sources(of: frame).allSatisfy({ isHere($0) }) else { return false }
            host.register(job.id, EngineHost.Request(frameID: frame.id, source: first.url, isRAW: false,
                            decode: DecodeSettings(), longEdge: plan.decodeLongEdge, cut: nil,
                            wire: plan.wire, stamp: plan.key, purpose: .card(plan.key),
                            piece: piece, layers: plan.layers, strip: strip, decodesStrip: decodes))
            if decodes, let double = frame.double { note(job, piece: piece, frames: held(by: double)) }
            return true
        }
        // A RAW's card is made from its proxy where it is here: no decode of the file, the original or not.
        let lens = lensNow(frame, decode: edit.decode)
        let proxy = self.proxy(frame, decode: edit.decode, lens: lens).flatMap { plan.decodeLongEdge <= $0.longEdge ? $0 : nil }
        guard let host, let source = frame.developSource,
              isHere(frame) || proxy.map({ originals?.copies.hasProxy($0.url) ?? false }) == true else { return false }
        var request = EngineHost.Request(frameID: frame.id, source: source, isRAW: frame.developsFromRAW, decode: edit.decode,
                                         longEdge: plan.decodeLongEdge, cut: plan.cut, wire: plan.wire, turnsAfter: plan.turns,
                                         stamp: plan.key, purpose: .card(plan.key), strip: strip, decodesStrip: decodes,
                                         proxy: proxy)
        request.lens = plan.lens ?? lens
        host.register(job.id, request)
        return true
        #else
        return false
        #endif
    }

    /// A card's picture, once its job has ended: nil for one that never
    /// reached its delivery (cancelled, failed in the engine or in the making).
    func takeCard(_ jobID: UUID) -> CGImage? {
        #if SPK_ENGINE
        return host?.takeCard(jobID)
        #else
        return nil
        #endif
    }

    /// Hand the engine's host everything an **export** job will ask for: the
    /// file, its decode at the plan's size, the host's cut of it, the wire,
    /// and what to make of the result (`ExportOrder`). False when there is
    /// nothing to develop from: the job is then not to be submitted.
    ///
    /// `source` is the file the plan was made for: the frame's original, or
    /// its preview copy while the original is away.
    ///
    /// Where the host makes a photo's cut (`ExportPlan.cut`, no film edge) the
    /// wire's own is none, so the job can band, and the film's size follows
    /// the cut (`ExportPlan.filmFormatMM`): the engine's picture is then the
    /// one it makes when it cuts for itself — held to 2 parts in 65,535 by
    /// `tools/engine_smoke.sh mac 2016 1512 --cut-check`. Under a film edge
    /// the wire is the develop page's own (`FrameEdit.engineWire`): its cut is
    /// already none, and the gate's millimetres decide.
    @discardableResult
    func prepareExport(_ job: RenderJob, frame: LibraryFrame, source: URL, isRAW: Bool, plan: ExportPlan, order: ExportOrder) -> Bool {
        #if SPK_ENGINE
        guard let host else { return true }       // the simulation asks for nothing
        let edit = frame.edit
        if let kept = frame.double {
            // A double exposure: its two photographs' light added at the plan's size (RFC-048 §5: at Full,
            // the frame no larger than either fills unenlarged). `source` is only where the file's
            // metadata comes from. The look's Edit crop is the export's own (`ExportOrder.printCrop`).
            let frames = held(by: kept)
            let double = kept.mirrored(frames)
            let piece = double.piece(frames, look: edit, longEdge: plan.decodeLongEdge)
            guard !piece.pictures.isEmpty,
                  let shape = double.pieceFrame(double.framed(frames), look: edit, longEdge: plan.decodeLongEdge) else { return false }
            let wire = wire(double, item: frame, frames: frames, look: edit, longEdge: job.tier == .full ? nil : plan.decodeLongEdge)
            host.register(job.id, EngineHost.Request(frameID: frame.id, source: source, isRAW: false, decode: DecodeSettings(),
                                                     longEdge: plan.decodeLongEdge, cut: nil, wire: wire, turnsAfter: shape.turnsAfter,
                                                     stamp: "", purpose: .export(order), piece: piece))
            note(job, piece: piece, frames: frames)
            return true
        }
        if let kept = frame.pair {
            // A half-frame pair: the piece composed at the plan's size, from its two
            // frames' own files. `source` is only where the file's metadata comes from.
            let frames = held(by: kept)
            let pair = kept.mirrored(frames)
            let piece = pair.piece(frames, look: edit, longEdge: plan.decodeLongEdge)
            guard !piece.pictures.isEmpty else { return false }
            let wire = wire(pair, frames: frames, look: edit, longEdge: job.tier == .full ? nil : plan.decodeLongEdge)
            var request = EngineHost.Request(frameID: frame.id, source: source, isRAW: false, decode: DecodeSettings(),
                                             longEdge: plan.decodeLongEdge, cut: nil, wire: wire, turnsAfter: 0,
                                             stamp: "", purpose: .export(order), piece: piece,
                                             layers: layers(pair, piece: piece, look: edit))
            // Enable HDR: the map's curve is the session's that prints the pair (never rendered twice: no slide rendition).
            if order.gainMap { request.hdrCurve = HDRSessionCurve.request(for: edit) }
            host.register(job.id, request)
            return true
        }
        let wire = exportWire(frame, plan: plan, full: job.tier == .full)
        var request = EngineHost.Request(frameID: frame.id, source: source, isRAW: isRAW, decode: edit.decode,
                                         longEdge: plan.decodeLongEdge, cut: plan.cut, wire: wire,
                                         turnsAfter: plan.turnsAfter, stamp: "", purpose: .export(order))
        request.lens = isRAW ? LensResolver.current(source, fileName: frame.fileName, decode: edit.decode) : nil
        request.sceneLayers = sceneAsk(frame, edit: edit, longEdge: plan.decodeLongEdge, cut: plan.cut)
        // Enable HDR (the export round, D8): the file's map is of the curve this render's own session gives
        // (`HDRSessionCurve`, asked after the render as the canvas asks), and a slide's of its second rendition.
        if order.gainMap, edit.appliesFilm {
            request.hdrCurve = HDRSessionCurve.request(for: edit)
            if let headroom = order.slideHeadroom, HDRGain.isSlide(edit) { request.slideHDR = HDRGain.rendition(for: edit, headroom: headroom) }
        }
        // The page's zoom may have kept this very render (`FullRender`): then it is the export's — not with a map,
        // whose curve (or second rendition) needs the session a kept render has not.
        if job.tier == .full, !order.gainMap { request.fullRender = fullAsk(frame, plan: plan, source: source, isRAW: isRAW, lens: request.lens) }
        if !edit.appliesFilm { request.digital = plan.cut ?? (plan.engineCuts ? edit.geometry : .default) }
        host.register(job.id, request)
        return true
        #else
        return true
        #endif
    }

    // MARK: the full render (the page's zoom, and an export's)

    /// What a full-size job of `frame` renders and how it is planned: its
    /// export at Full on this device (`ExportService.prepared`). Set by the
    /// app's model. Nil where the frame cannot be rendered from its original.
    var fullPlan: ((LibraryFrame) -> (plan: ExportPlan, source: URL, isRAW: Bool)?)?

    /// The wire of an export's render, as `prepareExport` hands it: the
    /// edit's own, with the photo's crop taken off where the host makes it.
    private func exportWire(_ frame: LibraryFrame, plan: ExportPlan, full: Bool) -> [String: ParamValue] {
        let edit = frame.edit
        // Below the full tier the engine renders its `live` tier at the size it is told.
        var wire = wire(frame, edit: edit, longEdge: full ? nil : plan.decodeLongEdge)
        if !edit.filmEdge.effective, !plan.engineCuts {
            for field in Geometry.default.wire { wire[field.name] = field.value }
            if let format = plan.filmFormatMM { wire["film_format_mm"] = .double(format) }
        }
        // The 场景 layers through the export's own cut (the host may make all of it): their matrix, so their stamp.
        if let ask = sceneAsk(frame, edit: edit, longEdge: plan.decodeLongEdge, cut: plan.cut) {
            wire["scene_layers"] = .string(ask.stamp)
        } else {
            wire["scene_layers"] = nil
        }
        return wire
    }

    /// Where the full render of `frame` as `plan` renders it is kept, named by
    /// what it is made of: the whole wire, the decode, the host's cut and turn,
    /// the size, the file and the engine — everything an export's render is,
    /// and nothing that is made after it (Edit's layer, its crop, the file's
    /// colour space). Nil for a half-frame pair, and where nothing is kept.
    func fullAsk(_ frame: LibraryFrame, plan: ExportPlan, source: URL, isRAW: Bool, lens given: LensResolution? = nil) -> FullRender.Ask? {
        guard !frame.isComposite, makesPictures, let folder = originals?.copies.proxyFolder else { return nil }
        let wire = exportWire(frame, plan: plan, full: true)
        // The answer the kept render is decoded with (`prepareFullView` hands it on): the stamp names it.
        let lens = given ?? (isRAW ? LensResolver.current(source, fileName: frame.fileName, decode: frame.edit.decode) : nil)
        let stamp = DevelopStamp.of(wire: wire, cut: plan.cut, turns: plan.turnsAfter, decode: frame.edit.decode, isRAW: isRAW,
                                    longEdge: plan.decodeLongEdge ?? 0, engine: identity, origin: frame.stampOrigin,
                                    lens: lens?.word ?? "")
            + "|\(plan.engineCanvas.width)x\(plan.engineCanvas.height)|\(source.lastPathComponent)"
        return FullRender.Ask(url: folder.appendingPathComponent(FullRender.fileName(frame: frame.id, stamp: stamp)), stamp: stamp, lens: lens)
    }

    /// Hand the engine's host a full-size render of `frame` for the page's
    /// zoom: an export's at Full in every respect but what is made of it.
    @discardableResult
    func prepareFullView(_ job: RenderJob, frame: LibraryFrame, plan: ExportPlan, source: URL, isRAW: Bool,
                         ask: FullRender.Ask) -> Bool {
        #if SPK_ENGINE
        guard let host, !frame.isComposite, isHere(frame) else { return false }
        var request = EngineHost.Request(frameID: frame.id, source: source, isRAW: isRAW, decode: frame.edit.decode,
                                         longEdge: plan.decodeLongEdge, cut: plan.cut,
                                         wire: exportWire(frame, plan: plan, full: true),
                                         turnsAfter: plan.turnsAfter, stamp: ask.stamp, purpose: .fullView(ask))
        request.lens = ask.lens
        if !frame.edit.appliesFilm { request.digital = plan.cut ?? (plan.engineCuts ? frame.edit.geometry : .default) }
        host.register(job.id, request)
        return true
        #else
        return false
        #endif
    }

    #if SPK_ENGINE
    /// The output transform's numbers into Display P3, for the page's zoom
    /// (`FullDetail`): asked of the engine on its queue, once.
    func pageTransform() async throws -> SpkEngine.OutputTransformData? {
        guard let engine = engine as? SpkEngine else { return nil }
        return try await engine.outputTransform(from: OutputTransformer.workingSpace, to: OutputTransformer.Target.displayP3.rawValue,
                                                gamutCompress: OutputTransformer.withoutLightness)
    }

    /// The Metal device the engine runs on, for the page's zoom.
    var device: MTLDevice? { (engine as? SpkEngine)?.device }

    /// The output transform's numbers from the page's Display P3 into `target`, for a proof of the
    /// page's picture in a smaller space (`GamutProof`): asked of the engine on its queue.
    func proofTransform(to target: OutputTransformer.Target) async throws -> SpkEngine.OutputTransformData? {
        guard let engine = engine as? SpkEngine else { return nil }
        return try await engine.outputTransform(from: OutputTransformer.Target.displayP3.rawValue, to: target.rawValue,
                                                gamutCompress: OutputTransformer.withoutLightness)
    }
    #endif

    /// What became of an export job's file: asked once, after the job has
    /// ended. Nil where no file was to be made (no engine here), and for a job
    /// that never reached its delivery.
    func takeExport(_ jobID: UUID) -> ExportOutcome? {
        #if SPK_ENGINE
        return host?.takeExport(jobID)
        #else
        return nil
        #endif
    }

    /// The job has ended, however it ended.
    func forget(_ jobID: UUID) {
        #if SPK_ENGINE
        host?.forget(jobID)
        composed[jobID] = nil
        #endif
    }

    /// The engine's own wire names (`spk_params_schema`), for a check of a wire this app builds (`DoubleHarness`).
    /// Empty with no engine.
    func schemaNames() async -> [String] {
        #if SPK_ENGINE
        guard let spk else { return [] }
        return Array(await spk.schema().keys)
        #else
        return []
        #endif
    }

    /// The frame whose engine session is open between canvas jobs (`SpkEngine.editingFrame`): nil with
    /// none, or no engine. For the harness's check that an exposure held alone left the page's session.
    func editingFrame() async -> UUID? {
        #if SPK_ENGINE
        guard let spk else { return nil }
        return await spk.editingFrame()
        #else
        return nil
        #endif
    }

    /// The frame's page closed: its session, with its source and its cached
    /// negative, is given back (113 MB of a 2,560 px canvas on the reference device).
    func closeEditing(_ frameID: UUID) {
        #if SPK_ENGINE
        guard let spk else { return }
        Task { await spk.closeEditing(frameID: frameID) }
        #endif
    }

    /// The develop page's last picture, kept as the frame's develop: written
    /// off the main thread, and reported like any other (`onKept`).
    func keep(_ image: UIImage, frameID: UUID, stamp: String) {
        #if SPK_ENGINE
        guard host != nil, let cg = image.cgImage else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let picture = try? EngineHost.write(cg, frameID: frameID, stamp: stamp) else { return }
            await MainActor.run { self?.onKept?(frameID, picture) }
        }
        #endif
    }

    /// Pay a stock pair's fixed setup before the first frame waits on it
    /// (145-191 ms on the reference device).
    func warmUp(film: String, paper: String) {
        #if SPK_ENGINE
        guard let spk else { return }
        Task { _ = await spk.warmUp(film: film, paper: paper) }
        #endif
    }

    /// The frame on the develop page against its film and paper
    /// (`spk_scene_latitude`): what the Latitude card draws, and the fit Scene
    /// Placement commits. Asked of the session the page's canvas keeps open,
    /// so only after a develop of that page has landed; it renders nothing.
    ///
    /// Nil when there is nothing to ask — no engine here, or no session open
    /// on that frame (its page has closed): whatever the card shows stays. A
    /// failure is the engine refusing, in the engine's words — for
    /// `LatitudeReading.refusal`, and the log, never for a page.
    func sceneLatitude(_ frameID: UUID, request: SceneLatitudeRequest) async -> Result<SceneLatitudeReply, EngineError>? {
        #if SPK_ENGINE
        guard let spk else { return nil }
        let started = Date()
        do {
            let json = try await spk.sceneLatitude(frameID: frameID, request: request.json)
            guard let reply = SceneLatitudeReply.decode(json) else {
                log.error("scene latitude: the engine's reply did not parse (\(json.utf8.count) bytes)")
                return .failure(.failed("the reply did not parse"))
            }
            let ms = Date().timeIntervalSince(started) * 1000
            // The pull-backs as asked, and the engine's own code for a refusal: what a log is read for.
            let fit = reply.fit.valid ? "valid" : "refused (" + reply.fit.issues.map { $0.code + ", " + $0.side }.joined(separator: "; ") + ")"
            log.info("scene latitude: held \(reply.medium.shadowEV, format: .fixed(precision: 2)) to \(reply.medium.highlightEV, format: .fixed(precision: 2)), the scene \(reply.scene.p0_1, format: .fixed(precision: 2)) to \(reply.scene.p99_9, format: .fixed(precision: 2)); pulled back \(reply.fit.highlight.pullBack, format: .fixed(precision: 2)) and \(reply.fit.shadow.pullBack, format: .fixed(precision: 2)): \(fit, privacy: .public); \(ms, format: .fixed(precision: 1)) ms")
            return .success(reply)
        } catch EngineError.cancelled {
            return nil
        } catch EngineError.failed(let message) {
            log.error("scene latitude: \(message, privacy: .public)")
            return .failure(.failed(message))
        } catch {
            log.error("scene latitude: \(String(describing: error), privacy: .public)")
            return .failure(.failed("\(error)"))
        }
        #else
        return nil
        #endif
    }

    /// The wire fields this engine does not know, or would refuse for their
    /// value: an unknown name fails a whole open. Empty where there is no
    /// engine to ask. Checked once at launch, and written to the log.
    func wireProblems(_ wire: [String: ParamValue]) async -> [String] {
        #if SPK_ENGINE
        guard let spk else { return [] }
        let schema = await spk.schema()
        guard !schema.isEmpty else { return ["the engine's schema is empty"] }
        var problems: [String] = []
        for (name, value) in wire.sorted(by: { $0.key < $1.key }) where name != "product_defaults" {
            guard let field = schema[name] else { problems.append("\(name): not in the engine's schema"); continue }
            if case .double(let d) = value, let range = field, !range.contains(d) {
                problems.append("\(name) = \(d): outside \(range.lowerBound)...\(range.upperBound)")
            }
        }
        return problems
        #else
        return []
        #endif
    }

    #if SPK_ENGINE
    private func landed(_ delivery: EngineHost.Delivery) {
        switch delivery {
        case .canvas(_, let frame, let image, let stamp):
            onCanvas?(frame, UIImage(cgImage: image), stamp)
        case .kept(_, let frame, let picture):
            onKept?(frame, picture)
        case .asShot(let frame, let temperature, let tint):
            onAsShot?(frame, temperature, tint)
        case .rawExposure(let frame, let facts):
            onRawExposure?(frame, facts)
        case .metered(let piece, let index, let ev, let key):
            // A double exposure's exposure, or a pair's hole: the piece the reading is of says which.
            if frames(piece)?.isDouble == true {
                if let position = DoubleExposure.Position(rawValue: index) { onDoubleMetered?(piece, position, ev, key) }
            } else {
                onMetered?(piece, index, ev, key)
            }
        case .gates(let pair, let rects):
            onGates?(pair, rects)
        case .proxy(_, let event):
            originals?.copies.noteProxy(event.url, bytes: event.bytes)
        case .fullView(_, _, let ask, let bytes):
            originals?.copies.noteFull(ask.url, bytes: bytes)
        case .hdrCurve(let frame, let stamp, let answer):
            said(frame, answer)
            onHDRCurve?(frame, answer, stamp)
        case .failed(_, let frame, let message):
            log.error("frame \(frame.uuidString, privacy: .public): \(message, privacy: .public)")
        }
    }
    #endif
}

extension LibraryFrame {
    /// Whether the file the engine develops from is a RAW. A frame read in
    /// place from Photos is developed from its original too, brought into the
    /// working copies (`Originals`); only one the app has no way back to — the
    /// drawings' own, which are never developed — is not.
    var developsFromRAW: Bool { isRAW && (source != .photos || readsFromPhotos) }

    /// A word in the develop's stamp for a frame read in place from Photos
    /// (`DevelopStamp.of`, `origin`): until 2026-10-10 such a frame was
    /// developed from a preview copy that was its file's embedded thumbnail —
    /// 352 pixels of an 18 MP photo — and a develop kept from that is not one
    /// of the original, whatever else of its stamp agrees. The word does not
    /// change with whether the working copy is here.
    /// A photo's original kept in the app is the same file it was read from in Photos: its
    /// develops are the same pictures, and moving it in develops nothing again.
    var stampOrigin: String? { readsFromPhotos || (source == .copiedIn && assetIdentifier != nil) ? "the original, from Photos" : nil }
}
