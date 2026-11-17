//! # spk-scheduler
//!
//! The Mac v2 app's render scheduler (RFC-036; `app/SpektraLab/Sources/Scheduler/*.swift`), ported to
//! Rust for SpektraLab 2 on Windows, and an engine conformer that drives v1's C++/Vulkan engine through
//! its host process (`desktop/HOST-PROTOCOL.md`).
//!
//! | module | Swift |
//! |---|---|
//! | [`types`] | `SchedulerTypes.swift` (+ `PixelSize`, `ParamLayer`) |
//! | [`cost_model`] | `CostModel.swift` |
//! | [`budget`] | `MemoryBudget.swift` |
//! | [`device_policy`] | `DevicePolicy.swift`, plus the desktop PC (R2) |
//! | [`planner`] | `Planner.swift` |
//! | [`prefetch`] | `PrefetchPolicy.swift` |
//! | [`queue`] | `RenderQueue.swift` |
//! | [`engine`] | `DevelopEngine.swift` |
//! | [`simulated`] | `SimulatedEngine.swift` |
//! | [`memory_probe`] | `MemoryProbe.swift`, as a trait: injected, macOS, Windows (R3) |
//! | [`job_log`] | `JobLogFile.swift` (R7) |
//! | [`host`] | `SpkEngine.swift`'s role, over the host: `HostLink`, `ProcessHostLink`, `HostEngine` (R5) |
//! | [`wire`], [`scheduler`] | the webview's side (R6), `WIRE.md` |
//! | `selftest` | `tools/scheduler_selftest.swift` (T1, T2) |
//!
//! The crate README says what was left out and what is unmeasured on Windows.

pub mod budget;
pub mod cost_model;
pub mod device_policy;
pub mod engine;
pub mod host;
pub mod job_log;
pub mod memory_probe;
pub mod planner;
pub mod prefetch;
pub mod queue;
pub mod scheduler;
pub mod simulated;
pub mod types;
pub mod wire;

#[cfg(all(target_os = "macos", any(test, feature = "selftest")))]
pub mod selftest;

pub use budget::{Binding, BudgetTuning, MemoryBudget};
pub use cost_model::{CostEstimate, CostModel};
pub use device_policy::{DeviceClass, DevicePolicy, GpuMemory};
pub use engine::{Delivery, DevelopEngine, EngineError, RenderResult};
pub use host::{HostEngine, HostError, HostLink, HostReply, ProcessHostLink};
pub use job_log::{JobLogFile, JobSink};
pub use memory_probe::{InjectedProbe, MemoryProbe, MemoryReading};
pub use planner::{Planner, RenderPlan};
pub use queue::{JobOutcome, Pressure, QueueConfig, RenderQueue};
pub use scheduler::{Scheduler, SchedulerOptions};
pub use simulated::SimulatedEngine;
pub use types::{FrameId, JobId, JobKind, JobRecord, PixelSize, RenderJob, RenderMode, RenderTier};
