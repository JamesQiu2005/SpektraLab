//  DevelopEngine.swift — the seam between the scheduler and the engine.
//
//  The scheduler lives in the app, in Swift, because only the app knows the
//  frontend; the engine stays a deterministic executor (RFC-036 §6.1). This
//  protocol is everything the scheduler asks of it, and each call is one the C
//  ABI already has (`engine/include/spektralab/spk_engine.h`):
//
//  | here | the ABI |
//  |---|---|
//  | `run` in `.whole` | `spk_render` / `spk_reprint` |
//  | `run` in `.bands(rows)` | the same: the engine renders a frame whole, and the band count is the scheduler's own progress |
//  | `run` of a job with `printLayers` | after its own render, for each: `spk_set_params` with that print's rows, `spk_reprint`, the print cut into the result by the host; then `spk_set_params` with the rows it had |
//  | `progress` | the stages the conformer itself passes. **Not `spk_progress` while a render is in flight**: it copies a `std::string` the render thread is assigning, so the desktop reads it only after a render, and so does `SpkEngine` (for the bands the engine cut) |
//  | `cancel` | `spk_cancel(session, NULL)`: unwinds at the next node boundary, `SPK_ERR_CANCELLED` |
//  | `trim` | nothing: the engine trims its own pool (at `spk_open`, and after an idle spell), so this returns 0 |
//  | `heldBytes` | `spk_memory_report(engine)`: `total_bytes` |
//  | `effectVersions` | `spk_capabilities`: `backend.effect_versions` |
//
//  **Two conformers.** `SimulatedEngine` keeps time and makes no picture; it is
//  what this app runs until the engine is linked. `SpkEngine` (SpkEngine.swift,
//  compiled where `SPK_ENGINE` is set) is the engine itself, and it opens a
//  frame as the handoff of 2026-10-03 says it must: the engine created on the
//  host's own `MTLDevice`, the decode rendered into a buffer from that device,
//  and `spk_open_device` — never `spk_open` with a host pointer, which copies
//  the whole frame on the CPU (744 MiB at 48 MP) and leaves it in the pool.
//  One autorelease pool per develop and one Core Image context with its caches
//  cleared: the bench leaked 72 → 646 MB over four photos without them.

import Foundation

/// The bands the engine cut, read from `spk_progress` after the render. The
/// scheduler asks for a height; the engine decides it, from a byte budget and
/// its own reach for the frame's settings (`BandGeometry`), so the two are
/// compared in every job's record.
struct BandsRan: Codable, Equatable, Sendable {
    var rows: Int
    var count: Int
    /// The rows a band reads below its interior: the film side's reach.
    var halo: Int
}

/// What a real render measured about itself, for the job's record (R8) and for
/// calibrating the budget. Bytes; seconds.
struct RunMeasurement: Codable, Equatable, Sendable {
    /// `phys_footprint` when the job started, and its highest sample (every 4 ms).
    var footprintBefore: UInt64
    var peakFootprint: UInt64
    /// The highest sample up to the end of the open: the decode's buffer beside
    /// the source plane, before the render has taken anything. Equal to
    /// `footprintBefore` for a job on a session already open.
    var openPeakFootprint: UInt64
    /// The engine's pool that was free when the job started, and the pool's
    /// own high-water mark during the render (`frame_high_water_bytes`).
    var idlePoolBefore: UInt64
    var poolHighWater: UInt64
    /// The job started from rest: no idle pool to reuse, and two seconds since
    /// the job before it, which is how long `phys_footprint` takes to come
    /// back. Only then is the footprint's growth the job's own peak.
    var fromRest: Bool
    /// Everything the engine held when the job ended (a one-shot job's session
    /// already released).
    var engineHeldAfter: UInt64
    var decodeSeconds: Double
    var openSeconds: Double
    var renderSeconds: Double
    /// Handing the result to the host: the encode and the save. Not in `seconds`.
    var deliverSeconds: Double
    /// The host during the job, sampled every 20 ms: its lowest reclaimable
    /// headroom (free + inactive + purgeable) and free pages, its highest
    /// wired memory, and the app's lowest remaining allowance.
    /// `hostHeadroomBefore` is the host as the job started, so the fall to
    /// the lowest is what the job took from the host — more than its
    /// footprint shows (`CostEstimate.hostBytes`).
    var phoneHeadroomBefore: UInt64
    var lowestPhoneHeadroom: UInt64
    var lowestPhoneFree: UInt64
    var highestWired: UInt64
    var lowestAppAvailable: UInt64
    /// Milliseconds per node, only when the engine was started with
    /// `SPK_NODE_TIMINGS=1` — which flushes after every node and so
    /// changes the schedule: read the proportions, not the times (AGENTS.md).
    var nodeMilliseconds: [String: Double]? = nil
    /// The exposure the session's meter applied, in EV (`spk_progress`). A
    /// session meters its own source once, at 1,600 px, for every tier — so
    /// two sessions on two sizes of one photo (a preview decoded small, an
    /// export from the original) each meter for themselves, and where they
    /// differ their pictures differ in brightness.
    var autoExposureEV: Double? = nil
    /// The size of the frame the host handed over to be opened; nil for a job
    /// on a session already open. For a job below the full tier it should be
    /// the job's canvas (`FrameSource.decode`).
    var opened: PixelSize? = nil
    /// The prints made after the job's own and cut into it — a half-frame
    /// pair's frames that print as their own (`FrameSource.printLayers`):
    /// each one's seconds, its rows set, the negative printed again and the
    /// print cut in. Not in `renderSeconds`; in the job's `seconds`. Nil for
    /// a job with none.
    var layerSeconds: [Double]? = nil
    /// What made the pixels the engine was handed: "ImageIO", "Core Image",
    /// "RAW 9 dng" (`DecodeReport.how`, `EngineHost.recorded`); a pair's two, joined. Nil for a job
    /// on a session already open. In the record because the open's price is
    /// the decoder's: a 48 MP ProRAW shot opened at up to five times HEIF's
    /// on the beta's first day, and the log could tell the two apart only by
    /// the shot before the job (RFC-036, the handoff of 2026-10-12, §6.6 step 3).
    var decodedBy: String? = nil
}

struct RenderResult: Equatable, Sendable {
    /// Decode, open and render. The save is the host's and is not counted.
    var seconds: Double
    /// The job's measured peak over the engine's resting footprint; 0 when the
    /// engine cannot say. The simulated engine never can. The real one can
    /// only for a job that started from rest (`RunMeasurement.fromRest`): one
    /// that reused an idle pool, or started while the footprint of the job
    /// before it was still coming back, grew by less than it needs, and a
    /// cost model taught that figure would predict too little. Measured on the
    /// Mac, 2026-10-03: a 48 MP whole render run again straight after a cancel
    /// grew 1,489 MB where the same render from rest takes 3,208.
    var peakBytes: UInt64
    /// 1 if the cached negative was reused.
    var reprint: Bool
    /// The size that was rendered. Never larger than was asked, and when it is
    /// smaller the caller says so on the page.
    var size: PixelSize
    /// What the engine cut; nil when it rendered the frame whole — which it
    /// does whenever it cannot band a job, whatever was asked (a crop or a
    /// turn in the engine's geometry, a canvas tier).
    var bands: BandsRan? = nil
    /// nil from the simulated engine.
    var measured: RunMeasurement? = nil
}

enum EngineError: Error, Equatable, Sendable {
    /// `SPK_ERR_CANCELLED`.
    case cancelled
    /// `SPK_ERR_RESOURCE`: out of memory, image too large.
    case resource(String)
    case failed(String)
}

protocol DevelopEngine: AnyObject, Sendable {
    /// "simulated" or the engine's build stamp, for Settings and for the log.
    var name: String { get }
    /// Whether a render here makes a picture. The simulated engine keeps time
    /// and makes none; the pages ask this, not the engine's name, before they
    /// say a frame is developed or a file was written.
    var makesPictures: Bool { get }
    /// `halation=<version>;grain=<version>` — part of any cache key built from a render,
    /// because two engines that differ here render different pictures.
    var effectVersions: String { get }

    /// Render one job in one mode. Throws `EngineError.cancelled` when
    /// `cancel` reached it. `progress` may be called from any thread.
    func run(_ job: RenderJob, mode: RenderMode,
             progress: @escaping @Sendable (RenderProgress) -> Void) async throws -> RenderResult

    /// Safe from any thread while `run` is in flight.
    func cancel(_ jobID: UUID)

    /// Give back every pooled buffer that is free and idle. Returns the bytes freed.
    @discardableResult func trim() async -> UInt64

    /// What the engine holds now: pool plus persistent.
    func heldBytes() async -> UInt64

    /// More than `trim`, for a job someone waits on: the editing session kept open between canvas
    /// jobs closes too — unless it is `keeping`'s, whose next reprint it is — then the pool is
    /// trimmed. Returns the bytes freed.
    @discardableResult func reclaim(keeping frameID: UUID?) async -> UInt64
}

extension DevelopEngine {
    var makesPictures: Bool { true }
    @discardableResult func reclaim(keeping frameID: UUID?) async -> UInt64 { await trim() }
}
