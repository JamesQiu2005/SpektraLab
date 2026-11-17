//! The facade a Tauri layer holds (R6): the queue, the wire, the job log and the snapshot events.
//! `Send + Sync`, no `tauri` dependency. Made inside a tokio runtime (Tauri's), whose handle the queue
//! keeps for its own tasks.

use std::sync::{Arc, Mutex, RwLock};

use tokio::sync::broadcast;

use crate::cost_model::CorrectionStore;
use crate::device_policy::DevicePolicy;
use crate::engine::DevelopEngine;
use crate::job_log::JobSink;
use crate::memory_probe::MemoryProbe;
use crate::queue::{Pressure, QueueConfig, RenderQueue};
use crate::types::{FrameId, JobId, JobKind};
use crate::wire::{
    BudgetReadingWire, EngineWire, FrontendStateMsg, JobSnapshotWire, JobSpec, OutcomeWire, PolicyWire, PressureLevel,
    SubmitError,
};

/// What a scheduler is made with.
pub struct SchedulerOptions {
    pub policy: DevicePolicy,
    /// The host's memory, read before every plan.
    pub probe: Arc<dyn MemoryProbe>,
    /// Where the cost model's corrections are kept across launches; `None` keeps nothing.
    pub corrections: Option<Arc<dyn CorrectionStore>>,
    pub config: QueueConfig,
}

/// How many snapshot events a slow subscriber may fall behind before it misses some.
const EVENT_BACKLOG: usize = 1024;

type SinkSlot = Arc<RwLock<Option<Arc<dyn JobSink>>>>;

pub struct Scheduler {
    queue: RenderQueue,
    events: broadcast::Sender<JobSnapshotWire>,
    sink: SinkSlot,
    frontend: Mutex<FrontendStateMsg>,
    policy: DevicePolicy,
}

impl Scheduler {
    pub fn new(engine: Arc<dyn DevelopEngine>, options: SchedulerOptions) -> Self {
        let probe = options.probe.clone();
        let queue =
            RenderQueue::new(engine, options.policy.clone(), options.corrections, Arc::new(move || probe.read()));
        let config = options.config;
        queue.configure(|c| *c = config);
        let (events, _) = broadcast::channel(EVENT_BACKLOG);
        let sink: SinkSlot = Arc::new(RwLock::new(None));
        {
            let events = events.clone();
            let sink = sink.clone();
            queue.set_hooks(move |h| {
                h.on_update = Some(Arc::new(move |s| {
                    let _ = events.send(JobSnapshotWire::from(s));
                }));
                h.on_record = Some(Arc::new(move |r| {
                    if let Some(sink) = sink.read().unwrap().as_ref() {
                        sink.append(r);
                    }
                }));
            });
        }
        Scheduler { queue, events, sink, frontend: Mutex::new(FrontendStateMsg::default()), policy: options.policy }
    }

    /// The queue itself, for what the wire does not cover (its hooks, its configuration, its records).
    pub fn queue(&self) -> &RenderQueue {
        &self.queue
    }

    /// `scheduler_submit`.
    pub fn submit(&self, spec: &JobSpec) -> Result<JobId, SubmitError> {
        Ok(self.queue.submit(spec.to_job()?))
    }

    /// `scheduler_cancel`.
    pub fn cancel(&self, id: JobId) {
        self.queue.cancel(id);
    }

    /// `scheduler_cancel_frame`: every job of a frame, or those of these kinds.
    pub fn cancel_frame(&self, frame_id: &str, kinds: Option<&[JobKind]>) {
        let frame = FrameId::new(frame_id);
        self.queue.cancel_all(&frame, |j| kinds.map_or(true, |k| k.contains(&j.kind)));
    }

    /// `scheduler_outcome`: resolves when the job ends. The payload is handed over once.
    pub async fn outcome(&self, id: JobId) -> (OutcomeWire, Option<Arc<Vec<u8>>>) {
        let outcome = self.queue.outcome(id).await;
        let out = OutcomeWire::of(id, &outcome);
        self.queue.release_payload(id);
        out
    }

    /// `scheduler_snapshot`: the job a frame's page shows, or every job not finished.
    pub fn snapshot(&self, frame_id: Option<&str>) -> Vec<JobSnapshotWire> {
        match frame_id {
            Some(f) => self.queue.snapshot(&FrameId::new(f), |_| true).iter().map(JobSnapshotWire::from).collect(),
            None => self.queue.snapshots().iter().map(JobSnapshotWire::from).collect(),
        }
    }

    /// `scheduler_budget`.
    pub fn budget(&self) -> BudgetReadingWire {
        let (budget, reading) = self.queue.budget_now(false);
        let (asked, _) = self.queue.budget_now(true);
        let engine = self.queue.engine();
        BudgetReadingWire {
            budget: (&budget).into(),
            asked: (&asked).into(),
            reading,
            frontend: self.queue.frontend().text(),
            engine: EngineWire {
                name: engine.name(),
                makes_pictures: engine.makes_pictures(),
                effect_versions: engine.effect_versions(),
            },
            policy: PolicyWire {
                device: self.policy.device_name().into(),
                develop_cap_megapixels: self.policy.develop_cap_megapixels,
                preview_long_edge: self.policy.preview_long_edge,
                preview_edges: DevicePolicy::PREVIEW_EDGES.to_vec(),
                time_ratio: self.policy.time_ratio,
                unmeasured: self.policy.unmeasured(),
            },
            jobs: self.queue.snapshots().len(),
        }
    }

    /// `scheduler_frontend_state`. A change of `openFrame` closes the old frame's editing session.
    pub fn set_frontend_state(&self, msg: FrontendStateMsg) {
        let previous = {
            let mut current = self.frontend.lock().unwrap();
            std::mem::replace(&mut *current, msg.clone())
        };
        if previous.open_frame.is_some() && previous.open_frame != msg.open_frame {
            let engine = self.queue.engine();
            let frame = previous.open_frame.map(FrameId::new);
            tokio::runtime::Handle::current().spawn(async move {
                engine.close_editing(frame.as_ref()).await;
            });
        }
        self.queue.set_frontend(msg.to_state());
    }

    /// `scheduler_memory_pressure`.
    pub fn memory_pressure(&self, level: PressureLevel) {
        self.queue.memory_pressure(match level {
            PressureLevel::Warning => Pressure::Warning,
            PressureLevel::Critical => Pressure::Critical,
        });
    }

    /// The `scheduler://job` events: every change to every job.
    pub fn subscribe(&self) -> broadcast::Receiver<JobSnapshotWire> {
        self.events.subscribe()
    }

    /// Where the job records go (R7). `None` stops writing them.
    pub fn set_job_log(&self, sink: Option<Arc<dyn JobSink>>) {
        *self.sink.write().unwrap() = sink;
    }

    /// The frontend's caches: dropped on a memory warning (`trim_caches`), and everything that can be
    /// drawn again when a job someone waits on cannot fit (`reclaim`).
    pub fn set_cache_hooks(
        &self,
        trim_caches: Option<Arc<dyn Fn() + Send + Sync>>,
        reclaim: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        self.queue.set_hooks(|h| {
            h.on_trim_caches = trim_caches;
            h.on_reclaim = reclaim;
        });
    }
}
