//! `HostEngine`: the scheduler's `DevelopEngine` over the v1 host (HOST-PROTOCOL.md §3).
//!
//! The model is the Mac's `SpkEngine` (not ported line by line: that one drives the C ABI in process):
//!
//! - **The sessions are the engine's.** A canvas job runs on the frame's *editing* session, kept open
//!   between canvas jobs so a print-side edit reprints from the cached negative; one editing session at
//!   a time. Every other job is *one-shot*: its session is its own and goes when the job ends, however
//!   it ends (`SpkEngine.oneShot = tier == .full || !kind.isCanvas`). `export_frame`, `export_cineon` and
//!   `render_proof` need none at all: the host opens a private session from `source_path`.
//! - **Same frame, other pixels**: another `decode` is a `redecode` in place; another path or pair
//!   recipe is opened again (`SpkEngine.sourceKey`).
//! - **A cancel that arrives before the call is not lost**: it is kept here and the call is never sent;
//!   one that arrives during the call is forwarded as `cancel {session, progress_id}`. A call that takes
//!   no `progress_id` (`thumbnail`, `preview_stock_lut`) cannot be stopped: it finishes and its result is
//!   thrown away, and the job ends cancelled.
//! - **Bands**: the v1 host renders whole frames; a banded plan is run whole and recorded as such.
//! - **Measurements**: the host reports timings and the engine's ledger (`memory_report`), not a
//!   process footprint, so a job's measured peak is 0 (the cost model's peak is left alone) and its time
//!   is the host call's.

use std::collections::HashSet;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Map, Value};
use tokio::task::JoinHandle;

use super::{HostError, HostLink};
use crate::cost_model::BandGeometry;
use crate::device_policy::GpuMemory;
use crate::engine::{Delivery, DevelopEngine, EngineError, ProgressFn, RenderResult};
use crate::types::{
    FrameId, JobId, PixelSize, RenderJob, RenderMode, RenderProgress, RenderStage, RenderTier, RunMeasurement,
};
use crate::wire::{JobRequest, SourceSpec};

/// Calls that run on a session the engine provides.
const SESSION_METHODS: &[&str] = &[
    "render_view",
    "render",
    "export_image",
    "export_di",
    "preview_stock_lut",
    "render_source",
    "scene_latitude",
    "overscan_geometry",
];
/// Calls that open a private session from `source_path` when they are given none.
const PRIVATE_SESSION_METHODS: &[&str] = &["export_frame", "export_cineon", "render_proof"];
/// Calls that take no session.
const SESSIONLESS_METHODS: &[&str] = &["thumbnail", "write_image", "export_cube", "probe"];
/// Calls that carry a `progress_id`, and so can be cancelled while they run.
const PROGRESS_METHODS: &[&str] =
    &["render_view", "render", "export_frame", "export_cineon", "export_image", "render_proof"];
/// Calls that read a session without changing it: they may borrow the editing session.
const BORROWING_METHODS: &[&str] = &["preview_stock_lut", "render_source"];

struct Editing {
    frame: FrameId,
    session: String,
    key: String,
    source: SourceSpec,
}

#[derive(Default)]
struct Sessions {
    editing: Option<Editing>,
}

struct InFlight {
    job: JobId,
    session: String,
    progress_id: Option<String>,
}

#[derive(Default)]
struct Cancels {
    cancelled: HashSet<JobId>,
    in_flight: Option<InFlight>,
}

pub struct HostEngine {
    link: Arc<dyn HostLink>,
    name: String,
    effect_versions: String,
    methods: HashSet<String>,
    gpu: GpuMemory,
    hello: Value,
    /// Every call that touches a session, one job at a time (the Mac's `work` queue).
    sessions: tokio::sync::Mutex<Sessions>,
    cancels: Mutex<Cancels>,
    held: AtomicU64,
    runtime: tokio::runtime::Handle,
}

/// The host's error code and message, as the scheduler's error (PRD-W1 R5).
pub fn engine_error(code: &str, message: &str) -> EngineError {
    match code {
        "cancelled" => EngineError::Cancelled,
        // SPK_ERR_RESOURCE (out of memory, image too large) reaches the wire as `engine_error`.
        "engine_error" => EngineError::Resource(format!("engine_error: {message}")),
        "internal" if message.contains("out of memory") => EngineError::Resource(format!("internal: {message}")),
        _ => EngineError::Failed(format!("{code}: {message}")),
    }
}

fn link_error(e: &HostError) -> EngineError {
    EngineError::Failed(format!("{}: {}", e.code, e.message))
}

fn link_died(e: &HostError) -> bool {
    matches!(e.code.as_str(), "host_exited" | "not_running")
}

/// How long a call may take before the link gives up (the webview's own timeouts, `host/client.ts`).
fn timeout_for(method: &str, tier: RenderTier) -> Duration {
    Duration::from_secs(match method {
        "open" | "redecode" => 300,
        "open_pair" | "update_pair" => 600,
        "render_view" | "render" if tier == RenderTier::Full => 900,
        "render_view" | "render" | "preview_stock_lut" | "render_source" => 180,
        "export_frame" | "export_cineon" | "render_proof" | "export_image" | "export_di" | "write_image" => 1800,
        "thumbnail" => 120,
        _ => 30,
    })
}

fn ms(v: &Value) -> f64 {
    v.as_f64().unwrap_or(0.0) / 1000.0
}

/// A reply as the engine reads it: its `result` and payload, or the host's error.
enum Answer {
    Ok(Value, Vec<u8>),
    Refused(String, String),
}

impl HostEngine {
    /// Say `hello` and read what this host is.
    pub async fn connect(link: Arc<dyn HostLink>) -> Result<HostEngine, EngineError> {
        let (header, _) =
            link.request("hello", json!({}), Vec::new(), Duration::from_secs(45)).await.map_err(|e| link_error(&e))?;
        if header["ok"] != json!(true) {
            return Err(engine_error(
                header["error"]["code"].as_str().unwrap_or("internal"),
                header["error"]["message"].as_str().unwrap_or("hello refused"),
            ));
        }
        let hello = header["result"].clone();
        let caps = &hello["capabilities"];
        let build = hello["build_info"].as_str().or(caps["version"].as_str()).unwrap_or("unknown").to_string();
        let name = format!("spektralab-host {} ({build})", hello["host_version"].as_str().unwrap_or("?"));
        // The v1 engine has no `backend.effect_versions`: its build stamp stands in, so two engines
        // that may render differently never share a cache key.
        let effect_versions =
            caps["backend"]["effect_versions"].as_str().map(str::to_string).unwrap_or_else(|| format!("build={build}"));
        let methods = hello["methods"]
            .as_array()
            .map(|m| m.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        Ok(HostEngine {
            link,
            name,
            effect_versions,
            methods,
            gpu: GpuMemory::from_hello(&hello),
            hello,
            sessions: tokio::sync::Mutex::new(Sessions::default()),
            cancels: Mutex::new(Cancels::default()),
            held: AtomicU64::new(0),
            runtime: tokio::runtime::Handle::current(),
        })
    }

    /// The host's `hello` reply.
    pub fn hello(&self) -> &Value {
        &self.hello
    }

    /// What `hello` said of the GPU's memory (`Unknown` for every v1 host).
    pub fn gpu_memory(&self) -> GpuMemory {
        self.gpu
    }

    /// `memory_report.total_bytes` as last read: after every job and every `held_bytes`. Cheap, for a
    /// memory probe that composes the GPU side (`DevicePolicy::gpu_available`).
    pub fn held_bytes_cached(&self) -> u64 {
        self.held.load(Ordering::SeqCst)
    }

    /// The frame whose session is open between canvas jobs, if any.
    pub async fn editing_frame(&self) -> Option<FrameId> {
        self.sessions.lock().await.editing.as_ref().map(|e| e.frame.clone())
    }

    async fn ask(&self, method: &str, params: Value, tier: RenderTier) -> Result<Answer, HostError> {
        let (header, payload) = self.link.request(method, params, Vec::new(), timeout_for(method, tier)).await?;
        if header["ok"] == json!(true) {
            Ok(Answer::Ok(header["result"].clone(), payload))
        } else {
            Ok(Answer::Refused(
                header["error"]["code"].as_str().unwrap_or("internal").to_string(),
                header["error"]["message"].as_str().unwrap_or("").to_string(),
            ))
        }
    }

    /// A request whose failure, of either kind, is the job's.
    async fn must(
        &self,
        sessions: &mut Sessions,
        method: &str,
        params: Value,
        tier: RenderTier,
    ) -> Result<(Value, Vec<u8>), EngineError> {
        match self.ask(method, params, tier).await {
            Ok(Answer::Ok(result, payload)) => Ok((result, payload)),
            Ok(Answer::Refused(code, message)) => Err(engine_error(&code, &message)),
            Err(e) => {
                if link_died(&e) {
                    sessions.editing = None;
                }
                Err(link_error(&e))
            }
        }
    }

    async fn close(&self, session: &str) {
        let _ = self
            .link
            .request("close", json!({"session": session}), Vec::new(), timeout_for("close", RenderTier::Live))
            .await;
    }

    async fn refresh_held(&self) -> Option<u64> {
        match self.ask("memory_report", json!({}), RenderTier::Live).await {
            Ok(Answer::Ok(result, _)) => {
                let held = result["total_bytes"].as_f64().unwrap_or(0.0).max(0.0) as u64;
                self.held.store(held, Ordering::SeqCst);
                Some(held)
            }
            _ => None,
        }
    }

    fn take_cancelled(&self, id: JobId) -> bool {
        self.cancels.lock().unwrap().cancelled.remove(&id)
    }

    fn is_cancelled(&self, id: JobId) -> bool {
        self.cancels.lock().unwrap().cancelled.contains(&id)
    }

    /// Open a session on `source`. Returns the session id and the size it decoded.
    async fn open(
        &self,
        sessions: &mut Sessions,
        source: &SourceSpec,
        tier: RenderTier,
    ) -> Result<(String, PixelSize, f64, f64), EngineError> {
        let (method, params) = match &source.pair {
            Some(pair) => (
                "open_pair",
                json!({"path": source.path, "pair": pair, "params": source.params.clone().unwrap_or_else(|| json!({}))}),
            ),
            None => {
                let mut p = Map::new();
                p.insert("path".into(), json!(source.path));
                if let Some(d) = &source.decode {
                    p.insert("decode".into(), d.clone());
                }
                if let Some(params) = &source.params {
                    p.insert("params".into(), params.clone());
                }
                ("open", Value::Object(p))
            }
        };
        let (result, _) = self.must(sessions, method, params, tier).await?;
        let session = result["session"]
            .as_str()
            .ok_or_else(|| EngineError::Failed(format!("{method}: no session in the reply")))?
            .to_string();
        let size = PixelSize::new(result["width"].as_i64().unwrap_or(0), result["height"].as_i64().unwrap_or(0));
        let t = &result["timings_ms"];
        Ok((session, size, ms(&t["decode"]), ms(&t["open"])))
    }
}

/// What a job's session turned out to be.
struct Placed {
    session: Option<String>,
    /// Ours alone: closed when the job ends.
    owned: bool,
    /// Opened for this job (not reused).
    fresh: bool,
    opened: Option<PixelSize>,
    decode_seconds: f64,
    open_seconds: f64,
}

impl HostEngine {
    async fn place(
        &self,
        sessions: &mut Sessions,
        job: &RenderJob,
        request: &JobRequest,
    ) -> Result<Placed, EngineError> {
        let method = request.method.as_str();
        let one_shot = job.tier == RenderTier::Full || !job.kind.is_canvas();
        let none =
            Placed { session: None, owned: false, fresh: false, opened: None, decode_seconds: 0.0, open_seconds: 0.0 };
        if SESSIONLESS_METHODS.contains(&method) || (PRIVATE_SESSION_METHODS.contains(&method) && one_shot) {
            return Ok(none);
        }
        if !SESSION_METHODS.contains(&method) && !PRIVATE_SESSION_METHODS.contains(&method) {
            return Err(EngineError::Failed(format!("{method} is not a call the scheduler runs")));
        }
        let source =
            request.source.as_ref().ok_or_else(|| EngineError::Failed(format!("{method} needs a source to open")))?;
        let key = source.key();
        let same = sessions.editing.as_ref().is_some_and(|e| e.frame == job.frame_id && e.key == key);
        if one_shot {
            if BORROWING_METHODS.contains(&method) && same {
                let session = sessions.editing.as_ref().unwrap().session.clone();
                return Ok(Placed { session: Some(session), ..none });
            }
            let (session, size, d, o) = self.open(sessions, source, job.tier).await?;
            return Ok(Placed {
                session: Some(session),
                owned: true,
                fresh: true,
                opened: Some(size),
                decode_seconds: d,
                open_seconds: o,
            });
        }
        // A canvas job: the editing session.
        if same {
            let session = sessions.editing.as_ref().unwrap().session.clone();
            return Ok(Placed { session: Some(session), ..none });
        }
        let redecode = sessions.editing.as_ref().is_some_and(|e| {
            e.frame == job.frame_id && e.source.path == source.path && e.source.pair.is_none() && source.pair.is_none()
        });
        if redecode {
            let session = sessions.editing.as_ref().unwrap().session.clone();
            let decode = source.decode.clone().unwrap_or_else(|| json!({}));
            match self.must(sessions, "redecode", json!({"session": session, "decode": decode}), job.tier).await {
                Ok((result, _)) => {
                    let size =
                        PixelSize::new(result["width"].as_i64().unwrap_or(0), result["height"].as_i64().unwrap_or(0));
                    let t = &result["timings_ms"];
                    if let Some(e) = sessions.editing.as_mut() {
                        e.key = key;
                        e.source = source.clone();
                    }
                    return Ok(Placed {
                        session: Some(session),
                        owned: false,
                        fresh: true,
                        opened: Some(size),
                        decode_seconds: ms(&t["decode"]),
                        open_seconds: ms(&t["open"]),
                    });
                }
                Err(EngineError::Cancelled) => return Err(EngineError::Cancelled),
                Err(_) => {
                    // The old session is untouched on a failed redecode (R2); open the frame afresh.
                }
            }
        }
        // Another frame's page, or this one's from other pixels: its session goes before this decode.
        if let Some(old) = sessions.editing.take() {
            self.close(&old.session).await;
        }
        let (session, size, d, o) = self.open(sessions, source, job.tier).await?;
        sessions.editing =
            Some(Editing { frame: job.frame_id.clone(), session: session.clone(), key, source: source.clone() });
        Ok(Placed {
            session: Some(session),
            owned: false,
            fresh: true,
            opened: Some(size),
            decode_seconds: d,
            open_seconds: o,
        })
    }

    /// The call's params: the job's, with the engine's session and progress id.
    fn call_params(request: &JobRequest, session: Option<&str>, progress_id: Option<&str>) -> Value {
        let mut p = match &request.params {
            Value::Object(m) => m.clone(),
            _ => Map::new(),
        };
        p.remove("session");
        p.remove("progress_id");
        if let Some(s) = session {
            p.insert("session".into(), json!(s));
        }
        if PRIVATE_SESSION_METHODS.contains(&request.method.as_str())
            && session.is_none()
            && !p.contains_key("source_path")
        {
            if let Some(source) = &request.source {
                p.insert("source_path".into(), json!(source.path));
            }
        }
        if let Some(id) = progress_id {
            p.insert("progress_id".into(), json!(id));
        }
        Value::Object(p)
    }

    fn stage_of(job: &RenderJob, host_stage: &str) -> RenderStage {
        match host_stage {
            "transform" => RenderStage::Scan,
            "encode" => RenderStage::Save,
            "done" => {
                if job.decodes_original {
                    RenderStage::Save
                } else {
                    RenderStage::Scan
                }
            }
            _ => {
                if job.is_reprint() {
                    RenderStage::Print
                } else {
                    RenderStage::Film
                }
            }
        }
    }

    /// Forward the host's `progress` events for this call to the queue.
    fn forward_progress(
        &self,
        job: &RenderJob,
        progress_id: &str,
        progress: ProgressFn,
        band_count: i64,
    ) -> JoinHandle<()> {
        let mut rx = self.link.subscribe();
        let id = progress_id.to_string();
        let job = job.clone();
        self.runtime.spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(e) => {
                        if e["event"] != json!("progress") || e["progress_id"].as_str() != Some(id.as_str()) {
                            continue;
                        }
                        let f = e["fraction"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0);
                        let stage = Self::stage_of(&job, e["stage"].as_str().unwrap_or(""));
                        let fraction = 0.15 + 0.8 * f;
                        progress(RenderProgress {
                            stage,
                            fraction,
                            band: ((fraction * band_count as f64) as i64).min(band_count - 1),
                            band_count,
                        });
                    }
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => return,
                }
            }
        })
    }

    async fn run_on(
        &self,
        sessions: &mut Sessions,
        job: &RenderJob,
        request: &JobRequest,
        band_count: i64,
        progress: &ProgressFn,
    ) -> Result<RenderResult, EngineError> {
        let started = std::time::Instant::now();
        let method = request.method.as_str();
        if (SESSION_METHODS.contains(&method) || PRIVATE_SESSION_METHODS.contains(&method)) && request.source.is_some()
        {
            progress(RenderProgress { stage: RenderStage::Decode, fraction: 0.0, band: 0, band_count });
        }
        let mut retried = false;
        loop {
            let placed = self.place(sessions, job, request).await?;
            let result = self.call(sessions, job, request, &placed, band_count, progress).await;
            if placed.owned {
                if let Some(s) = &placed.session {
                    // However it ended; not if the host is gone (its sessions went with it).
                    if !matches!(&result, Err(EngineError::Failed(m)) if m.starts_with("host_exited") || m.starts_with("not_running"))
                    {
                        self.close(s).await;
                    }
                }
            }
            match result {
                // A session the host no longer knows (restarted between jobs): open it again, once.
                Err(EngineError::Failed(m))
                    if m.starts_with("not_found") && !placed.fresh && !placed.owned && !retried =>
                {
                    retried = true;
                    sessions.editing = None;
                    continue;
                }
                Err(e) => return Err(e),
                Ok((result, payload, reprint)) => {
                    let held = self.refresh_held().await.unwrap_or(0);
                    let size_of = |v: &Value| {
                        let (w, h) = (v["width"].as_i64(), v["height"].as_i64());
                        w.zip(h).map(|(w, h)| PixelSize::new(w, h))
                    };
                    let size = size_of(&result["image"]).or_else(|| size_of(&result)).unwrap_or(job.canvas);
                    let t = &result["timings_ms"];
                    let render_seconds = if t["total"].is_number() { ms(&t["total"]) } else { ms(&t["engine"]) };
                    let measured = RunMeasurement {
                        engine_held_after: held,
                        decode_seconds: placed.decode_seconds,
                        open_seconds: placed.open_seconds,
                        render_seconds,
                        opened: placed.opened,
                        ..Default::default()
                    };
                    progress(RenderProgress {
                        stage: if job.decodes_original { RenderStage::Save } else { RenderStage::Scan },
                        fraction: 0.97,
                        band: band_count - 1,
                        band_count,
                    });
                    return Ok(RenderResult {
                        seconds: started.elapsed().as_secs_f64(),
                        peak_bytes: 0,
                        reprint,
                        size,
                        bands: None,
                        measured: Some(measured),
                        delivery: Some(Delivery { method: request.method.clone(), result, payload: Arc::new(payload) }),
                    });
                }
            }
        }
    }

    /// `set_params`, then the job's own call.
    async fn call(
        &self,
        sessions: &mut Sessions,
        job: &RenderJob,
        request: &JobRequest,
        placed: &Placed,
        band_count: i64,
        progress: &ProgressFn,
    ) -> Result<(Value, Vec<u8>, bool), EngineError> {
        if let (Some(delta), Some(session)) = (&request.set_params, &placed.session) {
            self.must(sessions, "set_params", json!({"session": session, "delta": delta}), job.tier).await?;
        }
        let method = request.method.as_str();
        let progress_id = PROGRESS_METHODS.contains(&method).then(|| format!("spk-{}", job.id));
        {
            let mut c = self.cancels.lock().unwrap();
            if c.cancelled.contains(&job.id) {
                return Err(EngineError::Cancelled);
            }
            c.in_flight = Some(InFlight {
                job: job.id,
                session: placed.session.clone().unwrap_or_default(),
                progress_id: progress_id.clone(),
            });
        }
        progress(RenderProgress {
            stage: if job.is_reprint() { RenderStage::Print } else { RenderStage::Film },
            fraction: if placed.fresh { 0.15 } else { 0.05 },
            band: 0,
            band_count,
        });
        let forwarder = progress_id.as_deref().map(|id| self.forward_progress(job, id, progress.clone(), band_count));
        let params = Self::call_params(request, placed.session.as_deref(), progress_id.as_deref());
        let answer = self.must(sessions, method, params, job.tier).await;
        self.cancels.lock().unwrap().in_flight = None;
        if let Some(f) = forwarder {
            f.abort();
        }
        let (result, payload) = answer?;
        // A call that could not be stopped finished after its job was cancelled: thrown away.
        if progress_id.is_none() && self.is_cancelled(job.id) {
            return Err(EngineError::Cancelled);
        }
        let reprint = result["reprinted"].as_bool().or(result["print_cached"].as_bool()).unwrap_or(false);
        Ok((result, payload, reprint))
    }
}

#[async_trait]
impl DevelopEngine for HostEngine {
    fn name(&self) -> String {
        self.name.clone()
    }

    fn effect_versions(&self) -> String {
        self.effect_versions.clone()
    }

    async fn run(&self, job: &RenderJob, mode: &RenderMode, progress: ProgressFn) -> Result<RenderResult, EngineError> {
        let band_count = match mode {
            RenderMode::Wait(_) => {
                return Err(EngineError::Failed("a job that waits is not handed to the engine".into()))
            }
            RenderMode::Whole => 1,
            // The host renders a frame whole; the count is the progress the scheduler planned.
            RenderMode::Bands { rows } => BandGeometry::new(job.canvas).band_count(*rows),
        };
        let Some(request) = job.request.clone() else {
            return Err(EngineError::Failed("the job has no host request".into()));
        };
        if self.take_cancelled(job.id) {
            return Err(EngineError::Cancelled);
        }
        let mut sessions = self.sessions.lock().await;
        let result = self.run_on(&mut sessions, job, &request, band_count, &progress).await;
        drop(sessions);
        // Whatever ended it, the job's cancel is spent.
        let cancelled = self.take_cancelled(job.id);
        match result {
            Err(EngineError::Failed(_)) | Err(EngineError::Resource(_)) if cancelled => Err(EngineError::Cancelled),
            other => other,
        }
    }

    fn cancel(&self, job_id: JobId) {
        let mut c = self.cancels.lock().unwrap();
        c.cancelled.insert(job_id);
        let Some(f) = c.in_flight.as_ref().filter(|f| f.job == job_id) else { return };
        let Some(progress_id) = f.progress_id.clone() else { return };
        let session = f.session.clone();
        let link = self.link.clone();
        self.runtime.spawn(async move {
            let _ = link
                .request(
                    "cancel",
                    json!({"session": session, "progress_id": progress_id}),
                    Vec::new(),
                    Duration::from_secs(10),
                )
                .await;
        });
    }

    async fn trim(&self) -> u64 {
        if !self.methods.contains("trim") {
            // An older host trims only by its own timer.
            return 0;
        }
        match self.ask("trim", json!({}), RenderTier::Live).await {
            Ok(Answer::Ok(result, _)) => result["freed_bytes"].as_f64().unwrap_or(0.0).max(0.0) as u64,
            _ => 0,
        }
    }

    async fn held_bytes(&self) -> u64 {
        self.refresh_held().await.unwrap_or_else(|| self.held.load(Ordering::SeqCst))
    }

    async fn reclaim(&self, keeping: Option<&FrameId>) -> u64 {
        let before = self.held.load(Ordering::SeqCst);
        {
            let mut sessions = self.sessions.lock().await;
            if sessions.editing.as_ref().is_some_and(|e| Some(&e.frame) != keeping) {
                let old = sessions.editing.take().unwrap();
                self.close(&old.session).await;
            }
        }
        let trimmed = self.trim().await;
        let after = self.refresh_held().await.unwrap_or(before);
        trimmed.max(before.saturating_sub(after))
    }

    async fn close_editing(&self, frame: Option<&FrameId>) {
        let mut sessions = self.sessions.lock().await;
        if sessions.editing.as_ref().is_some_and(|e| frame.map_or(true, |f| &e.frame == f)) {
            let old = sessions.editing.take().unwrap();
            self.close(&old.session).await;
        }
    }
}
