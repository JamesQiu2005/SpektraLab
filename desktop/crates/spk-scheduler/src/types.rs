//! The words the scheduler is written in (`SchedulerTypes.swift`).
//!
//! RFC-036: on a host short of memory, **memory decides whether a render finishes; speed only decides
//! when.** So every render goes through one scheduler. Before each job it asks how much memory the host
//! can spare at that moment, and picks the fastest way to render that fits: whole, in bands, in smaller
//! bands, or not yet.
//!
//! Nothing in this file touches a pixel or an operating-system call: it is the vocabulary, so the
//! planner and the queue can be tested on any machine.

use std::collections::BTreeSet;
use std::fmt;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::time::Instant;
use uuid::Uuid;

use crate::memory_probe::MemoryReading;

/// A job's identity (Swift `UUID`). Written upper-case on the wire, as Swift's `JSONEncoder` writes a
/// `UUID`, so a job log reads the same on every platform; read in either case.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Default)]
pub struct JobId(pub Uuid);

impl JobId {
    pub fn new() -> Self {
        JobId(Uuid::new_v4())
    }
}

impl fmt::Display for JobId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0.hyphenated().to_string().to_uppercase())
    }
}

impl fmt::Debug for JobId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl std::str::FromStr for JobId {
    type Err = uuid::Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Uuid::parse_str(s).map(JobId)
    }
}

impl Serialize for JobId {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for JobId {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let text = String::deserialize(d)?;
        text.parse().map_err(serde::de::Error::custom)
    }
}

/// A frame's identity. Swift's is a `UUID`; the desktop's frames are named by the webview (a library id
/// or a path), so here it is any string the submitter uses consistently.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Default)]
#[serde(transparent)]
pub struct FrameId(pub String);

impl FrameId {
    pub fn new(id: impl Into<String>) -> Self {
        FrameId(id.into())
    }
    /// A fresh one, as `UUID()` makes in the selftest.
    pub fn random() -> Self {
        FrameId(Uuid::new_v4().hyphenated().to_string().to_uppercase())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for FrameId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for FrameId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// `PixelSize` (Format.swift).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
pub struct PixelSize {
    pub width: i64,
    pub height: i64,
}

impl PixelSize {
    pub const fn new(width: i64, height: i64) -> Self {
        PixelSize { width, height }
    }
    pub fn megapixels(&self) -> f64 {
        self.width as f64 * self.height as f64 / 1_000_000.0
    }
    pub fn long_edge(&self) -> i64 {
        self.width.max(self.height)
    }
    pub fn short_edge(&self) -> i64 {
        self.width.min(self.height)
    }
    pub fn pixels(&self) -> f64 {
        self.width as f64 * self.height as f64
    }
    /// The same shape with this long edge (never larger than this).
    pub fn scaled_to_long_edge(&self, edge: i64) -> PixelSize {
        if !(self.long_edge() > edge && edge > 0) {
            return *self;
        }
        let s = edge as f64 / self.long_edge() as f64;
        PixelSize::new((self.width as f64 * s).round() as i64, (self.height as f64 * s).round() as i64)
    }
    /// "3400x2550", as a record writes a size.
    pub fn text(&self) -> String {
        format!("{}x{}", self.width, self.height)
    }
}

/// `ParamLayer` (FilmParams.swift): which side of the darkroom an edit touched.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ParamLayer {
    Shoot,
    Print,
}

impl ParamLayer {
    pub fn raw_value(&self) -> &'static str {
        match self {
            ParamLayer::Shoot => "shoot",
            ParamLayer::Print => "print",
        }
    }
}

/// The engine's three tiers (API-SPEC §6), by their wire names.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RenderTier {
    /// The canvas while editing.
    Live,
    /// The frame's preview copy: what the library and the develop page show.
    Preview,
    /// The export, from the original.
    Full,
}

impl RenderTier {
    pub fn raw_value(&self) -> &'static str {
        match self {
            RenderTier::Live => "live",
            RenderTier::Preview => "preview",
            RenderTier::Full => "full",
        }
    }
}

/// Who asked, which is the job's priority (RFC-036 §5). Lower runs first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobKind {
    /// A print-side edit on the canvas: a reprint from the cached negative.
    CanvasReprint,
    /// A film-side edit on the canvas: the negative develops again.
    CanvasDevelop,
    /// The shot just taken, developed behind the viewfinder at preview size (phone rules; a desktop
    /// never submits one).
    Shot,
    /// A frame that just arrived by import, developed at preview size.
    ImportDevelop,
    /// A full-size develop, from the original, for a file.
    Export,
    /// A full-size develop for the develop page's zoom.
    FullView,
    /// A library thumbnail.
    Thumbnail,
    /// A card of Develop's film and paper strips. The last of all: it starts only when nothing else is
    /// queued and gives way at once to anything. Coalesced by its `slot`.
    StockPreview,
}

impl JobKind {
    pub const ALL: [JobKind; 8] = [
        JobKind::CanvasReprint,
        JobKind::CanvasDevelop,
        JobKind::Shot,
        JobKind::ImportDevelop,
        JobKind::Export,
        JobKind::FullView,
        JobKind::Thumbnail,
        JobKind::StockPreview,
    ];

    pub fn priority(&self) -> i32 {
        match self {
            JobKind::CanvasReprint | JobKind::CanvasDevelop => 1,
            JobKind::Shot => 2,
            JobKind::Export | JobKind::FullView => 3,
            // The page's own cards before the library's develops of other frames (2026-10-21).
            JobKind::StockPreview => 4,
            JobKind::ImportDevelop => 5,
            JobKind::Thumbnail => 6,
        }
    }

    pub fn is_canvas(&self) -> bool {
        matches!(self, JobKind::CanvasReprint | JobKind::CanvasDevelop)
    }

    /// A job someone is looking at the screen for: an edit on the develop page, the full-size zoom, an
    /// export. Planned against more of the host; the app gives back what it holds before it waits.
    pub fn is_asked(&self) -> bool {
        self.is_canvas() || matches!(self, JobKind::FullView | JobKind::Export)
    }

    pub fn raw_value(&self) -> &'static str {
        match self {
            JobKind::CanvasReprint => "canvasReprint",
            JobKind::CanvasDevelop => "canvasDevelop",
            JobKind::Shot => "shot",
            JobKind::ImportDevelop => "importDevelop",
            JobKind::Export => "export",
            JobKind::FullView => "fullView",
            JobKind::Thumbnail => "thumbnail",
            JobKind::StockPreview => "stockPreview",
        }
    }
}

/// Why a job is not running, in the words the page shows (RFC-036 §3.5).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WaitReason {
    /// Nothing fits in what the host can spare right now.
    Memory,
    /// The camera holds the memory this size needs.
    Camera,
    /// A photo is being taken: everything holds until it lands.
    Capture,
    /// GPU work is refused in the background.
    Background,
    /// Something more urgent is running.
    Queued,
}

impl WaitReason {
    pub fn raw_value(&self) -> &'static str {
        match self {
            WaitReason::Memory => "memory",
            WaitReason::Camera => "camera",
            WaitReason::Capture => "capture",
            WaitReason::Background => "background",
            WaitReason::Queued => "queued",
        }
    }
    pub fn text(&self) -> &'static str {
        match self {
            WaitReason::Memory => "Waiting for memory",
            WaitReason::Camera => "Waiting for the camera to free memory",
            WaitReason::Capture => "Waiting for the photo to land",
            WaitReason::Background => "Paused — app in the background",
            WaitReason::Queued => "Waiting its turn",
        }
    }
}

/// What a photo in flight does to a develop below the full tier (phone rules, kept so the queue's
/// logic is the Swift's).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CaptureRule {
    /// The running develop stops (a cancel and a run again), and nothing starts until the photo lands.
    Stops,
    /// The running develop finishes; nothing new starts until the photo lands.
    Holds,
    /// A develop starts whenever the budget has room, keeping aside every capture in flight and one more.
    Shares,
}

/// How a job renders. The mode changes how long a render takes, never what it computes (RFC-036 G3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RenderMode {
    /// M0: the whole frame at once.
    Whole,
    /// M1…Mk: bands of this many rows.
    Bands { rows: i64 },
    /// W: no render; the job keeps its place and states its reason.
    Wait(WaitReason),
}

impl RenderMode {
    pub fn name(&self) -> String {
        match self {
            RenderMode::Whole => "whole".into(),
            RenderMode::Bands { rows } => format!("bands({rows})"),
            RenderMode::Wait(why) => format!("wait({})", why.raw_value()),
        }
    }
    pub fn is_wait(&self) -> bool {
        matches!(self, RenderMode::Wait(_))
    }
}

/// The camera, as the frontend states it.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub enum Camera {
    #[default]
    Off,
    /// The session is running, with photos of this many megapixels.
    Live { photo_megapixels: f64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Interaction {
    #[default]
    Idle,
    /// A finger (a pointer) is on a control of this layer.
    Dragging(ParamLayer),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Scene {
    #[default]
    Active,
    Inactive,
    Background,
}

impl Scene {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Scene::Active => "active",
            Scene::Inactive => "inactive",
            Scene::Background => "background",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Thermal {
    #[default]
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl Thermal {
    pub fn raw_value(&self) -> i32 {
        match self {
            Thermal::Nominal => 0,
            Thermal::Fair => 1,
            Thermal::Serious => 2,
            Thermal::Critical => 3,
        }
    }
}

/// What the frontend is doing, because that is where the memory goes (RFC-036 §6.2, §6.7).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct FrontendState {
    pub camera: Camera,
    /// Photos taken and not yet delivered.
    pub captures_in_flight: i64,
    pub interaction: Interaction,
    pub scene: Scene,
    pub thermal: Thermal,
    pub low_power: bool,
}

impl FrontendState {
    pub fn camera_live(&self) -> bool {
        self.camera != Camera::Off
    }
    pub fn camera_photo_megapixels(&self) -> f64 {
        match self.camera {
            Camera::Live { photo_megapixels } => photo_megapixels,
            Camera::Off => 0.0,
        }
    }
    /// "camera 48 MP, 1 in flight", or "camera off".
    pub fn camera_text(&self) -> String {
        if self.camera_live() {
            let mut s = format!("camera {:.0} MP", self.camera_photo_megapixels());
            if self.captures_in_flight > 0 {
                s += &format!(", {} in flight", self.captures_in_flight);
            }
            s
        } else {
            "camera off".into()
        }
    }
    /// One line for a job's record: "camera 48 MP, 1 in flight; active".
    pub fn text(&self) -> String {
        let mut parts = vec![self.camera_text()];
        if let Interaction::Dragging(layer) = self.interaction {
            parts.push(format!("dragging {}", layer.raw_value()));
        }
        parts.push(self.scene.raw_value().into());
        if self.thermal > Thermal::Nominal {
            parts.push(format!("thermal {}", self.thermal.raw_value()));
        }
        if self.low_power {
            parts.push("low power".into());
        }
        parts.join("; ")
    }
}

/// What a composed open decodes, as the cost model prices it (`RenderJob.Composition`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Composition {
    /// The size each picture's decode is priced by, in the order they are decoded.
    pub decodes: Vec<PixelSize>,
    /// The scratch band the pictures are rendered into, held beside the piece through the open.
    pub scratch_bytes: u64,
    /// Whether any of its pictures is a RAW (priced dearer below the full tier, learned apart).
    #[serde(default)]
    pub raw: bool,
}

impl Composition {
    /// **The size one picture's decode is priced by**: below the full tier the original; at the full
    /// tier decoded whole its own size; made smaller, a RAW still its own size (Core Image decodes it
    /// whole and scales after), anything else the size it is made at.
    pub fn decode(
        tier: RenderTier,
        own: PixelSize,
        original: PixelSize,
        long_edge: Option<i64>,
        is_raw: bool,
    ) -> PixelSize {
        if tier != RenderTier::Full {
            return original;
        }
        match long_edge {
            Some(edge) if edge < own.long_edge() && !is_raw => own.scaled_to_long_edge(edge),
            _ => own,
        }
    }
}

/// One thing to render (`RenderJob`). Field for field the Swift's, plus `request`: what the submitter
/// asks the engine to run (the host calls), which the Mac keeps in its `FrameSource` instead.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderJob {
    pub id: JobId,
    pub frame_id: FrameId,
    pub kind: JobKind,
    pub tier: RenderTier,
    /// The canvas the engine will render: the picture's pixels at this tier.
    pub canvas: PixelSize,
    /// Which layers the edit touched. Empty is a first develop.
    pub layers: BTreeSet<ParamLayer>,
    /// What changed, as the status line says it: "Film Exp. +0.3".
    pub what: String,
    /// The original has to be decoded first: the decode's own buffer is part of what the job holds.
    pub decodes_original: bool,
    /// The engine can render this frame in bands. A job that is not bandable is planned whole, or waits.
    pub bandable: bool,
    /// The original's own size, for a job that decodes it to something smaller (the decode is priced by
    /// this); for a full-size job the size of the decode where it is more than the canvas.
    pub original: Option<PixelSize>,
    /// How many more prints of its negative the job makes after its own, each cut into the result.
    pub print_layers: i64,
    /// The frame the engine opens, where it is larger than the canvas on purpose. Nil: the canvas.
    pub opens: Option<PixelSize>,
    /// Which card of a strip the job is for: a newer job of the same kind, frame and slot replaces it.
    pub slot: Option<String>,
    /// An export whose file carries a gain map.
    pub gain_map: bool,
    /// How many copies of the map its delivery holds.
    pub gain_maps: i64,
    /// A slide's HDR rendition: the frame rendered a second time beside the first.
    pub hdr_rendition: bool,
    /// A frame the host composes from more than one decode before the engine opens it.
    pub composition: Option<Composition>,
    /// A photograph's open below the full tier decodes a RAW file itself (no proxy to read).
    pub raw_decode: bool,
    /// Scene layers the job hands the engine, and their planes' bytes.
    pub scene_planes: i64,
    pub scene_plane_bytes: u64,
    /// What the job's watermark pass holds beside its source. Set at submit by the `marks` hook.
    pub watermark_bytes: u64,
    /// When it was submitted, on the queue's clock (tokio time: virtual in tests).
    pub submitted: Instant,
    /// What the engine is asked to run for it (`HostEngine`); ignored by the simulated engine.
    pub request: Option<Arc<crate::wire::JobRequest>>,
}

impl RenderJob {
    /// Swift's `init` with every default.
    pub fn new(frame_id: FrameId, kind: JobKind, tier: RenderTier, canvas: PixelSize) -> Self {
        RenderJob {
            id: JobId::new(),
            frame_id,
            kind,
            tier,
            canvas,
            layers: BTreeSet::new(),
            what: String::new(),
            decodes_original: false,
            bandable: true,
            original: None,
            print_layers: 0,
            opens: None,
            slot: None,
            gain_map: false,
            gain_maps: 1,
            hdr_rendition: false,
            composition: None,
            raw_decode: false,
            scene_planes: 0,
            scene_plane_bytes: 0,
            watermark_bytes: 0,
            submitted: Instant::now(),
            request: None,
        }
    }

    pub fn with_layers(mut self, layers: &[ParamLayer]) -> Self {
        self.layers = layers.iter().copied().collect();
        self
    }
    pub fn with_what(mut self, what: impl Into<String>) -> Self {
        self.what = what.into();
        self
    }
    pub fn decoding(mut self, decodes: bool) -> Self {
        self.decodes_original = decodes;
        self
    }
    pub fn with_bandable(mut self, bandable: bool) -> Self {
        self.bandable = bandable;
        self
    }
    pub fn with_original(mut self, original: Option<PixelSize>) -> Self {
        self.original = original;
        self
    }
    /// Never fewer than none (`max(printLayers, 0)`).
    pub fn with_print_layers(mut self, n: i64) -> Self {
        self.print_layers = n.max(0);
        self
    }
    pub fn with_opens(mut self, opens: Option<PixelSize>) -> Self {
        self.opens = opens;
        self
    }
    pub fn with_slot(mut self, slot: Option<String>) -> Self {
        self.slot = slot;
        self
    }
    pub fn with_gain_map(mut self, gain_map: bool, maps: i64) -> Self {
        self.gain_map = gain_map;
        self.gain_maps = maps;
        self
    }
    pub fn with_hdr_rendition(mut self, hdr: bool) -> Self {
        self.hdr_rendition = hdr;
        self
    }
    pub fn with_raw_decode(mut self, raw: bool) -> Self {
        self.raw_decode = raw;
        self
    }
    /// Never fewer than none (`max(scenePlanes, 0)`).
    pub fn with_scene_planes(mut self, planes: i64, bytes: u64) -> Self {
        self.scene_planes = planes.max(0);
        self.scene_plane_bytes = bytes;
        self
    }
    pub fn with_request(mut self, request: Option<Arc<crate::wire::JobRequest>>) -> Self {
        self.request = request;
        self
    }

    /// The same job, its open composed of these decodes.
    pub fn composed(&self, composition: Option<Composition>) -> RenderJob {
        let mut out = self.clone();
        out.composition = composition;
        out
    }
    /// The same job, its watermark pass priced at `bytes`.
    pub fn marked(&self, bytes: u64) -> RenderJob {
        let mut out = self.clone();
        out.watermark_bytes = bytes;
        out
    }

    /// A reprint reuses the cached negative; anything else develops it.
    pub fn is_reprint(&self) -> bool {
        self.kind == JobKind::CanvasReprint
    }
    /// "Developing" or "Printing".
    pub fn verb(&self) -> &'static str {
        if self.is_reprint() {
            "Printing"
        } else {
            "Developing"
        }
    }

    /// What to record when the engine rendered `size`: nil when it is the canvas (to the rounding of a
    /// scaled size), else the size it was.
    pub fn rendered_instead(&self, size: PixelSize) -> Option<String> {
        if (size.width - self.canvas.width).abs() <= 2 && (size.height - self.canvas.height).abs() <= 2 {
            None
        } else {
            Some(size.text())
        }
    }
    /// The render is of more pixels than the job was priced for.
    pub fn is_over_asked(&self, size: PixelSize) -> bool {
        self.rendered_instead(size).is_some() && size.width * size.height > self.canvas.width * self.canvas.height
    }
    /// The frame the job was priced to open: `opens`, or the canvas.
    pub fn priced_open(&self) -> PixelSize {
        self.opens.unwrap_or(self.canvas)
    }
    pub fn opened_instead(&self, size: PixelSize) -> Option<String> {
        let priced = self.priced_open();
        if (size.width - priced.width).abs() <= 2 && (size.height - priced.height).abs() <= 2 {
            None
        } else {
            Some(size.text())
        }
    }
    /// The frame opened is larger than the one priced: another job's cost.
    pub fn is_over_opened(&self, size: PixelSize) -> bool {
        let priced = self.priced_open();
        self.opened_instead(size).is_some() && size.width * size.height > priced.width * priced.height
    }
}

/// The engine's stages, as Exporting shows them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RenderStage {
    Decode,
    Film,
    Print,
    Scan,
    Save,
}

impl RenderStage {
    pub fn raw_value(&self) -> &'static str {
        match self {
            RenderStage::Decode => "Decode",
            RenderStage::Film => "Film",
            RenderStage::Print => "Print",
            RenderStage::Scan => "Scan",
            RenderStage::Save => "Save",
        }
    }
}

/// Where a running job is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RenderProgress {
    pub stage: RenderStage,
    /// 0…1 across the whole job.
    pub fraction: f64,
    pub band: i64,
    pub band_count: i64,
}

impl RenderProgress {
    pub fn new(stage: RenderStage, fraction: f64) -> Self {
        RenderProgress { stage, fraction, band: 0, band_count: 1 }
    }
}

/// A job's state, from outside (`JobSnapshot.State`).
#[derive(Clone, Debug, PartialEq)]
pub enum SnapshotState {
    Queued,
    Waiting(WaitReason),
    Running(RenderProgress),
    Done,
    Cancelled,
    Failed(String),
}

/// What a job looked like from outside, for the page.
#[derive(Clone, Debug, PartialEq)]
pub struct JobSnapshot {
    pub id: JobId,
    pub job: RenderJob,
    pub state: SnapshotState,
    pub mode: Option<RenderMode>,
}

impl JobSnapshot {
    pub fn is_running(&self) -> bool {
        matches!(self.state, SnapshotState::Running(_))
    }
}

/// The bands the engine cut (`BandsRan`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BandsRan {
    pub rows: i64,
    pub count: i64,
    /// The rows a band reads below its interior.
    pub halo: i64,
}

/// What a real render measured about itself (`RunMeasurement`). Bytes; seconds. The keys are the
/// Swift's, so a record reads the same on every platform.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RunMeasurement {
    pub footprint_before: u64,
    pub peak_footprint: u64,
    pub open_peak_footprint: u64,
    pub idle_pool_before: u64,
    pub pool_high_water: u64,
    pub from_rest: bool,
    pub engine_held_after: u64,
    pub decode_seconds: f64,
    pub open_seconds: f64,
    pub render_seconds: f64,
    pub deliver_seconds: f64,
    pub phone_headroom_before: u64,
    pub lowest_phone_headroom: u64,
    pub lowest_phone_free: u64,
    pub highest_wired: u64,
    pub lowest_app_available: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node_milliseconds: Option<std::collections::BTreeMap<String, f64>>,
    #[serde(rename = "autoExposureEV", default, skip_serializing_if = "Option::is_none")]
    pub auto_exposure_ev: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened: Option<PixelSize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer_seconds: Option<Vec<f64>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decoded_by: Option<String>,
}

/// ISO-8601 to the second, as Swift's `.iso8601` date strategy writes it ("2026-11-17T10:19:00Z").
pub mod iso8601 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(at: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&at.to_rfc3339_opts(SecondsFormat::Secs, true))
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&text).map(|t| t.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

/// R8: every job is logged — mode, budget, predicted against measured peak and time, waits and their
/// reasons — enough to rebuild its schedule. Field for field the Mac's `JobRecord`, with its keys.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JobRecord {
    #[serde(rename = "jobID")]
    pub job_id: JobId,
    pub kind: String,
    pub tier: String,
    pub megapixels: f64,
    pub mode: String,
    #[serde(rename = "budgetBytes")]
    pub budget_bytes: u64,
    #[serde(rename = "predictedPeakBytes")]
    pub predicted_peak_bytes: u64,
    #[serde(rename = "predictedPhoneBytes", default, skip_serializing_if = "Option::is_none")]
    pub predicted_phone_bytes: Option<u64>,
    #[serde(rename = "measuredPeakBytes", default, skip_serializing_if = "Option::is_none")]
    pub measured_peak_bytes: Option<u64>,
    #[serde(rename = "predictedSeconds")]
    pub predicted_seconds: f64,
    #[serde(rename = "measuredSeconds", default, skip_serializing_if = "Option::is_none")]
    pub measured_seconds: Option<f64>,
    pub waits: Vec<String>,
    pub outcome: String,
    #[serde(with = "iso8601")]
    pub at: chrono::DateTime<chrono::Utc>,
    /// What the engine did: "whole", or "bands(1008) x 6, halo 656". Nil when the engine cannot say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ran: Option<String>,
    #[serde(rename = "appSideBytes", default, skip_serializing_if = "Option::is_none")]
    pub app_side_bytes: Option<u64>,
    #[serde(rename = "phoneSideBytes", default, skip_serializing_if = "Option::is_none")]
    pub phone_side_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binding: Option<String>,
    #[serde(rename = "cameraReserveBytes", default, skip_serializing_if = "Option::is_none")]
    pub camera_reserve_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reading: Option<MemoryReading>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frontend: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub measurement: Option<RunMeasurement>,
    #[serde(rename = "renderedInstead", default, skip_serializing_if = "Option::is_none")]
    pub rendered_instead: Option<String>,
    #[serde(rename = "openedInstead", default, skip_serializing_if = "Option::is_none")]
    pub opened_instead: Option<String>,
}

/// `UInt64.megabytes`: megabytes (2^20), as every figure in RFC-035 and RFC-036.
pub fn megabytes(bytes: u64) -> f64 {
    bytes as f64 / 1_048_576.0
}

pub(crate) fn clamp(x: f64, lo: f64, hi: f64) -> f64 {
    x.max(lo).min(hi)
}
