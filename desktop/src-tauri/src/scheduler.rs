//! The render scheduler in the app (PRD-W2 R10, phase 2): `spk_scheduler` over the app's one engine
//! host, and the Tauri surface `desktop/crates/spk-scheduler/WIRE.md` defines.
//!
//! - [`AppHostLink`] is `spk_scheduler::HostLink` over [`HostManager`]: the scheduler's requests go to
//!   the same host process as the webview's, and a restarted host serves the scheduler again with no
//!   reconnect (the manager waits for the new host to be ready). **Session ids are scoped to the host
//!   process that made them**: the link hands the engine `"<generation>:<sid>"`, and a call naming a
//!   session of an older host is answered `not_found` without being sent, so the engine opens the frame
//!   again (WIRE.md, "Sessions") instead of reaching a session the new host gave the same id.
//! - [`SchedulerHub`] owns the `Scheduler` facade and its `HostEngine`, made inside the async runtime
//!   on first use (the engine says `hello`, so it cannot be made before the host runs).
//! - The commands are thin: each `#[tauri::command]` calls a plain method here, which is what T5a
//!   (`tests/t5a_real_host.rs`) drives with no window.
//!
//! What the webview does that is not a job but needs the frame's session (opening the frame for its
//! parameters and metadata, `set_params`, `solve`, `scene_latitude`, `pick_neutral`, `render_source`,
//! `redecode`, `update_pair`) goes through [`SchedulerHub::editing_open`] / [`SchedulerHub::editing_call`]:
//! the engine's own editing session, reached by the frame, under the lock the jobs take. The webview
//! never opens or closes a host session of its own.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use spk_scheduler::cost_model::{CorrectionStore, FileCorrectionStore};
use spk_scheduler::host::{HostLink, HostReply};
use spk_scheduler::memory_probe::{FnProbe, MemoryProbe, MemoryReading};
use spk_scheduler::wire::{
    BudgetReadingWire, FrontendStateMsg, JobSnapshotWire, JobSpec, OutcomeWire, PressureLevel, SourceSpec,
};
use spk_scheduler::{
    DevicePolicy, FrameId, HostEngine, JobId, JobKind, JobLogFile, QueueConfig, Scheduler, SchedulerOptions,
};
#[cfg(not(target_os = "macos"))]
use spk_scheduler::GpuMemory;
use tauri::Runtime;
use tokio::sync::{broadcast, OnceCell};

use crate::framing;
use crate::host::HostManager;
use crate::workspace::Workspace;

/// The event every job change is sent as (WIRE.md).
pub const JOB_EVENT: &str = "scheduler://job";

/// The scheduler's way to the app's host.
pub struct AppHostLink<R: Runtime> {
    host: Arc<HostManager<R>>,
    workspace: Option<Arc<Workspace>>,
}

impl<R: Runtime> AppHostLink<R> {
    pub fn new(host: Arc<HostManager<R>>, workspace: Option<Arc<Workspace>>) -> Self {
        AppHostLink { host, workspace }
    }
}

/// `"<generation>:<sid>"` → `(generation, sid)`; anything else is not one of ours.
fn scoped(session: &str) -> Option<(u64, &str)> {
    let (generation, sid) = session.split_once(':')?;
    Some((generation.parse().ok()?, sid))
}

fn not_found(session: &str) -> HostReply {
    Ok((
        json!({"ok": false, "error": {"code": "not_found",
            "message": format!("session {session} belonged to an engine host that has exited")}}),
        Vec::new(),
    ))
}

/// Calls that hold no file and so take no workspace lease (as `host_request` exempts its own).
fn lease_free(method: &str) -> bool {
    matches!(method, "cancel" | "ping" | "hello" | "memory_report" | "trim" | "progress")
}

#[async_trait]
impl<R: Runtime> HostLink for AppHostLink<R> {
    async fn request(&self, method: &str, mut params: Value, payload: Vec<u8>, timeout: Duration) -> HostReply {
        let mut require = None;
        if let Some(session) = params.get("session").and_then(Value::as_str).map(str::to_string) {
            if let Some((generation, sid)) = scoped(&session) {
                if generation != self.host.generation() {
                    return not_found(&session);
                }
                require = Some(generation);
                params["session"] = json!(sid);
            }
        }
        let lease = match (&self.workspace, lease_free(method)) {
            (Some(w), false) => match w.enter() {
                Ok(lease) => Some(lease),
                Err(e) => return Err(spk_scheduler::HostError::new("busy", e)),
            },
            _ => None,
        };
        let (reply, generation) = self.host.request_on(method, params, payload, timeout, lease, require).await;
        match reply {
            Ok((mut header, payload)) => {
                if let (Some(generation), Some(sid)) = (generation, header["result"]["session"].as_str()) {
                    let scoped = format!("{generation}:{sid}");
                    header["result"]["session"] = json!(scoped);
                }
                Ok((header, payload))
            }
            Err(e) => Err(spk_scheduler::HostError::new(&e.code, e.message)),
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.host.subscribe()
    }
}

/// Where the scheduler keeps what outlives a launch.
#[derive(Clone, Debug)]
pub struct SchedulerPaths {
    /// The app's log folder: `scheduler-log.jsonl`, the Mac's job log (R7).
    pub logs: PathBuf,
    /// The app's data folder: `scheduler-corrections.json`, the cost model's corrections.
    pub data: PathBuf,
}

impl SchedulerPaths {
    pub fn job_log(&self) -> PathBuf {
        self.logs.join("scheduler-log.jsonl")
    }
    pub fn corrections(&self) -> PathBuf {
        self.data.join("scheduler-corrections.json")
    }
}

pub struct Wired {
    pub scheduler: Scheduler,
    pub engine: Arc<HostEngine>,
}

type Emit = Arc<dyn Fn(&JobSnapshotWire) + Send + Sync>;

/// The facade, made on first use inside the runtime.
pub struct SchedulerHub<R: Runtime> {
    host: Arc<HostManager<R>>,
    workspace: Option<Arc<Workspace>>,
    paths: SchedulerPaths,
    emit: Emit,
    wired: OnceCell<Arc<Wired>>,
    /// The last `FrontendStateMsg`, replayed onto a scheduler made after it was sent.
    frontend: Mutex<Option<FrontendStateMsg>>,
}

/// The memory the policy is made for, from this machine's own probe.
#[cfg(target_os = "macos")]
fn policy(_hello: &Value) -> DevicePolicy {
    DevicePolicy::mac()
}

#[cfg(windows)]
fn policy(hello: &Value) -> DevicePolicy {
    DevicePolicy::desktop_pc(spk_scheduler::memory_probe::WindowsProbe::installed_memory(), GpuMemory::from_hello(hello))
}

#[cfg(all(unix, not(target_os = "macos")))]
fn policy(hello: &Value) -> DevicePolicy {
    DevicePolicy::desktop_pc(linux::meminfo("MemTotal").unwrap_or(0), GpuMemory::from_hello(hello))
}

/// Linux has no probe in the crate (the scheduler ports the Mac and Windows readings): `/proc/meminfo`,
/// mapped as `MemoryReading::windows` maps a PC (allowance = available memory; commit = it plus free
/// swap). Unmeasured, as every PC number is.
#[cfg(all(unix, not(target_os = "macos")))]
mod linux {
    pub fn meminfo(key: &str) -> Option<u64> {
        let text = std::fs::read_to_string("/proc/meminfo").ok()?;
        let line = text.lines().find(|l| l.starts_with(key) && l[key.len()..].starts_with(':'))?;
        let kb: u64 = line[key.len() + 1..].trim().trim_end_matches("kB").trim().parse().ok()?;
        Some(kb * 1024)
    }
    pub fn footprint(pid: Option<u32>) -> u64 {
        let path = pid.map_or_else(|| "/proc/self/status".to_string(), |p| format!("/proc/{p}/status"));
        std::fs::read_to_string(path)
            .ok()
            .and_then(|t| t.lines().find(|l| l.starts_with("VmRSS:")).map(str::to_string))
            .and_then(|l| l[6..].trim().trim_end_matches("kB").trim().parse::<u64>().ok())
            .map_or(0, |kb| kb * 1024)
    }
}

/// The host process's memory, read before every plan; the host's pid is read each time (a restart
/// changes it).
fn probe<R: Runtime>(host: Arc<HostManager<R>>) -> Arc<dyn MemoryProbe> {
    Arc::new(FnProbe(move || -> MemoryReading {
        let pid = host.pid();
        #[cfg(target_os = "macos")]
        {
            spk_scheduler::memory_probe::MacProbe { pid }.read()
        }
        #[cfg(windows)]
        {
            let mut reading = spk_scheduler::memory_probe::WindowsProbe { pid }.read();
            reading.gpu_available = host.gpu_available();
            reading
        }
        #[cfg(all(unix, not(target_os = "macos")))]
        {
            let available = linux::meminfo("MemAvailable").unwrap_or(0);
            let swap = linux::meminfo("SwapFree").unwrap_or(0);
            MemoryReading::windows(available, available + swap, linux::footprint(pid))
        }
    }))
}

fn parse_job(id: &str) -> Result<JobId, String> {
    id.parse().map_err(|e| format!("{id} is not a job id: {e}"))
}

impl<R: Runtime> SchedulerHub<R> {
    pub fn new(
        host: Arc<HostManager<R>>,
        workspace: Option<Arc<Workspace>>,
        paths: SchedulerPaths,
        emit: impl Fn(&JobSnapshotWire) + Send + Sync + 'static,
    ) -> Self {
        SchedulerHub { host, workspace, paths, emit: Arc::new(emit), wired: OnceCell::new(), frontend: Mutex::new(None) }
    }

    pub fn paths(&self) -> &SchedulerPaths {
        &self.paths
    }

    /// The scheduler, made on first call: `hello` through the link (waiting for the host to be ready),
    /// the policy and probe of this platform, the job log and the corrections. Must run inside the
    /// async runtime (Tauri's), as `Scheduler::new` and `HostEngine::connect` require. A failure (the
    /// host is not running) is returned and the next call tries again.
    pub async fn wired(&self) -> Result<Arc<Wired>, String> {
        self.wired
            .get_or_try_init(|| async {
                let link = Arc::new(AppHostLink::new(self.host.clone(), self.workspace.clone()));
                let engine = Arc::new(HostEngine::connect(link).await.map_err(|e| format!("the scheduler's engine: {e}"))?);
                let corrections: Arc<dyn CorrectionStore> =
                    Arc::new(FileCorrectionStore { path: self.paths.corrections() });
                let _ = std::fs::create_dir_all(&self.paths.data);
                let scheduler = Scheduler::new(
                    engine.clone(),
                    SchedulerOptions {
                        policy: policy(engine.hello()),
                        probe: probe(self.host.clone()),
                        corrections: Some(corrections),
                        config: QueueConfig::default(),
                    },
                );
                let _ = std::fs::create_dir_all(&self.paths.logs);
                match JobLogFile::open(self.paths.job_log(), false) {
                    Ok(file) => scheduler.set_job_log(Some(Arc::new(file))),
                    Err(e) => log::warn!(target: "scheduler", "no job log at {}: {e}", self.paths.job_log().display()),
                }
                let mut events = scheduler.subscribe();
                let emit = self.emit.clone();
                tokio::spawn(async move {
                    loop {
                        match events.recv().await {
                            Ok(snapshot) => emit(&snapshot),
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                log::warn!(target: "scheduler", "{n} job events dropped (a slow webview)")
                            }
                            Err(broadcast::error::RecvError::Closed) => break,
                        }
                    }
                });
                if let Some(state) = self.frontend.lock().unwrap().clone() {
                    scheduler.set_frontend_state(state);
                }
                log::info!(target: "scheduler", "scheduler on {} ({}), job log {}", engine.hello()["backend"]["device_name"],
                    scheduler.budget().policy.device, self.paths.job_log().display());
                Ok(Arc::new(Wired { scheduler, engine }))
            })
            .await
            .cloned()
    }

    pub async fn submit(&self, job: Value) -> Result<String, String> {
        let spec: JobSpec = serde_json::from_value(job).map_err(|e| format!("not a job: {e}"))?;
        let wired = self.wired().await?;
        wired.scheduler.submit(&spec).map(|id| id.to_string()).map_err(|e| e.to_string())
    }

    pub async fn cancel(&self, job_id: &str) -> Result<(), String> {
        let id = parse_job(job_id)?;
        self.wired().await?.scheduler.cancel(id);
        Ok(())
    }

    pub async fn cancel_frame(&self, frame_id: &str, kinds: Option<Vec<JobKind>>) -> Result<(), String> {
        self.wired().await?.scheduler.cancel_frame(frame_id, kinds.as_deref());
        Ok(())
    }

    /// `OutcomeWire` and the payload, in the host protocol's own framing (WIRE.md).
    pub async fn outcome(&self, job_id: &str) -> Result<Vec<u8>, String> {
        let id = parse_job(job_id)?;
        let wired = self.wired().await?;
        let (outcome, payload): (OutcomeWire, _) = wired.scheduler.outcome(id).await;
        let header = serde_json::to_value(&outcome).map_err(|e| e.to_string())?;
        Ok(framing::encode(&header, payload.as_deref().map_or(&[][..], |p| p.as_slice())))
    }

    pub async fn snapshot(&self, frame_id: Option<&str>) -> Result<Vec<JobSnapshotWire>, String> {
        Ok(self.wired().await?.scheduler.snapshot(frame_id))
    }

    pub async fn budget(&self) -> Result<BudgetReadingWire, String> {
        Ok(self.wired().await?.scheduler.budget())
    }

    /// Kept, and replayed if the scheduler is made later (the window says what it shows at once).
    pub async fn frontend_state(&self, state: FrontendStateMsg) -> Result<(), String> {
        *self.frontend.lock().unwrap() = Some(state.clone());
        if let Some(wired) = self.wired.get() {
            wired.scheduler.set_frontend_state(state);
        }
        Ok(())
    }

    pub async fn memory_pressure(&self, level: PressureLevel) -> Result<(), String> {
        self.wired().await?.scheduler.memory_pressure(level);
        Ok(())
    }

    /// Open the frame in the engine's editing session (closing any other) and return the host's
    /// `open` reply, framed as `host_request` frames it.
    pub async fn editing_open(&self, frame_id: &str, source: SourceSpec) -> Result<Vec<u8>, String> {
        let wired = self.wired().await?;
        Ok(frame_reply(wired.engine.open_editing(&FrameId::new(frame_id), &source).await))
    }

    /// One host call on the frame's editing session (`session` as `editing_open` returned it).
    pub async fn editing_call(&self, frame_id: &str, session: &str, method: &str, params: Value) -> Result<Vec<u8>, String> {
        if !EDITING_METHODS.contains(&method) {
            return Err(format!("{method} is not a call on a frame's session"));
        }
        let wired = self.wired().await?;
        Ok(frame_reply(wired.engine.call_editing(&FrameId::new(frame_id), session, method, params).await))
    }
}

/// What the webview may call on the frame's editing session (`host/client.ts`).
pub const EDITING_METHODS: &[&str] = &[
    "set_params",
    "get_params",
    "solve",
    "scene_latitude",
    "overscan_geometry",
    "pick_neutral",
    "render_source",
    "redecode",
    "update_pair",
];

/// A host reply as `host_request` hands it to the webview (`ok` + `result`/`error`, and the payload).
pub fn frame_reply(reply: HostReply) -> Vec<u8> {
    match reply {
        Ok((header, payload)) => {
            let h = if header["ok"] == json!(true) {
                json!({"ok": true, "result": header["result"]})
            } else {
                json!({"ok": false, "error": header["error"]})
            };
            framing::encode(&h, &payload)
        }
        Err(e) => framing::encode(&json!({"ok": false, "error": {"code": e.code, "message": e.message}}), &[]),
    }
}
