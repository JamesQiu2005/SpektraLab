//  EngineHost.swift — what the engine asks its host for: this app's `FrameSource`.
//
//  `SpkEngine` runs a job on its own queue and asks three things of its host
//  (`FrameSource`): the frame's pixels, its settings in wire names, and what
//  to do with the result. The pages live on the main actor and a frame's edit
//  moves under a finger, so none of that can be read when the engine asks.
//  **Each job's answers are captured when the job is submitted** (`Request`,
//  made on the main actor by `EngineRouter.prepare`) and kept here until the job
//  has ended — a job that gives way runs again from the start with the same
//  id, and asks again.
//
//  What happens to a result:
//
//  - **the canvas** (`.canvas`): out of the working space into Display P3
//    (`OutputTransformer`), and to the develop page as a picture in memory;
//  - **a frame's own develop** (`.keep`: a shot, an import): the same picture,
//    written beside the preview copies (`DevelopedPicture`), which is what the
//    library reads.
//
//  **With a film edge the frame handed over is already cut** (`Request.cut`,
//  made by `FrameDecoder`): the engine takes its frame as the gate and sets
//  the film's millimetres from it, so the picture is cut to the film's
//  framing before the engine sees it and the wire carries no cut
//  (`EngineWire`). The engine keeps the source a session was opened with, so
//  a job whose pixels would be others — another framing, another white
//  balance of a RAW — says so (`sourceKey`) and its frame is opened again.
//
//  **A film turned half round is turned here.** The engine reads a film's
//  direction from the frame it is handed, which gives it two of the four
//  turns; for the other two the picture goes in turned back (in the same cut,
//  `FrameEdit.hostCut`) and the canvas that comes out is turned forward by
//  the same whole quarter turns (`Request.turnsAfter`, `turned`): pixels
//  moved, none resampled.
//
//  **A half-frame pair's frame is made here** (`Request.piece`, `PieceAsk`):
//  two pictures laid on one piece of film by `FrameDecoder`, each under its
//  hole and each exposed by itself. A picture whose meter has not read yet is
//  read during that decode, by the engine's own meter on that picture alone
//  (`SpkEngine.meterOnQueue`), and the reading is handed back (`.metered`) to
//  be kept in the pair — so it is read once, and the picture does not pump.
//
//  **A double exposure's frame is made the same way** (RFC-048): its two
//  exposures' light **added** over the whole frame (`PieceAsk.Lay.add`,
//  `PieceAdder`), each metered alone from a small render of its own, the
//  reading handed back the same way (`.metered`, its index the exposure's
//  position) and kept in the double (`EngineRouter.onDoubleMetered`). It is one
//  frame in one gate: no gates are asked of the engine and no print is cut in.
//
//  **A frame of a pair that prints as its own is cut in here**
//  (`Request.layers`, `PrintLayers.swift`). The engine prints the piece once
//  for the film; for each such frame it is then asked for another print of
//  the same negative with that frame's rows (`printLayers`), and that print
//  is taken into the result inside the frame's rectangle (`cut`), before the
//  result is made a picture. On a strip the frame is where the engine put its
//  gate, so the engine is asked (`wantsFilmGeometry`) — and for the develop
//  page's canvas the two gates go to the page too (`.gates`), which has no
//  other way to know where a touch on the film lands.
//
//  - **Enable HDR's curve** (HDR port, 2026-11-06, API-SPEC §19.2): a canvas job asks the engine for its
//    session's curve after the render (`Request.hdrCurve`, `SpkEngine`), and the answer goes to the page
//    just before the picture it is of (`.hdrCurve`, then `.canvas`), so the page draws that picture's HDR
//    with no engine in the way. A slide's export may ask for a second rendition (`Request.slideHDR`): its ratio over the picture is kept here for the export's file (`takeSlideMap`).
//  - **An export's gain map** (the export round, D8): an export of a frame with Enable HDR on asks its own
//    render's session for the curve (`Request.hdrCurve`, as the canvas does), so the file's map is the gain of
//    the develop it is written from — never a page's curve, and never a kept full render's, which has no
//    session (`cached` steps aside for it). The map is made of the finished picture (Layer 2 and the crop on
//    it, as the base is), and a map that cannot be made or written leaves today's file, said in the log.
//
//  - **an export** (`.export`): out of the working space into the recipe's
//    own colour space, at the file's own depth — 8 bits written by the
//    transform's kernel for JPEG, HEIF and PNG, 16 for TIFF — and into the
//    file (`ExportWriter`). A frame with Edit's Light, Curve or Colour on it
//    goes through the same transform with the page's Layer 2 pass inside it
//    (`Layer2Export`), in one kernel: no picture more is held. What became of it is kept here until the export
//    asks (`takeExport`): the job has finished by then, and a delivery that
//    hops to the main actor may not have.

#if SPK_ENGINE
import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import os

final class EngineHost: FrameSource, @unchecked Sendable {
    /// `card`: a card of Develop's strips (`StockPreviews`), its key.
    /// `fullView`: the develop page's zoom — the render kept on disk (`FullRender`), nothing else made of it.
    /// `alone`: one exposure of a double exposure by itself (`EngineRouter.prepareAlone`, PRD 2 D12): the
    /// page's picture, kept in memory for the page to take when the job has ended (`takeCard`), never
    /// the page's canvas nor the frame's develop.
    enum Purpose: Sendable { case canvas, keep, export(ExportOrder), card(String), fullView(FullRender.Ask), alone }

    /// A strip's picture, decoded once and handed to each of its cards' opens
    /// (`StripSource`). The engine borrows the buffer for the open and keeps
    /// its own copy, so one buffer serves every card.
    final class StripDecode {
        let frame: DecodedFrame
        init(_ frame: DecodedFrame) { self.frame = frame }
    }

    /// A strip that takes the page's own decode of the same pixels (`pixels`),
    /// made `longEdge` on its long side, as its decode (`word`): the page's
    /// develop decodes the file anyway, and a RAW's decode is seconds.
    struct Feed {
        let source: StripSource
        let pixels: String
        let word: String
        let longEdge: Int
        /// The frame the strip's cards are priced to open (`CardPlan.opens`):
        /// what the page's decode is made. The page's decode is already cut,
        /// so its long edge is not the strip's decode's long edge whenever the
        /// cut is narrower than the picture.
        let size: PixelSize
    }

    /// One job's answers, captured when it was submitted.
    struct Request: Sendable {
        var frameID: UUID
        /// The file to develop from: the original — a Photos frame's working copy of it.
        var source: URL
        var isRAW: Bool
        var decode: DecodeSettings
        /// The decode's long edge; nil is the file's own size (a full-size job).
        var longEdge: Int?
        /// The host's own cut of the decode — a film edge's framing
        /// (`FrameEdit.hostCut`); nil hands the engine the whole decode.
        var cut: Geometry?
        /// The whole wire (`FrameEdit.engineWire`).
        var wire: [String: ParamValue]
        /// Quarter turns, clockwise, to give the engine's canvas before it is
        /// a picture: a film's half turn (`FrameEdit.hostTurns`).
        var turnsAfter = 0
        /// What the picture is made from (`DevelopStamp`).
        var stamp: String
        var purpose: Purpose
        /// A half-frame pair: the frame is this piece, composed by the host,
        /// and `source`, `isRAW`, `decode`, `longEdge` and `cut` are not read
        /// (each picture of the piece has its own). `frameID` is the pair's.
        var piece: PieceAsk? = nil
        /// A half-frame pair's frames that print as their own: each is
        /// printed again from the job's negative and cut into its picture
        /// (`PrintLayer`). Not pixels of the source, so not in `sourceKey`: a
        /// frame's print changed is a reprint, not another open.
        var layers: [PrintLayer] = []
        /// A strip's card: the picture its cards share, and whether this job
        /// was priced to decode it. One that was not, and finds it given back,
        /// fails rather than decode unpriced (`StockPreviews` asks again).
        var strip: StripSource? = nil
        var decodesStrip = false
        /// Canonical 1600 px pair composition, independent of canvas tier.
        var stripPixels: String? = nil
        /// A trim after preparation invalidates late decode completion.
        var sourceGeneration: Int? = nil
        /// A RAW's proxy at the frame's preview size (`RawProxy`): a decode no
        /// larger than it is made from it. Nil for every other job.
        var proxy: RawProxy.Ask? = nil
        /// An export's own render, kept on disk by the page's zoom (`FullRender`):
        /// where it is there and of this request's stamp, the export is made from
        /// it and the engine is not run (`cached`).
        var fullRender: FullRender.Ask? = nil
        /// Apply Film Emulation off: the cut Apple's decode is given (`DigitalDecode`) — the whole of the
        /// frame's geometry, the engine taking none of it. Nil: the film, through the engine.
        var digital: Geometry? = nil
        /// Enable HDR's curve: the request `spk_session_hdr_curve` is asked with after the render
        /// (`HDRSessionCurve.request`), its answer delivered before the picture (`.hdrCurve`), or for an export
        /// its file's map's curve (`ExportOrder.gainMap`). The develop
        /// page's canvas asks with every develop of a film (`EngineRouter.prepare`); nil asks nothing.
        var hdrCurve: String? = nil
        /// A slide's Enable HDR on an export (`HDRGain`): the second rendition the engine renders after the
        /// job's own, whose ratio over it is the file's map. Nil for everything else.
        var slideHDR: HDRGain.SlideRendition? = nil
        /// PRD-E's 场景 layers (RFC-052 §6.4): what `spk_set_scene_layers` is handed for this job — the layers'
        /// value, the matrix, the stamp the wire names (`scene_layers`) — captured here with the rest of the job's
        /// answers, so its planes are made from the edit this job was submitted with (`SceneLayerWire.planes`). Nil:
        /// no layer can act, and the wire has no `scene_layers`.
        var sceneLayers: SceneLayerWire.Ask? = nil
        /// 镜头校正 as this request's keys name it (`stamp`, `sourceKey`, `pixelsKey`, its proxy's name), taken once when
        /// it was made (`EngineRouter.prepare`): every decode of the request is made with it (`DecodeAsk.lens`,
        /// `DigitalDecode.render`), so a resolution that settles between the two never puts a picture of one corrector
        /// under a key that names another. Nil (a piece's, whose pictures carry their own; a request no key named a
        /// lens for) asks the resolver.
        var lens: LensResolution? = nil

        /// Whether the engine draws the film round the frame: the canvas is
        /// then the film, and a pair's frames are where its gates are.
        var wearsFilm: Bool { wire["overscan_active"] == .bool(true) }

        /// What the frame's pixels are made of, as a word: the file, how it is
        /// decoded and how the host cuts it. The decode's settings change a
        /// RAW's pixels and nothing else's (as in `DevelopStamp`), the app's lens correction among them
        /// (`LensCorrection.word`).
        static func sourceKey(source: URL, isRAW: Bool, decode: DecodeSettings, longEdge: Int?, cut: Geometry?,
                              lens: LensResolution? = nil) -> String {
            [source.path, isRAW ? "raw " + decode.pixelsKey(source: source, lens: lens) : "", longEdge.map { "\($0)" } ?? "whole", cut?.cutKey ?? ""]
                .joined(separator: "|")
        }
        /// The same pixels at any size: the file, its decode, the host's cut.
        static func pixelsKey(source: URL, isRAW: Bool, decode: DecodeSettings, cut: Geometry?, lens: LensResolution? = nil) -> String {
            [source.path, isRAW ? "raw " + decode.pixelsKey(source: source, lens: lens) : "", cut?.cutKey ?? ""].joined(separator: "|")
        }
        var pixelsKey: String { Self.pixelsKey(source: source, isRAW: isRAW, decode: decode, cut: cut, lens: lens) }
        var sourceKey: String {
            piece?.key ?? Self.sourceKey(source: source, isRAW: isRAW, decode: decode, longEdge: longEdge, cut: cut, lens: lens)
        }
    }

    enum Delivery: @unchecked Sendable {
        /// The develop page's picture, already in Display P3.
        case canvas(job: UUID, frame: UUID, image: CGImage, stamp: String)
        /// A frame's own develop, written.
        case kept(job: UUID, frame: UUID, picture: DevelopedPicture)
        /// The camera's own white balance, read from a RAW at its decode.
        case asShot(frame: UUID, temperature: Double, tint: Double)
        case rawExposure(frame: UUID, facts: RawExposureFacts)
        /// What the engine's meter chose for one picture of a pair alone, and
        /// what it was read for (`PieceAsk.Exposure.metered`). `index` is the
        /// hole: 0 the first, 1 the second.
        case metered(pair: UUID, index: Int, ev: Double, key: String)
        /// Where the engine put a pair's two frames on the strip it has just
        /// developed for the develop page: each gate's rectangle, normalised
        /// to the canvas with a top-left origin, the first frame's first
        /// (`FilmGates`). Sent before that develop's `.canvas`.
        case gates(frame: UUID, rects: [CGRect])
        /// A decode read a RAW's proxy, or wrote it (`RawProxy`): for the book.
        case proxy(frame: UUID, event: RawProxy.Event)
        /// The page's full render is on disk (`FullRender`).
        case fullView(job: UUID, frame: UUID, ask: FullRender.Ask, bytes: Int64)
        /// Enable HDR's curve of the session that made the develop page's next picture (`stamp`): sent just
        /// before that picture's `.canvas`.
        case hdrCurve(frame: UUID, stamp: String, answer: HDRSessionCurve.Answer)
        /// The render finished and its picture could not be made or written.
        case failed(job: UUID, frame: UUID, message: String)
    }

    let device: MTLDevice
    /// The engine, for the output transform's numbers. Set once, before any job.
    weak var engine: SpkEngine?
    /// Called on the engine's queue; whoever sets it hops to where it lives.
    var onDelivery: (@Sendable (Delivery) -> Void)?

    private let lock = NSLock()
    private var requests: [UUID: Request] = [:]
    private var exports: [UUID: ExportOutcome] = [:]
    private var cards: [UUID: CGImage] = [:]
    private var feeds: [UUID: Feed] = [:]
    /// A slide's export's map, made of its two renditions (`takeHDRRendition`), until the export takes it.
    enum SlideMap: @unchecked Sendable {
        case made(HDRGain.SlideRendition, HDRGainMap.Attachment)
        /// Nothing past a knee: no map is better than a map of zeros.
        case noGain
        /// The rendition could not be made: the curve stands in.
        case failed(String)
    }
    private var slideMaps: [UUID: SlideMap] = [:]
    private let decoder: FrameDecoder
    private var transformer: OutputTransformer?
    /// The export's Layer 2 pass, made when an export first carries an edit.
    private var layer2: Layer2Export?
    /// For carrying a cut into a texture that is a copy of its result
    /// (`carry`): the the operating system simulator's. Made when first needed, on the engine's
    /// queue, and never on a device.
    private var copyQueue: MTLCommandQueue?
    private let log = Logger(subsystem: "com.spektralab.mac", category: "engine")

    init(device: MTLDevice) {
        self.device = device
        decoder = FrameDecoder(device: device)
    }

    // MARK: the requests (any thread)

    func register(_ jobID: UUID, _ request: Request) {
        lock.lock()
        var prepared = request
        prepared.sourceGeneration = request.strip?.generation ?? feeds[request.frameID]?.source.generation
        requests[jobID] = prepared
        lock.unlock()
        #if DEBUG
        Self.registered?(request)
        #endif
    }

    #if DEBUG
    /// A check's: told of every request as it is registered, before its job can start (`MacLensCheck` settles a lens
    /// resolution there, the moment the model stage's race needs).
    nonisolated(unsafe) static var registered: ((Request) -> Void)?
    #endif

    /// The job has ended, however: its answers are no longer needed.
    func forget(_ jobID: UUID) {
        lock.lock(); requests[jobID] = nil; slideMaps[jobID] = nil; lock.unlock()
    }

    private func request(_ jobID: UUID) -> Request? {
        lock.lock(); defer { lock.unlock() }
        return requests[jobID]
    }

    /// What became of an export job's file, once: nil for a job that never
    /// reached its delivery (cancelled, failed in the engine), or was not an
    /// export. Set before the job's `run` returns, so whoever waited for the
    /// job's end finds it here.
    func takeExport(_ jobID: UUID) -> ExportOutcome? {
        lock.lock(); defer { lock.unlock() }
        return exports.removeValue(forKey: jobID)
    }

    private func exported(_ jobID: UUID, _ outcome: ExportOutcome) {
        lock.lock(); exports[jobID] = outcome; lock.unlock()
    }

    /// A card's picture, once: nil for a job that never reached its delivery.
    /// Set before the job's `run` returns.
    func takeCard(_ jobID: UUID) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cards.removeValue(forKey: jobID)
    }

    /// The strip of a frame that takes the page's decode (`Feed`); nil: none does.
    func feed(_ feed: Feed?, for frame: UUID) {
        lock.lock(); feeds[frame] = feed; lock.unlock()
    }

    private func feed(for frame: UUID) -> Feed? {
        lock.lock(); defer { lock.unlock() }
        return feeds[frame]
    }

    /// The page's decode, made the strip's size and kept as its decode, where a
    /// strip of the frame takes it and does not hold it yet. On the engine's
    /// queue, inside the page's job, before the decode's buffer goes: a scale
    /// on the CPU (the strip's size is 29 MB, the page's frame is read once).
    private func feedStrip(_ r: Request, _ frame: DecodedFrame, generation: Int?) {
        guard let generation, case .canvas = r.purpose, let f = feed(for: r.frameID),
              generation == f.source.generation, f.pixels == (r.stripPixels ?? r.pixelsKey),
              !f.source.holds(f.word), case let pageEdge = frame.size.longEdge, pageEdge > 0 else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        // The size the cards are priced to open, never larger than the page's own: a film's
        // framing a hair narrower than the picture made a cut 1609 × 1079 where 1600 × 1073 was
        // priced, and every card of the frame was refused (the owner's reference device, 2026-10-20).
        let w = max(1, min(f.size.width, frame.size.width)), h = max(1, min(f.size.height, frame.size.height))
        guard frame.channels == 4, let buffer = device.makeBuffer(length: w * h * 16, options: .storageModeShared) else { return }
        var from = vImage_Buffer(data: frame.buffer.contents(), height: vImagePixelCount(frame.size.height),
                                 width: vImagePixelCount(frame.size.width), rowBytes: frame.size.width * 16)
        var to = vImage_Buffer(data: buffer.contents(), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 16)
        guard vImageScale_ARGBFFFF(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return }
        f.source.keep(StripDecode(DecodedFrame(buffer: buffer, size: PixelSize(width: w, height: h), channels: 4)), for: f.word, bytes: w * h * 16, expectedGeneration: generation)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        log.info("the page's decode made a strip's: \(frame.size.width) x \(frame.size.height) to \(w) x \(h) in \(ms, format: .fixed(precision: 1)) ms")
    }

    // MARK: FrameSource (the engine's queue)

    func decode(_ job: RenderJob, device: MTLDevice) throws -> DecodedFrame {
        guard let r = request(job.id) else { throw EngineError.failed("no frame was handed over for this job") }
        let generation = r.sourceGeneration ?? feed(for: r.frameID)?.source.generation
        if let piece = r.piece {
            if let strip = r.strip {
                if let kept = strip.take(r.sourceKey) as? StripDecode {
                    var said = kept.frame; said.how = "the strip's composed decode"
                    return said
                }
                guard r.decodesStrip else { throw EngineError.resource(StripSource.givenBack) }
            }
            let (frame, report) = try decoder.decode(piece, meter: { picture, asked in
                guard let engine = self.engine else { throw EngineError.failed("the engine has gone") }
                return try engine.meterOnQueue(picture, wire: asked.meterWire)
            })
            for reading in report.readings {
                onDelivery?(.metered(pair: r.frameID, index: reading.index, ev: reading.ev, key: reading.key))
            }
            // A pair's holes are first and second; a double exposure's exposures bottom and top.
            let names = piece.adds ? ("bottom", "top") : ("first", "second")
            let stops = report.stops.sorted { $0.key < $1.key }
                .map { "\($0.key == 0 ? names.0 : names.1) \(String(format: "%+.2f", $0.value)) EV" }.joined(separator: ", ")
            log.info("composed a piece of \(piece.pictures.count) by \(report.how.joined(separator: ", "), privacy: .public): \(frame.size.width) x \(frame.size.height); \(stops, privacy: .public)\(report.readings.isEmpty ? "" : "; metered \(report.readings.count)", privacy: .public)")
            var said = frame
            said.how = Self.recorded(report.how.joined(separator: ", "))
            if let strip = r.strip, let generation {
                strip.keep(StripDecode(said), for: r.sourceKey, bytes: frame.size.width * frame.size.height * 16, expectedGeneration: generation)
            }
            feedStrip(r, said, generation: generation)
            return said
        }
        if let strip = r.strip {
            // A strip's card: the picture its cards share, decoded by the first that was priced to.
            if let kept = strip.take(r.sourceKey) as? StripDecode {
                var said = kept.frame
                said.how = "the strip's decode"
                return said
            }
            // A RAW whose proxy is here opens from it for the price of an open: no decode of the file.
            guard r.decodesStrip || r.proxy.map({ FileManager.default.fileExists(atPath: $0.url.path) }) == true else {
                throw EngineError.resource(StripSource.givenBack)
            }
            let (frame, report) = try decoder.decode(DecodeAsk(url: r.source, isRAW: r.isRAW, settings: r.decode,
                                                               longEdge: r.longEdge, cut: r.cut, proxy: r.proxy, lens: r.lens))
            if let facts = report.rawExposure { onDelivery?(.rawExposure(frame: r.frameID, facts: facts)) }
            if let event = report.proxy { onDelivery?(.proxy(frame: r.frameID, event: event)) }
            if let generation {
                strip.keep(StripDecode(frame), for: r.sourceKey, bytes: frame.size.width * frame.size.height * 16, expectedGeneration: generation)
            }
            log.info("decoded \(r.source.lastPathComponent, privacy: .public) for a strip by \(report.how, privacy: .public): \(frame.size.width) x \(frame.size.height)")
            var said = frame
            said.how = Self.recorded(report.how)
            return said
        }
        let (frame, report) = try decoder.decode(DecodeAsk(url: r.source, isRAW: r.isRAW, settings: r.decode, longEdge: r.longEdge,
                                                           cut: r.cut, proxy: r.proxy, lens: r.lens))
        if let facts = report.rawExposure { onDelivery?(.rawExposure(frame: r.frameID, facts: facts)) }
        if let event = report.proxy { onDelivery?(.proxy(frame: r.frameID, event: event)) }
        if let wb = report.asShot, r.decode.whiteBalance == .asShot {
            onDelivery?(.asShot(frame: r.frameID, temperature: wb.temperature, tint: wb.tint))
        }
        feedStrip(r, frame, generation: generation)
        log.info("decoded \(r.source.lastPathComponent, privacy: .public) by \(report.how, privacy: .public): \(frame.size.width) x \(frame.size.height)\(r.cut == nil ? "" : ", cut to the film's framing", privacy: .public)")
        var said = frame
        said.how = Self.recorded(report.how)
        return said
    }

    /// A decode's word as a job's record carries it. The RAW decoder names its
    /// version like a file ("9.dng"), and the log takes a file's name out of
    /// every string (`LogScrub`): "RAW 9.dng" is written "RAW 9 dng".
    static func recorded(_ how: String) -> String { how.replacingOccurrences(of: ".", with: " ") }

    /// An export whose render the page's zoom kept (`FullRender`): read back,
    /// the engine not asked. Only where the file is whole and of this request's stamp.
    func cached(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels? {
        // Not for a slide's HDR export: its second rendition needs a session, which a kept render has not. Nor for
        // any export with a map: its curve is its session's (`Request.hdrCurve`), and a kept render has none.
        guard let r = request(job.id), case .export(let order) = r.purpose, r.slideHDR == nil, !order.gainMap,
              let ask = r.fullRender,
              let reader = FullRender.Reader(ask.url, stamp: ask.stamp) else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        let pixels = try reader.pixels(device: device)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        log.info("an export from the kept full render: \(pixels.size.width) x \(pixels.size.height) read in \(ms, format: .fixed(precision: 0)) ms")
        onDelivery?(.proxy(frame: r.frameID, event: RawProxy.Event(url: ask.url, bytes: Int64(reader.header.fileBytes), made: false)))
        return pixels
    }

    func digital(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels? {
        guard let r = request(job.id), let geometry = r.digital, r.piece == nil, r.strip == nil else { return nil }
        let started = DispatchTime.now().uptimeNanoseconds
        // Its 场景 layers on the linear decode, by the engine node's expression (`SceneLayerHost`, RFC-052 §6.5).
        var layers: DigitalDecode.Layers?
        if let ask = r.sceneLayers {
            let planes = try SceneLayerWire.planes(for: ask, device: device)
            let host = try Self.sceneLayerHost(device)
            let toSource = MaskFrame.finished(picture: geometry, source: CGSize(width: ask.source.width, height: ask.source.height))
            layers = { buffer, w, h in try host.apply(ask, planes: planes, frameToSource: toSource, to: buffer, width: w, height: h) }
        }
        let pixels = try DigitalDecode.render(r.source, isRAW: r.isRAW, decode: r.decode, geometry: geometry,
                                              canvas: job.canvas, device: device, layers: layers, lens: r.lens)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        log.info("Apple's decode of \(r.source.lastPathComponent, privacy: .public), no film: \(pixels.size.width) x \(pixels.size.height) in \(ms, format: .fixed(precision: 0)) ms")
        return pixels
    }

    private static let hostLock = NSLock()
    nonisolated(unsafe) private static var hosts: [ObjectIdentifier: SceneLayerHost] = [:]

    /// The 场景 layers' host kernel on `device`: one, compiled the first time it is asked for.
    static func sceneLayerHost(_ device: MTLDevice) throws -> SceneLayerHost {
        hostLock.lock(); defer { hostLock.unlock() }
        if let h = hosts[ObjectIdentifier(device)] { return h }
        let h = try SceneLayerHost(device: device)
        hosts[ObjectIdentifier(device)] = h
        return h
    }

    func sourceKey(_ job: RenderJob) -> String {
        guard let r = request(job.id) else { return "" }
        // A trim gave the shared decode back. On the next foreground edit,
        // reopen once so that the canvas can refill it; background cards do
        // not perform an uninterruptible RAW decode on the user's behalf.
        if case .canvas = r.purpose, let f = feed(for: r.frameID) {
            return r.sourceKey + "|strip-generation=\(r.sourceGeneration ?? f.source.generation)"
        }
        return r.sourceKey
    }

    func params(_ job: RenderJob) -> [String: ParamValue] {
        request(job.id)?.wire ?? [:]
    }

    func sceneLayers(_ job: RenderJob) -> SceneLayerWire.Ask? {
        guard let r = request(job.id), r.digital == nil, r.piece == nil else { return nil }
        return r.sceneLayers
    }

    func hdrCurveRequest(_ job: RenderJob) -> String? {
        guard let r = request(job.id), r.digital == nil else { return nil }
        return r.hdrCurve
    }

    // MARK: a slide's HDR rendition (`HDRGain`)

    func hdrRendition(_ job: RenderJob) -> (delta: [String: ParamValue], restore: [String: ParamValue])? {
        guard let r = request(job.id), case .export = r.purpose, let slide = r.slideHDR, r.piece == nil,
              r.layers.isEmpty, r.digital == nil else { return nil }
        // Put back what the job's own wire had for each field (the stretch and its defaults otherwise).
        var restore = slide.restore
        for name in slide.delta.keys { if let own = r.wire[name] { restore[name] = own } }
        return (slide.delta, restore)
    }

    func takeHDRRendition(_ job: RenderJob, sdr: RenderedPixels, hdr: RenderedPixels) throws {
        guard let r = request(job.id), let slide = r.slideHDR else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let a = HDRGain.Pixels(rgba16: sdr.rgba16, width: sdr.size.width, height: sdr.size.height, stride: sdr.rowStridePixels)
        let b = HDRGain.Pixels(rgba16: hdr.rgba16, width: hdr.size.width, height: hdr.size.height, stride: hdr.rowStridePixels)
        let made = try HDRGain.ratioMap(sdr: a, hdr: b, rendition: slide)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        if let made {
            log.info("a slide's HDR rendition at H \(slide.headroom, format: .fixed(precision: 2)): its map \(made.map.width) x \(made.map.height), top \(made.headroom, format: .fixed(precision: 2)), made in \(ms, format: .fixed(precision: 0)) ms")
        } else {
            log.info("a slide's HDR rendition at H \(slide.headroom, format: .fixed(precision: 2)): no pixel past a knee, no map")
        }
        lock.lock(); slideMaps[job.id] = made.map { .made(slide, $0) } ?? .noGain; lock.unlock()
    }

    func hdrRenditionFailed(_ job: RenderJob, _ message: String) {
        log.error("a slide's HDR rendition was not made, its curve stands in: \(message, privacy: .public)")
        lock.lock(); slideMaps[job.id] = .failed(message); lock.unlock()
    }

    /// A slide's export's map, once (the export round's writer takes it; nil where none was asked).
    func takeSlideMap(_ jobID: UUID) -> SlideMap? {
        lock.lock(); defer { lock.unlock() }
        return slideMaps.removeValue(forKey: jobID)
    }

    func printLayers(_ job: RenderJob) -> [[String: ParamValue]] {
        request(job.id)?.layers.map(\.rows) ?? []
    }

    /// An exposure of a double shown alone is developed in a session of its own that goes with the job: the
    /// page's open session — the double composed, its negative cached — stays the engine's `editing`.
    func leavesEditingAlone(_ job: RenderJob) -> Bool {
        guard let r = request(job.id), case .alone = r.purpose else { return false }
        return true
    }

    /// A pair on its strip: for the page's canvas, which is told where the two
    /// frames are, and for any job with a frame's own print to cut in there.
    func wantsFilmGeometry(_ job: RenderJob) -> Bool {
        // A pair's only: a double exposure is one frame in one gate, and nothing is cut in along a hole.
        guard let r = request(job.id), let piece = r.piece, !piece.adds, r.wearsFilm else { return false }
        if case .canvas = r.purpose { return true }
        return !r.layers.isEmpty
    }

    func cut(_ job: RenderJob, layer index: Int, _ layer: RenderedPixels, into base: RenderedPixels) throws {
        guard let r = request(job.id), r.layers.indices.contains(index) else {
            throw EngineError.failed("a print was made that this job did not ask for")
        }
        // The canvas is not turned after a pair's render; a frame's rectangle is of the canvas as the engine made it.
        guard r.turnsAfter == 0, layer.size == base.size else {
            throw EngineError.failed("a frame's own print cannot be cut into a canvas the host turns, or of another size")
        }
        let asked = r.layers[index]
        var rect = asked.rect
        if r.wearsFilm {
            // On its strip the canvas is the film: the frame is where the engine put its gate.
            let gates = base.filmGeometry.map(FilmGates.rects) ?? []
            guard gates.count == 2, gates.indices.contains(asked.index) else {
                throw EngineError.failed("the engine did not say where the strip's two frames are")
            }
            rect = gates[asked.index]
        }
        let written = PrintCut.cut(layer.rgba16, stride: layer.rowStridePixels,
                                   into: UnsafeMutablePointer(mutating: base.rgba16), stride: base.rowStridePixels,
                                   width: base.size.width, height: base.size.height, rect: rect)
        if let written { try carry(written, into: base) }
    }

    /// What `cut` wrote into a result's memory, made true of its texture —
    /// which is what `deliver` makes the picture of (`OutputTransformer`).
    ///
    /// **On a device and a Mac there is nothing to do, and this looks rather
    /// than assumes**: the engine hands over a linear texture over the very
    /// buffer `rgba16` points into (`engine/src/gpu/metal_gpu.cpp`,
    /// `texture`), the texture names that buffer, and a write to the one is a
    /// write to the other.
    ///
    /// **The the operating system simulator's Metal makes no linear texture over a shared
    /// buffer** (it asserts), so there the engine's texture is one of its own,
    /// filled from the result buffer by a blit: a copy, which a write to
    /// `rgba16` never reaches. A frame's own print was cut in and did not
    /// show — the scheduler's log had the layer printed, and the page had
    /// both frames in the film's print (the simulator, 2026-10-10). So where
    /// the texture is not the memory that was written, the pixels written are
    /// carried into it the way the engine filled it: one more copy of that
    /// part of the picture, for as long as the blit takes.
    private func carry(_ written: PrintCut.Written, into base: RenderedPixels) throws {
        if let buffer = base.texture.buffer, buffer.contents() + base.texture.bufferOffset == UnsafeRawPointer(base.rgba16) { return }
        let width = written.columns.count, height = written.rows.count, rowBytes = width * 8
        if copyQueue == nil { copyQueue = device.makeCommandQueue() }
        guard let copyQueue, let part = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else {
            throw EngineError.resource("no \((rowBytes * height) >> 20) MB to carry a frame's own print into the picture")
        }
        let pitch = base.rowStridePixels * 8
        let from = UnsafeRawPointer(base.rgba16) + written.rows.lowerBound * pitch + written.columns.lowerBound * 8
        for row in 0..<height { memcpy(part.contents() + row * rowBytes, from + row * pitch, rowBytes) }
        guard let commands = copyQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw EngineError.failed("a frame's own print could not be carried into the picture")
        }
        blit.copy(from: part, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * height,
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: base.texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: written.columns.lowerBound, y: written.rows.lowerBound, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            throw EngineError.failed("a frame's own print could not be carried into the picture: \(commands.error.map { "\($0)" } ?? "the copy did not finish")")
        }
    }

    func deliver(_ job: RenderJob, _ pixels: RenderedPixels) {
        guard let r = request(job.id) else { return }
        do {
            // The page's zoom: the render as the engine made it, on disk, and nothing more.
            if case .fullView(let ask) = r.purpose {
                let started = DispatchTime.now().uptimeNanoseconds
                // An edit while it is written stops it (it was 6 s of the zoom before vImage made the half size).
                let jobID = job.id
                let bytes = try FullRender.write(pixels.rgba16, rowStride: pixels.rowStridePixels, width: pixels.size.width,
                                                 height: pixels.size.height, stamp: ask.stamp, turnsAfter: r.turnsAfter, to: ask.url,
                                                 cancelled: { [weak engine] in engine?.isCancelled(jobID) ?? false })
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
                log.info("kept the full render, \(pixels.size.width) x \(pixels.size.height), \(bytes >> 20) MB in \(ms, format: .fixed(precision: 0)) ms")
                onDelivery?(.fullView(job: job.id, frame: r.frameID, ask: ask, bytes: bytes))
                return
            }
            if transformer == nil { transformer = try OutputTransformer(device: device) }
            guard let transformer, let engine else { throw EngineError.failed("the engine has gone") }
            // A page's picture is Display P3 at 16 bits; a file is in its recipe's space, at its own depth.
            var target = OutputTransformer.Target.displayP3
            var depth = OutputTransformer.Depth.sixteen
            if case .export(let order) = r.purpose {
                target = OutputTransformer.Target(order.colour)
                depth = order.format.bitDepth == 8 ? .eight : .sixteen
            }
            // A card uses an 8-bit page preview; edited exports keep their Layer 2 transform.
            if case .card = r.purpose { depth = .eight }
            let fetch: (String, String, String?) throws -> SpkEngine.OutputTransformData = { source, target, compress in
                try engine.outputTransformOnQueue(from: source, to: target, gamutCompress: compress)
            }
            // An export of an edited frame bakes the edit (design/v5 §3.5); anything else is as before.
            let made: CGImage
            if case .export(let order) = r.purpose, let edit = order.adjustments, Layer2Local.acts(edit, order.layers) {
                if layer2 == nil { layer2 = try Layer2Export(device: device) }
                guard let layer2 else { throw EngineError.failed("Layer 2's export pass could not be made") }
                // Its 成片 layers: their planes made here, on the engine's queue (the store's where the page baked them
                // already), and read at the pixel's place on this render, before the host's turns. A plane that cannot
                // be made fails the file: never the file without its layer.
                let local = try order.layers.map { l in
                    Layer2LocalPass(l, planes: try l.planesBlocking(device: device), adjustments: edit, matrix: l.matrix(turnsAfter: r.turnsAfter))
                }
                made = try layer2.image(pixels, to: target, depth: depth, adjustments: edit, local: local, fetch: fetch)
            } else {
                made = try transformer.image(pixels, to: target, depth: depth, fetch: fetch)
            }
            var image = try Self.turned(made, quarterTurns: r.turnsAfter)
            // Edit's crop: a cut of the finished picture, made last (`FinishedCut`).
            if case .export(let order) = r.purpose, let cut = order.printCrop {
                image = try FinishedCut.image(image, by: cut.onFinished(CGSize(width: image.width, height: image.height)))
            }
            switch r.purpose {
            case .canvas:
                // A pair's strip: where its two frames are on the picture that follows.
                if let piece = r.piece, !piece.adds, r.wearsFilm, let said = pixels.filmGeometry {
                    let gates = FilmGates.rects(said)
                    log.debug("a pair's strip, \(pixels.size.width) x \(pixels.size.height): the engine's gates \(said, privacy: .public)")
                    if gates.count == 2 { onDelivery?(.gates(frame: r.frameID, rects: gates)) }
                }
                // Enable HDR's curve of the session that made this picture, before the picture (`Request.hdrCurve`).
                if let answer = pixels.hdrCurve { onDelivery?(.hdrCurve(frame: r.frameID, stamp: r.stamp, answer: answer)) }
                onDelivery?(.canvas(job: job.id, frame: r.frameID, image: image, stamp: r.stamp))
            case .keep:
                let picture = try Self.write(image, frameID: r.frameID, stamp: r.stamp)
                onDelivery?(.kept(job: job.id, frame: r.frameID, picture: picture))
            case .export(let order):
                // The frame's Enable HDR (`order.gainMap`): a gain map beside the unchanged picture, JPEG and HEIF
                // only, of the curve this render's own session gave (`pixels.hdrCurve`). A slide's map is the ratio
                // of its two renditions (`HDRGain`, made on the engine's queue); its session's curve stands in
                // where that rendition was not made. The map is never the export's failure: one that cannot be
                // made or written leaves today's file, and the log says why.
                let gainMap = order.gainMap ? exportMap(job, order, pixels, image: image, turns: r.turnsAfter) : nil
                let written: ExportWriter.Written
                do {
                    written = try ExportWriter.write(image, format: order.format, quality: order.quality, to: order.url,
                                                     metadataFrom: order.metadataFrom, gainMap: gainMap, layout: order.hdrLayout)
                } catch where gainMap != nil {
                    log.error("the file with its gain map was not written (\(String(describing: error), privacy: .public)); written again without it")
                    written = try ExportWriter.write(image, format: order.format, quality: order.quality, to: order.url,
                                                     metadataFrom: order.metadataFrom)
                }
                if gainMap != nil {
                    Log.note(.export, "written with a gain map", ["hdr": written.hdr ?? "dropped", "write_s": (written.seconds * 100).rounded() / 100,
                                                                  "phases": written.phases, "picture": "\(image.bitsPerComponent)/\(image.bitsPerPixel) bpc/bpp, info \(image.bitmapInfo.rawValue), \((image.colorSpace?.name as String?) ?? "?")"])
                }
                #if DEBUG
                if let gainMap, written.hdr != nil { HDRGainMap.exportWitness?(written.url, gainMap) }
                #endif
                let layered = order.layers.map { ", \($0.layers.count) finished-stage mask layer\($0.layers.count == 1 ? "" : "s")" } ?? ""
                let edited = (order.adjustments.map { $0.isActive ? ", edited after the print (" + $0.changedTools.map(\.rawValue).joined(separator: ", ") + ")" : "" } ?? "") + layered
                let hdr = written.hdr.map { ", HDR " + $0 } ?? ""
                log.info("exported \(order.url.lastPathComponent, privacy: .public): \(written.size.width) x \(written.size.height), \(order.format.rawValue, privacy: .public) \(order.format.bitDepth)-bit in \(order.colour.engineName, privacy: .public)\(edited, privacy: .public)\(hdr, privacy: .public), \(Double(written.bytes) / 1_048_576, format: .fixed(precision: 1)) MB, written in \(written.seconds, format: .fixed(precision: 2)) s")
                exported(job.id, .written(written))
            case .card:
                // Kept for the service to take when the job has ended (`takeCard`), as an export's file is.
                let made = try Self.card(image, size: StockPreviewSize.cover(PixelSize(width: image.width, height: image.height)))
                lock.lock(); cards[job.id] = made; lock.unlock()
            case .fullView:
                break                                        // kept above, before any picture is made
            case .alone:
                // One exposure alone, at the page's size: kept for the page to take (`EngineRouter.takeAlone`).
                lock.lock(); cards[job.id] = image; lock.unlock()
            }
        } catch {
            // Stopped by an edit (the zoom's write): nothing to say, the job ends as cancelled.
            if let e = error as? EngineError, e == .cancelled { return }
            let message: String
            if let e = error as? EngineError, case .failed(let m) = e { message = m }
            else if let e = error as? EngineError, case .resource(let m) = e { message = m }
            else { message = "\(error)" }
            log.error("the picture of \(job.kind.rawValue, privacy: .public) could not be made: \(message, privacy: .public)")
            if case .export = r.purpose {
                // The page's own words; the engine's and the encoder's are in the log.
                exported(job.id, .failed((error as? ExportWriter.Failure)?.text ?? "The picture could not be made into a file"))
            }
            onDelivery?(.failed(job: job.id, frame: r.frameID, message: message))
        }
    }

    // MARK: an export's gain map

    /// The map an export of a frame with Enable HDR on carries (`ExportOrder.gainMap`): a slide's ratio of two
    /// renditions where it was made, else the curve of this render's session over the finished picture. Nil, and
    /// said, where there is none to make; never a throw (the file is written either way).
    private func exportMap(_ job: RenderJob, _ order: ExportOrder, _ pixels: RenderedPixels, image: CGImage, turns: Int) -> HDRGainMap.Attachment? {
        let started = DispatchTime.now().uptimeNanoseconds
        let name = order.url.lastPathComponent
        var made: HDRGainMap.Attachment?, whose = ""
        switch takeSlideMap(job.id) {
        case .made(let rendition, let ratio)?:
            do {
                made = try Self.follow(ratio, turns: turns, crop: order.printCrop, picture: image)
                whose = "the slide's own HDR rendition at H " + String(format: "%.2f", rendition.headroom)
            } catch {
                log.error("\(name, privacy: .public): a slide's map could not follow its picture (\(String(describing: error), privacy: .public)); its curve stands in")
            }
        case .noGain?:
            log.info("\(name, privacy: .public): HDR on, no gain map: the slide has no pixel past a knee")
            return nil
        default: break
        }
        if made == nil {
            switch pixels.hdrCurve {
            case .curve(let curve)?:
                do {
                    made = try HDRGainMap.exportAttachment(for: image, format: order.format, curve: curve)
                    whose = curve.curve.name
                } catch {
                    log.error("\(name, privacy: .public): export gain map not made, the file is written without it: \(String(describing: error), privacy: .public)")
                }
            case .refused(let why)?:
                log.info("\(name, privacy: .public): HDR on, no gain map: the engine gave no curve (\(why, privacy: .public))")
            case nil:
                log.error("\(name, privacy: .public): HDR on, no gain map: the render carried no curve")
            }
        }
        if let made {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            log.info("\(name, privacy: .public): export gain map \(made.map.width) x \(made.map.height), headroom \(made.headroom, format: .fixed(precision: 2)), \(whose, privacy: .public), layout \(order.hdrLayout.rawValue, privacy: .public), made in \(ms, format: .fixed(precision: 0)) ms")
            Log.note(.export, "gain map", ["size": "\(made.map.width)x\(made.map.height)", "headroom": (made.headroom * 1000).rounded() / 1000,
                                          "of": whose, "layout": order.hdrLayout.rawValue, "ms": Int(ms),
                                          "strips": HDRRendition.lastTimes])
        }
        return made
    }

    /// A slide's ratio map, made at the render's size and orientation, turned and cut as its picture was.
    private static func follow(_ a: HDRGainMap.Attachment, turns: Int, crop: Geometry?, picture: CGImage) throws -> HDRGainMap.Attachment {
        var map = try HDRGain.turned(a.map, quarterTurns: turns)
        if let crop {
            guard let whole = HDRGain.image(of: map),
                  let cut = HDRGain.map(of: try FinishedCut.image(whole, by: crop.onFinished(CGSize(width: map.width, height: map.height)))) else {
                throw HDRGainMap.Failure.gpu("the map could not be cut as its picture was")
            }
            map = cut
        }
        guard map.width == picture.width, map.height == picture.height else {
            throw HDRGainMap.Failure.gpu("the map is \(map.width) x \(map.height), its picture \(picture.width) x \(picture.height)")
        }
        return HDRGainMap.Attachment(map: map, headroom: a.headroom)
    }

    // MARK: a card

    /// The live tier's 800 px made the card's size, in the same space and
    /// depth: a display's scaling of the render, as the page draws its own
    /// develop smaller than it is — the render itself is untouched. Any thread.
    static func card(_ image: CGImage, size: PixelSize) throws -> CGImage {
        guard size.width < image.width || size.height < image.height else { return image }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EngineError.resource("no room to make a card")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let made = context.makeImage() else { throw EngineError.failed("the card could not be made") }
        return made
    }

    // MARK: the host's turn

    /// The picture turned by whole quarter turns, clockwise. Its pixels are
    /// moved as they are (four channels, 16 bits each or 8); nothing is
    /// resampled and nothing goes through a colour space. Any thread.
    static func turned(_ image: CGImage, quarterTurns: Int) throws -> CGImage {
        let k = ((quarterTurns % 4) + 4) % 4
        guard k != 0 else { return image }
        let bits = image.bitsPerComponent
        guard bits == 16 || bits == 8, image.bitsPerPixel == bits * 4, let space = image.colorSpace,
              let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data) else {
            throw EngineError.failed("the film could not be turned: not the picture the output transform makes")
        }
        let w = image.width, h = image.height
        let ow = k % 2 == 0 ? w : h, oh = k % 2 == 0 ? h : w
        let rowBytes = ow * bits / 2
        guard let out = malloc(rowBytes * oh) else { throw EngineError.resource("no \((rowBytes * oh) >> 20) MB to turn the film in") }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(h),
                                   width: vImagePixelCount(w), rowBytes: image.bytesPerRow)
        var turned = vImage_Buffer(data: out, height: vImagePixelCount(oh), width: vImagePixelCount(ow), rowBytes: rowBytes)
        // vImage counts quarter turns anticlockwise.
        let rc = bits == 16
            ? vImageRotate90_ARGB16U(&source, &turned, UInt8((4 - k) % 4), [0, 0, 0, 0] as [UInt16], vImage_Flags(kvImageNoFlags))
            : vImageRotate90_ARGB8888(&source, &turned, UInt8((4 - k) % 4), [0, 0, 0, 0] as [UInt8], vImage_Flags(kvImageNoFlags))
        guard rc == kvImageNoError,
              let provider = CGDataProvider(dataInfo: nil, data: out, size: rowBytes * oh,
                                            releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else {
            free(out)
            throw EngineError.failed("the film could not be turned (\(rc))")
        }
        guard let made = CGImage(width: ow, height: oh, bitsPerComponent: bits, bitsPerPixel: bits * 4, bytesPerRow: rowBytes,
                                 space: space, bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                                 shouldInterpolate: true, intent: .defaultIntent) else {
            throw EngineError.failed("the turned film could not be made a picture")
        }
        return made
    }

    // MARK: keeping a develop

    /// A develop as a file beside the preview copies: HEIF where this system
    /// writes it, JPEG where it does not. The picture is Display P3 and its
    /// profile travels in the file. Any thread.
    ///
    /// Into the previews of the library the frame was carried from, while that
    /// library is there (`LibraryPreviews`, the Mac's catalogs and sessions,
    /// 2026-11-05); else, and wherever that write fails (a disk gone in the
    /// middle), the app's `Previews`, as before. The same pixels and the same
    /// stamp either way: where it lies is not part of the picture. Which
    /// folder, and making it, are `LibraryPreviews.write`'s (held to its rules
    /// by `tools/storage_selftest.swift`): a library's folder is never made
    /// where the library is not.
    static func write(_ image: CGImage, frameID: UUID, stamp: String) throws -> DevelopedPicture {
        let kept = LibraryPreviews.write(for: frameID, fallback: ImportService.previews) { folder -> DevelopedPicture? in
            for (type, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
                let url = ImportService.developedURL(frameID: frameID, stamp: stamp, fileExtension: ext, in: folder)
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    return DevelopedPicture(picture: .file(url), size: PixelSize(width: image.width, height: image.height), stamp: stamp)
                }
                try? FileManager.default.removeItem(at: url)
            }
            return nil
        }
        guard let kept else { throw EngineError.failed("the developed picture could not be written") }
        return kept
    }
}
#endif
