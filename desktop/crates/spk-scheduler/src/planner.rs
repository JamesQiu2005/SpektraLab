//! The fastest way to render that fits, or not yet (`Planner.swift`, RFC-036 §6.4 and §6.7).
//!
//! Two questions, in this order:
//!
//! 1. **May this job run at all, given what the frontend is doing?** Nothing runs in the background;
//!    nothing starts while a photo is in flight; with the camera live an export waits, and so does a
//!    48 MP shot at full size. A host may close the darkroom to a camera (`beside_camera`).
//! 2. **Which mode?** The one with the least predicted time whose predicted cost fits the budget. Ties
//!    go to the larger band. If none fits, the job waits — it does not gamble (G1).
//!
//! **A job never drops below full quality.** What gives is time.

use crate::budget::MemoryBudget;
use crate::cost_model::{BandGeometry, CostEstimate, CostModel};
use crate::device_policy::DevicePolicy;
use crate::types::{CaptureRule, FrontendState, JobKind, RenderJob, RenderMode, RenderTier, Scene, WaitReason};

/// `RenderPlan`.
#[derive(Clone, Debug, PartialEq)]
pub struct RenderPlan {
    pub mode: RenderMode,
    pub estimate: CostEstimate,
    pub budget: MemoryBudget,
}

impl RenderPlan {
    pub fn waits(&self) -> bool {
        self.mode.is_wait()
    }
}

/// `Planner`.
pub struct Planner;

impl Planner {
    /// The modes a job could run in, fastest first.
    pub fn ladder(job: &RenderJob) -> Vec<RenderMode> {
        // Only a full-tier render bands; a canvas is one piece, and so is a frame with a crop or a turn.
        if !(job.tier == RenderTier::Full && job.kind != JobKind::Thumbnail && job.bandable) {
            return vec![RenderMode::Whole];
        }
        let g = BandGeometry::new(job.canvas);
        let mut modes = vec![RenderMode::Whole];
        let mut last = i64::MAX;
        for count in [2i64, 3, 4, 6, 8, 11, 16, 22, 32, 45, 64, 96] {
            let rows = BandGeometry::cuttable((job.canvas.height as f64 / count as f64).ceil() as i64);
            if rows < g.floor_rows {
                break;
            }
            if rows < last {
                modes.push(RenderMode::Bands { rows });
                last = rows;
            }
        }
        modes
    }

    /// The policy table's verdict, before memory is even asked about: may this job start now?
    pub fn gate(
        job: &RenderJob,
        frontend: &FrontendState,
        policy: &DevicePolicy,
        captures: CaptureRule,
        beside_camera: bool,
    ) -> Option<WaitReason> {
        if frontend.scene != Scene::Active {
            return Some(WaitReason::Background);
        }
        if !frontend.camera_live() {
            return None;
        }
        if !beside_camera && job.kind != JobKind::Thumbnail {
            return Some(WaitReason::Camera);
        }
        if frontend.captures_in_flight > 0
            && job.kind != JobKind::Thumbnail
            && (job.tier == RenderTier::Full || captures != CaptureRule::Shares)
        {
            return Some(WaitReason::Capture);
        }
        match job.kind {
            // "camera live, idle: export waits."
            JobKind::Export | JobKind::ImportDevelop | JobKind::FullView => Some(WaitReason::Camera),
            // Develop's strips are the darkroom's, and never beside a camera.
            JobKind::StockPreview => Some(WaitReason::Camera),
            // At preview size a shot develops at once; above the band threshold at full size it waits.
            JobKind::Shot => {
                if job.canvas.width as u64 * job.canvas.height as u64 > policy.band_above_pixels {
                    Some(WaitReason::Camera)
                } else {
                    None
                }
            }
            JobKind::CanvasReprint | JobKind::CanvasDevelop | JobKind::Thumbnail => None,
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub fn plan(
        job: &RenderJob,
        budget: &MemoryBudget,
        frontend: &FrontendState,
        model: &CostModel,
        derate: f64,
        captures: CaptureRule,
        beside_camera: bool,
    ) -> RenderPlan {
        if let Some(why) = Self::gate(job, frontend, &model.policy, captures, beside_camera) {
            return RenderPlan {
                mode: RenderMode::Wait(why),
                estimate: model.estimate(job, &RenderMode::Whole),
                budget: budget.clone(),
            };
        }
        let ladder = Self::ladder(job);
        for mode in &ladder {
            let cost = model.estimate(job, mode);
            if budget.fits(&cost, derate) {
                return RenderPlan { mode: *mode, estimate: cost, budget: budget.clone() };
            }
        }
        let smallest = ladder.last().copied().unwrap_or(RenderMode::Whole);
        RenderPlan {
            mode: RenderMode::Wait(if frontend.camera_live() { WaitReason::Camera } else { WaitReason::Memory }),
            estimate: model.estimate(job, &smallest),
            budget: budget.clone(),
        }
    }

    /// `plan` with the Swift's defaults (`derate: 1, captures: .holds, besideCamera: true`).
    pub fn plan_default(
        job: &RenderJob,
        budget: &MemoryBudget,
        frontend: &FrontendState,
        model: &CostModel,
    ) -> RenderPlan {
        Self::plan(job, budget, frontend, model, 1.0, CaptureRule::Holds, true)
    }
}
