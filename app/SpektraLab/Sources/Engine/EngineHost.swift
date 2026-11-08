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
    enum Purpose: Sendable { case canvas, keep, export(ExportOrder), card(String), fullView(FullRender.Ask) }

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

        /// Whether the engine draws the film round the frame: the canvas is
        /// then the film, and a pair's frames are where its gates are.
        var wearsFilm: Bool { wire["overscan_active"] == .bool(true) }

        /// What the frame's pixels are made of, as a word: the file, how it is
        /// decoded and how the host cuts it. The decode's settings change a
        /// RAW's pixels and nothing else's (as in `DevelopStamp`).
        static func sourceKey(source: URL, isRAW: Bool, decode: DecodeSettings, longEdge: Int?, cut: Geometry?) -> String {
            [source.path, isRAW ? "raw " + decode.pixelsKey : "", longEdge.map { "\($0)" } ?? "whole", cut?.cutKey ?? ""]
                .joined(separator: "|")
        }
        /// The same pixels at any size: the file, its decode, the host's cut.
        static func pixelsKey(source: URL, isRAW: Bool, decode: DecodeSettings, cut: Geometry?) -> String {
            [source.path, isRAW ? "raw " + decode.pixelsKey : "", cut?.cutKey ?? ""].joined(separator: "|")
        }
        var pixelsKey: String { Self.pixelsKey(source: source, isRAW: isRAW, decode: decode, cut: cut) }
        var sourceKey: String {
            piece?.key ?? Self.sourceKey(source: source, isRAW: isRAW, decode: decode, longEdge: longEdge, cut: cut)
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
    }

    /// The job has ended, however: its answers are no longer needed.
    func forget(_ jobID: UUID) {
        lock.lock(); requests[jobID] = nil; lock.unlock()
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
            let stops = report.stops.sorted { $0.key < $1.key }
                .map { "\($0.key == 0 ? "first" : "second") \(String(format: "%+.2f", $0.value)) EV" }.joined(separator: ", ")
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
                                                               longEdge: r.longEdge, cut: r.cut, proxy: r.proxy))
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
                                                           cut: r.cut, proxy: r.proxy))
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
        guard let r = request(job.id), case .export = r.purpose, let ask = r.fullRender,
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
        let pixels = try DigitalDecode.render(r.source, isRAW: r.isRAW, decode: r.decode, geometry: geometry,
                                              canvas: job.canvas, device: device)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        log.info("Apple's decode of \(r.source.lastPathComponent, privacy: .public), no film: \(pixels.size.width) x \(pixels.size.height) in \(ms, format: .fixed(precision: 0)) ms")
        return pixels
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

    func printLayers(_ job: RenderJob) -> [[String: ParamValue]] {
        request(job.id)?.layers.map(\.rows) ?? []
    }

    /// A pair on its strip: for the page's canvas, which is told where the two
    /// frames are, and for any job with a frame's own print to cut in there.
    func wantsFilmGeometry(_ job: RenderJob) -> Bool {
        guard let r = request(job.id), r.piece != nil, r.wearsFilm else { return false }
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
            if case .export(let order) = r.purpose, let edit = order.adjustments, edit.isActive {
                if layer2 == nil { layer2 = try Layer2Export(device: device) }
                guard let layer2 else { throw EngineError.failed("Layer 2's export pass could not be made") }
                made = try layer2.image(pixels, to: target, depth: depth, adjustments: edit, fetch: fetch)
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
                if r.piece != nil, r.wearsFilm, let said = pixels.filmGeometry {
                    let gates = FilmGates.rects(said)
                    log.debug("a pair's strip, \(pixels.size.width) x \(pixels.size.height): the engine's gates \(said, privacy: .public)")
                    if gates.count == 2 { onDelivery?(.gates(frame: r.frameID, rects: gates)) }
                }
                onDelivery?(.canvas(job: job.id, frame: r.frameID, image: image, stamp: r.stamp))
            case .keep:
                let picture = try Self.write(image, frameID: r.frameID, stamp: r.stamp)
                onDelivery?(.kept(job: job.id, frame: r.frameID, picture: picture))
            case .export(let order):
                let written = try ExportWriter.write(image, format: order.format, quality: order.quality, to: order.url,
                                                     metadataFrom: order.metadataFrom)
                let edited = order.adjustments.map { $0.isActive ? ", edited after the print (" + $0.changedTools.map(\.rawValue).joined(separator: ", ") + ")" : "" } ?? ""
                log.info("exported \(order.url.lastPathComponent, privacy: .public): \(written.size.width) x \(written.size.height), \(order.format.rawValue, privacy: .public) \(order.format.bitDepth)-bit in \(order.colour.engineName, privacy: .public)\(edited, privacy: .public), \(Double(written.bytes) / 1_048_576, format: .fixed(precision: 1)) MB, written in \(written.seconds, format: .fixed(precision: 2)) s")
                exported(job.id, .written(written))
            case .card:
                // Kept for the service to take when the job has ended (`takeCard`), as an export's file is.
                let made = try Self.card(image, size: StockPreviewSize.cover(PixelSize(width: image.width, height: image.height)))
                lock.lock(); cards[job.id] = made; lock.unlock()
            case .fullView:
                break                                        // kept above, before any picture is made
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
