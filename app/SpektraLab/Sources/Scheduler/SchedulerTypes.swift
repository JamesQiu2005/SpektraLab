//  SchedulerTypes.swift — the words the scheduler is written in.
//
//  RFC-036: on an 8 GB host with the camera running, **memory decides whether
//  a render finishes; speed only decides when.** So every render goes through
//  one scheduler. Before each job it asks how much memory the host can spare
//  at that moment, and picks the fastest way to render that fits: whole, in
//  bands, in smaller bands, or not yet.
//
//  Nothing in this file touches a pixel or an operating-system call: it is the
//  vocabulary, so the planner and the queue can be tested on any machine.

import Foundation

/// The engine's three tiers (API-SPEC §6), by their wire names.
enum RenderTier: String, Codable, Sendable {
    /// The canvas while editing.
    case live
    /// The frame's preview copy: what the library and the develop page show.
    case preview
    /// The export, from the original.
    case full
}

/// Who asked, which is the job's priority (RFC-036 §5). Lower runs first.
enum JobKind: String, Codable, Sendable, CaseIterable {
    /// A print-side edit on the canvas: a reprint from the cached negative.
    case canvasReprint
    /// A film-side edit on the canvas: the negative develops again.
    case canvasDevelop
    /// The shot just taken, developed behind the viewfinder **at preview
    /// size**, while the photographer goes on shooting. Its full-size render
    /// belongs to the develop page (the owner's flow, 2026-10-03).
    case shot
    /// A frame that just arrived by import, developed at preview size.
    case importDevelop
    /// A full-size develop, from the original, for a file.
    case export
    /// A full-size develop for the develop page's zoom (`FullRender`): an
    /// export's render at Full, kept on disk instead of written to a file.
    case fullView
    /// A library thumbnail.
    case thumbnail
    /// A card of Develop's film and paper strips (design/v4 §6): the frame
    /// through one film on one paper, at the live tier's smallest size. The
    /// last of all: it starts only when nothing else is queued, and gives way
    /// at once to anything (`RenderQueue`). Coalesced by its `slot`.
    case stockPreview

    var priority: Int {
        switch self {
        case .canvasReprint, .canvasDevelop: 1
        case .shot: 2
        case .export, .fullView: 3
        // The page's own cards before the library's develops of other frames (2026-10-21: on the owner's
        // reference device a RAW's cards waited 20 minutes behind 85 develops a setting had asked of the library).
        case .stockPreview: 4
        case .importDevelop: 5
        case .thumbnail: 6
        }
    }

    var isCanvas: Bool { self == .canvasReprint || self == .canvasDevelop }

    /// A job someone is looking at the screen for: an edit on the develop page, the page's
    /// full-size zoom, an export. It is planned against more of the host, the app gives back what
    /// it holds before it waits, and it does not wait for long (`RenderQueue.reclaim`).
    var isAsked: Bool { isCanvas || self == .fullView || self == .export }
}

/// Why a job is not running, in the words the page shows (RFC-036 §3.5: a job
/// that is waiting says why).
enum WaitReason: String, Codable, Equatable, Sendable {
    /// Nothing fits in what the host can spare right now.
    case memory
    /// The camera holds the memory this size needs.
    case camera
    /// A photo is being taken: everything holds until it lands.
    case capture
    /// GPU work is refused in the background.
    case background
    /// Something more urgent is running.
    case queued

    var text: String {
        switch self {
        case .memory: "Waiting for memory"
        case .camera: "Waiting for the camera to free memory"
        case .capture: "Waiting for the photo to land"
        case .background: "Paused — app in the background"
        case .queued: "Waiting its turn"
        }
    }
}

/// What a photo in flight does to a develop **below the full tier** — a shot
/// or an import at preview size, which is the job that runs while the user
/// keeps shooting (the owner's flow, 2026-10-03: photos are taken and
/// developed at the same time, at preview size; the full-size render belongs
/// to the develop page). A full-size job is not asked: it never starts under a
/// photo and always gives way to one (RFC-036 §6.7), because its peak is
/// gigabytes.
enum CaptureRule: String, Codable, Sendable, CaseIterable {
    /// RFC-036 §6.7 as first written: the running develop stops — in phase 1 a
    /// cancel and a run again from the start — and nothing starts until the
    /// photo lands.
    case stops
    /// The running develop finishes; nothing new starts until the photo lands.
    case holds
    /// A develop starts, and goes on, whenever the budget has room for it —
    /// and the budget keeps aside the growth of every capture in flight and of
    /// one more.
    case shares
}

/// How a job renders. The mode changes how long a render takes, never what it
/// computes: a banded render equals the whole one to the parity bar (RFC-035
/// §9), no effect is approximated to save memory, and nothing reduced is
/// labelled full (RFC-036 G3).
enum RenderMode: Equatable, Sendable {
    /// M0: the whole frame at once.
    case whole
    /// M1…Mk: bands of this many rows. Fewer rows, less memory, more time.
    case bands(rows: Int)
    /// W: no render. The job keeps its place, states its reason, and re-plans
    /// on every memory or camera signal.
    case wait(WaitReason)

    var name: String {
        switch self {
        case .whole: "whole"
        case .bands(let rows): "bands(\(rows))"
        case .wait(let why): "wait(\(why.rawValue))"
        }
    }
}

/// What the frontend is doing, because that is where the memory goes
/// (RFC-036 §6.2, §6.7).
struct FrontendState: Equatable, Sendable {
    enum Camera: Equatable, Sendable {
        case off
        /// The session is running, with photos of this many megapixels.
        case live(photoMegapixels: Double)
    }
    enum Interaction: Equatable, Sendable {
        case idle
        /// A finger is on a control of this layer.
        case dragging(ParamLayer)
    }
    enum Scene: String, Equatable, Sendable { case active, inactive, background }
    enum Thermal: Int, Equatable, Sendable, Comparable {
        case nominal, fair, serious, critical
        static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    var camera: Camera = .off
    /// Photos taken and not yet delivered.
    var capturesInFlight = 0
    var interaction: Interaction = .idle
    var scene: Scene = .active
    var thermal: Thermal = .nominal
    var lowPower = false

    var cameraLive: Bool { camera != .off }
    var cameraPhotoMegapixels: Double {
        if case .live(let mp) = camera { mp } else { 0 }
    }

    /// The camera's part of `text`: "camera 48 MP, 1 in flight", or "camera off".
    var cameraText: String {
        cameraLive ? String(format: "camera %.0f MP", cameraPhotoMegapixels) + (capturesInFlight > 0 ? ", \(capturesInFlight) in flight" : "")
                   : "camera off"
    }

    /// One line for a job's record: "camera 48 MP, 1 in flight; active".
    var text: String {
        var parts = [cameraText]
        if case .dragging(let layer) = interaction { parts.append("dragging \(layer.rawValue)") }
        parts.append(scene.rawValue)
        if thermal > .nominal { parts.append("thermal \(thermal.rawValue)") }
        if lowPower { parts.append("low power") }
        return parts.joined(separator: "; ")
    }
}

/// One thing to render.
struct RenderJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let frameID: UUID
    let kind: JobKind
    let tier: RenderTier
    /// The canvas the engine will render: the picture's pixels at this tier.
    let canvas: PixelSize
    /// Which layers the edit touched. Empty is a first develop.
    let layers: Set<ParamLayer>
    /// What changed, as the status line says it: "Film Exp. +0.3".
    let what: String
    /// The original has to be decoded first (an export, an import, a shot):
    /// the decode's own buffer is part of what the job holds.
    let decodesOriginal: Bool
    /// The engine can render this frame in bands. It bands nothing that has a
    /// crop, a turn or a flip in its geometry — a band cannot read across rows
    /// the geometry moves — and renders such a frame whole whatever it is
    /// asked. So a job that is not bandable is planned whole, or waits.
    /// Measured before this was here: a cropped 48 MP frame planned as bands
    /// in a 1.5 GB budget ran whole, at 2.4 GB (EngineBench, 2026-10-03).
    let bandable: Bool
    /// The original's own size, for a job that decodes it to something smaller
    /// (`decodesOriginal` below the full tier: a shot or an import at preview
    /// size). The render is priced by the canvas; **the decode is priced by
    /// this**, because a decoder may hold the whole original while it makes
    /// the small frame — Core Image's open of a 2,400 px frame was 290-308 MB
    /// from a 12 MP photo and 438-588 MB from a 48 MP one (reference device). nil is
    /// priced as the canvas, which is right only for a decoder that never
    /// holds the original (ImageIO's reduced decode: 140-194 MB from either).
    ///
    /// For a full-size job it is the size of the decode, where that is more
    /// than the canvas: an export the host cuts decodes the whole picture for
    /// the part of it that is developed (`ExportPlan`).
    let original: PixelSize?
    /// How many more prints of its negative the job makes after its own, each
    /// cut into the result: a half-frame pair's frames that print as their
    /// own (`PrintLayer`), two at most. While one is made the job holds a
    /// second result beside its own, and each is a print pass more
    /// (`CostModel`). Not `layers`, which is what an edit touched.
    let printLayers: Int
    /// The frame the engine opens, where it is larger than the canvas on
    /// purpose: a stock's preview opens its picture at the meter's 1,600 px,
    /// so that the session meters what the page's develop meters (AGENTS.md:
    /// a preview size must not change the meter), and renders the live tier's
    /// smallest, 800 px. The source plane is priced by it, and an open of it
    /// is not another job's cost. Nil: the canvas.
    let opens: PixelSize?
    /// Which card of a strip the job is for: a newer job of the same kind,
    /// frame and slot replaces it, queued or running (`RenderQueue.submit`).
    let slot: String?
    let submitted: Date

    init(id: UUID = UUID(), frameID: UUID, kind: JobKind, tier: RenderTier, canvas: PixelSize,
         layers: Set<ParamLayer> = [], what: String = "", decodesOriginal: Bool = false, bandable: Bool = true,
         original: PixelSize? = nil, printLayers: Int = 0, opens: PixelSize? = nil, slot: String? = nil,
         submitted: Date = Date()) {
        self.id = id; self.frameID = frameID; self.kind = kind; self.tier = tier; self.canvas = canvas
        self.layers = layers; self.what = what; self.decodesOriginal = decodesOriginal; self.bandable = bandable
        self.original = original
        self.printLayers = max(printLayers, 0)
        self.opens = opens
        self.slot = slot
        self.submitted = submitted
    }

    /// A reprint reuses the cached negative; anything else develops it.
    var isReprint: Bool { kind == .canvasReprint }

    /// "Developing" or "Printing": the status line names the layer, so the user
    /// learns which edits are cheap without being told about layers.
    var verb: String { isReprint ? "Printing" : "Developing" }
}

/// The engine's stages, as `spk_progress` reports them and Exporting shows them.
enum RenderStage: String, CaseIterable, Codable, Sendable {
    case decode = "Decode", film = "Film", print = "Print", scan = "Scan", save = "Save"
}

/// Where a running job is.
struct RenderProgress: Equatable, Sendable {
    var stage: RenderStage
    /// 0…1 across the whole job. `spk_progress`'s `pct` climbs once across all
    /// bands, so a banded render's bar does not restart per band.
    var fraction: Double
    var band: Int = 0
    var bandCount: Int = 1
}

/// What a job looked like from outside, for the page.
struct JobSnapshot: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case waiting(WaitReason)
        case running(RenderProgress)
        case done
        case cancelled
        case failed(String)
    }
    let id: UUID
    let job: RenderJob
    var state: State
    var mode: RenderMode?
}

/// R8: every job is logged — mode, budget, predicted against measured peak and
/// time, waits and their reasons — enough to rebuild its schedule.
struct JobRecord: Codable, Equatable, Sendable {
    var jobID: UUID
    var kind: String
    var tier: String
    var megapixels: Double
    var mode: String
    var budgetBytes: UInt64
    var predictedPeakBytes: UInt64
    /// What the job was predicted to take from the host: its peak and its
    /// source plane. The measured side is `measurement`'s fall in headroom.
    var predictedPhoneBytes: UInt64?
    var measuredPeakBytes: UInt64?
    var predictedSeconds: Double
    var measuredSeconds: Double?
    var waits: [String]
    var outcome: String
    var at: Date
    /// What the engine did, which may not be what was asked: "whole", or
    /// "bands(1008) x 6, halo 656". Nil when the engine cannot say.
    var ran: String?
    /// The budget's two sides before the margin, which of them bound, and the
    /// camera's share of the host's side.
    var appSideBytes: UInt64?
    var phoneSideBytes: UInt64?
    var binding: String?
    var cameraReserveBytes: UInt64?
    /// The host as the plan read it, and the frontend as the plan saw it.
    var reading: MemoryReading?
    var frontend: String?
    /// What the render measured about itself. Nil from the simulated engine,
    /// and for a job that did not finish.
    var measurement: RunMeasurement?
    /// The size the engine rendered, when it is not the size the job asked for
    /// and was priced at ("3400x2550"). Smaller is the frame's own size and is
    /// allowed. **Larger means the plan's cost was for another picture**: a
    /// job below the full tier must be handed a frame no larger than its
    /// canvas (`FrameSource.decode`), or the engine renders its own tier — a
    /// shot asked for at 2,400 px came back 3,400 px, at 1.6 times the
    /// predicted peak (EngineBench, 2026-10-03).
    var renderedInstead: String?
    /// The size of the frame the host handed the engine to open, for a job
    /// below the full tier, when it is not the job's canvas ("8064x6048").
    /// Larger is the same fault, and the dearer half of it: the open of a
    /// photo is its decode beside its source plane, whatever is rendered from
    /// it.
    var openedInstead: String?
}

extension RenderJob {
    /// What to record when the engine rendered `size`: nil when it is the
    /// canvas (to the rounding of a scaled size), else the size it was.
    func renderedInstead(_ size: PixelSize) -> String? {
        abs(size.width - canvas.width) <= 2 && abs(size.height - canvas.height) <= 2 ? nil : "\(size.width)x\(size.height)"
    }

    /// The render is of more pixels than the job was priced for.
    func isOverAsked(_ size: PixelSize) -> Bool {
        renderedInstead(size) != nil && size.width * size.height > canvas.width * canvas.height
    }

    /// The frame the job was priced to open: `opens`, or the canvas.
    var pricedOpen: PixelSize { opens ?? canvas }

    /// What to record when the host handed the engine a frame of `size` to
    /// open: nil when it is the one priced (`pricedOpen`), to a rounding.
    func openedInstead(_ size: PixelSize) -> String? {
        let priced = pricedOpen
        return abs(size.width - priced.width) <= 2 && abs(size.height - priced.height) <= 2 ? nil : "\(size.width)x\(size.height)"
    }

    /// The frame opened is larger than the one priced: another job's cost.
    func isOverOpened(_ size: PixelSize) -> Bool {
        openedInstead(size) != nil && size.width * size.height > pricedOpen.width * pricedOpen.height
    }
}
