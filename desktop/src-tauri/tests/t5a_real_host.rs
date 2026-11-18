//! T5a — the app's Rust layer against the real engine host and the real library helper on this Mac, no
//! window (PRD-W2 T5). Everything goes through the app crate's own state and the functions its Tauri
//! commands call (`scheduler::SchedulerHub`, `library::LibraryState`), over the app's own
//! `HostManager` (one host process), not through the crates' APIs.
//!
//! One RAW from `SPEKTRALAB_RAW_FIXTURES`: the frame opened for its parameters (the webview's
//! `editing_open`), a canvas develop, a reprint on the same session, a full view, an export to a file
//! (it exists, decodes, has the size asked), a thumbnail, a cancel that lands; then the host killed in
//! the middle of a job (it fails), restarted by the manager, and the next job develops again, while the
//! old host's session is refused rather than reaching a new one. Then `library_call` against spklib's
//! fixtures, a Capture One catalog among them, whose bytes are unchanged afterwards.
//!
//! Variables: `SPEKTRALAB_HOST_DIR` (the staged MoltenVK host, `scripts/build-host-mac.sh`),
//! `SPEKTRALAB_RAW_FIXTURES`, `SPKLIB_HOST` (the Mac helper) and `SPKLIB_FIXTURES`. Unset, the test says
//! so and passes, unless `SPK_REQUIRE_REAL_HOST=1` (the gate sets it): then anything missing **fails**.
//! No assertion on time: pictures are checked for being pictures, jobs for how they ended.
#![cfg(target_os = "macos")]

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use serde_json::{json, Value};
use spektralab_lib::host::HostManager;
use spektralab_lib::library::LibraryState;
use spektralab_lib::scheduler::{SchedulerHub, SchedulerPaths};
use spektralab_lib::workspace::Workspace;
use tauri::test::{mock_builder, mock_context, noop_assets, MockRuntime};

const RAW: &str = "A7m3/DSC03710.ARW";

struct Gate {
    raw: PathBuf,
    spklib_fixtures: PathBuf,
}

fn gate() -> Option<Gate> {
    let required = std::env::var("SPK_REQUIRE_REAL_HOST").is_ok_and(|v| v == "1");
    let vars = ["SPEKTRALAB_HOST_DIR", "SPEKTRALAB_RAW_FIXTURES", "SPKLIB_HOST", "SPKLIB_FIXTURES"];
    let missing: Vec<_> = vars.iter().filter(|v| std::env::var_os(v).is_none()).collect();
    if !missing.is_empty() {
        assert!(!required, "SPK_REQUIRE_REAL_HOST=1 but {missing:?} unset");
        eprintln!("T5a NOT RUN: set {vars:?} (the gate does)");
        return None;
    }
    let var = |v: &str| PathBuf::from(std::env::var_os(v).unwrap());
    let host = var("SPEKTRALAB_HOST_DIR").join("spektralab-host");
    assert!(host.is_file(), "no host at {}", host.display());
    let raw = var("SPEKTRALAB_RAW_FIXTURES").join(RAW);
    assert!(raw.is_file(), "SPEKTRALAB_RAW_FIXTURES has no {RAW}");
    assert!(var("SPKLIB_HOST").is_file(), "SPKLIB_HOST is not a file");
    let spklib_fixtures = var("SPKLIB_FIXTURES");
    assert!(spklib_fixtures.join("capture_one_16_8_schema.sql").is_file(), "SPKLIB_FIXTURES has no Capture One schema");
    Some(Gate { raw, spklib_fixtures })
}

/// `u32 header_len · u32 payload_len · JSON · bytes`.
fn unframe(bytes: &[u8]) -> (Value, Vec<u8>) {
    let h = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let p = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    let header = serde_json::from_slice(&bytes[8..8 + h]).expect("a JSON header");
    (header, bytes[8 + h..8 + h + p].to_vec())
}

fn assert_picture(what: &str, payload: &[u8], width: u64, height: u64) {
    assert_eq!(payload.len() as u64, width * height * 4, "{what}: {width}x{height} rgba8");
    assert!(payload.chunks_exact(4).all(|p| p[3] == 255), "{what}: alpha is opaque");
    let first = &payload[0..3];
    let differing = payload.chunks_exact(4).filter(|p| &p[0..3] != first).count();
    assert!(differing > payload.len() / 40, "{what}: not one colour");
    let mean: f64 = payload.chunks_exact(4).map(|p| p[1] as f64).sum::<f64>() / (payload.len() / 4) as f64;
    assert!(mean > 2.0 && mean < 253.0, "{what}: neither black nor white (mean green {mean:.1})");
}

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

fn view(tier: &str, long_edge: u64, generation: u64) -> Value {
    json!({"tier": tier, "display": "srgb", "format": "rgba8", "long_edge": long_edge, "generation": generation,
           "adjustments": {}, "geometry": {}})
}

async fn wait_ready(host: &HostManager<MockRuntime>) {
    for _ in 0..600 {
        if host.state()["phase"] == "ready" {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("the host never became ready: {}", host.diagnostics());
}

async fn finished(hub: &SchedulerHub<MockRuntime>, what: &str, job: Value) -> (Value, Vec<u8>) {
    let id = hub.submit(job).await.unwrap_or_else(|e| panic!("{what}: submit: {e}"));
    let (out, payload) = unframe(&hub.outcome(&id).await.unwrap());
    assert_eq!(out["outcome"], "finished", "{what}: {out}");
    (out, payload)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_app_develops_a_raw_and_reads_a_library_on_the_real_binaries() {
    let Some(gate) = gate() else { return };
    let scratch = std::env::temp_dir().join(format!("spk-t5a-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    std::fs::create_dir_all(&scratch).unwrap();
    // The host needs MoltenVK's loader (volk dlopens libvulkan), as the gate's other hosts do.
    std::env::set_var("DYLD_FALLBACK_LIBRARY_PATH", "/opt/homebrew/lib");

    let app = mock_builder().build(mock_context(noop_assets())).expect("a windowless app");
    let host = HostManager::new(app.handle().clone());
    host.start().await;
    wait_ready(&host).await;
    assert_eq!(host.state()["hello"]["backend"]["available"], true, "Vulkan through MoltenVK: {}", host.state());
    let workspace = Workspace::new(scratch.join("data"));
    let events = Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let seen = events.clone();
    let hub = SchedulerHub::new(
        host.clone(),
        Some(workspace),
        SchedulerPaths { logs: scratch.join("logs"), data: scratch.join("data") },
        move |s| seen.lock().unwrap().push(serde_json::to_value(s).unwrap()),
    );
    let path = gate.raw.to_string_lossy().to_string();
    let frame = "raw:t5a";

    // The webview opens the frame for its parameters: the engine's editing session, reached by the frame.
    let (opened, _) = unframe(&hub.editing_open(frame, serde_json::from_value(json!({"path": path})).unwrap()).await.unwrap());
    assert_eq!(opened["ok"], true, "editing_open: {opened}");
    let session = opened["result"]["session"].as_str().unwrap().to_string();
    let (w, h) = (opened["result"]["width"].as_i64().unwrap(), opened["result"]["height"].as_i64().unwrap());
    let params = opened["result"]["params"].clone();
    let (set, _) = unframe(&hub.editing_call(frame, &session, "set_params", json!({"delta": {"print_exposure": 1.1}})).await.unwrap());
    assert_eq!(set["ok"], true, "set_params on the editing session: {set}");
    hub.frontend_state(serde_json::from_value(json!({"visiblePage": "develop", "openFrame": frame, "foreground": true, "scene": "active"})).unwrap()).await.unwrap();

    let source = json!({"path": path});
    let opens = json!({"width": w, "height": h});
    let edge = 1600u64;
    let (cw, ch) = if w >= h { (edge as i64, (h as f64 * edge as f64 / w as f64).round() as i64) } else { ((w as f64 * edge as f64 / h as f64).round() as i64, edge as i64) };

    // 1. A canvas develop, on the session the frame was opened in (no second open).
    let (out, pixels) = finished(&hub, "develop", json!({"frameId": frame, "kind": "canvasDevelop", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "opens": opens,
        "request": {"source": source, "method": "render_view", "params": view("live", edge, 1)}})).await;
    let image = &out["result"]["hostResult"]["image"];
    let (iw, ih) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(iw.max(ih), edge);
    assert_picture("develop", &pixels, iw, ih);
    // 2. A reprint: the print side only.
    let (out, pixels) = finished(&hub, "reprint", json!({"frameId": frame, "kind": "canvasReprint", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "layers": ["print"], "opens": opens,
        "request": {"source": source, "setParams": {"print_exposure": 1.2}, "method": "render_view", "params": view("live", edge, 2)}})).await;
    assert_eq!(out["result"]["hostResult"]["generation"], 2);
    assert_picture("reprint", &pixels, iw, ih);
    let (again, _) = unframe(&hub.editing_call(frame, &session, "get_params", json!({})).await.unwrap());
    assert_eq!(again["result"]["params"]["print_exposure"], json!(1.2), "the job ran on the frame's editing session");
    // 3. A full view of the frame being edited: it borrows the editing session (phase 3, part 2), so it
    // is priced as opening nothing, and it leaves its negative there beside the canvas's.
    let (out, pixels) = finished(&hub, "full view", json!({"frameId": frame, "kind": "fullView", "tier": "full",
        "canvas": {"width": w, "height": h},
        "request": {"source": {"path": path, "params": params}, "method": "render_view", "params": view("full", 3000, 3)}})).await;
    let image = &out["result"]["hostResult"]["image"];
    let (fw, fh) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(fw.max(fh), 3000);
    assert_picture("full view", &pixels, fw, fh);
    let (report, _) = host.request("memory_report", json!({}), vec![], Duration::from_secs(30), None).await.unwrap();
    let rows = report["result"]["persistent"]["sessions"].as_array().cloned().unwrap_or_default();
    assert_eq!(rows.len(), 1, "the editing session alone, nothing opened beside it: {rows:?}");
    assert_eq!(rows[0]["negatives"], 2, "the full view ran on the editing session: {rows:?}");
    let (again, _) = unframe(&hub.editing_call(frame, &session, "get_params", json!({})).await.unwrap());
    assert_eq!(again["result"]["params"]["print_exposure"], json!(1.2), "and left its parameters as the canvas had them");
    // 4. An export to a file.
    let file = scratch.join("export.jpg");
    finished(&hub, "export", json!({"frameId": frame, "kind": "export", "tier": "full",
        "canvas": {"width": w, "height": h}, "decodesOriginal": true, "original": opens,
        "request": {"source": source, "method": "export_frame", "params": {
            "params": params, "adjustments": {}, "geometry": {}, "path": file.to_string_lossy(), "format": "jpeg",
            "quality": 90, "color_space": "sRGB", "long_edge": 1200, "overwrite": true}}})).await;
    let bytes = std::fs::read(&file).expect("the exported file exists");
    let (jw, jh) = jpeg_size(&bytes).expect("the file decodes as a JPEG");
    assert_eq!(jw.max(jh), 1200, "the export has the long edge asked ({jw}x{jh})");
    assert_eq!(jw > jh, w > h, "and the frame's shape");
    // 5. A thumbnail.
    let (out, pixels) = finished(&hub, "thumbnail", json!({"frameId": frame, "kind": "thumbnail", "tier": "preview",
        "canvas": {"width": 256, "height": 256}, "request": {"method": "thumbnail", "params": {"path": path, "long_edge": 256}}})).await;
    let image = &out["result"]["hostResult"]["image"];
    let (tw, th) = (image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!(tw.max(th), 256);
    assert_picture("thumbnail", &pixels, tw, th);

    // 6. A cancel that lands: a full-size render, cancelled once the host is rendering it. Another
    // frame's, so one-shot from a fresh decode (a borrowed one prints from a cached negative, too fast
    // to catch in flight).
    let elsewhere = format!("{frame}#elsewhere");
    let slow = |generation: u64| json!({"frameId": elsewhere, "kind": "fullView", "tier": "full",
        "canvas": {"width": w, "height": h}, "decodesOriginal": true, "original": opens,
        "request": {"source": source, "method": "render_view", "params": view("full", 0, generation)}});
    let running = |id: &str| {
        let id = id.to_string();
        let events = events.clone();
        async move {
            for _ in 0..6000 {
                if events.lock().unwrap().iter().any(|e| e["jobId"] == json!(id) && e["state"] == "running" && e["fraction"].as_f64().unwrap_or(0.0) >= 0.15) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            panic!("job {id} never reached the render");
        }
    };
    let id = hub.submit(slow(4)).await.unwrap();
    running(&id).await;
    hub.cancel(&id).await.unwrap();
    let (out, _) = unframe(&hub.outcome(&id).await.unwrap());
    assert_eq!(out["outcome"], "cancelled", "the cancel reached the render: {out}");

    // 7. The host killed in the middle of a job: the job fails, the manager restarts the host, the
    // next job develops, and the old host's session is refused instead of reaching a new one.
    let generation = host.generation();
    let id = hub.submit(slow(5)).await.unwrap();
    running(&id).await;
    let pid = host.pid().expect("the host's pid");
    assert!(Command::new("/bin/kill").args(["-9", &pid.to_string()]).status().unwrap().success());
    let (out, _) = unframe(&hub.outcome(&id).await.unwrap());
    assert_eq!(out["outcome"], "failed", "the job in flight fails: {out}");
    assert!(out["message"].as_str().unwrap().starts_with("host_exited"), "{out}");
    wait_ready(&host).await;
    assert!(host.generation() > generation, "a new host");
    let (stale, _) = unframe(&hub.editing_call(frame, &session, "get_params", json!({})).await.unwrap());
    assert_eq!(stale["error"]["code"], "not_found", "the old host's session is gone: {stale}");
    let (out, pixels) = finished(&hub, "develop after the restart", json!({"frameId": frame, "kind": "canvasDevelop", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "opens": opens,
        "request": {"source": {"path": path, "params": params}, "method": "render_view", "params": view("live", edge, 6)}})).await;
    let image = &out["result"]["hostResult"]["image"];
    assert_picture("develop after the restart", &pixels, image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap());
    assert_eq!((image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap()), (iw, ih));

    // 8. A restart between jobs (Restart Render Service): the engine still holds the frame's editing
    // session, and the new host gives a session of someone else's (another frame, opened on the
    // direct path) the raw id the old one had. The canvas job must not land on it: the link scopes
    // sessions to their host, so the engine is told not_found and opens the frame again.
    host.restart().await;
    wait_ready(&host).await;
    let other = gate.raw.parent().unwrap().parent().unwrap().join("Olympus E300/sample1.orf");
    let (theirs, _) = host.request("open", json!({"path": other}), vec![], Duration::from_secs(300), None).await.unwrap();
    assert_eq!(theirs["ok"], true, "{theirs}");
    let raw_engine_id = hub.wired().await.unwrap().engine.editing_frame().await;
    assert_eq!(raw_engine_id.as_ref().map(|f| f.as_str()), Some(frame), "the engine still holds the frame's session");
    let (out, pixels) = finished(&hub, "develop after a restart between jobs", json!({"frameId": frame, "kind": "canvasReprint", "tier": "live",
        "canvas": {"width": cw, "height": ch}, "opens": opens, "layers": ["print"],
        "request": {"source": {"path": path, "params": params}, "method": "render_view", "params": view("live", edge, 7)}})).await;
    let image = &out["result"]["hostResult"]["image"];
    assert_eq!((image["width"].as_u64().unwrap(), image["height"].as_u64().unwrap()), (iw, ih),
        "the frame's own picture, not the session {} the new host gave the Olympus file", theirs["result"]["session"]);
    assert_picture("develop after a restart between jobs", &pixels, iw, ih);
    let (report, _) = host.request("memory_report", json!({}), vec![], Duration::from_secs(30), None).await.unwrap();
    assert_eq!(report["result"]["persistent"]["sessions"].as_array().map(Vec::len), Some(2),
        "the direct session and the engine's new one: {}", report["result"]["persistent"]);
    let _ = host.request("close", json!({"session": theirs["result"]["session"]}), vec![], Duration::from_secs(30), None).await;
    let (budget, log) = (hub.budget().await.unwrap(), std::fs::read_to_string(hub.paths().job_log()).unwrap());
    assert_eq!(budget.policy.device, "mac");
    assert!(log.lines().count() >= 8, "a record a job in the app's log folder: {log}");
    assert!(log.contains("\"outcome\":\"cancelled\"") && log.contains("\"outcome\":\"failed: host_exited"), "{log}");
    assert!(hub.paths().corrections().is_file(), "the corrections are kept in the data folder");

    // 9. The library: spklib's fixtures, a Capture One catalog among them, read and never written.
    library_part(&gate, &scratch);

    host.shutdown().await;
    let _ = std::fs::remove_dir_all(&scratch);
}

fn census(root: &Path) -> BTreeMap<PathBuf, (u64, Option<SystemTime>, Vec<u8>)> {
    let mut out = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(p) = stack.pop() {
        let md = std::fs::symlink_metadata(&p).unwrap();
        let bytes = if md.is_file() { std::fs::read(&p).unwrap() } else { Vec::new() };
        out.insert(p.clone(), (md.len(), md.modified().ok(), bytes));
        if md.is_dir() {
            for e in std::fs::read_dir(&p).unwrap() {
                stack.push(e.unwrap().path());
            }
        }
    }
    out
}

fn touch(p: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

/// A Capture One 16.8 catalog made from spklib's fixture schema (as spk-library's own test makes it).
fn capture_one_catalog(fixtures: &Path, root: &Path, raw: &Path) -> PathBuf {
    let package = root.join("Fixture.cocatalog");
    let photos = root.join("Photos");
    std::fs::create_dir_all(package.join("Originals")).unwrap();
    std::fs::create_dir_all(&photos).unwrap();
    std::fs::copy(raw, photos.join("A.ARW")).unwrap();
    touch(&photos.join("B.ARW"), b"arw-b");
    let schema = std::fs::read_to_string(fixtures.join("capture_one_16_8_schema.sql")).unwrap();
    let rel = photos.to_string_lossy().trim_start_matches('/').replace('\'', "''");
    let rows = format!("INSERT INTO ZVERSIONINFO VALUES (32, 1, '16.8.6.25 Pro Mac', '9.0.0 Mac', 160800, '16.8.6.25 Pro Mac', 160800);
INSERT INTO ZDOCUMENTCONTENT (Z_ENT, Z_PK, ZDATECREATED, ZDOCUMENTTYPE, ZDOCUMENTUUID, ZROOTCOLLECTION) VALUES (34, 1, 1729735821, 1, 'AAAAAAAA-2222-3333-4444-555555555555', 1);
INSERT INTO ZPATHLOCATION (Z_ENT, Z_PK, ZMACROOT, ZRELATIVEPATH, ZISRELATIVE, ZVOLUME) VALUES (38, 3, '/', '{rel}', 0, '/');
INSERT INTO ZIMAGE (Z_ENT, Z_PK, ZIMAGEUUID, ZIMAGEFILENAME, ZDISPLAYNAME, ZIMAGELOCATION, ZISINSIDECATALOG, ZISTRASHED, ZIMAGECLASSIFICATION, ZWIDTH, ZHEIGHT, ZEXP_DATE, ZIMPORTDATE, ZCAMERA_MAKE, ZCAMERA_MODEL, ZISO) VALUES
 (12, 1, 'IMG-A', 'A.ARW', 'A', 3, 0, 0, 17, 6000, 4000, 1704757144.25, 1729841315.9, 'SONY', 'ILCE-7M3', 100),
 (12, 2, 'IMG-B', 'B.ARW', 'B', 3, 0, 0, 17, 6000, 4000, 1704757148, 1729841315.9, 'SONY', 'ILCE-7M3', 400);
INSERT INTO ZVARIANT (Z_ENT, Z_PK, ZINDEX, ZVARIANTUUID, ZIMAGE, ZCOMBINEDSETTINGS, ZISMODIFIED) VALUES (15, 1, 127, 'VAR-A1', 1, 101, 0), (15, 2, 127, 'VAR-B1', 2, 102, 0);
INSERT INTO ZVARIANTLAYER (Z_ENT, Z_PK, ZVARIANT, ZROTATION, ZFLIP) VALUES (20, 101, 1, 0, 0), (20, 102, 2, 0, 0);
INSERT INTO ZVARIANTMETADATA (Z_ENT, Z_PK, ZLAYER, ZBASIC_RATING, ZCOLOR_TAG_INDEX) VALUES (13, 101, 101, 0, 0), (13, 102, 102, 4, 1);
INSERT INTO ZCOLLECTION (Z_ENT, Z_PK, ZUUID, ZNAME, ZPARENT, ZCOLLECTIONINDEX, ZFOLDERLOCATION, ZALLIMAGESCOLLECTION, ZLASTIMPORTSCOLLECTION, ZLASTCAPTURESCOLLECTION, ZTRASHCOLLECTION) VALUES
 (7, 1, 'COL-ROOT', 'root', NULL, 0, NULL, 2, 3, 4, 5), (40, 2, 'COL-ALL', 'All Images', 1, 1, NULL, NULL, NULL, NULL, NULL),
 (8, 3, 'COL-RI', 'Recent Imports', 1, 2, NULL, NULL, NULL, NULL, NULL), (8, 4, 'COL-RC', 'Recent Captures', 1, 3, NULL, NULL, NULL, NULL, NULL),
 (11, 5, 'COL-TRASH', 'Trash', 1, 4, NULL, NULL, NULL, NULL, NULL), (2, 8, 'COL-PICKS', 'Picks', 1, 6, NULL, NULL, NULL, NULL, NULL);
INSERT INTO ZIMAGEINCOLLECTION (Z_ENT, Z_PK, ZCOLLECTION, ZIMAGE) VALUES (47, 4, 8, 2);
");
    let script = root.join("make-catalog.sql");
    std::fs::write(&script, format!("{schema}\n{rows}")).unwrap();
    let db = package.join("Fixture.cocatalogdb");
    let st = Command::new("/usr/bin/sqlite3").arg(&db).arg(format!(".read {}", script.display())).status().unwrap();
    assert!(st.success(), "building the Capture One fixture catalog");
    std::fs::remove_file(&script).unwrap();
    package
}

fn library_part(gate: &Gate, scratch: &Path) {
    let root = scratch.join("library");
    std::fs::create_dir_all(&root).unwrap();
    std::env::set_var("SPEKTRALAB_LIBRARY_STORE", root.join("store"));
    // Resolved as the app resolves it: SPKLIB_HOST (the Mac's dev helper), the store from the override.
    let lib = LibraryState::resolve(None);
    let state = lib.state();
    assert_eq!(state["origin"], "SPKLIB_HOST", "{state}");
    assert_eq!(state["running"], false, "nothing starts before the first call");
    let call = |m: &str, p: Value| lib.call(m, p).unwrap_or_else(|e| panic!("{m}: {e}"));
    assert_eq!(call("sdk.version", json!({}))["abi"], 1);
    let state = lib.state();
    assert_eq!((state["running"].clone(), state["launches"].clone()), (json!(true), json!(1)), "{state}");
    assert!(state["store"].as_str().unwrap().ends_with("store"), "{state}");

    // A SpektraLab catalog with a linked folder.
    let folder = root.join("Folder");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::copy(&gate.raw, folder.join("DSC03710.ARW")).unwrap();
    let made = call("library.create", json!({"path": root.join("Darkroom.spkcatalog"), "kind": "catalog", "name": "Darkroom"}));
    let l = made["library"].as_str().unwrap().to_string();
    call("folders.add", json!({"library": l, "path": folder, "recursive": true}));
    let folders = call("folders.list", json!({"library": l}));
    assert_eq!(folders["folders"].as_array().map(Vec::len), Some(1), "{folders}");
    call("folders.sync", json!({"library": l}));
    let page = call("images.list", json!({"library": l}));
    assert_eq!(page["total"], 1, "the linked folder's picture: {page}");
    let cols = call("collections.list", json!({"library": l}));
    assert!(cols["collections"].as_array().unwrap().iter().any(|c| c["kind"] == "all_images"), "{cols}");
    call("library.close", json!({"library": l}));
    let reopened = call("library.open", json!({"path": root.join("Darkroom.spkcatalog")}));
    assert_eq!(reopened["info"]["counts"]["images"], 1, "{reopened}");

    // A Capture One catalog, read through a mirror and never written.
    let package = capture_one_catalog(&gate.spklib_fixtures, &root, &gate.raw);
    let before = census(&package);
    let probe = call("capture_one.probe", json!({"path": package}));
    assert_eq!(probe["supported"], true, "{probe}");
    let linked = call("capture_one.link", json!({"source": package}));
    let m = linked["library"].as_str().unwrap().to_string();
    assert_eq!(linked["info"]["origin"]["write_back"], false, "{linked}");
    let page = call("images.list", json!({"library": m, "check_files": true}));
    assert_eq!(page["total"], 2, "{page}");
    let picks = call("collections.list", json!({"library": m}))["collections"]
        .as_array().unwrap().iter().find(|c| c["name"] == "Picks").cloned().expect("Picks");
    let e = lib.call("collection.add", json!({"library": m, "collection": picks["uuid"], "images": [page["images"][0]["uuid"]]})).unwrap_err();
    assert_eq!(e["code"], "read_only", "{e}");
    let e = lib.call("library.create", json!({"path": package.join("Inside.spkcatalog"), "kind": "catalog"})).unwrap_err();
    assert!(matches!(e["code"].as_str(), Some("invalid_params" | "read_only")), "nothing is made inside the package: {e}");
    call("library.sync", json!({"library": m, "force": true}));
    lib.shutdown();
    assert_eq!(lib.state()["running"], false);
    let after = census(&package);
    assert_eq!(before, after, "the Capture One package is byte for byte, size and time, as it was");
    std::env::remove_var("SPEKTRALAB_LIBRARY_STORE");
}
