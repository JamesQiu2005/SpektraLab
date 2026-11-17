//! The facade is called from threads that are not inside the tokio runtime: Tauri runs a non-async
//! command on such a thread. Only `Scheduler::new` (and `HostEngine::connect`, `ProcessHostLink::spawn`)
//! need a runtime context; every other entry point must work from a plain `std::thread`.
//!
//! macOS only by design (README, "Tests").
#![cfg(target_os = "macos")]

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;
use spk_scheduler::engine::ProgressFn;
use spk_scheduler::wire::{FrontendStateMsg, JobSpec, OutcomeKind, PressureLevel};
use spk_scheduler::{
    DevelopEngine, DevicePolicy, EngineError, FrameId, InjectedProbe, JobId, MemoryReading, QueueConfig, RenderJob,
    RenderMode, RenderResult, Scheduler, SchedulerOptions, SimulatedEngine,
};

/// The simulated engine, with every `close_editing` it is asked recorded.
struct Recording {
    inner: SimulatedEngine,
    closed: Mutex<Vec<Option<String>>>,
}

#[async_trait]
impl DevelopEngine for Recording {
    fn name(&self) -> String {
        self.inner.name()
    }
    fn effect_versions(&self) -> String {
        self.inner.effect_versions()
    }
    async fn run(&self, job: &RenderJob, mode: &RenderMode, progress: ProgressFn) -> Result<RenderResult, EngineError> {
        self.inner.run(job, mode, progress).await
    }
    fn cancel(&self, job_id: JobId) {
        self.inner.cancel(job_id)
    }
    async fn trim(&self) -> u64 {
        self.inner.trim().await
    }
    async fn held_bytes(&self) -> u64 {
        0
    }
    async fn close_editing(&self, frame: Option<&FrameId>) {
        self.closed.lock().unwrap().push(frame.map(|f| f.0.clone()));
    }
}

fn spec(frame: &str) -> JobSpec {
    serde_json::from_value(json!({"frameId": frame, "kind": "export", "tier": "full",
        "canvas": {"width": 6000, "height": 4000}, "decodesOriginal": true}))
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_entry_point_works_from_a_thread_outside_the_runtime() {
    let engine =
        Arc::new(Recording { inner: SimulatedEngine::new(DevicePolicy::mac(), 2.0), closed: Mutex::new(vec![]) });
    let probe = InjectedProbe::new(MemoryReading { app_available: 32 << 30, free: 32 << 30, ..Default::default() });
    let scheduler = Arc::new(Scheduler::new(
        engine.clone(),
        SchedulerOptions {
            policy: DevicePolicy::mac(),
            probe: Arc::new(probe),
            corrections: None,
            config: QueueConfig::default(),
        },
    ));

    let s = scheduler.clone();
    let ids = std::thread::spawn(move || {
        assert!(tokio::runtime::Handle::try_current().is_err(), "the test thread is outside the runtime");
        let open = |frame: &str| FrontendStateMsg { open_frame: Some(frame.into()), ..Default::default() };
        s.set_frontend_state(open("a"));
        s.set_frontend_state(open("b")); // the open frame changed: a's editing session closes
        let kept = s.submit(&spec("b")).expect("submit");
        let cancelled = s.submit(&spec("c")).expect("submit");
        s.cancel(cancelled);
        let dropped = s.submit(&spec("d")).expect("submit");
        s.cancel_frame("d", None);
        let _ = s.snapshot(None);
        let _ = s.snapshot(Some("b"));
        let _ = s.budget();
        s.memory_pressure(PressureLevel::Warning);
        s.set_job_log(None);
        s.set_cache_hooks(None, None);
        (kept, cancelled, dropped)
    })
    .join();
    let (kept, cancelled, dropped) = ids.expect("no entry point needs the caller to be inside a runtime");

    assert_eq!(
        tokio::time::timeout(Duration::from_secs(60), scheduler.outcome(kept)).await.unwrap().0.outcome,
        OutcomeKind::Finished
    );
    assert_eq!(scheduler.outcome(cancelled).await.0.outcome, OutcomeKind::Cancelled);
    assert_eq!(scheduler.outcome(dropped).await.0.outcome, OutcomeKind::Cancelled);
    for _ in 0..100 {
        if !engine.closed.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(*engine.closed.lock().unwrap(), vec![Some("a".to_string())], "a's editing session was closed");
}
