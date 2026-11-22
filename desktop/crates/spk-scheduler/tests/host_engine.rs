//! T4 — `HostEngine` against a scripted link: the requests each job kind makes, a cancel during a
//! render, every host error code, a host that dies mid-job, superseded edits folding into the newest.
//! On tokio's paused clock: the link's "render time" is virtual.
#![cfg(any(target_os = "macos", windows))]

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use spk_scheduler::host::engine::engine_error;
use spk_scheduler::host::{HostEngine, HostError, HostLink, HostReply};
use spk_scheduler::types::SnapshotState;
use spk_scheduler::wire::{JobRequest, SourceSpec};
use spk_scheduler::{
    DevelopEngine, DevicePolicy, EngineError, FrameId, JobKind, JobOutcome, MemoryReading, PixelSize, RenderJob,
    RenderQueue, RenderTier,
};
use tokio::sync::{broadcast, Notify};

/// What the scripted host does with a call.
#[derive(Clone)]
enum Script {
    /// Answers `ok` after this long (virtual), or `cancelled` if its progress id is cancelled first.
    Takes(Duration),
    /// Answers `ok: false` with this code.
    Refuses(&'static str, &'static str),
    /// The process dies: this call and every one after it fail, until `revive`.
    Dies,
}

#[derive(Default)]
struct State {
    calls: Vec<(String, Value)>,
    scripts: HashMap<String, Script>,
    sessions: u32,
    open: HashSet<String>,
    cancelled: HashSet<String>,
    dead: bool,
}

struct ScriptedLink {
    state: Mutex<State>,
    cancel: Notify,
    events: broadcast::Sender<Value>,
}

impl ScriptedLink {
    fn new() -> Arc<Self> {
        Arc::new(ScriptedLink {
            state: Mutex::new(State::default()),
            cancel: Notify::new(),
            events: broadcast::channel(64).0,
        })
    }
    fn script(&self, method: &str, s: Script) {
        self.state.lock().unwrap().scripts.insert(method.into(), s);
    }
    fn revive(&self) {
        let mut st = self.state.lock().unwrap();
        st.dead = false;
        st.open.clear();
        st.scripts.retain(|_, s| !matches!(s, Script::Dies));
    }
    /// The calls made, without the bookkeeping ones (`hello`, `memory_report`, `trim`).
    fn calls(&self) -> Vec<(String, Value)> {
        self.state
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|(m, _)| !matches!(m.as_str(), "hello" | "memory_report" | "trim"))
            .cloned()
            .collect()
    }
    fn methods(&self) -> Vec<String> {
        self.calls().into_iter().map(|(m, _)| m).collect()
    }
    fn clear(&self) {
        self.state.lock().unwrap().calls.clear();
    }
    fn open_sessions(&self) -> usize {
        self.state.lock().unwrap().open.len()
    }
}

fn ok(result: Value) -> HostReply {
    Ok((json!({"ok": true, "result": result}), vec![]))
}

#[async_trait]
impl HostLink for ScriptedLink {
    async fn request(&self, method: &str, params: Value, _payload: Vec<u8>, _timeout: Duration) -> HostReply {
        let script = {
            let mut st = self.state.lock().unwrap();
            st.calls.push((method.to_string(), params.clone()));
            if st.dead {
                return Err(HostError::new("not_running", "the engine host is not running"));
            }
            st.scripts.get(method).cloned()
        };
        match method {
            "hello" => {
                return ok(json!({"protocol": 1, "host_version": "0.1.0", "build_info": "test build",
                    "backend": {"api": "vulkan", "available": true, "device_name": "scripted"},
                    "capabilities": {"version": "test build", "backend": {"gpu": "scripted"}},
                    "methods": ["hello", "open", "redecode", "close", "render_view", "export_frame", "thumbnail",
                                "preview_stock_lut", "cancel", "memory_report", "trim", "set_params", "render"]}))
            }
            "memory_report" => return ok(json!({"total_bytes": 1000})),
            "trim" => return ok(json!({"freed_bytes": 0})),
            "cancel" => {
                let id = params["progress_id"].as_str().unwrap_or("").to_string();
                self.state.lock().unwrap().cancelled.insert(id);
                self.cancel.notify_waiters();
                return ok(json!({"was_running": true}));
            }
            "open" | "open_pair" => {
                if let Some(Script::Refuses(code, message)) = &script {
                    return Ok((json!({"ok": false, "error": {"code": code, "message": message}}), vec![]));
                }
                let mut st = self.state.lock().unwrap();
                st.sessions += 1;
                let s = format!("s{}", st.sessions);
                st.open.insert(s.clone());
                return ok(
                    json!({"session": s, "width": 6000, "height": 4000, "timings_ms": {"decode": 400, "open": 50}}),
                );
            }
            "redecode" => {
                return ok(
                    json!({"session": params["session"], "width": 6000, "height": 4000, "timings_ms": {"decode": 300}}),
                )
            }
            "close" => {
                self.state.lock().unwrap().open.remove(params["session"].as_str().unwrap_or(""));
                return ok(json!({}));
            }
            "set_params" => return ok(json!({"params": {}})),
            _ => {}
        }
        // The job's own call.
        if let Some(s) = params["session"].as_str() {
            if !self.state.lock().unwrap().open.contains(s) {
                return Ok((
                    json!({"ok": false, "error": {"code": "not_found", "message": format!("no session {s}")}}),
                    vec![],
                ));
            }
        }
        let image = |w: i64, h: i64| json!({"image": {"width": w, "height": h, "format": "rgba8"}, "print_cached": false, "timings_ms": {"total": 120}});
        let result = match method {
            "thumbnail" => image(256, 171),
            "export_frame" => {
                json!({"path": params["path"], "width": 1200, "height": 800, "bytes": 1234, "timings_ms": {"total": 900}})
            }
            _ => image(2400, 1600),
        };
        match script.unwrap_or(Script::Takes(Duration::from_millis(50))) {
            Script::Refuses(code, message) => {
                Ok((json!({"ok": false, "error": {"code": code, "message": message}}), vec![]))
            }
            Script::Dies => {
                let mut st = self.state.lock().unwrap();
                st.dead = true;
                st.open.clear();
                Err(HostError::new("host_exited", "the engine host exited (signal 9)"))
            }
            Script::Takes(d) => {
                let progress = params["progress_id"].as_str().map(String::from);
                if let Some(id) = &progress {
                    let _ = self
                        .events
                        .send(json!({"event": "progress", "progress_id": id, "fraction": 0.5, "stage": "render"}));
                }
                let deadline = tokio::time::Instant::now() + d;
                loop {
                    if let Some(id) = &progress {
                        if self.state.lock().unwrap().cancelled.contains(id) {
                            return Ok((
                                json!({"ok": false, "error": {"code": "cancelled", "message": "operation cancelled"}}),
                                vec![],
                            ));
                        }
                    }
                    tokio::select! {
                        _ = tokio::time::sleep_until(deadline) => break,
                        _ = self.cancel.notified() => continue,
                    }
                }
                Ok((json!({"ok": true, "result": result}), vec![9; 64]))
            }
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events.subscribe()
    }
}

fn source(path: &str) -> SourceSpec {
    SourceSpec { path: path.into(), decode: None, params: None, pair: None }
}

fn request(method: &str, source: Option<SourceSpec>, params: Value) -> Arc<JobRequest> {
    Arc::new(JobRequest { source, set_params: None, method: method.into(), params })
}

fn view(tier: &str) -> Value {
    json!({"tier": tier, "display": "srgb", "format": "rgba8", "generation": 1, "adjustments": {}, "geometry": {}, "session": "stale", "progress_id": "theirs"})
}

fn canvas_job(kind: JobKind, frame: &FrameId, path: &str) -> RenderJob {
    RenderJob::new(frame.clone(), kind, RenderTier::Live, PixelSize::new(2400, 1600)).with_request(Some(request(
        "render_view",
        Some(source(path)),
        view("live"),
    )))
}

async fn setup() -> (Arc<ScriptedLink>, Arc<HostEngine>, RenderQueue) {
    let link = ScriptedLink::new();
    let engine = Arc::new(HostEngine::connect(link.clone()).await.expect("hello"));
    let queue = RenderQueue::new(
        engine.clone(),
        DevicePolicy::mac(),
        None,
        Arc::new(|| MemoryReading { app_available: 32 << 30, free: 32 << 30, ..Default::default() }),
    );
    link.clear();
    (link, engine, queue)
}

#[tokio::test(start_paused = true)]
async fn the_requests_each_job_kind_makes() {
    let (link, engine, q) = setup().await;
    assert!(engine.name().contains("test build"));
    assert_eq!(
        engine.effect_versions(),
        "build=test build",
        "the v1 engine has no effect_versions: its build stamp stands in"
    );
    let a = FrameId::new("a");

    // A canvas develop opens the frame's editing session; the reprint after it reuses it.
    let develop = q.submit(canvas_job(JobKind::CanvasDevelop, &a, "/p/a.ARW"));
    let out = q.outcome(develop).await;
    let JobOutcome::Finished(r) = out else { panic!("develop: {out:?}") };
    assert_eq!(r.size, PixelSize::new(2400, 1600));
    assert_eq!(r.delivery.as_ref().unwrap().payload.len(), 64, "the reply's payload reaches the submitter");
    assert_eq!(r.delivery.as_ref().unwrap().result["image"]["width"], 2400);
    let reprint = q.submit(canvas_job(JobKind::CanvasReprint, &a, "/p/a.ARW"));
    assert!(q.outcome(reprint).await.is_finished());
    let calls = link.calls();
    assert_eq!(link.methods(), ["open", "render_view", "render_view"]);
    assert_eq!(calls[0].1, json!({"path": "/p/a.ARW"}));
    for (_, p) in &calls[1..] {
        assert_eq!(p["session"], "s1", "the engine's session replaces the submitter's");
        assert!(p["progress_id"].as_str().unwrap().starts_with("spk-"), "and its progress id: {p}");
        assert_eq!(p["tier"], "live");
    }
    assert_eq!(engine.editing_frame().await, Some(a.clone()));

    // Another decode of the same frame is a redecode in place.
    link.clear();
    let mut redecoded = canvas_job(JobKind::CanvasDevelop, &a, "/p/a.ARW");
    redecoded.request = Some(request(
        "render_view",
        Some(SourceSpec { decode: Some(json!({"raw_mode": "headroom"})), ..source("/p/a.ARW") }),
        view("live"),
    ));
    assert!(q.outcome(q.submit(redecoded)).await.is_finished());
    assert_eq!(link.methods(), ["redecode", "render_view"]);
    assert_eq!(link.calls()[0].1, json!({"session": "s1", "decode": {"raw_mode": "headroom"}}));

    // A stock's preview of the frame being edited borrows its session; of another frame, it is one-shot.
    link.clear();
    let mut card = RenderJob::new(a.clone(), JobKind::StockPreview, RenderTier::Live, PixelSize::new(800, 600))
        .with_slot(Some("paper:x".into()))
        .with_request(Some(request(
            "preview_stock_lut",
            Some(SourceSpec { decode: Some(json!({"raw_mode": "headroom"})), ..source("/p/a.ARW") }),
            json!({"print_stock": "x", "format": "rgba8"}),
        )));
    assert!(q.outcome(q.submit(card.clone())).await.is_finished());
    assert_eq!(link.methods(), ["preview_stock_lut"]);
    assert_eq!(link.calls()[0].1["session"], "s1");
    assert!(link.calls()[0].1.get("progress_id").is_none(), "preview_stock_lut takes no progress id");
    link.clear();
    card.id = spk_scheduler::JobId::new();
    card.frame_id = FrameId::new("b");
    card.request = Some(request("preview_stock_lut", Some(source("/p/b.ARW")), json!({"print_stock": "x"})));
    assert!(q.outcome(q.submit(card)).await.is_finished());
    assert_eq!(link.methods(), ["open", "preview_stock_lut", "close"]);
    assert_eq!(link.calls()[2].1["session"], link.calls()[1].1["session"]);

    link.clear();
    let card_request = |path: &str| request(
        "render_stock_card",
        Some(SourceSpec { decode: Some(json!({"raw_mode": "headroom"})), ..source(path) }),
        json!({"params": {"film_stock": "alternate"}}),
    );
    let card = RenderJob::new(a.clone(), JobKind::StockPreview, RenderTier::Live, PixelSize::new(192, 128))
        .with_request(Some(card_request("/p/a.ARW")));
    assert!(q.outcome(q.submit(card)).await.is_finished());
    assert_eq!(link.methods(), ["render_stock_card"]);
    assert_eq!(link.calls()[0].1["session"], "s1");
    assert!(link.calls()[0].1["progress_id"].is_string());
    link.clear();
    let stale = RenderJob::new(FrameId::new("b"), JobKind::StockPreview, RenderTier::Live, PixelSize::new(192, 128))
        .with_request(Some(card_request("/p/b.ARW")));
    assert!(matches!(q.outcome(q.submit(stale)).await, spk_scheduler::JobOutcome::Cancelled));
    assert!(link.methods().is_empty());

    // A full view of the frame being edited, from the same source, borrows its session: the file is not
    // decoded again and nothing is closed (phase 3, part 2). Its delta lands on that session first.
    link.clear();
    let editing_source = SourceSpec { decode: Some(json!({"raw_mode": "headroom"})), ..source("/p/a.ARW") };
    let full = RenderJob::new(a.clone(), JobKind::FullView, RenderTier::Full, PixelSize::new(6000, 4000)).with_request(
        Some(Arc::new(JobRequest {
            source: Some(editing_source.clone()),
            set_params: Some(json!({"film_stock": "x"})),
            method: "render_view".into(),
            params: view("full"),
        })),
    );
    assert!(q.outcome(q.submit(full)).await.is_finished());
    assert_eq!(link.methods(), ["set_params", "render_view"]);
    assert_eq!(link.calls()[0].1["session"], "s1");
    assert_eq!(link.calls()[1].1["session"], "s1");
    assert_eq!(engine.editing_frame().await, Some(a.clone()));
    // Without a delta it is the render alone.
    link.clear();
    let full = RenderJob::new(a.clone(), JobKind::FullView, RenderTier::Full, PixelSize::new(6000, 4000))
        .with_request(Some(request("render_view", Some(editing_source.clone()), view("full"))));
    assert!(q.outcome(q.submit(full)).await.is_finished());
    assert_eq!(link.methods(), ["render_view"]);
    assert_eq!(link.open_sessions(), 1, "the editing session, and nothing opened beside it");

    // The same frame from other pixels, or another frame: one-shot, its own session, closed when it
    // ends; the editing session stays as it was.
    link.clear();
    let other_pixels = RenderJob::new(a.clone(), JobKind::FullView, RenderTier::Full, PixelSize::new(6000, 4000))
        .with_request(Some(request("render_view", Some(source("/p/a.ARW")), view("full"))));
    assert!(q.outcome(q.submit(other_pixels)).await.is_finished());
    assert_eq!(link.methods(), ["open", "render_view", "close"]);
    link.clear();
    let other_frame =
        RenderJob::new(FrameId::new("b"), JobKind::FullView, RenderTier::Full, PixelSize::new(6000, 4000))
            .with_request(Some(request("render_view", Some(source("/p/b.ARW")), view("full"))));
    assert!(q.outcome(q.submit(other_frame)).await.is_finished());
    assert_eq!(link.methods(), ["open", "render_view", "close"]);
    assert_ne!(link.calls()[1].1["session"], "s1");
    assert_eq!(engine.editing_frame().await, Some(a.clone()));
    assert_eq!(link.open_sessions(), 1);

    // An export runs without a session: the host opens a private one from source_path.
    link.clear();
    let export = RenderJob::new(a.clone(), JobKind::Export, RenderTier::Full, PixelSize::new(6000, 4000))
        .decoding(true)
        .with_request(Some(request(
            "export_frame",
            Some(source("/p/a.ARW")),
            json!({"path": "/out/a.jpg", "format": "jpeg", "params": {}, "long_edge": 1200, "session": "s1"}),
        )));
    let out = q.outcome(q.submit(export)).await;
    let JobOutcome::Finished(r) = out else { panic!("export: {out:?}") };
    assert_eq!(r.size, PixelSize::new(1200, 800), "an export's size is the file's");
    assert_eq!(link.methods(), ["export_frame"]);
    let p = &link.calls()[0].1;
    assert!(p.get("session").is_none(), "{p}");
    assert_eq!(p["source_path"], "/p/a.ARW");
    assert!(p["progress_id"].is_string());

    // A thumbnail needs no session.
    link.clear();
    let thumb = RenderJob::new(FrameId::new("c"), JobKind::Thumbnail, RenderTier::Preview, PixelSize::new(256, 171))
        .with_request(Some(request("thumbnail", None, json!({"path": "/p/c.ARW", "long_edge": 256}))));
    assert!(q.outcome(q.submit(thumb)).await.is_finished());
    assert_eq!(link.calls(), vec![("thumbnail".to_string(), json!({"path": "/p/c.ARW", "long_edge": 256}))]);

    // A canvas job of another frame closes the old editing session first.
    link.clear();
    let b = FrameId::new("b");
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasDevelop, &b, "/p/b.ARW"))).await.is_finished());
    assert_eq!(link.methods(), ["close", "open", "render_view"]);
    assert_eq!(link.calls()[0].1["session"], "s1");
    assert_eq!(link.open_sessions(), 1, "one editing session, nothing left over");

    // The page moved away: the editing session goes. A reclaim keeps the frame it is asked to keep.
    engine.reclaim(Some(&b)).await;
    assert_eq!(link.open_sessions(), 1);
    engine.close_editing(None).await;
    assert_eq!(link.open_sessions(), 0);

    // A job without a host request fails, saying so.
    let bare = RenderJob::new(a.clone(), JobKind::CanvasDevelop, RenderTier::Live, PixelSize::new(10, 10));
    assert_eq!(q.outcome(q.submit(bare)).await, JobOutcome::Failed("the job has no host request".into()));
    // The records say the v1 host rendered whole.
    assert!(q.records().iter().filter(|r| r.outcome == "done").all(|r| r.ran.as_deref() == Some("whole")));
}

#[tokio::test(start_paused = true)]
async fn a_cancel_during_a_render_reaches_the_host_and_the_job_ends_cancelled() {
    let (link, _engine, q) = setup().await;
    link.script("render_view", Script::Takes(Duration::from_secs(30)));
    let f = FrameId::new("a");
    let id = q.submit(canvas_job(JobKind::CanvasDevelop, &f, "/p/a.ARW"));
    // Running, the call in flight, and the host's progress event forwarded to the snapshot.
    let mut fraction = 0.0;
    for _ in 0..100 {
        tokio::time::sleep(Duration::from_millis(10)).await;
        if let Some(SnapshotState::Running(p)) = q.snapshot_of(id).map(|s| s.state) {
            fraction = p.fraction;
            if fraction > 0.5 {
                break;
            }
        }
    }
    assert!(fraction > 0.5, "the host's progress (0.5 of the render) reached the page: {fraction}");
    q.cancel(id);
    assert_eq!(q.outcome(id).await, JobOutcome::Cancelled);
    let cancel = link.calls().into_iter().find(|(m, _)| m == "cancel").expect("a cancel was sent");
    assert_eq!(cancel.1["session"], "s1");
    assert!(cancel.1["progress_id"].as_str().unwrap().starts_with("spk-"));
    assert_eq!(q.records().last().unwrap().outcome, "cancelled");

    // A cancel that arrives before the call never sends it.
    link.clear();
    link.script("open", Script::Takes(Duration::ZERO));
    let g = FrameId::new("g");
    let id = q.submit(canvas_job(JobKind::CanvasDevelop, &g, "/p/g.ARW"));
    q.cancel(id);
    assert_eq!(q.outcome(id).await, JobOutcome::Cancelled);
    assert!(!link.methods().contains(&"render_view".to_string()), "{:?}", link.methods());

    // A thumbnail cannot be stopped: it finishes and its result is thrown away.
    link.clear();
    link.script("thumbnail", Script::Takes(Duration::from_secs(1)));
    let t = q.submit(
        RenderJob::new(FrameId::new("t"), JobKind::Thumbnail, RenderTier::Preview, PixelSize::new(256, 171))
            .with_request(Some(request("thumbnail", None, json!({"path": "/p/t.ARW", "long_edge": 256})))),
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    q.cancel(t);
    assert_eq!(q.outcome(t).await, JobOutcome::Cancelled);
    assert!(!link.methods().contains(&"cancel".to_string()), "nothing to cancel on the host: {:?}", link.methods());
}

#[test]
fn every_host_error_code_maps() {
    assert_eq!(engine_error("cancelled", "operation cancelled"), EngineError::Cancelled);
    assert_eq!(
        engine_error("engine_error", "out of device memory"),
        EngineError::Resource("engine_error: out of device memory".into())
    );
    assert_eq!(engine_error("internal", "out of memory"), EngineError::Resource("internal: out of memory".into()));
    for code in ["bad_request", "not_found", "decode_failed", "unsupported", "io_error", "internal"] {
        assert_eq!(engine_error(code, "why"), EngineError::Failed(format!("{code}: why")), "{code}");
    }
}

#[tokio::test(start_paused = true)]
async fn a_host_error_of_each_code_ends_the_job_as_the_queue_expects() {
    let (link, _engine, q) = setup().await;
    for (code, want) in [
        ("engine_error", JobOutcome::Failed("engine_error: no memory".into())),
        ("bad_request", JobOutcome::Failed("bad_request: no memory".into())),
        ("decode_failed", JobOutcome::Failed("decode_failed: no memory".into())),
        ("unsupported", JobOutcome::Failed("unsupported: no memory".into())),
        ("io_error", JobOutcome::Failed("io_error: no memory".into())),
        ("internal", JobOutcome::Failed("internal: no memory".into())),
        ("cancelled", JobOutcome::Cancelled),
    ] {
        link.script("render_view", Script::Refuses(code, "no memory"));
        let id = q.submit(canvas_job(JobKind::CanvasDevelop, &FrameId::new("e"), "/p/e.ARW"));
        assert_eq!(q.outcome(id).await, want, "{code}");
    }
    // An open the host refuses is the job's failure too.
    link.script("render_view", Script::Takes(Duration::from_millis(10)));
    link.script("open", Script::Refuses("decode_failed", "not a picture"));
    let id = q.submit(canvas_job(JobKind::CanvasDevelop, &FrameId::new("x"), "/p/x.txt"));
    assert_eq!(q.outcome(id).await, JobOutcome::Failed("decode_failed: not a picture".into()));
    assert!(q.records().last().unwrap().outcome.starts_with("failed: decode_failed"));
}

#[tokio::test(start_paused = true)]
async fn a_host_that_dies_mid_job_fails_the_job_and_the_queue_goes_on() {
    let (link, engine, q) = setup().await;
    let f = FrameId::new("a");
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasDevelop, &f, "/p/a.ARW"))).await.is_finished());
    link.script("render_view", Script::Dies);
    let dying = q.submit(canvas_job(JobKind::CanvasReprint, &f, "/p/a.ARW"));
    let queued = q.submit(
        RenderJob::new(FrameId::new("t"), JobKind::Thumbnail, RenderTier::Preview, PixelSize::new(256, 171))
            .with_request(Some(request("thumbnail", None, json!({"path": "/p/t.ARW", "long_edge": 256})))),
    );
    let out = q.outcome(dying).await;
    assert!(matches!(&out, JobOutcome::Failed(m) if m.starts_with("host_exited")), "{out:?}");
    // The next job is tried at once (the host is still down: it fails too, and says why).
    assert!(matches!(q.outcome(queued).await, JobOutcome::Failed(m) if m.starts_with("not_running")));
    assert_eq!(engine.editing_frame().await, None, "the dead host's sessions are forgotten");
    // The host is back (the app's HostManager restarts it): the frame opens afresh and develops.
    link.revive();
    link.clear();
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasReprint, &f, "/p/a.ARW"))).await.is_finished());
    assert_eq!(link.methods(), ["open", "render_view"]);
    assert!(q.is_idle());
}

#[tokio::test(start_paused = true)]
async fn a_restarted_host_s_unknown_session_is_opened_again_once() {
    let (link, _engine, q) = setup().await;
    let f = FrameId::new("a");
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasDevelop, &f, "/p/a.ARW"))).await.is_finished());
    link.revive(); // a restart between jobs: the session s1 is gone, nothing failed
    link.clear();
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasReprint, &f, "/p/a.ARW"))).await.is_finished());
    assert_eq!(link.methods(), ["render_view", "open", "render_view"]);
}

#[tokio::test(start_paused = true)]
async fn superseded_edits_fold_into_the_newest() {
    let (link, _engine, q) = setup().await;
    link.script("render_view", Script::Takes(Duration::from_millis(400)));
    let f = FrameId::new("a");
    let ids: Vec<_> = (0..5).map(|_| q.submit(canvas_job(JobKind::CanvasReprint, &f, "/p/a.ARW"))).collect();
    let mut outcomes = vec![];
    for id in &ids {
        outcomes.push(q.outcome(*id).await);
    }
    assert!(outcomes.last().unwrap().is_finished(), "the newest edit renders: {outcomes:?}");
    assert!(outcomes[1..4].iter().all(|o| *o == JobOutcome::Cancelled), "the queued ones are dropped: {outcomes:?}");
    let renders = link.methods().iter().filter(|m| *m == "render_view").count();
    assert!(renders <= 2, "five edits are at most two renders ({renders})");
    // The running one was superseded on the host, not left to finish.
    assert_eq!(outcomes[0], JobOutcome::Cancelled);
    assert!(link.methods().contains(&"cancel".to_string()));
    assert!(q.records().iter().any(|r| r.outcome == "cancelled: superseded"));
}

/// The webview's own calls on a frame (not jobs) reach the engine's editing session by the frame; the
/// next canvas job reuses it; a redecode moves its source; a stale session is `not_found`.
#[tokio::test(start_paused = true)]
async fn the_webview_s_calls_run_on_the_editing_session() {
    let (link, engine, q) = setup().await;
    let f = FrameId::new("a");
    let (opened, _) = engine.open_editing(&f, &source("/p/a.ARW")).await.unwrap();
    let s1 = opened["result"]["session"].as_str().unwrap().to_string();
    assert_eq!(engine.editing_frame().await, Some(f.clone()));
    let (reply, _) =
        engine.call_editing(&f, &s1, "set_params", json!({"delta": {"print_exposure": 1.1}})).await.unwrap();
    assert_eq!(reply["ok"], true);
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasReprint, &f, "/p/a.ARW"))).await.is_finished());
    // Another decode by `redecode`: the next canvas job from that decode reuses the session.
    let wb = json!({"raw_mode": "headroom"});
    let (reply, _) = engine.call_editing(&f, &s1, "redecode", json!({"decode": wb})).await.unwrap();
    assert_eq!(reply["ok"], true);
    let mut job = canvas_job(JobKind::CanvasDevelop, &f, "/p/a.ARW");
    job.request =
        Some(request("render_view", Some(SourceSpec { decode: Some(wb), ..source("/p/a.ARW") }), view("live")));
    assert!(q.outcome(q.submit(job)).await.is_finished());
    assert_eq!(link.methods(), ["open", "set_params", "render_view", "redecode", "render_view"]);
    for (_, params) in link.calls().iter().skip(1) {
        assert_eq!(params["session"], json!(s1), "every call ran on the one session");
    }
    // A session that is not the frame's editing one any more is not sent.
    link.clear();
    let (reply, _) = engine.call_editing(&FrameId::new("b"), &s1, "solve", json!({"target": "both"})).await.unwrap();
    assert_eq!(reply["error"]["code"], "not_found");
    engine.close_editing(None).await;
    let (reply, _) = engine.call_editing(&f, &s1, "solve", json!({"target": "both"})).await.unwrap();
    assert_eq!(reply["error"]["code"], "not_found");
    assert_eq!(link.methods(), ["close"]);
    assert_eq!(link.open_sessions(), 0);
}

#[tokio::test(start_paused = true)]
async fn the_whole_frame_host_skips_an_optional_full_view_that_does_not_fit() {
    let (link, _engine, q) = setup().await;
    q.set_read_memory(|| MemoryReading {
        gpu_available: Some(4 << 30),
        ..MemoryReading::windows(18 << 30, 18 << 30, 0)
    });
    let frame = FrameId::new("fuji");
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasDevelop, &frame, "/p/fuji.RAF"))).await.is_finished());
    link.clear();
    let full = RenderJob::new(frame.clone(), JobKind::FullView, RenderTier::Full, PixelSize::new(11662, 8746))
        .with_request(Some(request("render_view", Some(source("/p/fuji.RAF")), view("full"))));
    assert_eq!(q.outcome(q.submit(full)).await, JobOutcome::Cancelled);
    let record = q.records().pop().unwrap();
    assert_eq!(record.mode, "wait(memory)");
    assert_eq!(record.outcome, "cancelled: memory");
    assert!(record.ran.is_none());
    assert!(link.methods().is_empty(), "{:?}", link.methods());
    assert_eq!(link.open_sessions(), 1);
    assert!(q.outcome(q.submit(canvas_job(JobKind::CanvasReprint, &frame, "/p/fuji.RAF"))).await.is_finished());
    assert_eq!(link.methods(), ["render_view"]);
}

#[tokio::test(start_paused = true)]
async fn export_does_not_force_a_whole_frame_over_the_gpu_budget() {
    use std::sync::atomic::{AtomicU64, Ordering};

    let (link, _engine, q) = setup().await;
    let available = Arc::new(AtomicU64::new(4 << 30));
    let read = available.clone();
    q.set_read_memory(move || MemoryReading {
        gpu_available: Some(read.load(Ordering::Relaxed)),
        ..MemoryReading::windows(18 << 30, 18 << 30, 0)
    });
    let job = RenderJob::new(FrameId::new("fuji"), JobKind::Export, RenderTier::Full, PixelSize::new(11662, 8746))
        .decoding(true)
        .with_request(Some(request("export_frame", Some(source("/p/fuji.RAF")), json!({"path": "/out/fuji.tif"}))));
    let id = q.submit(job);
    assert!(tokio::time::timeout(Duration::from_secs(8), q.outcome(id)).await.is_err());
    assert!(link.methods().is_empty(), "{:?}", link.methods());
    assert_eq!(q.snapshot_of(id).unwrap().state, SnapshotState::Waiting(spk_scheduler::types::WaitReason::Memory));

    available.store(12 << 30, Ordering::Relaxed);
    let result = tokio::time::timeout(Duration::from_secs(2), q.outcome(id)).await.unwrap();
    assert!(result.is_finished());
    assert_eq!(link.methods(), ["export_frame"]);
    let record = q.records().pop().unwrap();
    assert_eq!(record.mode, "whole");
    assert_eq!(record.ran.as_deref(), Some("whole"));
}
