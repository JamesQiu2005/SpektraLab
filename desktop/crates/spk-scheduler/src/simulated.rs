//! A stand-in engine that keeps time and makes no picture (`SimulatedEngine.swift`).
//!
//! It takes as long as the measured engine takes (the cost model's own seeds, with a little spread) and
//! walks the same stages — on the queue's clock, so under tokio's paused time it takes virtual time
//! only. It renders nothing and holds no memory: a job's measured peak comes back 0 and the cost model's
//! peak correction is left alone. What it exercises is real: the queue, the budget, the mode chosen,
//! cancellation, coalescing, waits and their reasons.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tokio::time::Instant;

use crate::cost_model::{BandGeometry, CostModel};
use crate::device_policy::DevicePolicy;
use crate::engine::{DevelopEngine, EngineError, ProgressFn, RenderResult};
use crate::types::{JobId, PixelSize, RenderJob, RenderMode, RenderProgress, RenderStage};

type TrimFn = Arc<dyn Fn() -> u64 + Send + Sync>;
type RendersFn = Arc<dyn Fn(&RenderJob) -> PixelSize + Send + Sync>;

pub struct SimulatedEngine {
    model: CostModel,
    cancelled: Mutex<HashSet<JobId>>,
    /// 1 runs at the measured pace; the tests run faster.
    speed: f64,
    /// It holds no pool of its own; a test gives it one by saying what a trim frees.
    on_trim: Mutex<Option<TrimFn>>,
    /// It renders the size it is asked for; a test makes it render another.
    renders: Mutex<Option<RendersFn>>,
}

impl SimulatedEngine {
    pub fn new(policy: DevicePolicy, speed: f64) -> Self {
        SimulatedEngine {
            model: CostModel::new(policy),
            cancelled: Mutex::new(HashSet::new()),
            speed,
            on_trim: Mutex::new(None),
            renders: Mutex::new(None),
        }
    }

    pub fn set_on_trim(&self, f: impl Fn() -> u64 + Send + Sync + 'static) {
        *self.on_trim.lock().unwrap() = Some(Arc::new(f));
    }

    pub fn set_renders(&self, f: impl Fn(&RenderJob) -> PixelSize + Send + Sync + 'static) {
        *self.renders.lock().unwrap() = Some(Arc::new(f));
    }

    fn is_cancelled(&self, id: JobId) -> bool {
        self.cancelled.lock().unwrap().contains(&id)
    }

    fn clear(&self, id: JobId) {
        self.cancelled.lock().unwrap().remove(&id);
    }

    /// 0.92…1.08, from the job's id: the Swift's `Double.random(in:)` spread, reproducible.
    fn spread(id: JobId) -> f64 {
        let bits = id.0.as_u128();
        let mut x = (bits as u64) ^ ((bits >> 64) as u64) ^ 0x9E37_79B9_7F4A_7C15;
        x ^= x >> 33;
        x = x.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
        x ^= x >> 33;
        0.92 + 0.16 * ((x >> 11) as f64 / (1u64 << 53) as f64)
    }
}

fn secs(s: f64) -> Duration {
    Duration::from_secs_f64(if s.is_finite() { s.max(0.0) } else { 0.0 })
}

#[async_trait]
impl DevelopEngine for SimulatedEngine {
    fn name(&self) -> String {
        "simulated".into()
    }
    fn makes_pictures(&self) -> bool {
        false
    }
    fn effect_versions(&self) -> String {
        "simulated".into()
    }

    async fn run(&self, job: &RenderJob, mode: &RenderMode, progress: ProgressFn) -> Result<RenderResult, EngineError> {
        let started = Instant::now();
        let speed = self.speed.max(0.01);
        let total = self.model.seed(job, mode).seconds * Self::spread(job.id) / speed;
        let bands = match mode {
            RenderMode::Bands { rows } => BandGeometry::new(job.canvas).band_count(*rows),
            _ => 1,
        };
        // The stages a job walks, and each one's share of its time.
        let mut stages: Vec<(RenderStage, f64)> = if job.is_reprint() {
            vec![(RenderStage::Print, 0.7), (RenderStage::Scan, 0.3)]
        } else {
            vec![(RenderStage::Film, 0.62), (RenderStage::Print, 0.24), (RenderStage::Scan, 0.14)]
        };
        if job.decodes_original {
            let mut walked = vec![(RenderStage::Decode, 0.18)];
            walked.extend(stages.iter().map(|(s, share)| (*s, share * 0.72)));
            walked.push((RenderStage::Save, 0.10));
            stages = walked;
        }
        let mut done = 0.0;
        for (stage, share) in stages {
            // A node boundary every ~40 ms: where a cancel is noticed.
            let slices = ((total * share / 0.04).ceil() as i64).max(1);
            for i in 1..=slices {
                if self.is_cancelled(job.id) {
                    self.clear(job.id);
                    return Err(EngineError::Cancelled);
                }
                tokio::time::sleep(secs(total * share / slices as f64)).await;
                let fraction = done + share * i as f64 / slices as f64;
                progress(RenderProgress {
                    stage,
                    fraction: fraction.min(1.0),
                    band: (bands - 1).min((fraction * bands as f64) as i64),
                    band_count: bands,
                });
            }
            done += share;
        }
        if self.is_cancelled(job.id) {
            self.clear(job.id);
            return Err(EngineError::Cancelled);
        }
        let size = match self.renders.lock().unwrap().clone() {
            Some(f) => f(job),
            None => job.canvas,
        };
        Ok(RenderResult::new(started.elapsed().as_secs_f64() * speed, size, job.is_reprint()))
    }

    fn cancel(&self, job_id: JobId) {
        self.cancelled.lock().unwrap().insert(job_id);
    }

    async fn trim(&self) -> u64 {
        let f = self.on_trim.lock().unwrap().clone();
        f.map_or(0, |f| f())
    }

    async fn held_bytes(&self) -> u64 {
        0
    }
}
