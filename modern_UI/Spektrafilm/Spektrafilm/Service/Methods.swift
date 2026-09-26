//  Methods.swift — Codable request/response types for the render service.
//
//  One type per method in `spektrafilm/service/service.py`. Field names are
//  the wire names. Additions made to the service for this client (all
//  additive, all optional on the wire) are marked `[client-added]`:
//
//    - `export_di` — the DI package: normalised-density negative plus the
//      print stock's `.cube`.
//
//  Every reply that used to carry a *path* no longer does. The engine renders
//  into an `MTLTexture` in this process (RFC-014), so `reprint`,
//  `preview_render`, `export`, `preview_stock_lut` and `export_di` all return
//  pixels through `RenderOutcome` and leave only metadata in these types. The
//  `output: "rgba16"` field and the workspace filename counter it needed are
//  gone with the file they described.

import Foundation

struct Capabilities: Decodable, Sendable {
    let version: String
    let engine: String
    let maxMP: Double
    /// The largest texture side the engine's device will make, so the app
    /// knows the same wall the engine does. Optional: an engine from before
    /// the field sends nothing, and the callers fall back to their own size.
    let maxTextureDimension2D: Double?
    let tiers: [String: Int?]
    let transportVersion: Int
    let schemaVersion: Int
    let backend: Backend?

    /// The wire this build was written against (contract §2). Both are 1.
    ///
    /// Neither field is optional here, and that is the point: a service that
    /// does not report them is a service whose framing this app cannot
    /// reason about, and the contract says refuse rather than guess. The
    /// backend session nearly shipped a refactor that dropped both while its
    /// commit message said "no wire change" — a split that only moves code
    /// still moves the wire, because the wire is assembled from both halves.
    static let knownTransportVersion = 1
    static let knownSchemaVersion = 1

    /// Why this app cannot talk to this service, or nil if it can.
    ///
    /// A *newer* transport is refused; the framing or the file-handoff
    /// convention has changed under us and every subsequent read would be a
    /// guess. An *older* one is refused too, for the same reason in the other
    /// direction. Schema is a warning, not a refusal: a renamed parameter
    /// makes some sliders stop working, which is bad, but it is not a reason
    /// to refuse to show the user their photograph.
    var unsupportedTransport: String? {
        guard transportVersion != Capabilities.knownTransportVersion else { return nil }
        return "This build speaks transport version \(Capabilities.knownTransportVersion); "
             + "the render service speaks \(transportVersion). "
             + (transportVersion > Capabilities.knownTransportVersion
                ? "The service is newer than the app — update the app."
                : "The service is older than the app — rebuild it from this checkout.")
    }

    var schemaMismatch: String? {
        guard schemaVersion != Capabilities.knownSchemaVersion else { return nil }
        return "Parameter schema version \(schemaVersion); this build was written against "
             + "\(Capabilities.knownSchemaVersion). Some controls may not reach the engine."
    }

    /// Which executor is actually rendering. The client had no way to ask
    /// this and it cost real time: with the engine on a branch the app did
    /// not have, every render ran on the CPU core and the only symptom was
    /// that things felt slow. A number in a log is not a substitute for the
    /// app knowing, so this is read at `open` and shown in the status bar.
    struct Backend: Decodable, Sendable {
        /// `"metal"` · `"mlx"` · `"cpu"` (contract §6, 2026-09-10).
        let renderCore: String?
        let gpu: String?
        let gpuAvailable: Bool?
        let workingPrecision: String?
        let host: String?
        /// Whether concurrent requests are safe. The client stays serial
        /// regardless until `configure_transport` is opted into.
        let concurrent: Bool?
        /// The engine's LRU over whole sessions (RFC-013 §2). Worth having on
        /// screen next to `render_core`: it is the difference between
        /// "switching frames is slow" and "the cache evicts on every switch".
        let sessionCache: SessionCache?
        struct SessionCache: Decodable, Sendable {
            let entries: Int?, maxEntries: Int?
            let hits: Int?, misses: Int?, evictions: Int?
            let bytes: Int?, enabled: Bool?
            enum CodingKeys: String, CodingKey {
                case entries, hits, misses, evictions, bytes, enabled
                case maxEntries = "max_entries"
            }
            var summary: String {
                "cache \(entries ?? 0)/\(maxEntries ?? 0) · \(hits ?? 0) hit / \(misses ?? 0) miss"
                + ((evictions ?? 0) > 0 ? " · \(evictions!) evicted" : "")
            }
        }
        enum CodingKeys: String, CodingKey {
            case gpu, concurrent, host
            case renderCore = "render_core", gpuAvailable = "gpu_available"
            case workingPrecision = "working_precision", sessionCache = "session_cache"
        }
        /// What the status bar shows. `nil` from a service too old to report
        /// one is not the same as "cpu", and saying so is the point.
        var label: String {
            switch renderCore {
            case "metal": "Metal"
            case "mlx": "MLX"
            case "cpu": "CPU"
            case let other?: other
            case nil: "unreported"
            }
        }
        /// True only when we know we are *not* on the GPU-native core. Drives
        /// the warning, so a service that does not report the field is not
        /// accused of anything.
        var isSlowPath: Bool { renderCore == "cpu" || renderCore == "mlx" }
    }

    enum CodingKeys: String, CodingKey {
        case version, engine, tiers, backend
        case maxMP = "max_mp", maxTextureDimension2D = "max_texture_dimension_2d",
             transportVersion = "transport_version", schemaVersion = "schema_version"
    }
}

struct OpenResponse: Decodable, Sendable {
    let sessionID: String
    let meta: Meta
    let detectedInput: DetectedInput
    let params: [String: ParamValue]
    /// `open` echoes the full capabilities block, so the client learns which
    /// executor it got without a second round trip.
    let capabilities: Capabilities?
    struct Meta: Decodable, Sendable { let width: Int, height: Int, megapixels: Double, source: String }
    struct DetectedInput: Decodable, Sendable {
        let inputColorSpace: String
        let inputCctfDecoding: Bool
        let inputColorSpaceSource: String
        let rawEngine: String?
        enum CodingKeys: String, CodingKey {
            case inputColorSpace = "input_color_space", inputCctfDecoding = "input_cctf_decoding"
            case inputColorSpaceSource = "input_color_space_source", rawEngine = "raw_engine"
        }
    }
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", meta, params, capabilities
        case detectedInput = "detected_input"
    }
}

struct SolveRequest: Encodable, Sendable {
    let sessionID: String
    var target = "both"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", target }
}

struct SolveResponse: Decodable, Sendable {
    let solvedParams: [String: Double]
    /// RFC-015 §3: what each of the four exposure intents would choose, all
    /// from the one sample `solve` already took, keyed by wire name.
    ///
    /// A **sibling** of `solved_params`, never a member of it: that dictionary
    /// is decoded as `[String: Double]`, so an object in there would throw and
    /// take the develop's exposure solve down with it — which is every
    /// develop. Optional, so a reply from an engine without the field (or from
    /// `solve(target:"filter_pack")`, which does not meter) still decodes.
    let exposureEvByMethod: [String: Double]?
    enum CodingKeys: String, CodingKey {
        case solvedParams = "solved_params"
        case exposureEvByMethod = "exposure_ev_by_method"
    }
}

struct SetParamsRequest: Encodable, Sendable {
    let sessionID: String
    let paramsDelta: [String: ParamValue]
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", paramsDelta = "params_delta" }
}

struct SetParamsResponse: Decodable, Sendable {
    let invalidated: String
    let params: [String: ParamValue]
}

struct RenderRequest: Encodable, Sendable {
    let sessionID: String
    var paramsDelta: [String: ParamValue]?
    var tier = "live"
    /// preview_render only: "shoot" forces the film side to run.
    var layer: String?
    var targetPx: Int?
    var output = "rgba16"
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", paramsDelta = "params_delta", tier, layer, output
        case targetPx = "target_px"
    }
}

/// `spk_progress`'s reply. No path to it through `call(_:_:as:)` before
/// RFC-016 needed one: the app never polled progress, because the transport
/// was single-flight and a render does not return until it is finished.
///
/// What it is for now is the two numbers a *finished* render still has in
/// `session->progress`: the per-node times when the engine has been asked for
/// them (§5.2), and `auto_exposure_ev` — the EV the meter actually applied to
/// this render's negative, which is the number an export has to be reconciled
/// against the canvas with (RFC-015 P.1, RFC-016 §1.4).
struct ProgressResponse: Decodable, Sendable {
    let progressID: String
    let stage: String?
    let pct: Double?
    let nodeTimes: [String: Double]?
    let autoExposureEV: Double?
    let done: Bool?
    let cancelled: Bool?
    enum CodingKeys: String, CodingKey {
        case stage, pct, done, cancelled
        case progressID = "progress_id", nodeTimes = "node_times"
        case autoExposureEV = "auto_exposure_ev"
    }
}

struct RenderResponse: Decodable, Sendable {
    let progressID: String
    let tier: String
    let elapsedMs: Double
    let reprint: Bool
    let negativeWasCached: Bool
    let previewPath: String?
    let exportPath: String?
    /// [client-added] raw 16-bit RGBA, `width`×`height`, row-major, top row first.
    let rawPath: String?
    let width: Int?
    let height: Int?
    enum CodingKeys: String, CodingKey {
        case progressID = "progress_id", tier, reprint, width, height
        case elapsedMs = "elapsed_ms", negativeWasCached = "negative_was_cached"
        case previewPath = "preview_path", exportPath = "export_path", rawPath = "raw_path"
    }
}

/// `preview_stock_lut`'s reply, pixels aside.
///
/// No paths any more: the engine hands back a texture the way every other
/// render does, so what is left here is the metadata — how long the table
/// lookup took, which film the table was baked against, and whether that is
/// the film this session is using.
struct StockLUTResponse: Decodable, Sendable {
    let printStock: String
    let tier: String
    let applyMs: Double
    let applyBackend: String
    let lutSource: String
    let pairedFilm: String
    let declaredPairing: Bool
    /// Present exactly when the session's film is not `pairedFilm`. The table
    /// is baked through a specific negative's dye spectra as well as through
    /// the paper, so a mismatched film is an approximation whose error nobody
    /// has measured (PRD §7.3) — which is worth saying rather than hiding.
    let warning: String?
    enum CodingKeys: String, CodingKey {
        case tier, warning
        case printStock = "print_stock", applyMs = "apply_ms", applyBackend = "apply_backend"
        case lutSource = "lut_source", pairedFilm = "paired_film", declaredPairing = "declared_pairing"
    }
}

/// One print stock's entry in `spk_print_lut_catalog`.
struct PrintLUTEntry: Decodable, Sendable {
    let pairedFilm: String
    let declaredPairing: Bool
    let lutSize: Int
    enum CodingKeys: String, CodingKey {
        case pairedFilm = "paired_film", declaredPairing = "declared_pairing", lutSize = "lut_size"
    }
}

struct ExportRequest: Encodable, Sendable {
    let sessionID: String
    var format = "tiff"
    var bitDepth = 16
    var output = "rgba16"
    enum CodingKeys: String, CodingKey { case sessionID = "session_id", format, bitDepth = "bit_depth", output }
}

/// `export_di`'s reply, pixels aside.
///
/// The three files are the client's business now, so no paths cross: the
/// engine returns the normalised-density picture as a texture and the LUT as
/// a pointer (`spk_print_lut_table`), and `Exporter` writes the TIFF, the
/// `.cube` and the optional print preview from those.
struct ExportDIResponse: Decodable, Sendable {
    let printStock: String
    let lutSize: Int
    let pairedFilm: String
    let declaredPairing: Bool
    let warning: String?
    enum CodingKeys: String, CodingKey {
        case warning
        case printStock = "print_stock", lutSize = "lut_size"
        case pairedFilm = "paired_film", declaredPairing = "declared_pairing"
    }
}

/// The service's own error taxonomy (`service/errors.py`).
struct ServiceError: Error, Decodable, Sendable, CustomStringConvertible {
    let code: String
    let category: String
    let message: String
    let param: String?
    let traceback: String?
    var description: String { "\(category): \(message)" + (param.map { " (\($0))" } ?? "") }
}

enum Method: String, Sendable {
    case capabilities, paramsSchema = "params_schema", open, getParams = "get_params"
    case setParams = "set_params", solve, previewRender = "preview_render", reprint, export
    case previewStockLUT = "preview_stock_lut", progress, cancel, exportDI = "export_di"
    /// `close` is deliberately absent: the engine has a `close()` but it is
    /// not dispatchable over the wire, and a `Method` case for it would be a
    /// call that always fails.
    case warmUp = "warm_up"
}

/// `warm_up` — pay the first frame's fixed setup before the user is looking
/// (RFC-013 §3). Every field is optional on the wire, but pass the stocks the
/// frame will actually open with: the engine builds a pipeline for the pair it
/// is given, and warming a pair the first `open` will not use is pure waste.
struct WarmUpRequest: Encodable, Sendable {
    var filmStock: String?
    var printStock: String?
    enum CodingKeys: String, CodingKey { case filmStock = "film_stock", printStock = "print_stock" }
}

struct WarmUpResponse: Decodable, Sendable {
    let alreadyWarm: Bool?
    let renderCore: String?
    let totalMs: Double?
    let steps: [Step]?
    /// A step that failed is **not** fatal: the work is simply paid again
    /// inside `open`. Log it and carry on (handoff §3.1).
    struct Step: Decodable, Sendable {
        let name: String
        let ok: Bool?
        let ms: Double?
    }
    enum CodingKeys: String, CodingKey {
        case steps
        case alreadyWarm = "already_warm", renderCore = "render_core", totalMs = "total_ms"
    }
    /// The names of the steps the engine reported as failed.
    var failedSteps: [String] { (steps ?? []).filter { $0.ok == false }.map(\.name) }
}

// MARK: - RFC-023 Scene Latitude (`spk_scene_latitude`, API-SPEC §12)

/// What to solve. Every field optional on the wire: an absent pull-back asks
/// for the engine's suggestion, an absent curve setting uses the session's.
struct SceneLatitudeRequest: Encodable, Equatable, Sendable {
    var highlightPullBack: Double?
    var shadowPullBack: Double?
    var rolloff: Double?
    var maxLift: Double?
    var norm: String?
    var margin: Double?
    /// 0.1 or 1.
    var shadowPercentile: Double?
    /// 99.9 or 99.
    var highlightPercentile: Double?
    enum CodingKeys: String, CodingKey {
        case rolloff, norm, margin
        case highlightPullBack = "highlight_pull_back", shadowPullBack = "shadow_pull_back"
        case maxLift = "max_lift", shadowPercentile = "shadow_percentile"
        case highlightPercentile = "highlight_percentile"
    }

    /// Only the keys that are set, so "absent" means what the engine says it
    /// means rather than arriving as `null`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(highlightPullBack, forKey: .highlightPullBack)
        try c.encodeIfPresent(shadowPullBack, forKey: .shadowPullBack)
        try c.encodeIfPresent(rolloff, forKey: .rolloff)
        try c.encodeIfPresent(maxLift, forKey: .maxLift)
        try c.encodeIfPresent(norm, forKey: .norm)
        try c.encodeIfPresent(margin, forKey: .margin)
        try c.encodeIfPresent(shadowPercentile, forKey: .shadowPercentile)
        try c.encodeIfPresent(highlightPercentile, forKey: .highlightPercentile)
    }
}

/// The medium, the scene, a suggestion and a solved fit -- measurements and a
/// proposal, never a render (API-SPEC §12).
struct SceneLatitudeResponse: Decodable, Sendable {
    /// The session's film + paper, measured by a neutral ramp (RFC-023 §8.1).
    struct Medium: Decodable, Sendable {
        let shadowEV: Double
        let highlightEV: Double
        let latitudeStops: Double
        let yBlack: Double
        let yWhite: Double
        /// 128 points of the print's relative luminance against scene EV --
        /// enough to draw the medium's response.
        let rampEV: [Double]
        let rampY: [Double]
        enum CodingKeys: String, CodingKey {
            case shadowEV = "shadow_ev", highlightEV = "highlight_ev", latitudeStops = "latitude_stops"
            case yBlack = "y_black", yWhite = "y_white", rampEV = "ramp_ev", rampY = "ramp_y"
        }
    }

    /// The frame on the curve's own axis: stops from the metered mid-grey.
    struct Scene: Decodable, Sendable {
        struct Histogram: Decodable, Sendable {
            let loEV: Double
            let hiEV: Double
            /// Fraction of the frame per bin; 128 bins across [loEV, hiEV].
            let fractions: [Double]
            /// The same bins after the requested pull-backs' curve. Absent
            /// when the fit was refused. Equal to `fractions` with both
            /// sides off.
            let placedFractions: [Double]?
            enum CodingKeys: String, CodingKey {
                case loEV = "lo_ev", hiEV = "hi_ev", fractions, placedFractions = "placed_fractions"
            }
        }
        let norm: String
        let samples: Double
        let p0_1: Double
        let p1: Double
        let p50: Double
        let p99: Double
        let p99_9: Double
        let histogram: Histogram
        enum CodingKeys: String, CodingKey {
            case norm, samples, p1, p50, p99, histogram
            case p0_1 = "p0_1", p99_9 = "p99_9"
        }
    }

    struct Suggested: Decodable, Sendable {
        let highlightPullBack: Double
        let shadowPullBack: Double
        let marginUsed: Double
        let valid: Bool
        enum CodingKeys: String, CodingKey {
            case valid
            case highlightPullBack = "highlight_pull_back", shadowPullBack = "shadow_pull_back"
            case marginUsed = "margin_used"
        }
    }

    struct Fit: Decodable, Sendable {
        /// A refusal (`issues`) or a legal-but-worth-saying note (`warnings`).
        struct Issue: Decodable, Equatable, Sendable {
            /// `pull_back_below_minimum`, `pull_back_exceeds_max_lift`,
            /// `knees_cross`, `room_below_minimum`, `out_of_range`;
            /// warnings: `knee_past_midgrey`.
            let code: String
            /// `highlight`, `shadow` or `both`.
            let side: String
            let message: String
        }
        /// One side's readouts. `knee`/`room` only when the side is on.
        struct Side: Decodable, Sendable {
            let on: Bool
            let pullBack: Double
            /// Below this the extreme lands past the medium's boundary.
            let minimumPullBack: Double
            let sceneExtremeEV: Double
            let mediumBoundaryEV: Double
            let knee: Double?
            let room: Double?
            /// Where the render really puts the extreme (the shadow side
            /// includes the lift bound), and the curve's slope there.
            let landingEV: Double
            let slopeAtExtreme: Double
            enum CodingKeys: String, CodingKey {
                case on, knee, room
                case pullBack = "pull_back", minimumPullBack = "minimum_pull_back"
                case sceneExtremeEV = "scene_extreme_ev", mediumBoundaryEV = "medium_boundary_ev"
                case landingEV = "landing_ev", slopeAtExtreme = "slope_at_extreme"
            }
        }
        /// The wire delta that commits this fit, typed.
        struct ParamsDelta: Decodable, Equatable, Sendable {
            let active: Bool
            let norm: String
            let highlightKnee: Double
            let highlightRoom: Double
            let shadowKnee: Double
            let shadowRoom: Double
            let rolloff: Double
            let maxLift: Double
            enum CodingKeys: String, CodingKey {
                case active = "scene_latitude_active", norm = "scene_latitude_norm"
                case highlightKnee = "scene_latitude_highlight_knee"
                case highlightRoom = "scene_latitude_highlight_room"
                case shadowKnee = "scene_latitude_shadow_knee"
                case shadowRoom = "scene_latitude_shadow_room"
                case rolloff = "scene_latitude_rolloff", maxLift = "scene_latitude_max_lift"
            }
        }
        let valid: Bool
        let issues: [Issue]
        let warnings: [Issue]
        let highlight: Side
        let shadow: Side
        /// The untouched core's width, when both sides are on.
        let coreStops: Double?
        /// Present only when `valid`.
        let paramsDelta: ParamsDelta?
        enum CodingKeys: String, CodingKey {
            case valid, issues, warnings, highlight, shadow
            case coreStops = "core_stops", paramsDelta = "params_delta"
        }
    }

    let medium: Medium
    let scene: Scene
    let suggested: Suggested
    let fit: Fit
}

// MARK: - RFC-024 mask field (`spk_contrast_mask_field`, API-SPEC §11)

/// The mask the next print of a tier applies, as a picture: the delta in stops
/// at each analysis-grid cell, row-major, top row first, `width` × `height` in
/// the frame's own aspect. Positive raises the print's highlights, negative
/// lowers its shadows. Empty (0 × 0) with the mask off.
struct ContrastMaskField: Equatable, Sendable {
    let width: Int
    let height: Int
    let delta: [Float]
    var isEmpty: Bool { width == 0 || height == 0 }
    func at(x: Int, y: Int) -> Float { delta[y * width + x] }
}
