//! SpektraLab's Tauri core: the window, the engine host process, and the
//! narrow file commands the webview needs. Everything else — the interface,
//! the session, the menus — is the TypeScript app in `desktop/src`.

pub mod files;
pub mod framing;
pub mod host;
pub mod pairs;
pub mod frame_cache;
pub mod agent_files;
pub mod workspace;
pub mod diagnostics;
pub mod scheduler;
pub mod library;
#[cfg(any(debug_assertions, feature = "selftest"))]
pub mod selftest;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::{AppHandle, Manager, State};
use tauri::Emitter;

use host::HostManager;

struct AppState {
    host: Arc<HostManager>,
    sidecars: files::SidecarStore,
    /// Paths from the command line (open-with) not yet taken by the webview.
    launch_paths: Mutex<Vec<String>>,
    frames: Arc<frame_cache::FrameCache>,
    cache_fingerprint: Arc<Mutex<Option<String>>>,
    workspace: Arc<workspace::Workspace>,
}

fn reply_bytes(reply: host::Reply) -> Response {
    match reply {
        Ok((header, payload)) => {
            // Keep only what the webview reads: ok + result/error.
            let h = if header["ok"] == json!(true) {
                json!({"ok": true, "result": header["result"]})
            } else {
                json!({"ok": false, "error": header["error"]})
            };
            Response::new(framing::encode(&h, &payload))
        }
        Err(e) => Response::new(framing::encode(&e.to_header(), &[])),
    }
}

fn timeout_of(ms: Option<u64>) -> Duration {
    Duration::from_millis(ms.unwrap_or(120_000).clamp(1_000, 3_600_000))
}

/// One host request. The reply is the protocol's framing (header + pixels) as
/// one binary response; `src/host/client.ts` splits it.
#[tauri::command]
async fn host_request(
    state: State<'_, AppState>,
    method: String,
    params: Value,
    timeout_ms: Option<u64>,
) -> Result<Response, String> {
    let lease=if matches!(method.as_str(),"cancel"|"ping"|"shutdown"){None}else{Some(state.workspace.enter()?)};
    let reply = state.host.request(&method, params, Vec::new(), timeout_of(timeout_ms), lease).await;
    Ok(reply_bytes(reply))
}

/// A request that carries a binary payload (an image to write). The body is a
/// frame: `{method, params, timeout_ms?}` + payload.
#[tauri::command]
async fn host_request_upload(state: State<'_, AppState>, request: Request<'_>) -> Result<Response, String> {
    let lease=state.workspace.enter()?;
    let InvokeBody::Raw(bytes) = request.body() else {
        return Err("host_request_upload takes a raw body".into());
    };
    let (header, payload) = framing::decode_one(bytes)?;
    let method = header["method"].as_str().ok_or("missing method")?.to_string();
    let params = header.get("params").cloned().unwrap_or(json!({}));
    let timeout = timeout_of(header.get("timeout_ms").and_then(Value::as_u64));
    let reply = state.host.request(&method, params, payload.to_vec(), timeout, Some(lease)).await;
    Ok(reply_bytes(reply))
}

// ------------------------------------------------------------------ the scheduler (WIRE.md)

type Hub = scheduler::SchedulerHub<tauri::Wry>;

#[tauri::command]
async fn scheduler_submit(hub: State<'_, Hub>, job: Value) -> Result<String, String> {
    hub.submit(job).await
}
#[tauri::command]
async fn scheduler_cancel(hub: State<'_, Hub>, job_id: String) -> Result<(), String> {
    hub.cancel(&job_id).await
}
#[tauri::command]
async fn scheduler_cancel_frame(hub: State<'_, Hub>, frame_id: String, kinds: Option<Vec<spk_scheduler::JobKind>>) -> Result<(), String> {
    hub.cancel_frame(&frame_id, kinds).await
}
/// `OutcomeWire` + the payload, in the protocol's framing (as `host_request` replies).
#[tauri::command]
async fn scheduler_outcome(hub: State<'_, Hub>, job_id: String) -> Result<Response, String> {
    hub.outcome(&job_id).await.map(Response::new)
}
#[tauri::command]
async fn scheduler_snapshot(hub: State<'_, Hub>, frame_id: Option<String>) -> Result<Vec<spk_scheduler::wire::JobSnapshotWire>, String> {
    hub.snapshot(frame_id.as_deref()).await
}
#[tauri::command]
async fn scheduler_budget(hub: State<'_, Hub>) -> Result<spk_scheduler::wire::BudgetReadingWire, String> {
    hub.budget().await
}
#[tauri::command]
async fn scheduler_frontend_state(hub: State<'_, Hub>, state: spk_scheduler::wire::FrontendStateMsg) -> Result<(), String> {
    hub.frontend_state(state).await
}
#[tauri::command]
async fn scheduler_memory_pressure(hub: State<'_, Hub>, level: spk_scheduler::wire::PressureLevel) -> Result<(), String> {
    hub.memory_pressure(level).await
}
/// The frame opened in the scheduler's editing session; the reply is `open`'s, framed.
#[tauri::command]
async fn scheduler_editing_open(hub: State<'_, Hub>, frame_id: String, source: spk_scheduler::wire::SourceSpec) -> Result<Response, String> {
    hub.editing_open(&frame_id, source).await.map(Response::new)
}
/// A call on the frame's editing session (`scheduler::EDITING_METHODS`), framed.
#[tauri::command]
async fn scheduler_editing_call(hub: State<'_, Hub>, frame_id: String, session: String, method: String, params: Value) -> Result<Response, String> {
    hub.editing_call(&frame_id, &session, &method, params).await.map(Response::new)
}

// ------------------------------------------------------------- the library helper (PRD-W0 §5.3)

type Library = Arc<library::LibraryState>;

/// Any method of spklib's API-SPEC; the error is the helper's `{code, message, data}`.
#[tauri::command]
async fn library_call(lib: State<'_, Library>, method: String, params: Option<Value>) -> Result<Value, Value> {
    let lib = Arc::clone(&lib);
    tauri::async_runtime::spawn_blocking(move || lib.call(&method, params.unwrap_or_else(|| json!({}))))
        .await
        .map_err(|e| json!({"code": "internal", "message": e.to_string(), "data": null}))?
}
#[tauri::command]
fn library_state(lib: State<'_, Library>) -> Value {
    lib.state()
}

#[tauri::command]
fn host_state(state: State<'_, AppState>) -> Value {
    state.host.state()
}

#[tauri::command]
fn host_diagnostics(state: State<'_, AppState>) -> Value {
    state.host.diagnostics()
}

#[tauri::command]
async fn host_restart(state: State<'_, AppState>) -> Result<(), String> {
    let lease=state.workspace.enter()?;
    let host = Arc::clone(&state.host);
    tauri::async_runtime::spawn(async move { let _lease=lease;host.restart().await });
    Ok(())
}

#[tauri::command]
fn list_images(dir: String) -> Result<Vec<files::Entry>, String> {
    files::list_images(&PathBuf::from(dir))
}

#[tauri::command]
fn expand_paths(paths: Vec<String>) -> Vec<files::Entry> {
    files::expand(&paths)
}

#[tauri::command]
fn sidecar_load(state: State<'_, AppState>, image: String) -> Result<Option<Value>,String> {
    let _lease=state.workspace.enter()?;
    state.workspace.load(&state.sidecars,&PathBuf::from(image))
}

#[tauri::command]
fn sidecar_save(state: State<'_, AppState>, image: String, sidecar: Value) -> Result<String, String> {
    let _lease=state.workspace.enter()?;
    state.workspace.save(&state.sidecars,&PathBuf::from(image), &sidecar).map(|p| p.display().to_string())
}

#[tauri::command]
fn sidecar_path(state: State<'_, AppState>, image: String) -> String {
    state.sidecars.path_for(&PathBuf::from(image)).display().to_string()
}

#[tauri::command]
fn sidecar_remove(state: State<'_, AppState>, image: String) -> Result<(), String> {
    let _lease=state.workspace.enter()?;
    state.sidecars.remove(&PathBuf::from(image))
}

fn pair_store(state: &AppState) -> pairs::PairStore {
    pairs::PairStore { dir: state.sidecars.dir.join("Pairs") }
}

#[tauri::command]
fn pair_create(state: State<'_, AppState>, folder: String, value: Value) -> Result<files::Entry, String> {
    let _lease=state.workspace.enter()?;
    pair_store(&state).create(&PathBuf::from(folder), &value)
}
#[tauri::command]
fn pair_load(path: String) -> Result<Option<Value>, String> {
    pairs::PairStore::load(&PathBuf::from(path))
}
#[tauri::command]
fn pair_save(state: State<'_, AppState>, path: String, value: Value) -> Result<(), String> {
    let _lease=state.workspace.enter()?;
    pair_store(&state).save(&PathBuf::from(path), &value)
}
#[tauri::command]
fn pair_list(state: State<'_, AppState>, folder: String) -> Result<Vec<files::Entry>, String> {
    pair_store(&state).list(&PathBuf::from(folder))
}
#[tauri::command]
fn pair_delete(state: State<'_, AppState>, path: String) -> Result<(), String> {
    let _lease=state.workspace.enter()?;
    pair_store(&state).delete(&PathBuf::from(path))
}

#[tauri::command]
async fn frame_cache_key(app: AppHandle, state: State<'_, AppState>, descriptor: Value) -> Result<String,String> {
    let launch=host::resolve_launch(&app)?;
    if launch.mock { return Err("Persistent native image cache is unavailable for a mock host".into()); }
    let i=launch.args.iter().position(|a|a=="--resources").ok_or("Host resource path is missing")?;
    let resources=PathBuf::from(launch.args.get(i+1).ok_or("Host resource path is missing")?);
    let fingerprint=Arc::clone(&state.cache_fingerprint);
    tauri::async_runtime::spawn_blocking(move || {
        let mut saved=fingerprint.lock().map_err(|e|e.to_string())?;
        if saved.is_none(){*saved=Some(frame_cache::engine_fingerprint(&launch.program,&resources)?);}
        frame_cache::key(&descriptor,saved.as_ref().unwrap())
    }).await.map_err(|e|e.to_string())?
}

#[tauri::command]
async fn frame_cache_read(state: State<'_, AppState>, key: String) -> Result<Response,String> {
    let cache=Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || {
        let (metadata,payload)=match cache.load(&key)?{Some((m,p))=>(json!({"hit":true,"metadata":m}),p),None=>(json!({"hit":false}),Vec::new())};
        Ok(Response::new(framing::encode(&metadata,&payload)))
    }).await.map_err(|e|e.to_string())?
}

#[tauri::command]
async fn frame_cache_write(state: State<'_, AppState>, request: Request<'_>) -> Result<bool,String> {
    let InvokeBody::Raw(bytes)=request.body()else{return Err("Frame cache requires a raw body".into())};
    let (header,payload)=framing::decode_one(bytes)?;
    let key=header["key"].as_str().ok_or("Cache key missing")?.to_string();
    let metadata=header["metadata"].clone();let payload=payload.to_vec();let cache=Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || cache.store(&key,&metadata,&payload)).await.map_err(|e|e.to_string())?
}

#[tauri::command]
async fn frame_cache_status(state: State<'_, AppState>) -> Result<Value,String> {
    let cache=Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || cache.status()).await.map_err(|e|e.to_string())?
}
#[tauri::command]
async fn frame_cache_configure(state: State<'_, AppState>, cap_bytes: u64) -> Result<(),String> {
    let cache=Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || cache.configure(cap_bytes)).await.map_err(|e|e.to_string())?
}
#[tauri::command]
async fn frame_cache_set_directory(state: State<'_, AppState>, folder: Option<PathBuf>) -> Result<(), String> {
    let cache = Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || cache.set_directory(folder)).await.map_err(|e| e.to_string())?
}
#[tauri::command]
async fn frame_cache_clear(state: State<'_, AppState>) -> Result<(),String> {
    let cache=Arc::clone(&state.frames);
    tauri::async_runtime::spawn_blocking(move || cache.clear()).await.map_err(|e|e.to_string())?
}

/// Small JSON documents the app keeps beside its sidecars (export recipes, a
/// folder's order). `name` is a bare file name inside `<app data>/<area>/`.
#[tauri::command]
fn store_read(app: AppHandle, area: String, name: String) -> Result<Option<Value>, String> {
    let p = store_path(&app, &area, &name)?;
    Ok(std::fs::read(&p).ok().and_then(|b| serde_json::from_slice(&b).ok()))
}

#[tauri::command]
fn store_write(app: AppHandle, state: State<'_, AppState>, area: String, name: String, value: Value) -> Result<(), String> {
    let _lease=state.workspace.enter()?;
    let p = store_path(&app, &area, &name)?;
    files::write_atomic(&p, &serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?)
}

#[tauri::command]
fn workspace_begin(state: State<'_,AppState>)->Result<u64,String>{state.workspace.begin()}
#[tauri::command]
fn workspace_end(state: State<'_,AppState>,token:u64)->Result<(),String>{state.workspace.end(token)}
#[tauri::command]
fn agent_changes(app:AppHandle)->Result<Value,String>{
    let root=app.path().app_data_dir().map_err(|e|e.to_string())?;
    Ok(std::fs::read(root.join("Agents/changed.json")).ok().filter(|b|b.len()<128*1024).and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null))
}

fn store_path(app: &AppHandle, area: &str, name: &str) -> Result<PathBuf, String> {
    let ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) && !s.starts_with('.');
    if !ok(area) || !ok(name) {
        return Err("bad store name".into());
    }
    Ok(app.path().app_data_dir().map_err(|e| e.to_string())?.join(area).join(name))
}

#[tauri::command]
fn path_exists(path: String) -> bool {
    PathBuf::from(path).exists()
}

/// Make an export folder (and its parents). Only absolute paths.
#[tauri::command]
fn ensure_dir(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !p.is_absolute() {
        return Err(format!("{path} is not absolute"));
    }
    std::fs::create_dir_all(&p).map_err(|e| format!("{path}: {e}"))
}

#[tauri::command]
fn take_launch_paths(state: State<'_, AppState>) -> Vec<String> {
    std::mem::take(&mut *state.launch_paths.lock().unwrap())
}

#[tauri::command]
fn app_paths(app: AppHandle, state: State<'_, AppState>) -> Value {
    let p = app.path();
    json!({
        "appData": p.app_data_dir().map(|d| d.display().to_string()).unwrap_or_default(),
        "sidecars": state.sidecars.dir.display().to_string(),
        "logs": app.try_state::<diagnostics::Diagnostics>().map(|d|d.directory.display().to_string()).unwrap_or_default(),
        "home": p.home_dir().map(|d| d.display().to_string()).unwrap_or_default(),
        "pictures": p.picture_dir().map(|d| d.display().to_string()).unwrap_or_default(),
        "os": std::env::consts::OS,
        "version": app.package_info().version.to_string(),
    })
}

fn file_args(argv: &[String]) -> Vec<String> {
    argv.iter()
        .skip(1)
        .filter(|a| !a.starts_with('-'))
        .filter(|a| PathBuf::from(a).exists())
        .cloned()
        .collect()
}

/// The command table, once; the self-test's three commands only where the self-test is compiled.
macro_rules! commands {
    ($($extra:path),*) => {
        tauri::generate_handler![
            host_request,
            host_request_upload,
            host_state,
            host_diagnostics,
            host_restart,
            scheduler_submit,
            scheduler_cancel,
            scheduler_cancel_frame,
            scheduler_outcome,
            scheduler_snapshot,
            scheduler_budget,
            scheduler_frontend_state,
            scheduler_memory_pressure,
            scheduler_editing_open,
            scheduler_editing_call,
            library_call,
            library_state,
            diagnostics::diagnostics_get,
            diagnostics::diagnostics_set,
            diagnostics::diagnostics_clear_logs,
            diagnostics::diagnostics_save_bundle,
            list_images,
            expand_paths,
            sidecar_load,
            sidecar_save,
            sidecar_path,
            sidecar_remove,
            pair_create,
            pair_load,
            pair_save,
            pair_list,
            pair_delete,
            frame_cache_key,
            frame_cache_read,
            frame_cache_write,
            frame_cache_status,
            frame_cache_configure,
            frame_cache_set_directory,
            frame_cache_clear,
            workspace_begin,
            workspace_end,
            agent_changes,
            agent_files::agent_access_get,
            agent_files::agent_access_set,
            agent_files::agent_rendering_set,
            agent_files::agent_cli_install,
            agent_files::agent_cli_uninstall,
            store_read,
            store_write,
            take_launch_paths,
            path_exists,
            ensure_dir,
            app_paths,
            $($extra),*
        ]
    };
}
#[cfg(any(debug_assertions, feature = "selftest"))]
macro_rules! handlers {
    () => { commands!(selftest::selftest_args, selftest::selftest_write, selftest::selftest_finish) };
}
#[cfg(not(any(debug_assertions, feature = "selftest")))]
macro_rules! handlers {
    () => { commands!() };
}

pub fn run() {
    let context = tauri::generate_context!();
    if std::env::args().nth(1).as_deref() == Some("--agent-files") {
        std::process::exit(agent_files::serve(&context.config().identifier));
    }
    let builder = tauri::Builder::default();

    // Single instance first, as the plugin requires: a second launch (a file
    // opened from the file manager) hands its paths to the running window.
    #[cfg(any(target_os = "linux", windows))]
    let builder = {
        builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let paths = file_args(&argv);
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
            if !paths.is_empty() {
                let _ = app.emit("open-paths", paths);
            }
        }))
    };

    builder
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .setup(|app| {
            let handle = app.handle().clone();
            diagnostics::initialize(&handle)?;
            let sidecar_dir = app.path().app_data_dir()?.join("Sidecars");
            let host = HostManager::new(handle.clone());
            let argv: Vec<String> = std::env::args().collect();
            let workspace = workspace::Workspace::new(app.path().app_data_dir()?);
            let logs = app.try_state::<diagnostics::Diagnostics>().map(|d| d.directory.clone()).unwrap_or(app.path().app_log_dir()?);
            let host_dir = host::resolve_launch(&handle).ok().filter(|l| !l.mock).and_then(|l| l.program.parent().map(PathBuf::from));
            app.manage::<Library>(Arc::new(library::LibraryState::resolve(host_dir.as_deref(), &handle)));
            let emitter = handle.clone();
            app.manage(scheduler::SchedulerHub::new(
                Arc::clone(&host),
                Some(Arc::clone(&workspace)),
                scheduler::SchedulerPaths { logs, data: app.path().app_data_dir()? },
                move |snapshot| { let _ = emitter.emit(scheduler::JOB_EVENT, snapshot); },
            ));
            app.manage(AppState {
                host: Arc::clone(&host),
                sidecars: files::SidecarStore { dir: sidecar_dir },
                launch_paths: Mutex::new(file_args(&argv)),
                frames: Arc::new(frame_cache::FrameCache::new(
                    app.path().app_cache_dir()?.join("Frames-v1"),
                    app.path().app_data_dir()?.join("display-cache.json"),
                )),
                cache_fingerprint: Arc::new(Mutex::new(None)),
                workspace,
            });
            log::info!("SpektraLab {} starting on {}", app.package_info().version, std::env::consts::OS);
            #[cfg(any(debug_assertions, feature = "selftest"))]
            if let Some(t) = selftest::SelfTest::from_args(&argv) {
                log::info!(target: "selftest", "self-test of {} into {}", t.raw.display(), t.out.display());
                app.manage(t);
                selftest::SelfTest::watchdog(handle.clone());
            }
            let wiring = handle.clone();
            tauri::async_runtime::spawn(async move {
                host.start().await;
                // Made inside the runtime once the host is up; a command made before then waits for it.
                if let Err(e) = wiring.state::<Hub>().wired().await { log::warn!(target: "scheduler", "{e}"); }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                if window.label() == "main" {
                    let host = Arc::clone(&window.state::<AppState>().host);
                    tauri::async_runtime::block_on(async move { host.shutdown().await });
                    window.state::<Library>().shutdown();
                    diagnostics::clean_exit(window.app_handle());
                }
            }
        })
        .invoke_handler(handlers!())
        .run(context)
        .expect("error while running SpektraLab");
}
