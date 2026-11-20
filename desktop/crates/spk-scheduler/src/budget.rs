//! How much a render may take before it starts (`MemoryBudget.swift`).
//!
//! ```text
//! budget = min(app headroom − app reserve, reclaimable pages − reserves [, GPU memory left]) × (1 − margin)
//! ```
//!
//! The tuning values are the reference device's calibration (an 8 GB phone, EngineBench 2026-10-03),
//! carried over unchanged: **none of them was measured on a Mac desktop or on Windows.** The camera's
//! reserves remain scheduler inputs for the phone's rules; a desktop has no capture session.

use serde::{Deserialize, Serialize};

use crate::cost_model::CostEstimate;
use crate::memory_probe::MemoryReading;
use crate::types::{clamp, FrontendState};

/// The budget's constants (`BudgetTuning`). Each says where it was measured.
#[derive(Clone, Debug, PartialEq)]
pub struct BudgetTuning {
    /// `r_app`. A guess: the library's thumbnails, the canvas's textures.
    pub app_reserve: u64,
    /// `r_floor`: the host's headroom the budget never plans below. Measured on the reference device:
    /// the OS declared critical pressure at 623 MB of free + inactive + purgeable.
    pub floor_reserve: u64,
    /// `m`. From rest, every measured peak was within 8 % of its prediction.
    pub margin: f64,
    /// What one capture takes from the host while in flight, at 48 MP (measured 713-725 MB).
    pub camera_growth_at_48mp: u64,
    /// The same at 12 MP (measured 407-420 MB).
    pub camera_growth_at_12mp: u64,
    /// One more photo once the session has delivered one (measured at most 245; held at 420).
    pub camera_growth_once_warm: u64,
    /// How long after its last photo a session still counts as having delivered one.
    pub camera_warm_seconds: f64,
    /// The floor for a job someone is waiting on: three quarters of `floor_reserve`.
    pub asked_floor_reserve: u64,
    /// Its margin.
    pub asked_margin: f64,
    /// How much of the host's compressed memory such a job may count on.
    pub asked_compressed_share: f64,
    /// Where the watch stops such a job while it runs.
    pub asked_watch_floor: u64,
}

impl Default for BudgetTuning {
    fn default() -> Self {
        BudgetTuning {
            app_reserve: 150 << 20,
            floor_reserve: 600 << 20,
            margin: 0.15,
            camera_growth_at_48mp: 750 << 20,
            camera_growth_at_12mp: 420 << 20,
            camera_growth_once_warm: 420 << 20,
            camera_warm_seconds: 10.0,
            asked_floor_reserve: 450 << 20,
            asked_margin: 0.08,
            asked_compressed_share: 0.5,
            asked_watch_floor: 360 << 20,
        }
    }
}

impl BudgetTuning {
    /// `BudgetTuning(appReserve:floorReserve:margin:)`, the selftest's form. The figures are taken as
    /// bytes, as the Swift's are.
    pub fn with(app_reserve: u64, floor_reserve: u64, margin: f64) -> Self {
        BudgetTuning { app_reserve, floor_reserve, margin, ..Default::default() }
    }

    /// `warm`: the session, as it is set now, has delivered a photo lately.
    pub fn camera_growth(&self, mp: f64, warm: bool) -> u64 {
        if mp <= 0.0 {
            return 0;
        }
        let u = clamp((mp - 12.0) / 36.0, 0.0, 1.0);
        let first = self.camera_growth_at_12mp
            + ((self.camera_growth_at_48mp as f64 - self.camera_growth_at_12mp as f64) * u) as u64;
        if warm {
            first.min(self.camera_growth_once_warm)
        } else {
            first
        }
    }
}

/// Which side of the budget bound.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Binding {
    /// The app's own allowance is the tighter side.
    Allowance,
    /// The host is: other processes and wired memory hold the rest (the Swift's name).
    Phone,
    /// **Desktop PC only**: the GPU budget reported by the driver is the tightest side.
    Gpu,
}

impl Binding {
    pub fn raw_value(&self) -> &'static str {
        match self {
            Binding::Allowance => "allowance",
            Binding::Phone => "phone",
            Binding::Gpu => "gpu",
        }
    }
}

/// `MemoryBudget`.
#[derive(Clone, Debug, PartialEq)]
pub struct MemoryBudget {
    /// What a job may take at its peak: the tighter of the sides, after the margin.
    pub bytes: u64,
    /// `A − r_app` and `P − r_cam − r_floor`, before the margin.
    pub app_side: u64,
    pub phone_side: u64,
    /// The same two after it. A job is held to both, each in its own measure (`fits`).
    pub app_bytes: u64,
    pub phone_bytes: u64,
    /// **Desktop PC only**: the GPU's memory left, before and after the margin. `None` on the Mac and
    /// wherever the reading has no `gpu_available`; then the budget is exactly the Swift's.
    pub gpu_side: Option<u64>,
    pub gpu_bytes: Option<u64>,
    pub camera_reserve: u64,
    pub binding: Binding,
}

impl MemoryBudget {
    /// `cameraWarm`: the camera session has delivered a photo lately. `asked`: for a job someone is
    /// waiting on, with no camera live — the host side counts on more of the host.
    pub fn compute(
        reading: &MemoryReading,
        frontend: &FrontendState,
        tuning: &BudgetTuning,
        camera_warm: bool,
        asked: bool,
    ) -> MemoryBudget {
        let asked = asked && !frontend.camera_live();
        let app_side = reading.app_available.saturating_sub(tuning.app_reserve);
        let mut camera_reserve = 0u64;
        if frontend.camera_live() {
            // Captures in flight, plus one more the shutter could take at any moment.
            let captures = (frontend.captures_in_flight.max(0) + 1) as u64;
            camera_reserve = tuning.camera_growth(frontend.camera_photo_megapixels(), camera_warm) * captures;
        }
        let headroom = reading.phone_headroom()
            + if asked { (reading.compressed as f64 * tuning.asked_compressed_share) as u64 } else { 0 };
        let phone_side = headroom.saturating_sub(camera_reserve).saturating_sub(if asked {
            tuning.asked_floor_reserve
        } else {
            tuning.floor_reserve
        });
        let keep = 1.0 - if asked { tuning.asked_margin } else { tuning.margin };
        let mut tighter = app_side.min(phone_side);
        let mut binding = if app_side <= phone_side { Binding::Allowance } else { Binding::Phone };
        // A driver's remaining GPU budget is a third side. The probe takes
        // current usage out of it, so only the planning margin is applied here.
        let gpu_side = reading.gpu_available;
        if let Some(gpu) = gpu_side {
            if gpu < tighter {
                tighter = gpu;
                binding = Binding::Gpu;
            }
        }
        MemoryBudget {
            bytes: (tighter as f64 * keep) as u64,
            app_side,
            phone_side,
            app_bytes: (app_side as f64 * keep) as u64,
            phone_bytes: (phone_side as f64 * keep) as u64,
            gpu_side,
            gpu_bytes: gpu_side.map(|g| (g as f64 * keep) as u64),
            camera_reserve,
            binding,
        }
    }

    /// Whether a job of this cost may run. `derate` is how much of the budget the job is trusted with
    /// after a pressure event (1 otherwise). With a driver budget the job's peak is also
    /// held to that memory: the engine's planes live there.
    pub fn fits(&self, cost: &CostEstimate, derate: f64) -> bool {
        let d = clamp(derate, 0.1, 1.0);
        cost.peak_bytes as f64 <= self.app_bytes as f64 * d
            && cost.phone_bytes as f64 <= self.phone_bytes as f64 * d
            && self.fits_gpu(cost, d)
    }

    pub(crate) fn fits_gpu(&self, cost: &CostEstimate, derate: f64) -> bool {
        self.gpu_bytes.map_or(true, |g| cost.peak_bytes as f64 <= g as f64 * derate)
    }
}
