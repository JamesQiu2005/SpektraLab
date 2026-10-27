//! SpektraLab's Tauri core: the window, the engine host process, and the
//! narrow file commands the webview needs. Everything else — the interface,
//! the session, the menus — is the TypeScript app in `desktop/src`.

pub mod files;
pub mod framing;
pub mod host;
pub mod binary_transfer;

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
    transfers: Mutex<binary_transfer::Transfers>,
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

fn bridge_reply(reply: host::Reply, state: &AppState, chunked: bool) -> Result<Response, String> {
    match reply {
        Ok((header, payload)) if chunked && header["ok"] == json!(true) && payload.len() > binary_transfer::CHUNK_BYTES => {
            let length = payload.len();
            let id = state.transfers.lock().map_err(|e| e.to_string())?.download(payload)?;
            log::info!("IPC download {length} bytes in bounded chunks");
            Ok(Response::new(framing::encode(&json!({"ok":true,"result":header["result"],
                "tauri_download":{"id":id,"bytes":length}}), &[])))
        }
        reply => Ok(reply_bytes(reply)),
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
    chunked: Option<bool>,
) -> Result<Response, String> {
    let reply = state.host.request(&method, params, Vec::new(), timeout_of(timeout_ms)).await;
    bridge_reply(reply, &state, chunked.unwrap_or(false))
}

#[tauri::command]
fn binary_read(state: State<'_, AppState>, id: String, offset: usize) -> Result<Response, String> {
    Ok(Response::new(state.transfers.lock().map_err(|e| e.to_string())?.read(&id, offset)?))
}

#[tauri::command]
fn binary_drop(state: State<'_, AppState>, id: String) {
    if let Ok(mut pool) = state.transfers.lock() { pool.drop_id(&id); }
}

#[tauri::command]
fn host_upload_open(state: State<'_, AppState>, method: String, params: Value,
                    timeout_ms: Option<u64>, bytes: usize) -> Result<String, String> {
    state.transfers.lock().map_err(|e| e.to_string())?.upload(
        json!({"method":method,"params":params,"timeout_ms":timeout_ms}).to_string(), bytes)
}

#[tauri::command]
fn host_upload_chunk(state: State<'_, AppState>, request: Request<'_>) -> Result<(), String> {
    let InvokeBody::Raw(bytes) = request.body() else { return Err("upload chunk takes a raw body".into()); };
    let (header, payload) = framing::decode_one(bytes)?;
    let id = header["id"].as_str().ok_or("missing upload id")?;
    let offset = usize::try_from(header["offset"].as_u64().ok_or("missing upload offset")?).map_err(|e| e.to_string())?;
    state.transfers.lock().map_err(|e| e.to_string())?.append(id, offset, payload)
}

#[tauri::command]
async fn host_upload_finish(state: State<'_, AppState>, id: String) -> Result<Response, String> {
    let (metadata, payload) = state.transfers.lock().map_err(|e| e.to_string())?.finish(&id)?;
    let header: Value = serde_json::from_str(&metadata).map_err(|e| e.to_string())?;
    let method = header["method"].as_str().ok_or("missing upload method")?;
    log::info!("IPC upload {} bytes for {method}", payload.len());
    let reply = state.host.request(method, header["params"].clone(), payload,
        timeout_of(header["timeout_ms"].as_u64())).await;
    bridge_reply(reply, &state, true)
}

/// A request that carries a binary payload (an image to write). The body is a
/// frame: `{method, params, timeout_ms?}` + payload.
#[tauri::command]
async fn host_request_upload(state: State<'_, AppState>, request: Request<'_>) -> Result<Response, String> {
    let InvokeBody::Raw(bytes) = request.body() else {
        return Err("host_request_upload takes a raw body".into());
    };
    let (header, payload) = framing::decode_one(bytes)?;
    let method = header["method"].as_str().ok_or("missing method")?.to_string();
    let params = header.get("params").cloned().unwrap_or(json!({}));
    let timeout = timeout_of(header.get("timeout_ms").and_then(Value::as_u64));
    let reply = state.host.request(&method, params, payload.to_vec(), timeout).await;
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
    let host = Arc::clone(&state.host);
    tauri::async_runtime::spawn(async move { host.restart().await });
    Ok(())
}

#[tauri::command]
fn list_images(app:AppHandle,dir: String) -> Result<Vec<files::Entry>, String> {
    let folder=PathBuf::from(dir); let mut images=files::list_images(&folder)?;
    let stored=files::stored_pairs(&app.path().app_data_dir().map_err(|e|e.to_string())?.join("Pairs"),&folder);
    for p in stored { if !images.iter().any(|e|e.path==p.path) {images.push(p);} }
    Ok(images)
}

#[tauri::command]
fn pair_load(path:String)->Result<Value,String>{files::pair_load(&PathBuf::from(path))}
#[tauri::command]
fn pair_save(path:String,value:Value)->Result<(),String>{files::pair_save(&PathBuf::from(path),&value)}
#[tauri::command]
fn pair_create(app:AppHandle,folder:String,value:Value)->Result<files::Entry,String>{
    files::pair_create(&app.path().app_data_dir().map_err(|e|e.to_string())?.join("Pairs"),&PathBuf::from(folder),&value)
}

#[tauri::command]
fn expand_paths(paths: Vec<String>) -> Vec<files::Entry> {
    files::expand(&paths)
}

#[tauri::command]
fn sidecar_load(state: State<'_, AppState>, image: String) -> Option<Value> {
    state.sidecars.load(&PathBuf::from(image))
}

#[tauri::command]
fn sidecar_save(state: State<'_, AppState>, image: String, sidecar: Value) -> Result<String, String> {
    state.sidecars.save(&PathBuf::from(image), &sidecar).map(|p| p.display().to_string())
}

#[tauri::command]
fn sidecar_path(state: State<'_, AppState>, image: String) -> String {
    state.sidecars.path_for(&PathBuf::from(image)).display().to_string()
}

#[tauri::command]
fn sidecar_remove(state: State<'_, AppState>, image: String) -> Result<(), String> {
    state.sidecars.remove(&PathBuf::from(image))
}

/// Small JSON documents the app keeps beside its sidecars (export recipes, a
/// folder's order). `name` is a bare file name inside `<app data>/<area>/`.
#[tauri::command]
fn store_read(app: AppHandle, area: String, name: String) -> Result<Option<Value>, String> {
    let p = store_path(&app, &area, &name)?;
    Ok(std::fs::read(&p).ok().and_then(|b| serde_json::from_slice(&b).ok()))
}

#[tauri::command]
fn store_write(app: AppHandle, area: String, name: String, value: Value) -> Result<(), String> {
    let p = store_path(&app, &area, &name)?;
    files::write_atomic(&p, &serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?)
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
        "logs": p.app_log_dir().map(|d| d.display().to_string()).unwrap_or_default(),
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
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::LogDir {
                        file_name: Some("spektralab".into()),
                    }),
                ])
                .max_file_size(4 * 1024 * 1024)
                .rotation_strategy(tauri_plugin_log::RotationStrategy::KeepSome(5))
                .level(log::LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .setup(|app| {
            let handle = app.handle().clone();
            let sidecar_dir = app.path().app_data_dir()?.join("Sidecars");
            let host = HostManager::new(handle.clone());
            let argv: Vec<String> = std::env::args().collect();
            app.manage(AppState {
                host: Arc::clone(&host),
                sidecars: files::SidecarStore { dir: sidecar_dir },
                launch_paths: Mutex::new(file_args(&argv)),
                transfers: Mutex::new(binary_transfer::Transfers::default()),
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
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            host_request,
            host_request_upload,
            binary_read,
            binary_drop,
            host_upload_open,
            host_upload_chunk,
            host_upload_finish,
            host_state,
            host_diagnostics,
            host_restart,
            list_images,
            pair_load,
            pair_save,
            pair_create,
            expand_paths,
            sidecar_load,
            sidecar_save,
            sidecar_path,
            sidecar_remove,
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
