//! T5 — `HostEngine` against the real v1 host on this Mac (Vulkan through MoltenVK), through
//! `ProcessHostLink` and the real queue: a RAW opened, a canvas develop then a reprint, a full view, an
//! export to a file, a thumbnail, and a cancel. Pictures are checked for being pictures (their size,
//! not constant, alpha opaque), never for how long anything took.
//!
//! Gated by `SPK_HOST_BIN` (the staged `spektralab-host`) and `SPEKTRALAB_RAW_FIXTURES` (the RAW
//! folder). Unset, the test says so and passes — unless `SPK_REQUIRE_REAL_HOST=1`, which `gate.sh` sets:
//! then a missing variable, host or file **fails**. macOS only by design (README, "Tests").
#![cfg(target_os = "macos")]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use spk_scheduler::host::{HostLink, HostReply, ProcessHostLink};
use spk_scheduler::memory_probe::{system_probe, MemoryProbe};
use spk_scheduler::wire::{JobSpec, OutcomeKind};
use spk_scheduler::{DevelopEngine as _, DevicePolicy, HostEngine, QueueConfig, Scheduler, SchedulerOptions};
use tokio::sync::broadcast;

/// The RAW the test develops, under `SPEKTRALAB_RAW_FIXTURES`.
const RAW: &str = "A7m3/DSC03710.ARW";

/// The real link, with every method it is asked recorded.
struct Recording {
    inner: Arc<ProcessHostLink>,
    methods: Mutex<Vec<String>>,
}

#[async_trait]
impl HostLink for Recording {
    async fn request(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration) -> HostReply {
        self.methods.lock().unwrap().push(method.to_string());
        self.inner.request(method, params, payload, timeout).await
    }
    fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.inner.subscribe()
    }
}

impl Recording {
    fn take(&self) -> Vec<String> {
        std::mem::take(&mut *self.methods.lock().unwrap())
            .into_iter()
            .filter(|m| !matches!(m.as_str(), "memory_report" | "trim"))
            .collect()
    }
}

fn gate() -> Option<(PathBuf, PathBuf)> {
    let required = std::env::var("SPK_REQUIRE_REAL_HOST").is_ok_and(|v| v == "1");
    let (host, fixtures) = (std::env::var_os("SPK_HOST_BIN"), std::env::var_os("SPEKTRALAB_RAW_FIXTURES"));
    let (Some(host), Some(fixtures)) = (host, fixtures) else {
        assert!(!required, "SPK_REQUIRE_REAL_HOST=1 but SPK_HOST_BIN or SPEKTRALAB_RAW_FIXTURES is unset");
        eprintln!("real host test NOT RUN: set SPK_HOST_BIN and SPEKTRALAB_RAW_FIXTURES (gate.sh does)");
        return None;
    };
    let host = PathBuf::from(host);
    let raw = PathBuf::from(fixtures).join(RAW);
    // A variable that is set names something that must be there.
    assert!(host.is_file(), "SPK_HOST_BIN={} is not a file", host.display());
    assert!(raw.is_file(), "SPEKTRALAB_RAW_FIXTURES has no {RAW} ({})", raw.display());
    Some((host, raw))
}

/// A picture is a picture: its size, every pixel opaque, and not one colour.
fn assert_picture(what: &str, payload: &[u8], width: u64, height: u64) {
    assert_eq!(
        payload.len() as u64,
        width * height * 4,
        "{what}: {width}x{height} rgba8 is {} bytes",
        width * height * 4
    );
    assert!(payload.chunks_exact(4).all(|p| p[3] == 255), "{what}: alpha is opaque");
    let first = &payload[0..3];
    let differing = payload.chunks_exact(4).filter(|p| &p[0..3] != first).count();
    assert!(
        differing > payload.len() / 4 / 10,
        "{what}: not a constant picture ({differing} pixels differ from the first)"
    );
    let mean: f64 = payload.chunks_exact(4).map(|p| p[1] as f64).sum::<f64>() / (payload.len() / 4) as f64;
    assert!(mean > 2.0 && mean < 253.0, "{what}: neither black nor white (mean green {mean:.1})");
}

/// A JPEG's size, from its SOF marker.
fn jpeg_size(bytes: &[u8]) -> Option<(u64, u64)> {
    if bytes.get(0..2)? != [0xFF, 0xD8] {
        return None;
    }
    let mut i = 2;
    while i + 9 < bytes.len() {
        if bytes[i] != 0xFF {
            return None;
        }
        let marker = bytes[i + 1];
        let len = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            let h = u16::from_be_bytes([bytes[i + 5], bytes[i + 6]]) as u64;
            let w = u16::from_be_bytes([bytes[i + 7], bytes[i + 8]]) as u64;
            return Some((w, h));
        }
        i += 2 + len;
    }
    None
}

fn spec(value: Value) -> JobSpec {
    serde_json::from_value(value).expect("a job spec")
}

fn view(tier: &str, long_edge: u64, generation: u64) -> Value {
    json!({"tier": tier, "display": "srgb", "format": "rgba8", "long_edge": long_edge, "generation": generation,
           "adjustments": {}, "geometry": {}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_real_host_develops_a_raw_through_the_queue() {
    let Some((host, raw)) = gate() else { return };
    let resources = std::env::var_os("SPK_HOST_RESOURCES")
        .map(PathBuf::from)
        .unwrap_or_else(|| host.parent().unwrap().join("engine"));
    let env = vec![("DYLD_FALLBACK_LIBRARY_PATH".to_string(), "/opt/homebrew/lib".to_string())];
    let process = ProcessHostLink::spawn(&host, &resources, &env).expect("the host starts");
    let link = Arc::new(Recording { inner: process.clone(), methods: Mutex::new(vec![]) });
    let engine = Arc::new(
        HostEngine::connect(link.clone())
            .await
            .unwrap_or_else(|e| panic!("hello: {e}; stderr: {:?}", process.stderr_tail())),
    );
    assert_eq!(
        engine.hello()["backend"]["available"],
        true,
        "the Vulkan engine started (MoltenVK): {}",
        engine.hello()["backend"]
    );
    assert!(
        engine.hello()["methods"].as_array().unwrap().iter().any(|m| m == "trim"),
        "the host offers the additive trim"
    );
    let path = raw.to_string_lossy().to_string();

    // What the frame is, and a full parameter snapshot for the export (from a session of the test's own).
    let (probe, _) = link.inner.request("probe", json!({"path": path}), vec![], Duration::from_secs(60)).await.unwrap();
    assert_eq!(probe["ok"], true, "probe: {probe}");
    let (w, h) = (probe["result"]["width"].as_i64().unwrap(), probe["result"]["height"].as_i64().unwrap());
    let (opened, _) =
        link.inner.request("open", json!({"path": path}), vec![], Duration::from_secs(300)).await.unwrap();
    assert_eq!(opened["ok"], true, "open: {opened}");
    let params = opened["result"]["params"].clone();
    assert!(params["print_exposure"].is_number(), "the reprint below edits a field there is");
    let _ = link
        .inner
        .request("close", json!({"session": opened["result"]["session"]}), vec![], Duration::from_secs(30))
        .await;
    link.take();

    let probe_reader: Arc<dyn MemoryProbe> = Arc::from(system_probe(None).expect("the Mac's probe"));
    let scheduler = Scheduler::new(
        engine.clone(),
        SchedulerOptions {
            policy: DevicePolicy::mac(),
            probe: probe_reader,
            corrections: None,
            config: QueueConfig::default(),
        },
    );
    let mut events = scheduler.subscribe();
    let frame = "raw:1";
    let source = json!({"path": path});
    let opens = json!({"width": w, "height": h});
    let canvas_edge = 1600u64;
    let (cw, ch) = if w >= h {
        (canvas_edge as i64, (h as f64 * canvas_edge as f64 / w as f64).round() as i64)
    } else {
        ((w as f64 * canvas_edge as f64 / h as f64).round() as i64, canvas_edge as i64)
    };

    // 1. The page's first develop: the frame opened in the editing session, rendered.
    let develop = scheduler.submit(&spec(json!({"frameId": frame, "kind": "canvasDevelop", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "decodesOriginal": true, "original": opens, "opens": opens, "rawDecode": true,
        "request": {"source": source, "method": "render_view", "params": view("live", canvas_edge, 1)}}))).unwrap();
    let (out, pixels) = scheduler.outcome(develop).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "develop: {out:?}; stderr: {:?}", process.stderr_tail());
    let image = &out.result.as_ref().unwrap().host_result.as_ref().unwrap()["image"];
    let (iw, ih) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(iw.max(ih), canvas_edge, "the develop is the long edge asked ({iw}x{ih})");
    assert_picture("develop", pixels.as_deref().expect("pixels"), iw, ih);
    eprintln!("T5 develop: timings={}", out.result.as_ref().unwrap().host_result.as_ref().unwrap()["timings_ms"]);
    assert_eq!(link.take(), ["open", "render_view"]);

    // 2. A print-side edit: a reprint on the same session, no second open.
    let reprint = scheduler
        .submit(&spec(json!({"frameId": frame, "kind": "canvasReprint", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "layers": ["print"], "opens": opens,
        "request": {"source": source, "method": "render_view", "params": view("live", canvas_edge, 2)}})))
        .unwrap();
    let (out, pixels) = scheduler.outcome(reprint).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "reprint: {out:?}");
    assert_eq!(out.result.as_ref().unwrap().host_result.as_ref().unwrap()["generation"], 2);
    eprintln!(
        "T5 reprint: print_cached={}",
        out.result.as_ref().unwrap().host_result.as_ref().unwrap()["print_cached"]
    );
    assert_picture("reprint", pixels.as_deref().expect("pixels"), iw, ih);
    assert_eq!(link.take(), ["render_view"], "a reprint reuses the editing session");
    let (again, none) = scheduler.outcome(reprint).await;
    assert!(none.is_none() && again.result.unwrap().payload_bytes == 0, "pixels are handed over once");

    // 3. The full view of the frame being edited: it borrows the editing session (no second decode of
    //    the file, nothing closed), at a bounded output size, from the whole frame.
    let full = scheduler
        .submit(&spec(json!({"frameId": frame, "kind": "fullView", "tier": "full",
        "canvas": {"width": w, "height": h},
        "request": {"source": source, "method": "render_view", "params": view("full", 3000, 3)}})))
        .unwrap();
    let (out, pixels) = scheduler.outcome(full).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "full view: {out:?}; stderr: {:?}", process.stderr_tail());
    let reply = out.result.as_ref().unwrap().host_result.as_ref().unwrap();
    let image = &reply["image"];
    let (fw, fh) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(fw.max(fh), 3000);
    assert_eq!(
        (image["source_width"].as_i64().unwrap(), image["source_height"].as_i64().unwrap()),
        (w, h),
        "from the whole frame"
    );
    assert_picture("full view", pixels.as_deref().expect("pixels"), fw, fh);
    assert_eq!(link.take(), ["render_view"], "a full view of the editing frame borrows its session");
    eprintln!("T5 full view (borrowed): print_cached={} timings={}", reply["print_cached"], reply["timings_ms"]);
    let (report, _) = link.inner.request("memory_report", json!({}), vec![], Duration::from_secs(30)).await.unwrap();
    let rows = report["result"]["persistent"]["sessions"].as_array().cloned().unwrap_or_default();
    eprintln!("T5 after the full view: {rows:?}");
    // The host keeps a negative per size: the canvas's beside the full view's, on the one session. (The
    // print times printed above are the evidence that the next reprint runs from the canvas's.)
    assert_eq!(rows.len(), 1, "the editing session alone: {rows:?}");
    assert_eq!(rows[0]["negatives"], 2, "the canvas's negative kept beside the full view's: {rows:?}");

    // 3b. A print-side edit after it still reprints on the editing session: the negative the develop made
    //     is the one it prints from (`print_cached`), so the full view did not cost the canvas its film.
    let after = scheduler
        .submit(&spec(json!({"frameId": frame, "kind": "canvasReprint", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "layers": ["print"], "opens": opens,
        "request": {"source": source, "setParams": {"print_exposure": 1.1},
                    "method": "render_view", "params": view("live", canvas_edge, 4)}})))
        .unwrap();
    let (out, pixels) = scheduler.outcome(after).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "reprint after the full view: {out:?}");
    let reply = out.result.as_ref().unwrap().host_result.as_ref().unwrap();
    assert_picture("reprint after the full view", pixels.as_deref().expect("pixels"), iw, ih);
    assert_eq!(link.take(), ["set_params", "render_view"], "on the editing session, no open");
    eprintln!("T5 reprint after the full view: print_cached={} timings={}", reply["print_cached"], reply["timings_ms"]);

    // 3c. A full view of a frame that is not the one being edited is one-shot: its own session, closed.
    let other = scheduler
        .submit(&spec(json!({"frameId": "raw:2", "kind": "fullView", "tier": "full",
        "canvas": {"width": w, "height": h}, "decodesOriginal": true, "original": opens,
        "request": {"source": source, "method": "render_view", "params": view("full", 1200, 5)}})))
        .unwrap();
    let (out, pixels) = scheduler.outcome(other).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "another frame's full view: {out:?}");
    let image = &out.result.as_ref().unwrap().host_result.as_ref().unwrap()["image"];
    let (ow, oh) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_picture("another frame's full view", pixels.as_deref().expect("pixels"), ow, oh);
    assert_eq!(link.take(), ["open", "render_view", "close"], "another frame's full view has its own session");

    // 4. An export to a file: it exists, decodes as a JPEG, at the size asked.
    let dir = std::env::temp_dir().join(format!("spk-scheduler-t5-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("export.jpg");
    let export = scheduler
        .submit(&spec(json!({"frameId": frame, "kind": "export", "tier": "full",
        "canvas": {"width": w, "height": h}, "decodesOriginal": true, "original": opens,
        "request": {"source": source, "method": "export_frame", "params": {
            "params": params, "adjustments": {}, "geometry": {}, "path": file.to_string_lossy(), "format": "jpeg",
            "quality": 90, "color_space": "sRGB", "long_edge": 1200, "overwrite": true}}})))
        .unwrap();
    let (out, _) = scheduler.outcome(export).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "export: {out:?}; stderr: {:?}", process.stderr_tail());
    let bytes = std::fs::read(&file).expect("the exported file exists");
    let (jw, jh) = jpeg_size(&bytes).expect("the file is a JPEG");
    assert_eq!(jw.max(jh), 1200, "the export is the long edge asked ({jw}x{jh})");
    assert_eq!((jw > jh), (w > h), "and the frame's shape");
    assert_eq!(link.take(), ["export_frame"], "an export opens a private session in the host");
    std::fs::remove_dir_all(&dir).unwrap();

    // 5. A thumbnail: no session.
    let thumb = scheduler
        .submit(&spec(json!({"frameId": frame, "kind": "thumbnail", "tier": "preview",
        "canvas": {"width": 256, "height": 256},
        "request": {"method": "thumbnail", "params": {"path": path, "long_edge": 256}}})))
        .unwrap();
    let (out, pixels) = scheduler.outcome(thumb).await;
    assert_eq!(out.outcome, OutcomeKind::Finished, "thumbnail: {out:?}");
    let image = &out.result.as_ref().unwrap().host_result.as_ref().unwrap()["image"];
    let (tw, th) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(tw.max(th), 256);
    assert_picture("thumbnail", pixels.as_deref().expect("pixels"), tw, th);
    assert_eq!(link.take(), ["thumbnail"]);

    // 6. A cancel: a full-size render cancelled while the host renders it ends `cancelled` (another
    //    frame's, so one-shot: a borrowed full view prints from the cached negative too fast to catch).
    let slow = scheduler
        .submit(&spec(json!({"frameId": "raw:2", "kind": "fullView", "tier": "full",
        "canvas": {"width": w, "height": h}, "decodesOriginal": true, "original": opens,
        "request": {"source": source, "method": "render_view", "params": view("full", 0, 6)}})))
        .unwrap();
    // Cancelled once its call is in flight: the snapshot reads Film at 0.15 (the session opened, the
    // render sent) — a state, not a time.
    loop {
        let event = tokio::time::timeout(Duration::from_secs(600), events.recv())
            .await
            .expect("the job moves")
            .expect("events");
        if event.job_id == slow {
            if let spk_scheduler::wire::JobStateWire::Running { fraction, .. } = event.state {
                if fraction >= 0.15 {
                    break;
                }
            }
        }
    }
    scheduler.cancel(slow);
    let (out, _) = scheduler.outcome(slow).await;
    assert_eq!(out.outcome, OutcomeKind::Cancelled, "the cancel reached the render: {out:?}");
    let methods = link.take();
    assert!(methods.contains(&"cancel".to_string()), "a host cancel was sent: {methods:?}");
    assert!(scheduler.queue().records().iter().any(|r| r.job_id == slow && r.outcome == "cancelled"));

    // Nothing left behind: the one-shot sessions are closed, the editing one goes with the page.
    engine.close_editing(None).await;
    let (report, _) = link.inner.request("memory_report", json!({}), vec![], Duration::from_secs(30)).await.unwrap();
    assert_eq!(
        report["result"]["persistent"]["sessions"].as_array().map(|s| s.len()),
        Some(0),
        "{}",
        report["result"]["persistent"]
    );
    assert!(scheduler.queue().is_idle());
    assert!(matches!(scheduler.snapshot(Some(frame)).as_slice(), []));
    process.shutdown().await;
}
