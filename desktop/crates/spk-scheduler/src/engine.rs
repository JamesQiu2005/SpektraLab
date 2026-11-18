//! The seam between the scheduler and the engine (`DevelopEngine.swift`).
//!
//! The scheduler lives in the app because only the app knows the frontend; the engine stays a
//! deterministic executor (RFC-036 §6.1). This trait is everything the scheduler asks of it.
//!
//! | here | the Mac (C ABI) | `HostEngine` (HOST-PROTOCOL.md) |
//! |---|---|---|
//! | `run` | `spk_render` / `spk_reprint` | `open`/`redecode`, `set_params`, the job's call (`render_view`, `export_frame`, `thumbnail` …), `close` |
//! | `run` in `Bands` | rendered whole | rendered whole, recorded as such |
//! | `progress` | the stages the conformer passes | the host's `progress` events |
//! | `cancel` | `spk_cancel` | `cancel {session, progress_id}` |
//! | `trim` | `spk_trim_pool` | `trim` (additive, W1) |
//! | `held_bytes` | `spk_memory_report.total_bytes` | `memory_report.total_bytes` |
//! | `effect_versions` | `capabilities.backend.effect_versions` | the same, else the engine's build stamp |

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use crate::types::{BandsRan, FrameId, JobId, PixelSize, RenderJob, RenderMode, RenderProgress, RunMeasurement};

/// What the host handed back for a job: its reply's `result` and binary payload, for the submitter.
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    /// The host method that made it.
    pub method: String,
    /// The reply's `result`, verbatim.
    pub result: Value,
    /// The reply's binary payload (pixels, an encoded thumbnail); empty for a file export.
    pub payload: Arc<Vec<u8>>,
}

/// `RenderResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderResult {
    /// Decode, open and render. The save is the host's and is not counted.
    pub seconds: f64,
    /// The job's measured peak over the engine's resting footprint; 0 when the engine cannot say.
    pub peak_bytes: u64,
    /// The cached negative was reused.
    pub reprint: bool,
    /// The size that was rendered.
    pub size: PixelSize,
    /// What the engine cut; `None` when it rendered the frame whole.
    pub bands: Option<BandsRan>,
    /// `None` from the simulated engine.
    pub measured: Option<RunMeasurement>,
    /// What the submitter gets: `None` from the simulated engine, which makes no picture.
    pub delivery: Option<Delivery>,
}

impl RenderResult {
    pub fn new(seconds: f64, size: PixelSize, reprint: bool) -> Self {
        RenderResult { seconds, peak_bytes: 0, reprint, size, bands: None, measured: None, delivery: None }
    }
}

/// `EngineError`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineError {
    /// `SPK_ERR_CANCELLED`; the host's `cancelled`.
    Cancelled,
    /// Out of memory, image too large: `SPK_ERR_RESOURCE`, which the host reports as `engine_error`.
    Resource(String),
    Failed(String),
}

impl EngineError {
    pub fn message(&self) -> String {
        match self {
            EngineError::Cancelled => "cancelled".into(),
            EngineError::Resource(m) | EngineError::Failed(m) => m.clone(),
        }
    }
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for EngineError {}

/// Called with a job's progress, from any thread.
pub type ProgressFn = Arc<dyn Fn(RenderProgress) + Send + Sync>;

/// `DevelopEngine`.
#[async_trait]
pub trait DevelopEngine: Send + Sync {
    /// "simulated" or the engine's build stamp, for Settings and for the log.
    fn name(&self) -> String;
    /// Whether a render here makes a picture. The simulated engine makes none.
    fn makes_pictures(&self) -> bool {
        true
    }
    /// Part of any cache key built from a render.
    fn effect_versions(&self) -> String;

    /// Render one job in one mode. `Err(Cancelled)` when `cancel` reached it.
    async fn run(&self, job: &RenderJob, mode: &RenderMode, progress: ProgressFn) -> Result<RenderResult, EngineError>;

    /// Safe from any thread while `run` is in flight.
    fn cancel(&self, job_id: JobId);

    /// Give back every pooled buffer that is free and idle. Returns the bytes freed.
    async fn trim(&self) -> u64;

    /// What the engine holds now: pool plus persistent.
    async fn held_bytes(&self) -> u64;

    /// More than `trim`, for a job someone waits on: the editing session closes too — unless it is
    /// `keeping`'s — then the pool is trimmed.
    async fn reclaim(&self, keeping: Option<&FrameId>) -> u64 {
        let _ = keeping;
        self.trim().await
    }

    /// The frame's page closed (or another opened): its editing session goes. `None`: whichever is open.
    /// The Mac's `SpkEngine.closeEditing`, which is not on its protocol; here so the facade can ask any
    /// engine. Nothing for an engine that keeps no session.
    async fn close_editing(&self, frame: Option<&FrameId>) {
        let _ = frame;
    }
}
