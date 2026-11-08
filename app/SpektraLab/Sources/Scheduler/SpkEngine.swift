//  SpkEngine.swift — the engine itself behind the scheduler: `DevelopEngine` over the C ABI.
//
//  The app links this implementation under SPK_ENGINE through its bridging header.
//  The linked library and resources are built by tools/build_engine_mac.sh.
//
//  What it holds to, each from a measurement:
//
//  - **The frame is opened without a CPU copy** (the handoff of 2026-10-03,
//    W1). The engine is created on the host's own `MTLDevice`, the host
//    decodes into a shared buffer of that device, and `spk_open_device`
//    borrows it for the call. `spk_open` with a host pointer copies the whole
//    frame (744 MiB at 48 MP) and leaves the copy in the pool.
//  - **The decode's buffer is gone before the render starts.** It is released
//    with the autorelease pool the open runs in, so the job's two peaks — the
//    decode beside the source plane, then the render — do not add up.
//  - **One autorelease pool per job.** The bench leaked 72 → 646 MB over four
//    photos without one (RFC-035 §11).
//  - **A parameter change is sent as its difference.** `spk_set_params` drops
//    the cached negative when the delta *names* a film-side field, whether or
//    not its value changed, and rebuilds the pipeline when it names a stock.
//    So the session remembers what it was last handed and sends only what
//    moved: a print-side edit stays a reprint.
//  - **Nothing is read from a render in flight.** `spk_progress` copies a
//    string the render thread is assigning; it is read after the render, for
//    the bands the engine cut. `spk_cancel` only sets a flag, and is safe.
//  - **A cancel that arrives before the render begins is not lost.** The
//    engine clears its flag when a render starts, so the flag is kept here
//    too and handed over again every few milliseconds until the render ends.
//  - **A job that keeps no session has given the engine's memory back before
//    its result is delivered.** The result is a texture of its own, never a
//    pooled one, so its session — the source plane, 12 B a pixel — and the
//    pool's idle planes are released first, and the host's side of the job
//    (the output transform, the encoder: another 4 to 8 B a pixel beside the
//    result's 8) starts from what the render left, not on top of it. Without
//    that an export's delivery was the render's planes and the file's
//    together.
//  - **A print of a frame's own is a print more of the same negative.** After
//    a job's own render the host is asked for its layers
//    (`FrameSource.printLayers`: a half-frame pair's frames that print as
//    their own). For each the session is set that print's rows — the
//    enlarger's live rows only, which rebuild nothing and leave the negative
//    — and printed again, and the host cuts the print into the job's result.
//    One layer's print is alive at a time beside the result, and the rows the
//    session had are put back however the job ends, so what an editing
//    session was last told stays true of it. A banded render keeps no
//    negative: there a layer develops again, with the same grain (RFC-035 §9).
//
//  The mode is the scheduler's (`RenderMode`); what the engine actually cut is
//  reported back (`RenderResult.bands`), because the engine decides the height
//  from a byte budget and its own reach (`BandGeometry`), and renders whole
//  whatever was asked when it cannot band a job.

#if SPK_ENGINE
import Foundation
import Metal

/// A frame's pixels, decoded for the engine: tightly packed float32, top row
/// first, in a shared buffer **on the engine's own device** — a buffer from
/// another device is refused.
struct DecodedFrame {
    let buffer: MTLBuffer
    let size: PixelSize
    /// 3 or 4. A fourth channel is dropped at the door.
    let channels: Int
    /// How the pixels were made, for the job's record: "ImageIO", "Core
    /// Image", "RAW 9 dng" (`DecodeReport.how`, `EngineHost.recorded`).
    var how: String? = nil
}

/// A finished render. The texture is the host's to keep (the engine hands over
/// its only reference); `rgba16` lives as long as it does.
///
/// **On a device and a Mac `rgba16` is the texture's own memory**: a linear
/// texture over the result's shared buffer (`texture.buffer`). **In the the operating system
/// simulator it is not** — its Metal makes no such texture, so the engine
/// fills one of its own from the buffer (`engine/src/gpu/metal_gpu.cpp`,
/// `texture`) and `rgba16` is the buffer it was filled from. A host that only
/// reads may read either. One that writes to `rgba16` has to make it true of
/// the texture where the two are apart (`EngineHost.carry`).
struct RenderedPixels {
    let texture: MTLTexture
    let rgba16: UnsafePointer<UInt16>
    let size: PixelSize
    /// The row pitch of `rgba16` in pixels: the width rounded up to the
    /// device's linear-texture alignment.
    let rowStridePixels: Int
    /// Where the film's gates are on this canvas, in the engine's own words
    /// (`spk_overscan_geometry`'s JSON, as it came: one gate, or two for a
    /// pair, each its four corners normalised to the canvas). Only for a job
    /// whose host asked (`FrameSource.wantsFilmGeometry`); nil otherwise.
    var filmGeometry: String? = nil
    /// What keeps `rgba16` alive where the texture does not: a result read
    /// back from disk (`FullRender.load`) whose texture is a copy of it.
    var keep: AnyObject? = nil
}

/// What the engine asks its host for. Every call arrives on the engine's own
/// queue, inside the job's autorelease pool.
protocol FrameSource: AnyObject {
    /// The frame's pixels at the size this job renders from: the engine never
    /// enlarges, so a tier is rendered at its own long edge or the frame's,
    /// whichever is smaller. For a full-tier job that `decodesOriginal` this is
    /// the original at full size. For one below the full tier (a shot or an
    /// import, developed at preview size) it is the original **decoded no
    /// larger than the job's canvas**: opened whole, a 48 MP photo's decode is
    /// 1.05-1.13 GB and its source plane 558 MiB whatever size is rendered
    /// from it, and the cost model prices the render by the canvas and the
    /// small decode by the original (`RenderJob.original`). A job handed more
    /// than its canvas says so in its record, and is not learned from.
    func decode(_ job: RenderJob, device: MTLDevice) throws -> DecodedFrame
    /// The frame's settings in wire names, complete — what `spk_open` is
    /// handed. The engine is sent only what changed since.
    func params(_ job: RenderJob) -> [String: ParamValue]
    /// The result: draw it, encode it, save it. Counted in the job's peak,
    /// not in its time.
    func deliver(_ job: RenderJob, _ pixels: RenderedPixels)
    /// What `decode` would hand over for this job, as a word: the file, how
    /// it is decoded, how the host cuts it. The engine keeps the source a
    /// session was opened with and nothing on the wire changes it, so a
    /// canvas job whose word is not its open session's is opened again.
    func sourceKey(_ job: RenderJob) -> String
    /// The prints of this job's negative that are made after its own and cut
    /// into it: for each, that print's rows in wire names. Only the
    /// enlarger's live rows (`FilmParams.liveMutable`) — they leave the
    /// negative as it is, so each is a reprint — and only rows `params(job)`
    /// carries, which is what the session is put back to. A half-frame pair's
    /// frames that print as their own; none for anything else.
    func printLayers(_ job: RenderJob) -> [[String: ParamValue]]
    /// One of those prints has been made: cut it into `base`, which is the
    /// job's own result and is what `deliver` is handed afterwards. `index`
    /// counts `printLayers(job)`. The two are the same size; `layer` lives
    /// until this returns, so that one is alive at a time beside the result.
    func cut(_ job: RenderJob, layer index: Int, _ layer: RenderedPixels, into base: RenderedPixels) throws
    /// Whether the host wants to be told where the film's gates are on this
    /// job's canvas (`RenderedPixels.filmGeometry`): a pair on its strip,
    /// whose frames are where the engine put them and nowhere the host knows.
    func wantsFilmGeometry(_ job: RenderJob) -> Bool
    /// The job's result already made and kept (`FullRender`): an export whose
    /// render is on disk. Handed to `deliver` in place of a render — nothing
    /// is opened, and the engine is not asked. Nil: render as ever.
    func cached(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels?
    /// A frame with Apply Film Emulation off (`DigitalDecode`): Apple's decode, cut, in the result's
    /// encoding. Handed to `deliver` in place of a render — no session, no film. Nil: render as ever.
    func digital(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels?
}

extension FrameSource {
    /// One source a frame, for a host whose decode never changes.
    func sourceKey(_ job: RenderJob) -> String { "" }
    /// One print a job, for a host with no pair to print.
    func printLayers(_ job: RenderJob) -> [[String: ParamValue]] { [] }
    func cut(_ job: RenderJob, layer index: Int, _ layer: RenderedPixels, into base: RenderedPixels) throws {}
    func wantsFilmGeometry(_ job: RenderJob) -> Bool { false }
    func cached(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels? { nil }
    func digital(_ job: RenderJob, device: MTLDevice) throws -> RenderedPixels? { nil }
}

final class SpkEngine: DevelopEngine, @unchecked Sendable {
    let name: String
    let effectVersions: String
    let device: MTLDevice

    private let engine: OpaquePointer
    private let source: any FrameSource
    /// Every call that renders. The engine is not re-entrant per session, and
    /// one job at a time is the scheduler's rule anyway.
    private let work = DispatchQueue(label: "com.spektralab.engine", qos: .userInitiated)

    private let lock = NSLock()
    private var cancelled = Set<UUID>()
    private var cancelAsked: [UUID: UInt64] = [:]
    private var inFlight: (job: UUID, session: OpaquePointer)?
    private var latencies: [Double] = []
    /// When the last job returned, for `RunMeasurement.fromRest`. Touched on `work`.
    private var lastEnded: UInt64 = 0
    /// For measuring what a shot's session costs when it is left open: with
    /// this set, every job below the full tier keeps its session, as a canvas
    /// job does (and as every such job did before 2026-10-03).
    var keepsEverySession = false

    /// The frame being edited: its session stays open between canvas jobs, so
    /// a print-side edit reprints from the cached negative. Touched on `work`.
    private struct Editing {
        let frame: UUID
        let session: OpaquePointer
        /// What its source was made of (`FrameSource.sourceKey`).
        let source: String
        var applied: [String: ParamValue]
    }
    private var editing: Editing?
    /// The Digital Intermediate's view (`CineonView`), made the first time a DI is rendered. Touched on `work`.
    private var cineonView: CineonView?

    /// `resources` holds the baked constants, the profiles and the metallib
    /// built **with safe math** (`tools/build_engine_mac.sh`). The engine is
    /// made on the host's own device, so the frames the host decodes into that
    /// device's buffers are the engine's to read (`spk_open_device`).
    /// Whether the engine renders this wire as a Digital Intermediate: the switch on, no film scan
    /// in front of it, a negative film (`Pipeline::di_active_`, `FilmParams.digitalIntermediateActive`).
    static func wantsCineonView(_ wire: [String: ParamValue], _ catalog: StockCatalog = .shared) -> Bool {
        guard wire["digital_intermediate"] == .bool(true), wire["scan_film"] != .bool(true) else { return false }
        if case .string(let film)? = wire["film_stock"] { return !catalog.isSlide(film) }
        return false
    }

    init(resources: String, device: MTLDevice, source: any FrameSource) throws {
        guard let engine = spk_engine_create(resources, Unmanaged.passUnretained(device as AnyObject).toOpaque()) else {
            throw EngineError.failed("engine: " + String(cString: spk_last_error(nil)))
        }
        self.engine = engine
        self.device = device
        self.source = source
        name = String(cString: spk_build_info())
        let caps = Self.object(String(cString: spk_capabilities(engine)))
        effectVersions = ((caps["backend"] as? [String: Any])?["effect_versions"] as? String) ?? "?"
    }

    deinit {
        if let e = editing { spk_session_release(e.session) }
        spk_engine_destroy(engine)
    }

    // MARK: - DevelopEngine

    func run(_ job: RenderJob, mode: RenderMode,
             progress: @escaping @Sendable (RenderProgress) -> Void) async throws -> RenderResult {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<RenderResult, Error>) in
            work.async {
                done.resume(with: Result { try autoreleasepool { try self.render(job, mode, progress) } })
            }
        }
    }

    /// Whether `cancel` has reached the job: for a host's own long work inside `deliver` (the zoom's
    /// full render written to disk, `FullRender.write`). Any thread.
    func isCancelled(_ jobID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(jobID)
    }

    func cancel(_ jobID: UUID) {
        lock.lock(); defer { lock.unlock() }
        cancelled.insert(jobID)
        if cancelAsked[jobID] == nil { cancelAsked[jobID] = DispatchTime.now().uptimeNanoseconds }
        if let f = inFlight, f.job == jobID { spk_cancel(f.session, nil) }
    }

    /// The engine trims its own pool: at the next open once no session is left
    /// or the frame's size changes (`spk_open`), and after an idle spell
    /// (`metal_gpu.cpp`), so it has no call for "now". Returns 0: nothing was
    /// freed by this call.
    @discardableResult func trim() async -> UInt64 { 0 }

    func heldBytes() async -> UInt64 { memory().held }

    // MARK: - beside the protocol

    /// Pay a stock pair's fixed setup before the first frame waits on it.
    func warmUp(film: String, paper: String) async -> Double {
        await withCheckedContinuation { (done: CheckedContinuation<Double, Never>) in
            work.async {
                let t = Self.now()
                var reply: UnsafeMutablePointer<CChar>?
                _ = spk_warm_up(self.engine, film, paper, &reply)
                if let reply { spk_string_free(reply) }
                done.resume(returning: Self.since(t))
            }
        }
    }

    /// The frame's page closed, or the frame was deleted: its session, with
    /// its source and cached negatives, is given back.
    func closeEditing(frameID: UUID? = nil) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            work.async {
                if let e = self.editing, frameID == nil || e.frame == frameID {
                    spk_session_release(e.session)
                    self.editing = nil
                }
                done.resume()
            }
        }
    }

    /// A job someone waits on cannot fit (`RenderQueue.reclaim`): the editing session goes —
    /// its source plane and negative, 155-369 MB on the reference device — unless it is `keeping`'s, then
    /// the pool. The next canvas job of that frame opens it again (its film side again: 0.2-0.6 s).
    @discardableResult func reclaim(keeping frameID: UUID?) async -> UInt64 {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            work.async {
                if let e = self.editing, e.frame != frameID {
                    spk_session_release(e.session)
                    self.editing = nil
                }
                done.resume()
            }
        }
        return await trim()
    }

    /// RFC-023's Scene Latitude on the frame being edited (`spk_scene_latitude`,
    /// API-SPEC §12): the medium's two boundaries, the frame's histogram on the
    /// stop axis, a suggestion and the fit of the pull-backs asked for. It
    /// measures and solves and **never renders**; the reply is the engine's
    /// JSON as it came. `request` is the JSON the call takes, nil for the
    /// engine's own suggestion.
    ///
    /// On the session the canvas keeps open, and on the engine's queue, so it
    /// never runs beside a render: asked while a job is in flight, it waits
    /// its turn. The medium is cached in the session on the fields it reads
    /// and the scene on the meter's (0.2 ms a call once both are, on the Mac);
    /// a first call, or one after a stock, filter or exposure change, probes
    /// a 1,024-sample ramp through the film and the print (48 ms on the Mac;
    /// **not measured on a host**).
    ///
    /// Throws `EngineError.cancelled` when no session is open on that frame —
    /// its page has closed, or nothing of it has been developed yet — and
    /// `.failed` with the engine's words when the engine refuses.
    func sceneLatitude(frameID: UUID, request: String?) async throws -> String {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
            work.async {
                done.resume(with: Result {
                    try autoreleasepool {
                        guard let e = self.editing, e.frame == frameID else { throw EngineError.cancelled }
                        var reply: UnsafeMutablePointer<CChar>?
                        let rc = spk_scene_latitude(e.session, request, &reply)
                        defer { if let reply { spk_string_free(reply) } }
                        guard Int(rc) == Int(SPK_OK), let reply else {
                            throw EngineError.failed(String(cString: spk_last_error(self.engine)))
                        }
                        return String(cString: reply)
                    }
                })
            }
        }
    }

    /// The engine's own account: everything it holds, and the part of its
    /// pool that is free or waiting on a command buffer.
    func memory() -> (held: UInt64, idlePool: UInt64, poolHighWater: UInt64) {
        let report = Self.object(String(cString: spk_memory_report(engine)))
        let pool = report["pool"] as? [String: Any] ?? [:]
        func bytes(_ v: Any?) -> UInt64 { UInt64(max(0, (v as? NSNumber)?.doubleValue ?? 0)) }
        return (bytes(report["total_bytes"]), bytes(pool["free_bytes"]) + bytes(pool["pending_bytes"]),
                bytes(pool["frame_high_water_bytes"]))
    }

    /// The numbers for leaving the working space (`spk_output_transform`,
    /// RFC-018 §5.2): a fetch, not a render. The transform itself runs in the
    /// host's own kernel; every number in it is the engine's.
    struct OutputTransformData {
        /// Source linear RGB → target linear RGB, row-major.
        var matrix: [Float]
        /// The transfer functions, as the engine's kernels number them.
        var sourceCctfMode: UInt32
        var targetCctfMode: UInt32
        /// CAM16-UCS into the target: its RGB↔XYZ pair, the 22 scalars, the
        /// C_max table (rows × columns), and the two gates.
        var toXYZ: [Float]
        var toRGB: [Float]
        var k: [Float]
        var compresses: Bool
        var compressesLightness: Bool
        var cmaxRows: Int
        var cmaxColumns: Int
        var cmax: [Float]
    }

    /// **For a `FrameSource`, inside its own callbacks** — they run on the
    /// engine's queue already, and this does not leave it. `gamutCompress` is
    /// the JSON `spk_output_transform` takes, nil for the session's default.
    /// An unknown space throws, and never falls back: that is how a picture
    /// ends up in a space nobody asked for.
    func outputTransformOnQueue(from source: String, to target: String, gamutCompress: String?) throws -> OutputTransformData {
        var reply: UnsafeMutablePointer<CChar>?
        var table: UnsafePointer<Float>?
        var count: UInt32 = 0
        let rc = spk_output_transform(engine, source, target, gamutCompress, &reply, &table, &count)
        defer { if let reply { spk_string_free(reply) } }
        guard Int(rc) == Int(SPK_OK), let reply, let table else {
            throw EngineError.failed(String(cString: spk_last_error(engine)))
        }
        let json = Self.object(String(cString: reply))
        let compress = json["gamut_compress"] as? [String: Any] ?? [:]
        func floats(_ v: Any?, _ n: Int) throws -> [Float] {
            guard let a = v as? [NSNumber], a.count == n else { throw EngineError.failed("the output transform's reply did not parse") }
            return a.map(\.floatValue)
        }
        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let rows = int(compress["cmax_rows"]), columns = int(compress["cmax_cols"])
        guard rows > 0, columns > 0, rows * columns == Int(count) else {
            throw EngineError.failed("the output transform's table is \(count) values, not \(rows) x \(columns)")
        }
        return OutputTransformData(
            matrix: try floats(json["matrix"], 9),
            sourceCctfMode: UInt32(int(json["source_cctf_mode"])), targetCctfMode: UInt32(int(json["target_cctf_mode"])),
            toXYZ: try floats(compress["m_to_xyz"], 9), toRGB: try floats(compress["m_to_rgb"], 9),
            k: try floats(compress["k"], 22),
            compresses: (compress["algorithm"] as? String) != "off",
            compressesLightness: (compress["lightness_compression_active"] as? Bool) ?? false,
            cmaxRows: rows, cmaxColumns: columns,
            // The engine owns the table for its lifetime; a copy is the host's to put on its device.
            cmax: Array(UnsafeBufferPointer(start: table, count: Int(count))))
    }

    /// **For a `FrameSource`, inside its own callbacks**, as
    /// `outputTransformOnQueue` is. What this engine's meter chooses for
    /// `frame` alone, in stops (`spk_solve`, target `exposure`): the number
    /// every tier's auto-exposure node would apply to it. It measures and
    /// never renders. The frame is opened in a session of its own, which is
    /// gone when this returns — the session a page keeps open is not touched,
    /// and neither is its cached negative.
    ///
    /// For a half-frame pair: each of its pictures is metered alone, as it
    /// would be by itself, and the piece is developed with the meter off
    /// (`PieceAsk.Exposure`). The host hands the picture small (1,024 px at
    /// most), so the session is a few megabytes for a few milliseconds.
    func meterOnQueue(_ frame: DecodedFrame, wire: [String: ParamValue]) throws -> Double {
        let json = try Self.json(wire)
        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer as AnyObject).toOpaque(),
                                     width: UInt32(frame.size.width), height: UInt32(frame.size.height),
                                     channels: UInt32(frame.channels))
        var opened: UnsafeMutablePointer<CChar>?
        let session = spk_open_device(engine, &image, json, &opened)
        if let opened { spk_string_free(opened) }
        guard let session else { throw EngineError.failed(String(cString: spk_last_error(engine))) }
        defer { spk_session_release(session) }
        var reply: UnsafeMutablePointer<CChar>?
        let rc = spk_solve(session, "exposure", &reply)
        defer { if let reply { spk_string_free(reply) } }
        guard Int(rc) == Int(SPK_OK), let reply else { throw EngineError.failed(String(cString: spk_last_error(engine))) }
        let solved = Self.object(String(cString: reply))["solved_params"] as? [String: Any]
        guard let ev = (solved?["exposure_compensation_ev"] as? NSNumber)?.doubleValue, ev.isFinite else {
            throw EngineError.failed("the meter's reply did not parse")
        }
        return ev
    }

    /// The parameters this engine knows, each with its range where it has one,
    /// from the engine's own schema (`spk_params_schema`). A host holds its
    /// wire against these before it opens a frame: an unknown name, or a value
    /// out of range, fails the whole call.
    func schema() async -> [String: ClosedRange<Double>?] {
        await withCheckedContinuation { (done: CheckedContinuation<[String: ClosedRange<Double>?], Never>) in
            work.async {
                let schema = Self.object(String(cString: spk_params_schema(self.engine)))
                var fields: [String: ClosedRange<Double>?] = [:]
                for case let f as [String: Any] in schema["fields"] as? [Any] ?? [] {
                    guard let name = f["name"] as? String else { continue }
                    if let r = f["range"] as? [NSNumber], r.count == 2, r[0].doubleValue <= r[1].doubleValue {
                        fields[name] = .some(r[0].doubleValue...r[1].doubleValue)
                    } else {
                        fields[name] = .some(nil)
                    }
                }
                done.resume(returning: fields)
            }
        }
    }

    /// Seconds from each `cancel` to its render's return, since the last call.
    func takeCancelLatencies() -> [Double] {
        lock.lock(); defer { lock.unlock() }
        defer { latencies = [] }
        return latencies
    }

    // MARK: - one job, on `work`

    private func render(_ job: RenderJob, _ mode: RenderMode,
                        _ progress: @escaping @Sendable (RenderProgress) -> Void) throws -> RenderResult {
        var bandCount = 1
        switch mode {
        case .wait:
            throw EngineError.failed("a job that waits is not handed to the engine")
        case .whole:
            break
        case .bands(let rows):
            // The engine renders a frame whole; the count is the progress the
            // scheduler planned, and nothing in the picture depends on it.
            bandCount = BandGeometry(canvas: job.canvas).bandCount(rows: rows)
        }
        defer { forget(job.id) }
        try throwIfCancelled(job.id)
        if let kept = try deliverKept(job, progress) { return kept }
        if let made = try deliverDigital(job, bandCount: bandCount, progress) { return made }

        let started = Self.now()
        let idleBefore = memory().idlePool
        // From rest: nothing in the pool to reuse, and the footprint of the job
        // before this one has had its two seconds to come back.
        let fromRest = idleBefore < (16 << 20) && (lastEnded == 0 || started - lastEnded >= 2_000_000_000)
        defer { lastEnded = Self.now() }
        let footprintBefore = MemoryProbe.footprint()
        let watch = RunWatch { [weak self] in self?.cancelAgain(job.id) }
        defer { watch.cancel() }

        // The session: the open one for a canvas job on the same frame, a new
        // one otherwise. Only the canvas keeps a session: it is the frame on
        // the develop page, and its next edit reprints from the negative. Any
        // other job's session is its own and goes when the job ends — an
        // export's, and a shot's or an import's at preview size, which nobody
        // is editing and which would otherwise sit beside the camera with its
        // source and its negative until the next frame arrived.
        let oneShot = job.tier == .full || (!job.kind.isCanvas && !keepsEverySession)
        var decodeSeconds = 0.0, openSeconds = 0.0
        var openPeak = footprintBefore
        var openedSize: PixelSize?
        var decodedBy: String?
        var fresh = false
        let session: OpaquePointer
        // The open session only while its source is still this job's: another
        // white balance of a RAW, or another cut of the picture for a film
        // edge, is other pixels, and the frame is opened again for them.
        let sourceKey = source.sourceKey(job)
        if !oneShot, var e = editing, e.frame == job.frameID, e.source == sourceKey {
            session = e.session
            let now = source.params(job)
            // Only what changed — and what a stock change handed back to the
            // engine is forgotten, so that it is sent when it returns
            // (`FilmParams.step`: a silver pair's filter pack).
            var applied = e.applied
            let delta = FilmParams.step(from: &applied, to: now)
            if !delta.isEmpty {
                try setParams(session, delta)
                e.applied = applied
                editing = e
            }
        } else {
            if !oneShot, let old = editing {
                // Another frame's page, or this one's from other pixels: its
                // source and negatives go before this one's decode, not after.
                spk_session_release(old.session)
                editing = nil
            }
            progress(RenderProgress(stage: .decode, fraction: 0, band: 0, bandCount: bandCount))
            let opened = try open(job)
            session = opened.session
            decodeSeconds = opened.decode
            openSeconds = opened.open
            openedSize = opened.size
            decodedBy = opened.how
            openPeak = max(watch.peakSoFar(), MemoryProbe.footprint())
            fresh = true
            if !oneShot { editing = Editing(frame: job.frameID, session: session, source: sourceKey, applied: opened.params) }
        }
        // A one-shot job's session goes when the job does, however it ends.
        var releaseAtExit = oneShot
        defer {
            if releaseAtExit {
                // Cancellation/failure takes this exit too. The session's
                // buffers go back to the pool, which the engine trims itself.
                spk_session_release(session)
            }
        }

        try throwIfCancelled(job.id)
        setInFlight(job.id, session)
        progress(RenderProgress(stage: job.isReprint ? .print : .film, fraction: fresh ? 0.15 : 0.05,
                                band: 0, bandCount: bandCount))
        var out = spk_result()
        let renderStarted = Self.now()
        // A reprint reuses the cached negative, and develops if there is none;
        // anything else is the film side again.
        let rc = job.isReprint && !fresh ? spk_reprint(session, job.tier.rawValue, &out)
                                         : spk_render(session, job.tier.rawValue, &out)
        let renderSeconds = Self.since(renderStarted)
        setInFlight(nil, nil)
        if Int(rc) == Int(SPK_ERR_CANCELLED) { throw EngineError.cancelled }
        guard Int(rc) == Int(SPK_OK), let texturePointer = out.texture, let rgba16 = out.rgba16 else {
            let message = String(cString: spk_last_error(engine))
            throw Int(rc) == Int(SPK_ERR_RESOURCE) ? EngineError.resource(message) : EngineError.failed(message)
        }
        // +1 from the engine: ARC owns it from here, so no `spk_result_free`.
        let texture = Unmanaged<AnyObject>.fromOpaque(texturePointer).takeRetainedValue() as! MTLTexture
        var seconds = Self.since(started)

        // Nothing is in flight now, so the engine's account of the render can be read.
        let (bands, nodes, meterEV) = account(session)
        let size = PixelSize(width: Int(out.width), height: Int(out.height))
        var highWater = memory().poolHighWater
        var pixels = RenderedPixels(texture: texture, rgba16: rgba16, size: size, rowStridePixels: Int(out.row_stride_px))
        // Where the film's gates are on this canvas, asked while the session that laid it out is still here.
        if source.wantsFilmGeometry(job) { pixels.filmGeometry = filmGeometry(session) }
        // A half-frame pair's frames that print as their own: a print more of this negative
        // for each, cut into the result. Before a one-shot session goes — they are its prints.
        let layers = source.printLayers(job)
        var layerSeconds: [Double] = []
        if !layers.isEmpty {
            layerSeconds = try printLayers(job, session, layers, into: pixels, bandCount: bandCount, progress)
            seconds += layerSeconds.reduce(0, +)
            highWater = max(highWater, memory().poolHighWater)
        }
        if oneShot {
            // Before the delivery, not after it: the result is the host's own
            // texture, and what the host makes of it is made beside it alone.
            spk_session_release(session)
            releaseAtExit = false
        }
        progress(RenderProgress(stage: job.decodesOriginal ? .save : .scan, fraction: 0.97,
                                band: bandCount - 1, bandCount: bandCount))
        // A Digital Intermediate is Cineon log: read through the DI view into the working space
        // before anything of the host's sees it (`CineonView`).
        if Self.wantsCineonView(source.params(job)) {
            if cineonView == nil { cineonView = try CineonView(device: device) }
            if let view = cineonView { pixels = try view.decode(pixels) }
        }
        let deliverStarted = Self.now()
        source.deliver(job, pixels)
        let deliverSeconds = Self.since(deliverStarted)
        // The zoom's render stopped while it was being written (an edit): it ends as cancelled, not done.
        if job.kind == .fullView { try throwIfCancelled(job.id) }

        let seen = watch.stop()
        let held = memory().held
        // The job's peak is its footprint's growth, and only from rest: a pool
        // left idle is reused (and hands a small job its largest buffers, so
        // the pool's own high-water mark says nothing about what was needed),
        // and a footprint still falling hides the growth altogether.
        let growth = seen.peak > footprintBefore ? seen.peak - footprintBefore : 0
        let peak = fromRest ? growth : 0
        let measured = RunMeasurement(
            footprintBefore: footprintBefore, peakFootprint: seen.peak, openPeakFootprint: openPeak,
            idlePoolBefore: idleBefore,
            poolHighWater: highWater, fromRest: fromRest, engineHeldAfter: held,
            decodeSeconds: decodeSeconds, openSeconds: openSeconds, renderSeconds: renderSeconds,
            deliverSeconds: deliverSeconds, phoneHeadroomBefore: seen.firstHeadroom,
            lowestPhoneHeadroom: seen.lowestHeadroom,
            lowestPhoneFree: seen.lowestFree, highestWired: seen.highestWired,
            lowestAppAvailable: seen.lowestAvailable, nodeMilliseconds: nodes.isEmpty ? nil : nodes,
            autoExposureEV: meterEV, opened: openedSize, layerSeconds: layerSeconds.isEmpty ? nil : layerSeconds,
            decodedBy: decodedBy)
        return RenderResult(seconds: seconds, peakBytes: peak, reprint: out.reprint == 1, size: size,
                            bands: bands, measured: measured)
    }

    /// A job whose result the host already has (`FrameSource.cached`): read,
    /// delivered, and recorded as that — no time and no peak for the cost
    /// model to learn an export's price from.
    private func deliverKept(_ job: RenderJob, _ progress: @escaping @Sendable (RenderProgress) -> Void) throws -> RenderResult? {
        let started = Self.now()
        let footprintBefore = MemoryProbe.footprint()
        guard let pixels = try source.cached(job, device: device) else { return nil }
        let readSeconds = Self.since(started)
        try throwIfCancelled(job.id)
        progress(RenderProgress(stage: .save, fraction: 0.97, band: 0, bandCount: 1))
        let deliverStarted = Self.now()
        source.deliver(job, pixels)
        let deliverSeconds = Self.since(deliverStarted)
        let peak = MemoryProbe.footprint()
        let measured = RunMeasurement(
            footprintBefore: footprintBefore, peakFootprint: max(peak, footprintBefore), openPeakFootprint: footprintBefore,
            idlePoolBefore: 0, poolHighWater: 0, fromRest: false, engineHeldAfter: memory().held,
            decodeSeconds: readSeconds, openSeconds: 0, renderSeconds: 0, deliverSeconds: deliverSeconds,
            phoneHeadroomBefore: 0, lowestPhoneHeadroom: 0, lowestPhoneFree: 0, highestWired: 0, lowestAppAvailable: 0,
            nodeMilliseconds: nil, autoExposureEV: nil, opened: pixels.size, layerSeconds: nil,
            decodedBy: "the full render kept on disk")
        return RenderResult(seconds: 0, peakBytes: 0, reprint: false, size: pixels.size, bands: nil, measured: measured)
    }

    /// A frame with Apply Film Emulation off (`FrameSource.digital`): Apple's decode, delivered as a
    /// render is, the engine not asked. Its peak is measured and given to nobody to learn from — a film
    /// job's price is not this (no peak, as `deliverKept`).
    private func deliverDigital(_ job: RenderJob, bandCount: Int, _ progress: @escaping @Sendable (RenderProgress) -> Void) throws -> RenderResult? {
        let started = Self.now()
        let footprintBefore = MemoryProbe.footprint()
        progress(RenderProgress(stage: .decode, fraction: 0, band: 0, bandCount: 1))
        guard let pixels = try source.digital(job, device: device) else { return nil }
        let decodeSeconds = Self.since(started)
        try throwIfCancelled(job.id)
        progress(RenderProgress(stage: .save, fraction: 0.97, band: 0, bandCount: 1))
        let deliverStarted = Self.now()
        source.deliver(job, pixels)
        let deliverSeconds = Self.since(deliverStarted)
        let peak = MemoryProbe.footprint()
        let measured = RunMeasurement(
            footprintBefore: footprintBefore, peakFootprint: max(peak, footprintBefore), openPeakFootprint: footprintBefore,
            idlePoolBefore: 0, poolHighWater: 0, fromRest: false, engineHeldAfter: memory().held,
            decodeSeconds: decodeSeconds, openSeconds: 0, renderSeconds: 0, deliverSeconds: deliverSeconds,
            phoneHeadroomBefore: 0, lowestPhoneHeadroom: 0, lowestPhoneFree: 0, highestWired: 0, lowestAppAvailable: 0,
            nodeMilliseconds: nil, autoExposureEV: nil, opened: pixels.size, layerSeconds: nil,
            decodedBy: "Apple's own decode, no film")
        return RenderResult(seconds: Self.since(started), peakBytes: 0, reprint: false, size: pixels.size, bands: nil,
                            measured: measured)
    }

    /// The output transform's numbers for a destination, asked from any thread
    /// but the engine's: on its queue, behind whatever job is there.
    func outputTransform(from source: String, to target: String, gamutCompress: String?) async throws -> OutputTransformData {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<OutputTransformData, Error>) in
            work.async {
                done.resume(with: Result { try self.outputTransformOnQueue(from: source, to: target, gamutCompress: gamutCompress) })
            }
        }
    }

    private func open(_ job: RenderJob) throws -> (session: OpaquePointer, decode: Double, open: Double,
                                                   params: [String: ParamValue], size: PixelSize, how: String?) {
        let params = source.params(job)
        let json = try Self.json(params)
        var session: OpaquePointer?
        var decodeSeconds = 0.0, openSeconds = 0.0
        var size = PixelSize(width: 0, height: 0)
        var how: String?
        var failure = ""
        // The decode's buffer lives exactly as long as this pool: the engine
        // borrows it for the call and keeps its own 3-channel source.
        try autoreleasepool {
            let t = Self.now()
            let frame = try source.decode(job, device: device)
            decodeSeconds = Self.since(t)
            size = frame.size
            how = frame.how
            try throwIfCancelled(job.id)
            // A decoder's dimensions, not its header estimate, are now
            // authoritative. Refuse an underpriced source before the engine
            // copies it or allocates render stages; never render first and
            // merely log the size mismatch afterwards. The caller can probe
            // the original again and submit a newly priced job.
            guard !job.isOverOpened(frame.size) else {
                throw EngineError.resource("decoded \(frame.size.width)x\(frame.size.height) exceeds the priced open \(job.pricedOpen.width)x\(job.pricedOpen.height); reopen the original and retry")
            }
            var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer as AnyObject).toOpaque(),
                                         width: UInt32(frame.size.width), height: UInt32(frame.size.height),
                                         channels: UInt32(frame.channels))
            let opening = Self.now()
            var reply: UnsafeMutablePointer<CChar>?
            session = spk_open_device(engine, &image, json, &reply)
            openSeconds = Self.since(opening)
            if let reply { spk_string_free(reply) }
            if session == nil { failure = String(cString: spk_last_error(engine)) }
        }
        guard let session else {
            throw failure.contains("too large") ? EngineError.resource(failure) : EngineError.failed(failure)
        }
        return (session, decodeSeconds, openSeconds, params, size, how)
    }

    /// The prints a job's picture is cut together from, after its own
    /// (`FrameSource.printLayers`): for each, the session is set that print's
    /// rows and printed again from the negative it has, and the host cuts the
    /// print into `base`. Each one's seconds are returned.
    ///
    /// **The rows the session had are put back however this ends** — a layer
    /// that failed, a job cancelled between two — so the session is left
    /// printing as its frame's settings say, and what an editing session was
    /// last told (`Editing.applied`) is still true of it: the next edit's
    /// difference is taken from the right rows. Should the engine refuse even
    /// that, those rows are forgotten instead, and the next job on the
    /// session sends them again.
    private func printLayers(_ job: RenderJob, _ session: OpaquePointer, _ layers: [[String: ParamValue]],
                             into base: RenderedPixels, bandCount: Int,
                             _ progress: @escaping @Sendable (RenderProgress) -> Void) throws -> [Double] {
        // What the session prints with now — the job's own settings — for every row a layer names.
        let own = source.params(job)
        var restore: [String: ParamValue] = [:]
        for rows in layers {
            for name in rows.keys {
                // A print of the same negative: only what the engine writes onto a live pipeline.
                guard FilmParams.liveMutable.contains(name), let value = own[name] else {
                    throw EngineError.failed("a frame's own print names \(name): not a row of the enlarger's that the frame's settings carry")
                }
                restore[name] = value
            }
        }
        defer {
            if (try? setParams(session, restore)) == nil, var e = editing, e.session == session {
                for name in restore.keys { e.applied[name] = nil }
                editing = e
            }
        }
        var seconds: [Double] = []
        for (index, rows) in layers.enumerated() {
            try throwIfCancelled(job.id)
            let started = Self.now()
            progress(RenderProgress(stage: .print, fraction: 0.55 + 0.4 * Double(index) / Double(layers.count),
                                    band: bandCount - 1, bandCount: bandCount))
            // From the job's own rows each time: what the layer before set and this one does not is put back with it.
            try setParams(session, restore.merging(rows) { _, layer in layer })
            // The layer's print goes with this pool: one is alive at a time beside the result.
            try autoreleasepool {
                setInFlight(job.id, session)
                var out = spk_result()
                let rc = spk_reprint(session, job.tier.rawValue, &out)
                setInFlight(nil, nil)
                if Int(rc) == Int(SPK_ERR_CANCELLED) { throw EngineError.cancelled }
                guard Int(rc) == Int(SPK_OK), let texturePointer = out.texture, let rgba16 = out.rgba16 else {
                    let message = String(cString: spk_last_error(engine))
                    throw Int(rc) == Int(SPK_ERR_RESOURCE) ? EngineError.resource(message) : EngineError.failed(message)
                }
                let texture = Unmanaged<AnyObject>.fromOpaque(texturePointer).takeRetainedValue() as! MTLTexture
                guard Int(out.width) == base.size.width, Int(out.height) == base.size.height else {
                    throw EngineError.failed("a frame's own print came out \(out.width) x \(out.height), not the picture's \(base.size.width) x \(base.size.height)")
                }
                try source.cut(job, layer: index, RenderedPixels(texture: texture, rgba16: rgba16, size: base.size,
                                                                 rowStridePixels: Int(out.row_stride_px)), into: base)
            }
            seconds.append(Self.since(started))
        }
        return seconds
    }

    /// Where the gates are on the canvas the session's last render laid out
    /// (`spk_overscan_geometry`, API-SPEC §13): the engine's reply as it came,
    /// `{"valid":false}` with no film edge. It renders nothing.
    private func filmGeometry(_ session: OpaquePointer) -> String? {
        var reply: UnsafeMutablePointer<CChar>?
        guard Int(spk_overscan_geometry(session, &reply)) == Int(SPK_OK), let reply else { return nil }
        defer { spk_string_free(reply) }
        return String(cString: reply)
    }

    private func setParams(_ session: OpaquePointer, _ delta: [String: ParamValue]) throws {
        var reply: UnsafeMutablePointer<CChar>?
        let rc = spk_set_params(session, try Self.json(delta), &reply)
        if let reply { spk_string_free(reply) }
        guard Int(rc) == Int(SPK_OK) else { throw EngineError.failed(String(cString: spk_last_error(engine))) }
    }

    /// `spk_progress` after the render: the bands, present only when it ran in
    /// bands; the node times, filled only under `SPK_NODE_TIMINGS`;
    /// and the exposure the meter applied, when it metered.
    private func account(_ session: OpaquePointer) -> (BandsRan?, [String: Double], Double?) {
        var reply: UnsafeMutablePointer<CChar>?
        guard Int(spk_progress(session, nil, &reply)) == Int(SPK_OK), let reply else { return (nil, [:], nil) }
        defer { spk_string_free(reply) }
        let progress = Self.object(String(cString: reply))
        var nodes: [String: Double] = [:]
        for (name, ms) in progress["node_times"] as? [String: Any] ?? [:] { nodes[name] = (ms as? NSNumber)?.doubleValue ?? 0 }
        let ev = (progress["auto_exposure_ev"] as? NSNumber)?.doubleValue
        guard let b = progress["bands"] as? [String: Any] else { return (nil, nodes, ev) }
        func int(_ k: String) -> Int { Int((b[k] as? NSNumber)?.doubleValue ?? 0) }
        return (BandsRan(rows: int("rows"), count: int("count"), halo: int("halo")), nodes, ev)
    }

    // MARK: - cancellation

    private func throwIfCancelled(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled.contains(id) { throw EngineError.cancelled }
    }

    private func setInFlight(_ job: UUID?, _ session: OpaquePointer?) {
        lock.lock(); defer { lock.unlock() }
        if let job, let session {
            inFlight = (job, session)
            if cancelled.contains(job) { spk_cancel(session, nil) }
        } else {
            inFlight = nil
        }
    }

    /// From the watch, every 4 ms while the job runs: the engine clears its
    /// flag when a render starts, so a cancel that landed just before is
    /// handed over again.
    private func cancelAgain(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if cancelled.contains(id), let f = inFlight, f.job == id { spk_cancel(f.session, nil) }
    }

    /// The job is over, however it ended: its cancel is forgotten, so the same
    /// job can be run again (a job that gave way keeps its id).
    private func forget(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cancelled.remove(id)
        if let asked = cancelAsked.removeValue(forKey: id) {
            latencies.append(Double(DispatchTime.now().uptimeNanoseconds - asked) / 1e9)
        }
    }

    // MARK: - small things

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func since(_ t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9 }

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    private static func json(_ params: [String: ParamValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let s = String(data: try encoder.encode(params), encoding: .utf8) else {
            throw EngineError.failed("the frame's settings could not be encoded")
        }
        return s
    }
}

/// The job's memory, watched from its own thread: `phys_footprint` every 4 ms
/// (never RSS, which cannot see the Metal pool) and the host's pages every
/// 20 ms. It also hands a pending cancel to the engine again.
private final class RunWatch {
    struct Seen {
        var peak: UInt64
        var firstHeadroom: UInt64
        var lowestHeadroom: UInt64
        var lowestFree: UInt64
        var highestWired: UInt64
        var lowestAvailable: UInt64
    }

    private let lock = NSLock()
    private var running = true
    private var seen: Seen
    private let ended = DispatchSemaphore(value: 0)
    private var joined = false

    init(tick: @escaping () -> Void) {
        let first = MemoryProbe.read()
        seen = Seen(peak: first.footprint, firstHeadroom: first.phoneHeadroom, lowestHeadroom: first.phoneHeadroom,
                    lowestFree: first.free,
                    highestWired: first.wired, lowestAvailable: first.appAvailable)
        let thread = Thread { [self] in
            var n = 0
            while isRunning {
                n += 1
                if n % 5 == 0 {
                    let r = MemoryProbe.read()
                    lock.lock()
                    seen.peak = max(seen.peak, r.footprint)
                    seen.lowestHeadroom = min(seen.lowestHeadroom, r.phoneHeadroom)
                    seen.lowestFree = min(seen.lowestFree, r.free)
                    seen.highestWired = max(seen.highestWired, r.wired)
                    seen.lowestAvailable = min(seen.lowestAvailable, r.appAvailable)
                    lock.unlock()
                } else {
                    let f = MemoryProbe.footprint()
                    lock.lock(); seen.peak = max(seen.peak, f); lock.unlock()
                }
                tick()
                usleep(4000)
            }
            ended.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Stop without waiting: for a job that ended by throwing.
    func cancel() { lock.lock(); running = false; lock.unlock() }

    func peakSoFar() -> UInt64 { lock.lock(); defer { lock.unlock() }; return seen.peak }

    /// Stop, and what was seen, with one last sample.
    func stop() -> Seen {
        cancel()
        if !joined { ended.wait(); joined = true }
        let f = MemoryProbe.footprint()
        lock.lock(); defer { lock.unlock() }
        seen.peak = max(seen.peak, f)
        return seen
    }
}
#endif
