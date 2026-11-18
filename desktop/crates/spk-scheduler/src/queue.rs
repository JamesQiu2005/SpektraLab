//! The one door every render goes through (`RenderQueue.swift`, RFC-036 phase 1).
//!
//! Before each job it reads the host's memory, computes a budget, and picks the fastest mode that
//! fits — whole, bands, smaller bands — or makes the job wait and say why. The rules it holds
//! (RFC-036 §3.1):
//!
//! - **G1 never killed.** A job that cannot fit waits; it does not gamble.
//! - **G2 the newest intent first.** Canvas jobs are coalesced: at most one queued per frame, latest
//!   wins, and a running one is cancelled once the newer one has waited a reprint's time.
//! - **G3 full quality, always.** The mode changes how long, never what.
//! - **G4 the camera never waits for the darkroom** (the phone's rules; a desktop has no camera).
//! - **G5 the state is visible.** Every job has a snapshot, and a waiting job carries its reason.
//!
//! **One GPU job runs at a time** (§6.9).
//!
//! ## How the Swift's main actor became this
//!
//! The Swift queue is a `@MainActor` class. Here the state is one `Mutex`, never held across an
//! `await` and never held while anything outside the queue is called: every operation locks, changes
//! the state, collects what it must do outside (`Fx`: snapshots to publish, records, waiters to wake,
//! engine cancels, hooks, tasks to spawn, a pump), unlocks, and then does those things in order. So a
//! hook may call back into the queue (the selftest's memory reading asks `is_idle`). The memory
//! reading is taken before the lock, for the same reason.
//!
//! Every interval is on tokio's clock (`tokio::time::Instant`, `sleep`): under a paused runtime the
//! rules run in virtual time, and no test waits on the wall clock (R4).

use std::collections::{HashMap, HashSet, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::budget::{BudgetTuning, MemoryBudget};
use crate::cost_model::{CorrectionStore, CostModel};
use crate::device_policy::DevicePolicy;
use crate::engine::{DevelopEngine, EngineError, ProgressFn, RenderResult};
use crate::memory_probe::MemoryReading;
use crate::planner::{Planner, RenderPlan};
use crate::types::{
    megabytes, CaptureRule, Composition, FrameId, FrontendState, JobId, JobKind, JobRecord, JobSnapshot, RenderJob,
    RenderMode, RenderProgress, RenderStage, RenderTier, Scene, SnapshotState, Thermal, WaitReason,
};

/// `JobOutcome`. A finished job's result is carried as the Swift's is, by value.
#[allow(clippy::large_enum_variant)]
#[derive(Clone, Debug, PartialEq)]
pub enum JobOutcome {
    Finished(RenderResult),
    Cancelled,
    Failed(String),
}

impl JobOutcome {
    pub fn is_finished(&self) -> bool {
        matches!(self, JobOutcome::Finished(_))
    }
}

/// `RenderQueue.Pressure`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pressure {
    Warning,
    Critical,
}

/// What a host may set (`RenderQueue`'s `@ObservationIgnored var`s), with the Swift's defaults.
#[derive(Clone, Debug, PartialEq)]
pub struct QueueConfig {
    pub tuning: BudgetTuning,
    /// **Reclaim before waiting.** False keeps RFC-036's G1 as it was: a job that cannot fit waits.
    pub reclaims_for_asked: bool,
    /// How long a job someone waits on waits for memory, after everything has been given back, before
    /// it starts in its smallest mode against the app's allowance alone, the watch on it.
    pub force_after: f64,
    /// **On a desktop, a job someone waits on never starves**: after this it starts anyway, in its
    /// smallest mode. The Swift's is 5 s on the Mac and nil on a phone; a Windows/Linux desktop, like the
    /// Mac, has no OS that frees memory for the app, so it keeps the Mac's 5 s (unmeasured there).
    pub force_anyway_after: Option<f64>,
    /// How long the queue is idle before the engine's pool is given back.
    pub idle_trim_after: f64,
    /// An export gives way to a canvas edit only if it has longer than this left.
    pub yield_threshold: f64,
    /// How long a waiting queue goes before it looks again by itself.
    pub replan_interval: f64,
    /// What a photo in flight does to a develop below the full tier.
    pub capture_rule: CaptureRule,
    /// Whether anything develops beside a live camera at all.
    pub develops_beside_camera: bool,
    /// A job that waits for memory first has the engine's own idle pool given back.
    pub trims_when_waiting: bool,
    /// After a critical pressure event a job's budget is cut to 60 %, given back evenly over this long.
    pub pressure_recovery: f64,
    /// Develop's strips never delay anything (three rules, each its own switch, as in the Swift).
    pub previews_give_way_at_once: bool,
    pub previews_wait_for_the_queue: bool,
    pub previews_coalesce: bool,
}

impl Default for QueueConfig {
    fn default() -> Self {
        QueueConfig {
            tuning: BudgetTuning::default(),
            reclaims_for_asked: true,
            force_after: 1.5,
            force_anyway_after: Some(5.0),
            idle_trim_after: 5.0,
            yield_threshold: 0.4,
            replan_interval: 0.5,
            capture_rule: CaptureRule::Holds,
            develops_beside_camera: true,
            trims_when_waiting: true,
            pressure_recovery: 10.0,
            previews_give_way_at_once: true,
            previews_wait_for_the_queue: true,
            previews_coalesce: true,
        }
    }
}

pub type ReadMemoryFn = Arc<dyn Fn() -> MemoryReading + Send + Sync>;
pub type HookFn = Arc<dyn Fn() + Send + Sync>;
pub type UpdateFn = Arc<dyn Fn(&JobSnapshot) + Send + Sync>;
pub type RecordFn = Arc<dyn Fn(&JobRecord) + Send + Sync>;
pub type CompositionFn = Arc<dyn Fn(&RenderJob) -> Option<Composition> + Send + Sync>;
pub type MarksFn = Arc<dyn Fn(&RenderJob) -> u64 + Send + Sync>;

/// The queue's hooks (the Swift's closures).
#[derive(Clone)]
pub struct Hooks {
    /// Injectable, so a test can put the host in any state. Called without the queue's lock held.
    pub read_memory: ReadMemoryFn,
    /// The frontend's own caches, dropped on a memory warning before the engine is asked for anything.
    pub on_trim_caches: Option<HookFn>,
    /// The first rung of `reclaim`: everything the frontend holds that can be drawn again.
    pub on_reclaim: Option<HookFn>,
    /// Every change to a job.
    pub on_update: Option<UpdateFn>,
    /// R8: every record as it is made.
    pub on_record: Option<RecordFn>,
    /// What a job's open composes, asked once when it is submitted.
    pub composition: Option<CompositionFn>,
    /// What a job's watermark pass holds, asked once when it is submitted.
    pub marks: Option<MarksFn>,
}

impl Hooks {
    pub fn new(read_memory: ReadMemoryFn) -> Self {
        Hooks {
            read_memory,
            on_trim_caches: None,
            on_reclaim: None,
            on_update: None,
            on_record: None,
            composition: None,
            marks: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CancelReason {
    User,
    Superseded,
    Yielded,
    Pressure,
}

#[derive(Clone)]
struct Running {
    job: RenderJob,
    plan: RenderPlan,
    started: Instant,
    reason: Option<CancelReason>,
}

/// A task the queue owns, by generation: a stale one finds its generation moved and does nothing.
#[derive(Default)]
struct Timer {
    generation: u64,
    handle: Option<JoinHandle<()>>,
}

impl Timer {
    fn cancel(&mut self) {
        self.generation += 1;
        if let Some(h) = self.handle.take() {
            h.abort();
        }
    }
}

struct State {
    config: QueueConfig,
    frontend: FrontendState,
    snapshots: Vec<JobSnapshot>,
    last_plan: Option<RenderPlan>,
    records: VecDeque<JobRecord>,
    cost_model: CostModel,
    queue: Vec<RenderJob>,
    running: Option<Running>,
    waits: HashMap<JobId, Vec<WaitReason>>,
    derate: HashMap<JobId, (f64, Instant)>,
    waiters: HashMap<JobId, Vec<oneshot::Sender<JobOutcome>>>,
    outcomes: HashMap<JobId, JobOutcome>,
    outcome_order: VecDeque<JobId>,
    replan: Timer,
    watch: Timer,
    idle_trim: Timer,
    last_reprint_start: Option<Instant>,
    trimmed_for_wait: bool,
    reclaimed: u8,
    reclaimed_at: Option<Instant>,
    waiting_for_memory_since: HashMap<JobId, Instant>,
    forced_stopped_at: HashMap<JobId, Instant>,
    last_photo_landed: Option<Instant>,
    forced: HashSet<JobId>,
}

type Task = Pin<Box<dyn Future<Output = ()> + Send>>;

/// What an operation does once the lock is let go, in order.
#[allow(clippy::large_enum_variant)]
enum Action {
    Update(JobSnapshot),
    Record(JobRecord),
    Resolve(Vec<oneshot::Sender<JobOutcome>>, JobOutcome),
    Cancel(JobId),
    TrimCaches,
    Reclaim,
    SaveCorrections,
    Spawn(Task),
    SpawnTimer(TimerKind, u64, Task),
    Pump,
}

#[derive(Clone, Copy)]
enum TimerKind {
    Replan,
    Watch,
    IdleTrim,
}

#[derive(Default)]
struct Fx(Vec<Action>);

impl Fx {
    fn push(&mut self, a: Action) {
        self.0.push(a);
    }
}

/// The wall clock a record's `at` is written in: the queue's clock from the moment it was made, so a
/// record made in virtual time has a virtual date.
#[derive(Clone, Copy)]
struct Clock {
    origin: Instant,
    wall: DateTime<Utc>,
}

impl Clock {
    fn date(&self, at: Instant) -> DateTime<Utc> {
        self.wall + chrono::Duration::from_std(at.saturating_duration_since(self.origin)).unwrap_or_default()
    }
}

struct Inner {
    state: Mutex<State>,
    hooks: RwLock<Hooks>,
    engine: Arc<dyn DevelopEngine>,
    store: Option<Arc<dyn CorrectionStore>>,
    clock: Clock,
    runtime: tokio::runtime::Handle,
    me: Weak<Inner>,
}

/// `RenderQueue`. Cheap to clone; every clone is the same queue. Must be made inside a tokio runtime,
/// whose handle it keeps for its own tasks.
#[derive(Clone)]
pub struct RenderQueue {
    inner: Arc<Inner>,
}

/// A queue that does not keep it alive (for a hook that reads the queue it belongs to).
#[derive(Clone)]
pub struct WeakQueue(Weak<Inner>);

impl WeakQueue {
    pub fn upgrade(&self) -> Option<RenderQueue> {
        self.0.upgrade().map(|inner| RenderQueue { inner })
    }
}

fn secs(s: f64) -> Duration {
    Duration::from_secs_f64(if s.is_finite() { s.max(0.0) } else { 0.0 })
}

fn since(now: Instant, then: Instant) -> f64 {
    now.saturating_duration_since(then).as_secs_f64()
}

impl RenderQueue {
    /// `store` keeps the cost model's corrections across launches; `None` keeps nothing (tests).
    pub fn new(
        engine: Arc<dyn DevelopEngine>,
        policy: DevicePolicy,
        store: Option<Arc<dyn CorrectionStore>>,
        read_memory: ReadMemoryFn,
    ) -> Self {
        let cost_model = match &store {
            Some(s) => CostModel::with_corrections(policy, s.load()),
            None => CostModel::new(policy),
        };
        let state = State {
            config: QueueConfig::default(),
            frontend: FrontendState::default(),
            snapshots: Vec::new(),
            last_plan: None,
            records: VecDeque::new(),
            cost_model,
            queue: Vec::new(),
            running: None,
            waits: HashMap::new(),
            derate: HashMap::new(),
            waiters: HashMap::new(),
            outcomes: HashMap::new(),
            outcome_order: VecDeque::new(),
            replan: Timer::default(),
            watch: Timer::default(),
            idle_trim: Timer::default(),
            last_reprint_start: None,
            trimmed_for_wait: false,
            reclaimed: 0,
            reclaimed_at: None,
            waiting_for_memory_since: HashMap::new(),
            forced_stopped_at: HashMap::new(),
            last_photo_landed: None,
            forced: HashSet::new(),
        };
        let inner = Arc::new_cyclic(|me| Inner {
            state: Mutex::new(state),
            hooks: RwLock::new(Hooks::new(read_memory)),
            engine,
            store,
            clock: Clock { origin: Instant::now(), wall: Utc::now() },
            runtime: tokio::runtime::Handle::current(),
            me: me.clone(),
        });
        RenderQueue { inner }
    }

    pub fn downgrade(&self) -> WeakQueue {
        WeakQueue(Arc::downgrade(&self.inner))
    }

    pub fn engine(&self) -> Arc<dyn DevelopEngine> {
        self.inner.engine.clone()
    }

    /// Change what a host may set.
    pub fn configure(&self, change: impl FnOnce(&mut QueueConfig)) {
        change(&mut self.inner.lock().config);
    }

    pub fn config(&self) -> QueueConfig {
        self.inner.lock().config.clone()
    }

    /// Change the hooks.
    pub fn set_hooks(&self, change: impl FnOnce(&mut Hooks)) {
        change(&mut self.inner.hooks.write().unwrap());
    }

    pub fn set_read_memory(&self, f: impl Fn() -> MemoryReading + Send + Sync + 'static) {
        self.set_hooks(|h| h.read_memory = Arc::new(f));
    }

    // ---- what the pages read ----

    /// Every job that has not finished, queued or running.
    pub fn snapshots(&self) -> Vec<JobSnapshot> {
        self.inner.lock().snapshots.clone()
    }

    pub fn snapshot_of(&self, id: JobId) -> Option<JobSnapshot> {
        self.inner.lock().snapshots.iter().find(|s| s.id == id).cloned()
    }

    pub fn contains(&self, id: JobId) -> bool {
        self.inner.lock().snapshots.iter().any(|s| s.id == id)
    }

    pub fn last_plan(&self) -> Option<RenderPlan> {
        self.inner.lock().last_plan.clone()
    }

    /// R8: the last 200 jobs' records.
    pub fn records(&self) -> Vec<JobRecord> {
        self.inner.lock().records.iter().cloned().collect()
    }

    pub fn cost_model(&self) -> CostModel {
        self.inner.lock().cost_model.clone()
    }

    pub fn frontend(&self) -> FrontendState {
        self.inner.lock().frontend.clone()
    }

    pub fn is_idle(&self) -> bool {
        let st = self.inner.lock();
        st.running.is_none() && st.queue.is_empty()
    }

    /// The job a frame's page should show: the one running, else the first waiting.
    pub fn snapshot(&self, frame: &FrameId, matches: impl Fn(&RenderJob) -> bool) -> Option<JobSnapshot> {
        let st = self.inner.lock();
        let mine: Vec<&JobSnapshot> =
            st.snapshots.iter().filter(|s| &s.job.frame_id == frame && matches(&s.job)).collect();
        mine.iter().find(|s| s.is_running()).or(mine.first()).map(|s| (*s).clone())
    }

    /// The budget a job would be given this instant, and the reading it was made from. `asked`: for a
    /// job someone waits on.
    pub fn budget_now(&self, asked: bool) -> (MemoryBudget, MemoryReading) {
        let reading = self.inner.read_memory();
        let st = self.inner.lock();
        let warm = st.camera_warm(Instant::now());
        (
            MemoryBudget::compute(
                &reading,
                &st.frontend,
                &st.config.tuning,
                warm,
                asked && st.config.reclaims_for_asked,
            ),
            reading,
        )
    }

    // ---- asking for a render ----

    pub fn submit(&self, asked: RenderJob) -> JobId {
        self.inner.submit(asked)
    }

    /// The job's end, whenever it comes. Safe to call before or after it ends.
    pub async fn outcome(&self, id: JobId) -> JobOutcome {
        let rx = {
            let mut st = self.inner.lock();
            if let Some(done) = st.outcomes.get(&id) {
                return done.clone();
            }
            if !st.snapshots.iter().any(|s| s.id == id) {
                return JobOutcome::Cancelled;
            }
            let (tx, rx) = oneshot::channel();
            st.waiters.entry(id).or_default().push(tx);
            rx
        };
        rx.await.unwrap_or(JobOutcome::Cancelled)
    }

    /// Drop the payload a finished job's kept outcome carries (it has been delivered).
    pub fn release_payload(&self, id: JobId) {
        if let Some(JobOutcome::Finished(r)) = self.inner.lock().outcomes.get_mut(&id) {
            if let Some(d) = r.delivery.as_mut() {
                d.payload = Arc::new(Vec::new());
            }
        }
    }

    pub fn cancel(&self, id: JobId) {
        self.inner.cancel(id);
    }

    /// Every job for a frame: it was deleted, or its page closed.
    pub fn cancel_all(&self, frame: &FrameId, matches: impl Fn(&RenderJob) -> bool) {
        let ids: Vec<JobId> = {
            let st = self.inner.lock();
            let mut ids: Vec<JobId> =
                st.queue.iter().filter(|j| &j.frame_id == frame && matches(j)).map(|j| j.id).collect();
            if let Some(r) = &st.running {
                if &r.job.frame_id == frame && matches(&r.job) {
                    ids.push(r.job.id);
                }
            }
            ids
        };
        for id in ids {
            self.inner.cancel(id);
        }
    }

    // ---- signals ----

    /// What the frontend is doing. Any change re-plans.
    pub fn set_frontend(&self, frontend: FrontendState) {
        self.inner.set_frontend(frontend);
    }

    /// Change one part of what the frontend is doing (`s.frontend.capturesInFlight = 1`).
    pub fn update_frontend(&self, change: impl FnOnce(&mut FrontendState)) {
        let mut f = self.frontend();
        change(&mut f);
        self.set_frontend(f);
    }

    /// The operating system's memory pressure, a memory warning, or the watch.
    pub fn memory_pressure(&self, level: Pressure) {
        self.inner.memory_pressure(level);
    }
}

impl Inner {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn arc(&self) -> Arc<Inner> {
        self.me.upgrade().expect("the queue is alive while it is called")
    }

    fn hooks(&self) -> Hooks {
        self.hooks.read().unwrap().clone()
    }

    fn read_memory(&self) -> MemoryReading {
        let f = self.hooks.read().unwrap().read_memory.clone();
        f()
    }

    fn spawn(&self, task: impl Future<Output = ()> + Send + 'static) -> JoinHandle<()> {
        self.runtime.spawn(task)
    }

    /// Run what an operation left to do outside the lock.
    fn apply(&self, fx: Fx) {
        let hooks = self.hooks();
        for action in fx.0 {
            match action {
                Action::Update(s) => {
                    if let Some(f) = &hooks.on_update {
                        f(&s)
                    }
                }
                Action::Record(r) => {
                    if let Some(f) = &hooks.on_record {
                        f(&r)
                    }
                }
                Action::Resolve(senders, outcome) => {
                    for tx in senders {
                        let _ = tx.send(outcome.clone());
                    }
                }
                Action::Cancel(id) => self.engine.cancel(id),
                Action::TrimCaches => {
                    if let Some(f) = &hooks.on_trim_caches {
                        f()
                    }
                }
                Action::Reclaim => {
                    if let Some(f) = &hooks.on_reclaim {
                        f()
                    }
                }
                Action::SaveCorrections => {
                    if let Some(store) = &self.store {
                        let corrections = self.lock().cost_model.corrections().clone();
                        store.save(&corrections);
                    }
                }
                Action::Spawn(task) => {
                    self.spawn(task);
                }
                Action::SpawnTimer(kind, generation, task) => {
                    let handle = self.spawn(task);
                    let mut st = self.lock();
                    let timer = match kind {
                        TimerKind::Replan => &mut st.replan,
                        TimerKind::Watch => &mut st.watch,
                        TimerKind::IdleTrim => &mut st.idle_trim,
                    };
                    if timer.generation == generation {
                        timer.handle = Some(handle);
                    } else {
                        handle.abort();
                    }
                }
                Action::Pump => self.pump(),
            }
        }
    }

    // ---- submit, cancel ----

    fn submit(&self, asked: RenderJob) -> JobId {
        // What an open holds must be known before the job runs (hooks asked outside the lock).
        let hooks = self.hooks();
        let mut job = if asked.composition.is_none() {
            match hooks.composition.as_ref().and_then(|f| f(&asked)) {
                Some(c) => asked.composed(Some(c)),
                None => asked,
            }
        } else {
            asked
        };
        if job.watermark_bytes == 0 {
            if let Some(bytes) = hooks.marks.as_ref().map(|f| f(&job)) {
                if bytes > 0 {
                    job = job.marked(bytes);
                }
            }
        }
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            let now = Instant::now();
            if job.kind.is_canvas() {
                // Latest wins: an older canvas job for this frame that has not started is dropped.
                let old: Vec<RenderJob> =
                    st.queue.iter().filter(|o| o.kind.is_canvas() && o.frame_id == job.frame_id).cloned().collect();
                for o in &old {
                    st.finish(&mut fx, o, JobOutcome::Cancelled);
                }
                st.queue.retain(|o| !(o.kind.is_canvas() && o.frame_id == job.frame_id));
                // One already running is given a reprint's time to finish.
                if let Some(r) = &st.running {
                    if r.job.kind.is_canvas() && r.job.frame_id == job.frame_id {
                        let after = st.cost_model.estimate(&job, &RenderMode::Whole).seconds;
                        self.supersede(&mut fx, r.job.id, after);
                    }
                }
            }
            if job.kind == JobKind::ImportDevelop {
                // A frame's own develop asked again before the first started: of the same size only.
                let same = |o: &RenderJob| {
                    o.kind == JobKind::ImportDevelop && o.frame_id == job.frame_id && o.tier == job.tier
                };
                let old: Vec<RenderJob> = st.queue.iter().filter(|o| same(o)).cloned().collect();
                for o in &old {
                    st.finish(&mut fx, o, JobOutcome::Cancelled);
                }
                st.queue.retain(|o| !same(o));
            }
            if job.kind == JobKind::StockPreview && st.config.previews_coalesce && job.slot.is_some() {
                // The newer card for a slot is the one wanted: the older, queued, is dropped, and one
                // running is stopped now.
                let same =
                    |o: &RenderJob| o.kind == JobKind::StockPreview && o.frame_id == job.frame_id && o.slot == job.slot;
                let old: Vec<RenderJob> = st.queue.iter().filter(|o| same(o)).cloned().collect();
                for o in &old {
                    st.finish(&mut fx, o, JobOutcome::Cancelled);
                }
                st.queue.retain(|o| !same(o));
                let running = st.running.as_ref().filter(|r| same(&r.job) && r.reason.is_none()).map(|r| r.job.id);
                if let Some(id) = running {
                    st.running.as_mut().unwrap().reason = Some(CancelReason::Superseded);
                    fx.push(Action::Cancel(id));
                }
            }
            st.queue.push(job.clone());
            let snapshot = JobSnapshot { id: job.id, job: job.clone(), state: SnapshotState::Queued, mode: None };
            st.snapshots.push(snapshot.clone());
            fx.push(Action::Update(snapshot));
            // Anything more urgent than what is running: the running job gives way — a card at once.
            // (A card does not stop the library's develop under way.)
            let yielding = st.running.as_ref().and_then(|r| {
                let urgent = r.job.kind.priority() > job.kind.priority()
                    && !(job.kind == JobKind::StockPreview && r.job.kind == JobKind::ImportDevelop);
                urgent.then(|| (r.job.kind == JobKind::StockPreview && st.config.previews_give_way_at_once, r.job.id))
            });
            if let Some((force, id)) = yielding {
                st.yield_running(&mut fx, id, "a more urgent job", force, now);
            }
            fx.push(Action::Pump);
        }
        let id = job.id;
        self.apply(fx);
        id
    }

    fn cancel(&self, id: JobId) {
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            if let Some(job) = st.queue.iter().find(|j| j.id == id).cloned() {
                st.queue.retain(|j| j.id != id);
                st.finish(&mut fx, &job, JobOutcome::Cancelled);
                fx.push(Action::Pump);
            } else if st.running.as_ref().is_some_and(|r| r.job.id == id) {
                st.running.as_mut().unwrap().reason = Some(CancelReason::User);
                fx.push(Action::Cancel(id));
            }
        }
        self.apply(fx);
    }

    // ---- signals ----

    fn set_frontend(&self, frontend: FrontendState) {
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            let old = st.frontend.clone();
            if frontend == old {
                return;
            }
            let now = Instant::now();
            // A photo has landed when a capture in flight is one fewer. The camera set up differently,
            // or stopped, is a session that has yet to deliver its first.
            if frontend.camera != old.camera {
                st.last_photo_landed = None;
            } else if frontend.camera_live() && frontend.captures_in_flight < old.captures_in_flight {
                st.last_photo_landed = Some(now);
            }
            st.frontend = frontend.clone();
            // frontendChanged(): a job the new state forbids gives way, then the queue re-plans.
            let stop = st
                .running
                .as_ref()
                .filter(|r| r.reason.is_none())
                .and_then(|r| st.must_stop(r, now).map(|w| (r.job.id, w)));
            if let Some((id, why)) = stop {
                st.yield_running(&mut fx, id, why.text(), true, now);
            }
            st.replan.cancel();
            fx.push(Action::Pump);
            if frontend.camera_live() && !old.camera_live() && !st.config.develops_beside_camera {
                // cameraOpened(): the closed darkroom gives back what it holds while the camera starts.
                fx.push(Action::TrimCaches);
                let engine = self.engine.clone();
                fx.push(Action::Spawn(Box::pin(async move {
                    engine.trim().await;
                })));
            }
            if frontend.scene != Scene::Active && old.scene == Scene::Active && st.config.reclaims_for_asked {
                // leftFront(): what the darkroom holds goes back.
                fx.push(Action::TrimCaches);
                fx.push(Action::Reclaim);
                let engine = self.engine.clone();
                fx.push(Action::Spawn(Box::pin(async move {
                    let freed = engine.reclaim(None).await;
                    log::info!(target: "scheduler", "left the front: the engine gave back {:.0} MB", megabytes(freed));
                })));
            }
        }
        self.apply(fx);
    }

    fn memory_pressure(&self, level: Pressure) {
        log::info!(target: "scheduler", "memory pressure: {}", if level == Pressure::Critical { "critical" } else { "warning" });
        let mut fx = Fx::default();
        fx.push(Action::TrimCaches);
        let engine = self.engine.clone();
        fx.push(Action::Spawn(Box::pin(async move {
            engine.trim().await;
        })));
        {
            let mut st = self.lock();
            // Only a full-size job is cancelled to run again smaller; the page's picture is one piece.
            let cancel = st
                .running
                .as_ref()
                .filter(|r| level == Pressure::Critical && r.reason.is_none() && r.job.tier == RenderTier::Full)
                .map(|r| r.job.id);
            if let Some(id) = cancel {
                st.running.as_mut().unwrap().reason = Some(CancelReason::Pressure);
                fx.push(Action::Cancel(id));
            } else {
                st.replan.cancel();
                fx.push(Action::Pump);
            }
        }
        self.apply(fx);
    }

    fn replan(&self) {
        self.lock().replan.cancel();
        self.pump();
    }

    // ---- the loop ----

    fn pump(&self) {
        {
            let st = self.lock();
            if st.running.is_some() {
                return;
            }
            if st.queue.is_empty() {
                drop(st);
                self.idle();
                return;
            }
        }
        // Read before the lock: a reading may ask the queue about itself.
        let reading = self.read_memory();
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            if st.running.is_some() {
                return;
            }
            if st.queue.is_empty() {
                drop(st);
                self.idle();
                return;
            }
            self.pump_locked(&mut st, &mut fx, reading);
        }
        self.apply(fx);
    }

    fn pump_locked(&self, st: &mut State, fx: &mut Fx, reading: MemoryReading) {
        let now = Instant::now();
        let warm = st.camera_warm(now);
        let tuning = st.config.tuning.clone();
        let reclaims = st.config.reclaims_for_asked;
        let budget = MemoryBudget::compute(&reading, &st.frontend, &tuning, warm, false);
        let asked_budget =
            if reclaims { MemoryBudget::compute(&reading, &st.frontend, &tuning, warm, true) } else { budget.clone() };
        // In front, every job asks the host as hard as one someone waits on.
        let in_front = reclaims && st.frontend.scene == Scene::Active;
        // Priority, then age (a stable sort: the same instant keeps the order of submission).
        let mut ordered = st.queue.clone();
        ordered.sort_by(|a, b| a.kind.priority().cmp(&b.kind.priority()).then(a.submitted.cmp(&b.submitted)));
        let mut soonest: Option<f64> = None;
        // A card waits for every other job, running or waiting — not the library's develops or thumbnails.
        let others_queued = st
            .queue
            .iter()
            .any(|j| !matches!(j.kind, JobKind::StockPreview | JobKind::ImportDevelop | JobKind::Thumbnail));
        for job in &ordered {
            // A hot host lowers cadence, never the effects (S6).
            if job.kind == JobKind::CanvasReprint {
                if let Some(hold) = st.cadence_hold(now) {
                    soonest = Some(soonest.map_or(hold, |s| s.min(hold)));
                    continue;
                }
            }
            if job.kind == JobKind::StockPreview && others_queued && st.config.previews_wait_for_the_queue {
                st.push_wait(job.id, WaitReason::Queued);
                st.update(fx, job.id, |s| {
                    s.state = SnapshotState::Waiting(WaitReason::Queued);
                    s.mode = None;
                });
                continue;
            }
            let derate = st.current_derate(job.id, now);
            let plan = Planner::plan(
                job,
                if job.kind.is_asked() || in_front { &asked_budget } else { &budget },
                &st.frontend,
                &st.cost_model,
                derate,
                st.config.capture_rule,
                st.config.develops_beside_camera,
            );
            st.last_plan = Some(plan.clone());
            if let RenderMode::Wait(why) = plan.mode {
                st.push_wait(job.id, why);
                st.update(fx, job.id, |s| {
                    s.state = SnapshotState::Waiting(why);
                    s.mode = Some(plan.mode);
                });
                if why == WaitReason::Memory && job.kind.is_asked() {
                    st.waiting_for_memory_since.entry(job.id).or_insert(now);
                }
                continue; // a smaller job further down may still fit
            }
            self.start(st, fx, job.clone(), plan, reading, now);
            return;
        }
        // A job someone waits on cannot fit: the app gives back its own memory, one rung at a time;
        // with nothing left to give, it starts in its smallest mode under the watch rather than wait.
        if reclaims {
            let asked = ordered
                .iter()
                .find(|j| j.kind.is_asked() && st.waits.get(&j.id).and_then(|w| w.last()) == Some(&WaitReason::Memory))
                .cloned();
            if let Some(asked) = asked {
                if st.reclaimed < 2 {
                    self.reclaim(st, fx, &asked, &reading, now);
                    return;
                }
                let since = st.waiting_for_memory_since.get(&asked.id).copied();
                let not_stopped_lately =
                    st.forced_stopped_at.get(&asked.id).map_or(true, |t| since_secs(now, *t) > 10.0);
                if let Some(since_t) = since {
                    if since_secs(now, since_t) >= st.config.force_after && not_stopped_lately {
                        if let Some(plan) = st.forced_plan(&asked, &asked_budget, now) {
                            log::info!(target: "scheduler", "{} has waited {:.1} s for memory with nothing left to give back: it starts in {}, the watch on it",
                                asked.kind.raw_value(), since_secs(now, since_t), plan.mode.name());
                            st.forced.insert(asked.id);
                            self.start(st, fx, asked, plan, reading, now);
                            return;
                        }
                    }
                    // The desktop's longer bound: it starts anyway, past what the host has left.
                    if let Some(bound) = st.config.force_anyway_after {
                        if since_secs(now, since_t) >= bound && not_stopped_lately {
                            if let Some(plan) = st.anyway_plan(&asked, &asked_budget) {
                                log::info!(target: "scheduler", "{} has waited {:.1} s for memory, past the {:.1} s bound: it starts anyway in {}, the watch on it",
                                    asked.kind.raw_value(), since_secs(now, since_t), bound, plan.mode.name());
                                st.forced.insert(asked.id);
                                self.start(st, fx, asked, plan, reading, now);
                                return;
                            }
                        }
                    }
                }
            }
        }
        // Nothing could start. If memory is why, the engine's own idle pool is the first place to look.
        if st.config.trims_when_waiting
            && !st.trimmed_for_wait
            && st.queue.iter().any(|j| {
                matches!(
                    st.waits.get(&j.id).and_then(|w| w.last()),
                    Some(WaitReason::Memory | WaitReason::Camera | WaitReason::Background)
                )
            })
        {
            st.trimmed_for_wait = true;
            let engine = self.engine.clone();
            let me = self.me.clone();
            fx.push(Action::Spawn(Box::pin(async move {
                let freed = engine.trim().await;
                if freed == 0 {
                    return;
                }
                log::info!(target: "scheduler", "a job waits for memory: {:.0} MB of idle pool given back", megabytes(freed));
                if let Some(me) = me.upgrade() {
                    me.replan();
                }
            })));
        }
        // Signals re-plan at once; otherwise look again soon.
        let recently = st.reclaimed_at.is_some_and(|t| since_secs(now, t) < 2.0);
        let interval = st.config.replan_interval;
        let delay = soonest.unwrap_or(if recently || !st.waiting_for_memory_since.is_empty() {
            interval.min(0.15)
        } else {
            interval
        });
        self.schedule_pump(st, fx, delay);
    }

    /// Look again after `delay` (the replan task).
    fn schedule_pump(&self, st: &mut State, fx: &mut Fx, delay: f64) {
        st.replan.cancel();
        let generation = st.replan.generation;
        let me = self.me.clone();
        fx.push(Action::SpawnTimer(
            TimerKind::Replan,
            generation,
            Box::pin(async move {
                tokio::time::sleep(secs(delay)).await;
                let Some(me) = me.upgrade() else { return };
                {
                    let mut st = me.lock();
                    if st.replan.generation != generation {
                        return;
                    }
                    st.replan.handle = None;
                }
                me.pump();
            }),
        ));
    }

    fn start(
        &self,
        st: &mut State,
        fx: &mut Fx,
        job: RenderJob,
        plan: RenderPlan,
        reading: MemoryReading,
        now: Instant,
    ) {
        st.idle_trim.cancel();
        st.queue.retain(|j| j.id != job.id);
        st.trimmed_for_wait = false;
        st.reclaimed = 0;
        st.waiting_for_memory_since.remove(&job.id);
        let first = if job.decodes_original {
            RenderStage::Decode
        } else if job.is_reprint() {
            RenderStage::Print
        } else {
            RenderStage::Film
        };
        let mode = plan.mode;
        st.update(fx, job.id, |s| {
            s.state = SnapshotState::Running(RenderProgress::new(first, 0.0));
            s.mode = Some(mode);
        });
        if job.kind == JobKind::CanvasReprint {
            st.last_reprint_start = Some(now);
        }
        st.running = Some(Running { job: job.clone(), plan: plan.clone(), started: now, reason: None });
        log::info!(target: "scheduler", "start {} {:.1} MP in {}: predicted {:.0} MB of {:.0} MB, {:.2} s",
            job.kind.raw_value(), job.canvas.megapixels(), plan.mode.name(),
            megabytes(plan.estimate.peak_bytes), megabytes(plan.budget.bytes), plan.estimate.seconds);
        let engine = self.engine.clone();
        let me = self.arc();
        let weak = self.me.clone();
        let id = job.id;
        let progress: ProgressFn = Arc::new(move |p| {
            if let Some(me) = weak.upgrade() {
                me.progressed(id, p);
            }
        });
        fx.push(Action::Spawn(Box::pin(async move {
            let result = engine.run(&job, &plan.mode, progress).await;
            me.ended(job, plan, now, reading, result);
        })));
        // Full-size jobs only: the page's own picture is never stopped by the watch.
        if st.running.as_ref().is_some_and(|r| r.job.tier == RenderTier::Full) {
            let asked = st.running.as_ref().unwrap().job.kind.is_asked()
                && st.config.reclaims_for_asked
                && !st.frontend.camera_live()
                && st.frontend.scene == Scene::Active;
            self.watch(st, fx, asked);
        }
    }

    /// One rung of giving back what the app holds, for a job someone waits on.
    fn reclaim(&self, st: &mut State, fx: &mut Fx, job: &RenderJob, before: &MemoryReading, now: Instant) {
        st.reclaimed += 1;
        st.reclaimed_at = Some(now);
        if st.reclaimed == 1 {
            fx.push(Action::TrimCaches);
            fx.push(Action::Reclaim);
            log::info!(target: "scheduler", "{} waits for memory: the frontend's caches go", job.kind.raw_value());
            self.replan_soon(st, fx);
        } else {
            let engine = self.engine.clone();
            let keeping = if job.kind.is_canvas() { Some(job.frame_id.clone()) } else { None };
            let me = self.me.clone();
            let kind = job.kind;
            let headroom = before.phone_headroom();
            fx.push(Action::Spawn(Box::pin(async move {
                let freed = engine.reclaim(keeping.as_ref()).await;
                let Some(me) = me.upgrade() else { return };
                log::info!(target: "scheduler", "{} waits for memory: the engine gave back {:.0} MB (headroom was {:.0} MB)",
                    kind.raw_value(), megabytes(freed), megabytes(headroom));
                let mut fx = Fx::default();
                {
                    let mut st = me.lock();
                    me.replan_soon(&mut st, &mut fx);
                }
                me.apply(fx);
            })));
        }
    }

    fn replan_soon(&self, st: &mut State, fx: &mut Fx) {
        self.schedule_pump(st, fx, 0.1);
    }

    fn progressed(&self, id: JobId, p: RenderProgress) {
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            if st.running.as_ref().map(|r| r.job.id) != Some(id) {
                return;
            }
            st.update(&mut fx, id, |s| s.state = SnapshotState::Running(p));
        }
        self.apply(fx);
    }

    fn ended(
        &self,
        job: RenderJob,
        plan: RenderPlan,
        _started: Instant,
        reading: MemoryReading,
        result: Result<RenderResult, EngineError>,
    ) {
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            let now = Instant::now();
            let mine = st.running.as_ref().is_some_and(|r| r.job.id == job.id);
            let reason = if mine { st.running.as_ref().unwrap().reason } else { None };
            if mine {
                st.running = None;
            }
            let was_forced = st.forced.remove(&job.id);
            st.watch.cancel();
            match result {
                Ok(r) => {
                    // Learned only from the job that was priced.
                    let over_opened = r
                        .measured
                        .as_ref()
                        .and_then(|m| m.opened)
                        .is_some_and(|o| job.tier != RenderTier::Full && job.is_over_opened(o));
                    if !job.is_over_asked(r.size) && !over_opened {
                        st.cost_model.learn(&job, &plan.mode, r.peak_bytes, r.seconds);
                        fx.push(Action::SaveCorrections);
                    }
                    self.record(&mut st, &mut fx, &job, &plan, &reading, "done", Some(&r), now);
                    if was_forced {
                        log::info!(target: "scheduler", "{}, started past the host's headroom, finished", job.kind.raw_value());
                    }
                    st.finish(&mut fx, &job, JobOutcome::Finished(r));
                }
                Err(EngineError::Cancelled) => match reason {
                    Some(CancelReason::Yielded) | Some(CancelReason::Pressure) => {
                        // It runs again from the start (phase 1). After pressure the same reading is
                        // trusted less, so the next plan is a smaller mode.
                        if reason == Some(CancelReason::Pressure) {
                            let d = st.current_derate(job.id, now) * 0.6;
                            st.derate.insert(job.id, (d, now));
                        }
                        let outcome = if reason == Some(CancelReason::Pressure) {
                            "cancelled: pressure, runs again smaller"
                        } else {
                            "cancelled: gave way, runs again"
                        };
                        self.record(&mut st, &mut fx, &job, &plan, &reading, outcome, None, now);
                        st.queue.push(job.clone());
                        st.update(&mut fx, job.id, |s| {
                            s.state = SnapshotState::Queued;
                            s.mode = None;
                        });
                    }
                    Some(CancelReason::Superseded) => {
                        self.record(&mut st, &mut fx, &job, &plan, &reading, "cancelled: superseded", None, now);
                        st.finish(&mut fx, &job, JobOutcome::Cancelled);
                    }
                    Some(CancelReason::User) | None => {
                        self.record(&mut st, &mut fx, &job, &plan, &reading, "cancelled", None, now);
                        st.finish(&mut fx, &job, JobOutcome::Cancelled);
                    }
                },
                Err(e) => {
                    let message = e.message();
                    self.record(&mut st, &mut fx, &job, &plan, &reading, &format!("failed: {message}"), None, now);
                    st.finish(&mut fx, &job, JobOutcome::Failed(message));
                }
            }
            fx.push(Action::Pump);
        }
        self.apply(fx);
    }

    /// A running canvas job is cancelled once the newer one has waited a reprint's time (§6.9).
    fn supersede(&self, fx: &mut Fx, id: JobId, after: f64) {
        let me = self.me.clone();
        fx.push(Action::Spawn(Box::pin(async move {
            tokio::time::sleep(secs(after.max(0.02))).await;
            let Some(me) = me.upgrade() else { return };
            let cancel = {
                let mut st = me.lock();
                match st.running.as_mut() {
                    Some(r) if r.job.id == id && r.reason.is_none() => {
                        r.reason = Some(CancelReason::Superseded);
                        true
                    }
                    _ => false,
                }
            };
            if cancel {
                me.engine.cancel(id);
            }
        })));
    }

    /// The host's headroom, every 50 ms while a full-size job runs (§6.2).
    fn watch(&self, st: &mut State, fx: &mut Fx, asked: bool) {
        st.watch.cancel();
        let generation = st.watch.generation;
        let floor = if asked { st.config.tuning.asked_watch_floor } else { st.config.tuning.floor_reserve / 4 * 3 };
        let allowance: u64 = if asked { 160 << 20 } else { 64 << 20 };
        let me = self.me.clone();
        fx.push(Action::SpawnTimer(
            TimerKind::Watch,
            generation,
            Box::pin(async move {
                loop {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    let Some(me) = me.upgrade() else { return };
                    {
                        let st = me.lock();
                        if st.watch.generation != generation || st.running.is_none() {
                            return;
                        }
                    }
                    let reading = me.read_memory();
                    if reading.phone_headroom() < floor || reading.app_available < allowance {
                        {
                            let mut st = me.lock();
                            if st.watch.generation != generation {
                                return;
                            }
                            if let Some(id) = st.running.as_ref().map(|r| r.job.id) {
                                if st.forced.contains(&id) {
                                    st.forced_stopped_at.insert(id, Instant::now());
                                }
                            }
                        }
                        me.memory_pressure(Pressure::Critical);
                        return;
                    }
                }
            }),
        ));
    }

    /// Nothing queued and nothing running: the engine's pool goes back once the queue has been idle for
    /// `idle_trim_after` — not at once.
    fn idle(&self) {
        let mut fx = Fx::default();
        {
            let mut st = self.lock();
            st.replan.cancel();
            st.idle_trim.cancel();
            let generation = st.idle_trim.generation;
            let after = st.config.idle_trim_after;
            let me = self.me.clone();
            let engine = self.engine.clone();
            fx.push(Action::SpawnTimer(
                TimerKind::IdleTrim,
                generation,
                Box::pin(async move {
                    tokio::time::sleep(secs(after)).await;
                    {
                        let Some(me) = me.upgrade() else { return };
                        let st = me.lock();
                        if st.idle_trim.generation != generation || st.running.is_some() || !st.queue.is_empty() {
                            return;
                        }
                    }
                    let freed = engine.trim().await;
                    if freed > 0 {
                        log::info!(target: "scheduler", "idle {after:.0} s: {:.0} MB of the engine's pool given back", megabytes(freed));
                    }
                }),
            ));
        }
        self.apply(fx);
    }

    #[allow(clippy::too_many_arguments)]
    fn record(
        &self,
        st: &mut State,
        fx: &mut Fx,
        job: &RenderJob,
        plan: &RenderPlan,
        reading: &MemoryReading,
        outcome: &str,
        measured: Option<&RenderResult>,
        now: Instant,
    ) {
        // What the engine did, beside what was asked. A real engine that reports no bands rendered whole.
        let ran = measured.and_then(|m| match m.bands {
            Some(b) => Some(format!("bands({}) x {}, halo {}", b.rows, b.count, b.halo)),
            None => m.measured.as_ref().map(|_| "whole".to_string()),
        });
        let warm = st.camera_warm(now);
        let r = JobRecord {
            job_id: job.id,
            kind: job.kind.raw_value().into(),
            tier: job.tier.raw_value().into(),
            megapixels: job.canvas.megapixels(),
            mode: plan.mode.name(),
            budget_bytes: plan.budget.bytes,
            predicted_peak_bytes: plan.estimate.peak_bytes,
            predicted_phone_bytes: Some(plan.estimate.phone_bytes),
            measured_peak_bytes: measured.map(|m| m.peak_bytes).filter(|p| *p > 0),
            predicted_seconds: plan.estimate.seconds,
            measured_seconds: measured.map(|m| m.seconds),
            waits: st
                .waits
                .get(&job.id)
                .map(|w| w.iter().map(|r| r.raw_value().to_string()).collect())
                .unwrap_or_default(),
            outcome: outcome.into(),
            at: self.clock.date(now),
            ran,
            app_side_bytes: Some(plan.budget.app_side),
            phone_side_bytes: Some(plan.budget.phone_side),
            binding: Some(plan.budget.binding.raw_value().into()),
            camera_reserve_bytes: Some(plan.budget.camera_reserve),
            reading: Some(*reading),
            frontend: Some(st.frontend.text() + if warm { "; the camera has taken a photo" } else { "" }),
            measurement: measured.and_then(|m| m.measured.clone()),
            rendered_instead: measured.and_then(|m| job.rendered_instead(m.size)),
            opened_instead: if job.tier == RenderTier::Full {
                None
            } else {
                measured.and_then(|m| m.measured.as_ref()).and_then(|m| m.opened).and_then(|o| job.opened_instead(o))
            },
        };
        if let Some(m) = measured {
            if job.is_over_asked(m.size) {
                log::error!(target: "scheduler", "{} was asked and priced at {} x {} and the engine rendered {} x {}",
                    job.kind.raw_value(), job.canvas.width, job.canvas.height, m.size.width, m.size.height);
            }
            if job.tier != RenderTier::Full {
                if let Some(o) = m.measured.as_ref().and_then(|x| x.opened) {
                    if job.is_over_opened(o) {
                        log::error!(target: "scheduler", "{} was priced at {} x {} and was handed a frame of {} x {} to open",
                            job.kind.raw_value(), job.canvas.width, job.canvas.height, o.width, o.height);
                    }
                }
            }
            if matches!(plan.mode, RenderMode::Bands { .. }) && m.measured.is_some() && m.bands.is_none() {
                // The plan and the render parted ways: the v1 host renders every frame whole.
                log::warn!(target: "scheduler", "{} was planned in {} and the engine rendered it whole", job.kind.raw_value(), plan.mode.name());
            }
        }
        st.records.push_back(r.clone());
        while st.records.len() > 200 {
            st.records.pop_front();
        }
        log::info!(target: "scheduler", "{} {}: {}, {:.2} s against {:.2} s predicted", job.kind.raw_value(), outcome,
            plan.mode.name(), measured.map_or(0.0, |m| m.seconds), plan.estimate.seconds);
        fx.push(Action::Record(r));
    }
}

fn since_secs(now: Instant, then: Instant) -> f64 {
    since(now, then)
}

impl State {
    /// The session has delivered a photo lately.
    fn camera_warm(&self, now: Instant) -> bool {
        if !self.frontend.camera_live() {
            return false;
        }
        match self.last_photo_landed {
            Some(landed) => since(now, landed) <= self.config.tuning.camera_warm_seconds,
            None => false,
        }
    }

    fn push_wait(&mut self, id: JobId, why: WaitReason) {
        let waits = self.waits.entry(id).or_default();
        if waits.last() != Some(&why) {
            waits.push(why);
        }
    }

    fn update(&mut self, fx: &mut Fx, id: JobId, change: impl FnOnce(&mut JobSnapshot)) {
        let Some(i) = self.snapshots.iter().position(|s| s.id == id) else { return };
        let mut s = self.snapshots[i].clone();
        change(&mut s);
        if s == self.snapshots[i] {
            return;
        }
        self.snapshots[i] = s.clone();
        fx.push(Action::Update(s));
    }

    fn finish(&mut self, fx: &mut Fx, job: &RenderJob, outcome: JobOutcome) {
        if let Some(i) = self.snapshots.iter().position(|s| s.id == job.id) {
            let mut s = self.snapshots.remove(i);
            s.state = match &outcome {
                JobOutcome::Finished(_) => SnapshotState::Done,
                JobOutcome::Cancelled => SnapshotState::Cancelled,
                JobOutcome::Failed(m) => SnapshotState::Failed(m.clone()),
            };
            fx.push(Action::Update(s));
        }
        self.waits.remove(&job.id);
        self.derate.remove(&job.id);
        self.waiting_for_memory_since.remove(&job.id);
        self.forced_stopped_at.remove(&job.id);
        self.outcomes.insert(job.id, outcome.clone());
        self.outcome_order.push_back(job.id);
        if self.outcome_order.len() > 100 {
            if let Some(old) = self.outcome_order.pop_front() {
                self.outcomes.remove(&old);
            }
        }
        self.trim_kept_payloads();
        if let Some(waiters) = self.waiters.remove(&job.id) {
            fx.push(Action::Resolve(waiters, outcome));
        }
    }

    /// The payloads finished jobs keep for a late `outcome` call: at most `KEPT_PAYLOAD_BYTES` in all,
    /// the oldest dropped first (the desktop's addition: the Mac hands pixels over in `deliver`).
    fn trim_kept_payloads(&mut self) {
        let mut total: u64 = 0;
        for id in self.outcome_order.iter().rev() {
            if let Some(JobOutcome::Finished(r)) = self.outcomes.get_mut(id) {
                if let Some(d) = r.delivery.as_mut() {
                    let n = d.payload.len() as u64;
                    if total + n > KEPT_PAYLOAD_BYTES {
                        d.payload = Arc::new(Vec::new());
                    } else {
                        total += n;
                    }
                }
            }
        }
    }

    /// How much of the budget a job is trusted with: 1, or less for a while after pressure cancelled it.
    fn current_derate(&self, id: JobId, now: Instant) -> f64 {
        let Some((factor, at)) = self.derate.get(&id) else { return 1.0 };
        let back = since(now, *at) / self.config.pressure_recovery.max(0.001);
        (factor + (1.0 - factor) * back).min(1.0)
    }

    /// Print-side updates at most 8 a second on a `serious` host and 4 on a `critical` one (§6.7).
    fn cadence_hold(&self, now: Instant) -> Option<f64> {
        let interval = match self.frontend.thermal {
            Thermal::Nominal | Thermal::Fair => return None,
            Thermal::Serious => 1.0 / 8.0,
            Thermal::Critical => 1.0 / 4.0,
        };
        let last = self.last_reprint_start?;
        let s = since(now, last);
        if s >= interval {
            None
        } else {
            Some(interval - s)
        }
    }

    /// Why a running job may not go on in the frontend's new state, or nil.
    fn must_stop(&self, r: &Running, now: Instant) -> Option<WaitReason> {
        let why = Planner::gate(
            &r.job,
            &self.frontend,
            &self.cost_model.policy,
            CaptureRule::Stops,
            self.config.develops_beside_camera,
        )?;
        if !(why == WaitReason::Capture
            && r.job.tier != RenderTier::Full
            && self.config.capture_rule != CaptureRule::Stops)
        {
            return Some(why);
        }
        // Below the full tier a develop goes on under as many captures as its budget kept aside.
        let taken = self.config.tuning.camera_growth(self.frontend.camera_photo_megapixels(), self.camera_warm(now))
            * self.frontend.captures_in_flight.max(0) as u64;
        if taken > r.plan.budget.camera_reserve {
            Some(WaitReason::Capture)
        } else {
            None
        }
    }

    /// A running job gives way. Short jobs are left to finish unless they must stop (`force`).
    fn yield_running(&mut self, fx: &mut Fx, id: JobId, what: &str, force: bool, now: Instant) {
        let threshold = self.config.yield_threshold;
        let Some(r) = self.running.as_mut() else { return };
        if r.job.id != id || r.reason.is_some() {
            return;
        }
        let left = r.plan.estimate.seconds - since(now, r.started);
        if !(force || left > threshold) {
            return;
        }
        log::info!(target: "scheduler", "{} gives way to {}", r.job.kind.raw_value(), what);
        r.reason = Some(CancelReason::Yielded);
        fx.push(Action::Cancel(id));
    }

    /// The last resort for a job someone waits on: its smallest mode, held to the app's own allowance only.
    fn forced_plan(&self, job: &RenderJob, budget: &MemoryBudget, now: Instant) -> Option<RenderPlan> {
        Planner::gate(
            job,
            &self.frontend,
            &self.cost_model.policy,
            self.config.capture_rule,
            self.config.develops_beside_camera,
        )
        .is_none()
        .then_some(())?;
        let mode = Planner::ladder(job).last().copied().unwrap_or(RenderMode::Whole);
        let cost = self.cost_model.estimate(job, &mode);
        if cost.peak_bytes as f64 > budget.app_bytes as f64 * self.current_derate(job.id, now) {
            return None;
        }
        Some(RenderPlan { mode, estimate: cost, budget: budget.clone() })
    }

    /// `forced_plan` without the allowance: the smallest mode, where the frontend allows the job at all.
    fn anyway_plan(&self, job: &RenderJob, budget: &MemoryBudget) -> Option<RenderPlan> {
        Planner::gate(
            job,
            &self.frontend,
            &self.cost_model.policy,
            self.config.capture_rule,
            self.config.develops_beside_camera,
        )
        .is_none()
        .then_some(())?;
        let mode = Planner::ladder(job).last().copied().unwrap_or(RenderMode::Whole);
        Some(RenderPlan { mode, estimate: self.cost_model.estimate(job, &mode), budget: budget.clone() })
    }
}

/// The payloads of finished jobs not yet collected, at most this many bytes in all.
pub const KEPT_PAYLOAD_BYTES: u64 = 1 << 30;
