//! The webview's half of the scheduler: the JSON a Tauri layer passes through, as serde types.
//!
//! `WIRE.md` (beside this crate's `Cargo.toml`) is the prose of this file and is kept true with it.
//! Everything is camelCase; where a Swift type exists the Swift `Codable` names are kept (`jobID` in a
//! job record, `appAvailable` in a reading), so a job log reads the same on every platform. Job ids are
//! upper-case UUID strings, as Swift writes a `UUID`.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::budget::{Binding, MemoryBudget};
use crate::engine::RenderResult;
use crate::memory_probe::MemoryReading;
use crate::queue::JobOutcome;
use crate::types::{
    Camera, Composition, FrameId, FrontendState, Interaction, JobId, JobKind, JobSnapshot, ParamLayer, PixelSize,
    RenderJob, RenderStage, RenderTier, Scene, SnapshotState, Thermal, WaitReason,
};

fn yes() -> bool {
    true
}
fn one() -> i64 {
    1
}

/// `scheduler_submit(job)`: one thing to render, as the webview asks for it. The pricing fields are
/// `RenderJob`'s (see WIRE.md for what each changes); `request` is what the engine host is asked to run.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobSpec {
    pub frame_id: String,
    pub kind: JobKind,
    pub tier: RenderTier,
    pub canvas: PixelSize,
    #[serde(default)]
    pub layers: Vec<ParamLayer>,
    #[serde(default)]
    pub what: String,
    #[serde(default)]
    pub decodes_original: bool,
    #[serde(default = "yes")]
    pub bandable: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original: Option<PixelSize>,
    #[serde(default)]
    pub print_layers: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opens: Option<PixelSize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot: Option<String>,
    #[serde(default)]
    pub gain_map: bool,
    #[serde(default = "one")]
    pub gain_maps: i64,
    #[serde(default)]
    pub hdr_rendition: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub composition: Option<Composition>,
    #[serde(default)]
    pub raw_decode: bool,
    #[serde(default)]
    pub scene_planes: i64,
    #[serde(default)]
    pub scene_plane_bytes: u64,
    #[serde(default)]
    pub watermark_bytes: u64,
    /// What the engine host is asked to run for this job. Required by `HostEngine`; the simulated
    /// engine ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<JobRequest>,
}

/// The host calls a job is made of (HOST-PROTOCOL.md §3). `HostEngine` adds `session` and
/// `progress_id` itself and decides which session the call runs on (WIRE.md, "Sessions").
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobRequest {
    /// The frame a session is opened on, where the call needs one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceSpec>,
    /// A `set_params` delta sent to the session before the call (the legacy `render` flow).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub set_params: Option<Value>,
    /// `render_view`, `render`, `export_frame`, `export_cineon`, `render_proof`, `export_image`,
    /// `thumbnail`, `preview_stock_lut` or `render_source`.
    pub method: String,
    /// The call's own params, without `session` and `progress_id`.
    #[serde(default = "empty_object")]
    pub params: Value,
}

fn empty_object() -> Value {
    Value::Object(Default::default())
}

/// What a session is opened from: `open {path, decode?, params?}`, or `open_pair {path, pair, params}`
/// when `pair` is set.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceSpec {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decode: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pair: Option<Value>,
}

impl SourceSpec {
    /// What the session's pixels were made of: another decode or another pair recipe is other pixels.
    pub fn key(&self) -> String {
        serde_json::json!({"path": self.path, "decode": self.decode, "pair": self.pair}).to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubmitError(pub String);

impl std::fmt::Display for SubmitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for SubmitError {}

impl JobSpec {
    /// The job the queue runs. Refuses what the queue could not price.
    pub fn to_job(&self) -> Result<RenderJob, SubmitError> {
        if self.frame_id.is_empty() {
            return Err(SubmitError("frameId is empty".into()));
        }
        if self.canvas.width <= 0 || self.canvas.height <= 0 {
            return Err(SubmitError(format!("canvas {}x{} is not a picture", self.canvas.width, self.canvas.height)));
        }
        let mut job = RenderJob::new(FrameId::new(self.frame_id.clone()), self.kind, self.tier, self.canvas)
            .with_layers(&self.layers)
            .with_what(self.what.clone())
            .decoding(self.decodes_original)
            .with_bandable(self.bandable)
            .with_original(self.original)
            .with_print_layers(self.print_layers)
            .with_opens(self.opens)
            .with_slot(self.slot.clone())
            .with_gain_map(self.gain_map, self.gain_maps)
            .with_hdr_rendition(self.hdr_rendition)
            .with_raw_decode(self.raw_decode)
            .with_scene_planes(self.scene_planes, self.scene_plane_bytes)
            .with_request(self.request.clone().map(Arc::new));
        job.composition = self.composition.clone();
        job.watermark_bytes = self.watermark_bytes;
        Ok(job)
    }
}

/// A job's state on the wire, tagged by `state`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum JobStateWire {
    Queued,
    Waiting {
        reason: WaitReason,
        /// The words the page shows ("Waiting for memory").
        text: String,
    },
    #[serde(rename_all = "camelCase")]
    Running {
        stage: RenderStage,
        fraction: f64,
        band: i64,
        band_count: i64,
    },
    Done,
    Cancelled,
    Failed {
        message: String,
    },
}

impl From<&SnapshotState> for JobStateWire {
    fn from(s: &SnapshotState) -> Self {
        match s {
            SnapshotState::Queued => JobStateWire::Queued,
            SnapshotState::Waiting(r) => JobStateWire::Waiting { reason: *r, text: r.text().into() },
            SnapshotState::Running(p) => {
                JobStateWire::Running { stage: p.stage, fraction: p.fraction, band: p.band, band_count: p.band_count }
            }
            SnapshotState::Done => JobStateWire::Done,
            SnapshotState::Cancelled => JobStateWire::Cancelled,
            SnapshotState::Failed(m) => JobStateWire::Failed { message: m.clone() },
        }
    }
}

/// `scheduler_snapshot` rows and the `scheduler://job` event: a job as the page shows it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobSnapshotWire {
    pub job_id: JobId,
    pub frame_id: String,
    pub kind: JobKind,
    pub tier: RenderTier,
    pub canvas: PixelSize,
    pub what: String,
    /// "Developing" or "Printing".
    pub verb: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub slot: Option<String>,
    #[serde(flatten)]
    pub state: JobStateWire,
    /// The plan's mode: "whole", "bands(1008)", "wait(memory)"; null before the job is planned.
    pub mode: Option<String>,
}

impl From<&JobSnapshot> for JobSnapshotWire {
    fn from(s: &JobSnapshot) -> Self {
        JobSnapshotWire {
            job_id: s.id,
            frame_id: s.job.frame_id.0.clone(),
            kind: s.job.kind,
            tier: s.job.tier,
            canvas: s.job.canvas,
            what: s.job.what.clone(),
            verb: s.job.verb().into(),
            slot: s.job.slot.clone(),
            state: (&s.state).into(),
            mode: s.mode.map(|m| m.name()),
        }
    }
}

/// What a finished job made, without its pixels (they travel beside it as binary).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResultWire {
    pub seconds: f64,
    pub reprint: bool,
    /// The size the engine rendered.
    pub size: PixelSize,
    /// The host method that made it, and its reply's `result` (`image`, `timings_ms`, `path` …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_result: Option<Value>,
    /// Bytes of the binary payload that goes with this outcome (0: none, or already delivered).
    pub payload_bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutcomeKind {
    Finished,
    Cancelled,
    Failed,
}

/// `scheduler_outcome(jobId)`: how a job ended.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutcomeWire {
    pub job_id: JobId,
    pub outcome: OutcomeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<ResultWire>,
}

impl OutcomeWire {
    /// The outcome, and the payload to send beside it (empty when there is none).
    pub fn of(job_id: JobId, outcome: &JobOutcome) -> (OutcomeWire, Option<Arc<Vec<u8>>>) {
        match outcome {
            JobOutcome::Finished(r) => {
                let payload = r.delivery.as_ref().map(|d| d.payload.clone()).filter(|p| !p.is_empty());
                (
                    OutcomeWire {
                        job_id,
                        outcome: OutcomeKind::Finished,
                        message: None,
                        result: Some(ResultWire::of(r, payload.as_ref().map_or(0, |p| p.len() as u64))),
                    },
                    payload,
                )
            }
            JobOutcome::Cancelled => {
                (OutcomeWire { job_id, outcome: OutcomeKind::Cancelled, message: None, result: None }, None)
            }
            JobOutcome::Failed(m) => {
                (OutcomeWire { job_id, outcome: OutcomeKind::Failed, message: Some(m.clone()), result: None }, None)
            }
        }
    }
}

impl ResultWire {
    fn of(r: &RenderResult, payload_bytes: u64) -> Self {
        ResultWire {
            seconds: r.seconds,
            reprint: r.reprint,
            size: r.size,
            method: r.delivery.as_ref().map(|d| d.method.clone()),
            host_result: r.delivery.as_ref().map(|d| d.result.clone()),
            payload_bytes,
        }
    }
}

/// The budget's two sides (three on a PC with a GPU of its own), as Settings shows them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BudgetSidesWire {
    /// What a job may take at its peak: the tightest side, after the margin.
    pub bytes: u64,
    pub app_side: u64,
    pub phone_side: u64,
    pub app_bytes: u64,
    pub phone_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_side: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_bytes: Option<u64>,
    pub camera_reserve: u64,
    /// "allowance", "phone" or "gpu": which side bound.
    pub binding: Binding,
}

impl From<&MemoryBudget> for BudgetSidesWire {
    fn from(b: &MemoryBudget) -> Self {
        BudgetSidesWire {
            bytes: b.bytes,
            app_side: b.app_side,
            phone_side: b.phone_side,
            app_bytes: b.app_bytes,
            phone_bytes: b.phone_bytes,
            gpu_side: b.gpu_side,
            gpu_bytes: b.gpu_bytes,
            camera_reserve: b.camera_reserve,
            binding: b.binding,
        }
    }
}

/// `scheduler_budget()`: the budget a job would be given this instant, and what it was made from.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BudgetReadingWire {
    /// For a job nobody waits on.
    pub budget: BudgetSidesWire,
    /// For a job someone waits on (an edit, the zoom, an export), which counts on more of the host.
    pub asked: BudgetSidesWire,
    pub reading: MemoryReading,
    /// `FrontendState.text`: "camera off; active".
    pub frontend: String,
    pub engine: EngineWire,
    pub policy: PolicyWire,
    /// Jobs queued or running.
    pub jobs: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineWire {
    pub name: String,
    pub makes_pictures: bool,
    pub effect_versions: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PolicyWire {
    /// "mac" or "desktopPc".
    pub device: String,
    pub develop_cap_megapixels: f64,
    pub preview_long_edge: i64,
    pub preview_edges: Vec<i64>,
    pub time_ratio: f64,
    /// Every number of this policy that was not measured on this kind of machine.
    pub unmeasured: Vec<String>,
}

/// `scheduler_frontend_state(state)`: what the window is doing.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FrontendStateMsg {
    /// The page shown: "library", "develop", "edit", "export" … (recorded; no rule reads it).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visible_page: Option<String>,
    /// The frame open on the develop/edit page. When it changes, the engine closes the old frame's
    /// editing session (the Mac's `closeEditing`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_frame: Option<String>,
    /// The window has the user's focus (recorded; a desktop keeps rendering behind other windows).
    #[serde(default = "yes")]
    pub foreground: bool,
    /// The gate: anything but "active" holds every job (`WaitReason::Background`). A desktop sends
    /// "active" unless it wants the queue paused; default "active".
    #[serde(default)]
    pub scene: Scene,
    /// `{ "dragging": "shoot" | "print" }` while a pointer is on a slider; null when idle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction: Option<InteractionWire>,
    #[serde(default)]
    pub thermal: Thermal,
    #[serde(default)]
    pub low_power: bool,
    /// Phone rules only; a desktop never sends these.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub camera_photo_megapixels: Option<f64>,
    #[serde(default)]
    pub captures_in_flight: i64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InteractionWire {
    pub dragging: ParamLayer,
}

impl FrontendStateMsg {
    pub fn to_state(&self) -> FrontendState {
        FrontendState {
            camera: match self.camera_photo_megapixels {
                Some(mp) if mp > 0.0 => Camera::Live { photo_megapixels: mp },
                _ => Camera::Off,
            },
            captures_in_flight: self.captures_in_flight.max(0),
            interaction: self.interaction.map_or(Interaction::Idle, |i| Interaction::Dragging(i.dragging)),
            scene: self.scene,
            thermal: self.thermal,
            low_power: self.low_power,
        }
    }
}

/// `scheduler_memory_pressure(level)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PressureLevel {
    Warning,
    Critical,
}

/// `scheduler_cancel_frame(frameId, kinds?)`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelFrame {
    pub frame_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kinds: Option<Vec<JobKind>>,
}
