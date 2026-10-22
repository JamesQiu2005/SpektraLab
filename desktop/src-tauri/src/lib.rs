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

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::{AppHandle, Emitter, Manager, State};

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

pub fn run() {
    let mut builder = tauri::Builder::default();

    // Single instance first, as the plugin requires: a second launch (a file
    // opened from the file manager) hands its paths to the running window.
    #[cfg(any(target_os = "linux", windows))]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            let paths = file_args(&argv);
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
            if !paths.is_empty() {
                let _ = app.emit("open-paths", paths);
            }
        }));
    }

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
            app.manage(AppState {
                host: Arc::clone(&host),
                sidecars: files::SidecarStore { dir: sidecar_dir },
                launch_paths: Mutex::new(file_args(&argv)),
                frames: Arc::new(frame_cache::FrameCache { dir: app.path().app_cache_dir()?.join("Frames-v1") }),
                cache_fingerprint: Arc::new(Mutex::new(None)),
                workspace: workspace::Workspace::new(app.path().app_data_dir()?),
            });
            log::info!("SpektraLab {} starting on {}", app.package_info().version, std::env::consts::OS);
            tauri::async_runtime::spawn(async move { host.start().await });
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Destroyed = event {
                if window.label() == "main" {
                    let host = Arc::clone(&window.state::<AppState>().host);
                    tauri::async_runtime::block_on(async move { host.shutdown().await });
                    diagnostics::clean_exit(window.app_handle());
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            host_request,
            host_request_upload,
            host_state,
            host_diagnostics,
            host_restart,
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running SpektraLab");
}
