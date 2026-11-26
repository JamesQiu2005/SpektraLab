//! SpektraLab's Tauri core: the window, the engine host process, and the
//! narrow file commands the webview needs. Everything else — the interface,
//! the session, the menus — is the TypeScript app in `desktop/src`.

pub mod files;
pub mod framing;
pub mod host;
pub mod no_network;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::ipc::{InvokeBody, Request, Response};
use tauri::{AppHandle, Manager, State};
#[cfg(any(target_os = "linux", windows))]
use tauri::Emitter;

use host::HostManager;

struct AppState {
    host: Arc<HostManager>,
    sidecars: files::SidecarStore,
    /// Paths from the command line (open-with) not yet taken by the webview.
    launch_paths: Mutex<Vec<String>>,
    /// Payloads being sent in parts (`upload_part`), by upload id.
    uploads: Mutex<HashMap<String, Vec<u8>>>,
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
    let reply = state.host.request(&method, params, Vec::new(), timeout_of(timeout_ms)).await;
    Ok(reply_bytes(reply))
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

/// One part of a payload, base64. Android's WebView cannot hand a request body to the app, so Tauri sends
/// everything there as JSON, and a whole image (a Uint8Array becomes an array of numbers) runs the WebView out
/// of memory. The app sends it in parts instead (src/host/tauriTransport.ts), then `host_request_uploaded`.
/// The part at offset 0 starts the upload afresh.
#[tauri::command]
fn upload_part(state: State<'_, AppState>, id: String, offset: usize, data: String) -> Result<(), String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD.decode(data.as_bytes()).map_err(|e| e.to_string())?;
    let mut uploads = state.uploads.lock().unwrap();
    if offset == 0 {
        uploads.insert(id.clone(), Vec::new());
    }
    let buf = uploads.get_mut(&id).ok_or("upload not started")?;
    let have = buf.len();
    if have != offset {
        uploads.remove(&id);
        return Err(format!("upload part at byte {offset}, expected {have}"));
    }
    buf.extend_from_slice(&bytes);
    Ok(())
}

/// Forget an upload that will not be sent (a part failed).
#[tauri::command]
fn upload_discard(state: State<'_, AppState>, id: String) {
    state.uploads.lock().unwrap().remove(&id);
}

/// `host_request_upload` for a payload sent in parts.
#[tauri::command]
async fn host_request_uploaded(
    state: State<'_, AppState>,
    id: String,
    method: String,
    params: Value,
    timeout_ms: Option<u64>,
) -> Result<Response, String> {
    let payload = state.uploads.lock().unwrap().remove(&id).ok_or("upload not found")?;
    let reply = state.host.request(&method, params, payload, timeout_of(timeout_ms)).await;
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
fn list_images(dir: String) -> Result<Vec<files::Entry>, String> {
    files::list_images(&PathBuf::from(dir))
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

/// "Original + edits": a copy of the photograph with its edits beside it (files.rs `export_original`).
/// Returns the files written, the photograph first.
#[tauri::command]
fn export_original(
    state: State<'_, AppState>,
    image: String,
    dir: String,
    name: String,
    overwrite: bool,
) -> Result<Vec<String>, String> {
    let dir = PathBuf::from(dir);
    if !dir.is_absolute() {
        return Err(format!("{} is not absolute", dir.display()));
    }
    files::export_original(&state.sidecars, &PathBuf::from(image), &dir, &name, overwrite)
        .map(|v| v.iter().map(|p| p.display().to_string()).collect())
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

/// Android's Import: the app's own Kotlin plugin (gen/android/.../PhotoImportPlugin.kt) opens Android's
/// picker and copies the chosen photographs into app storage, so the rest of the app gets real paths.
#[cfg(target_os = "android")]
mod android_import {
    pub struct Importer(pub tauri::plugin::PluginHandle<tauri::Wry>);

    pub fn init() -> tauri::plugin::TauriPlugin<tauri::Wry> {
        tauri::plugin::Builder::new("photo-import")
            .setup(|app, api| {
                use tauri::Manager;
                let handle = api.register_android_plugin("io.github.jegly.develop", "PhotoImportPlugin")?;
                app.manage(Importer(handle));
                Ok(())
            })
            .build()
    }
}

/// The photographs the user picked, as paths (empty if they cancelled). Android only: the desktop picks
/// files with the dialog plugin.
#[tauri::command]
async fn pick_photos(app: AppHandle) -> Result<Vec<String>, String> {
    #[cfg(target_os = "android")]
    {
        #[derive(serde::Deserialize)]
        struct Picked {
            paths: Vec<String>,
        }
        let importer = app.state::<android_import::Importer>();
        let picked: Picked = importer.0.run_mobile_plugin_async("pickPhotos", ()).await.map_err(|e| e.to_string())?;
        Ok(picked.paths)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = app;
        Err("pick_photos is for Android".into())
    }
}

/// Android's shared storage (gen/android/.../SharedStoragePlugin.kt): exports go to Pictures/Develop
/// (Download/Develop for a .cube) through MediaStore, which needs no permission for the app's own files.
#[cfg(target_os = "android")]
mod android_shared {
    pub struct Saver(pub tauri::plugin::PluginHandle<tauri::Wry>);

    pub fn init() -> tauri::plugin::TauriPlugin<tauri::Wry> {
        tauri::plugin::Builder::new("shared-storage")
            .setup(|app, api| {
                use tauri::Manager;
                let handle = api.register_android_plugin("io.github.jegly.develop", "SharedStoragePlugin")?;
                app.manage(Saver(handle));
                Ok(())
            })
            .build()
    }
}

/// Whether the app already saved `name` in shared folder `dir` (e.g. "Pictures/Develop"). Android only.
#[tauri::command]
async fn shared_exists(app: AppHandle, dir: String, name: String) -> Result<bool, String> {
    #[cfg(target_os = "android")]
    {
        #[derive(serde::Deserialize)]
        struct Found {
            exists: bool,
        }
        let saver = app.state::<android_shared::Saver>();
        let r: Found = saver
            .0
            .run_mobile_plugin_async("exists", json!({"dir": dir, "name": name}))
            .await
            .map_err(|e| e.to_string())?;
        Ok(r.exists)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, dir, name);
        Err("shared_exists is for Android".into())
    }
}

/// Moves the written file at `path` into shared folder `dir` as `name` and returns where it landed
/// ("Pictures/Develop/<name as Android stored it>"). Android only.
#[tauri::command]
async fn shared_publish(
    app: AppHandle,
    path: String,
    dir: String,
    name: String,
    mime: String,
    overwrite: bool,
) -> Result<String, String> {
    #[cfg(target_os = "android")]
    {
        #[derive(serde::Deserialize)]
        struct Saved {
            location: String,
        }
        let saver = app.state::<android_shared::Saver>();
        let r: Saved = saver
            .0
            .run_mobile_plugin_async(
                "publish",
                json!({"path": path, "dir": dir, "name": name, "mime": mime, "overwrite": overwrite}),
            )
            .await
            .map_err(|e| e.to_string())?;
        Ok(r.location)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (app, path, dir, name, mime, overwrite);
        Err("shared_publish is for Android".into())
    }
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
        // Android: where Import keeps the photographs (PhotoImportPlugin.kt: files/Photos, beside files/engine).
        "photos": android_photos_dir(),
        // Android: where exports are written before they go to Pictures/Develop (SharedStoragePlugin.kt).
        "exporting": android_files_dir().map(|d| d.join("Exporting").display().to_string()),
        "version": app.package_info().version.to_string(),
    })
}

fn android_photos_dir() -> Option<String> {
    android_files_dir().map(|d| d.join("Photos").display().to_string())
}

/// Android: the app's files folder (MainActivity puts the engine in files/engine).
fn android_files_dir() -> Option<PathBuf> {
    #[cfg(target_os = "android")]
    {
        let engine = std::env::var("DEVELOP_ANDROID_ENGINE").ok()?;
        Some(PathBuf::from(engine).parent()?.to_path_buf())
    }
    #[cfg(not(target_os = "android"))]
    {
        None
    }
}

/// The app's own origin: `tauri://localhost` on Linux, `http(s)://tauri.localhost` on Windows, and
/// the Vite dev server in a debug build. Everything else is another site.
fn navigation_allowed(url: &tauri::Url) -> bool {
    match url.scheme() {
        "tauri" => url.host_str() == Some("localhost"),
        "http" | "https" => {
            let host = url.host_str();
            host == Some("tauri.localhost")
                || (cfg!(debug_assertions) && host == Some("127.0.0.1") && url.port() == Some(5173))
        }
        _ => false,
    }
}

fn file_args(argv: &[String]) -> Vec<String> {
    argv.iter()
        .skip(1)
        .filter(|a| !a.starts_with('-'))
        .filter(|a| PathBuf::from(a).exists())
        .cloned()
        .collect()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
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

    builder = builder
        .plugin(
            tauri_plugin_log::Builder::new()
                .targets([
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::Stdout),
                    tauri_plugin_log::Target::new(tauri_plugin_log::TargetKind::LogDir {
                        file_name: Some("develop".into()),
                    }),
                ])
                .max_file_size(4 * 1024 * 1024)
                .rotation_strategy(tauri_plugin_log::RotationStrategy::KeepSome(5))
                .level(log::LevelFilter::Info)
                .build(),
        )
        // The window shows the app's own bundled pages and nothing else: any navigation to another
        // origin is refused (no_network.rs keeps the processes off the network; this keeps the
        // webview from even trying).
        .plugin(
            tauri::plugin::Builder::<tauri::Wry>::new("no-navigation")
                .on_navigation(|_webview, url| {
                    let ok = navigation_allowed(url);
                    if !ok {
                        log::warn!("refused navigation to {url}");
                    }
                    ok
                })
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init());
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_window_state::Builder::default().build());
    }
    #[cfg(target_os = "android")]
    {
        builder = builder.plugin(android_import::init()).plugin(android_shared::init());
    }
    builder
        .setup(|app| {
            let handle = app.handle().clone();
            let sidecar_dir = app.path().app_data_dir()?.join("Sidecars");
            let host = HostManager::new(handle.clone());
            let argv: Vec<String> = std::env::args().collect();
            app.manage(AppState {
                host: Arc::clone(&host),
                sidecars: files::SidecarStore { dir: sidecar_dir },
                launch_paths: Mutex::new(file_args(&argv)),
                uploads: Mutex::new(HashMap::new()),
            });
            log::info!("Develop {} starting on {}", app.package_info().version, std::env::consts::OS);
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
            upload_part,
            upload_discard,
            host_request_uploaded,
            host_state,
            host_diagnostics,
            host_restart,
            list_images,
            expand_paths,
            sidecar_load,
            sidecar_save,
            sidecar_path,
            export_original,
            sidecar_remove,
            store_read,
            store_write,
            take_launch_paths,
            pick_photos,
            shared_exists,
            shared_publish,
            path_exists,
            ensure_dir,
            app_paths,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Develop");
}
