//! The library helper in the app (PRD-W2 R10, PRD-W0 §5.3): `spk_library::LibraryHost` behind the
//! Tauri commands `library_call(method, params)` and `library_state()`
//! (`desktop/crates/spk-library/README.md`, "Wiring it").
//!
//! The helper is resolved **beside the engine host**: `spklib-host.exe` next to `spektralab-host.exe`
//! in the Windows bundle (both are sidecars beside the app's executable), `spklib-host` beside a staged
//! host (`SPEKTRALAB_HOST_DIR`); on macOS, where nothing is bundled, a dev helper built from the spklib
//! clone in `build/spklib` (walked up to from the executable) or named by `SPKLIB_HOST`. The store is
//! under the app's local data directory on Windows, or `spk_library::default_store()` elsewhere.
//! `SPEKTRALAB_LIBRARY_STORE` overrides it for tests. Nothing starts until the first call.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{json, Value};
use spk_library::{Launch, LibraryHost};
use tauri::{AppHandle, Manager, Runtime};

pub fn helper_name() -> &'static str {
    if cfg!(windows) {
        "spklib-host.exe"
    } else {
        "spklib-host"
    }
}

/// Where the helper is, in order: `SPKLIB_HOST`; beside the engine host (`host_dir`: the bundled
/// sidecar's folder, or `SPEKTRALAB_HOST_DIR`); beside the app's executable; a checkout's
/// `build/spklib/build/spklib-host` above the executable (a dev build on the Mac). The second value
/// says how it was found.
pub fn resolve_helper(host_dir: Option<&Path>) -> Result<(PathBuf, &'static str), String> {
    if let Some(p) = std::env::var_os("SPKLIB_HOST").filter(|v| !v.is_empty()) {
        let p = PathBuf::from(p);
        return if p.is_file() { Ok((p, "SPKLIB_HOST")) } else { Err(format!("SPKLIB_HOST={} is not a file", p.display())) };
    }
    if let Some(dir) = host_dir {
        let p = dir.join(helper_name());
        if p.is_file() {
            return Ok((p, "beside the engine host"));
        }
    }
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    if let Some(dir) = &exe_dir {
        let p = dir.join(helper_name());
        if p.is_file() {
            return Ok((p, "beside the app"));
        }
        let mut cur = Some(dir.as_path());
        while let Some(d) = cur {
            let p = d.join("build").join("spklib").join("build").join(helper_name());
            if p.is_file() {
                return Ok((p, "checkout build/spklib"));
            }
            cur = d.parent();
        }
    }
    Err(format!("SpektraLab could not find its library helper ({}); folders and catalogs are unavailable", helper_name()))
}

fn resolve_store<R: Runtime>(app: &AppHandle<R>) -> Result<PathBuf, String> {
    if let Some(p) = std::env::var_os("SPEKTRALAB_LIBRARY_STORE").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(p));
    }
    if cfg!(windows) {
        return app.path().app_local_data_dir().map(|dir| dir.join("Libraries")).map_err(|err| err.to_string());
    }
    spk_library::default_store().ok_or_else(|| "no place for the library store (HOME unset)".to_string())
}

/// The app's one helper, or why there is none.
pub struct LibraryState {
    host: Result<Arc<LibraryHost>, String>,
    origin: &'static str,
}

impl LibraryState {
    /// Resolve the helper and the store (nothing is started).
    pub fn resolve<R: Runtime>(host_dir: Option<&Path>, app: &AppHandle<R>) -> Self {
        match resolve_helper(host_dir).and_then(|(exe, origin)| Ok((exe, origin, resolve_store(app)?))) {
            Ok((exe, origin, store)) => Self::with(exe, store, origin),
            Err(e) => {
                log::warn!(target: "library", "{e}");
                LibraryState { host: Err(e), origin: "absent" }
            }
        }
    }

    pub fn with(executable: PathBuf, store: PathBuf, origin: &'static str) -> Self {
        log::info!(target: "library", "helper {} ({origin}), store {}", executable.display(), store.display());
        let mut launch = Launch::new(executable, store);
        launch.log = Some(Arc::new(|line: &str| log::info!(target: "library", "{line}")));
        LibraryState { host: Ok(Arc::new(LibraryHost::new(launch))), origin }
    }

    /// `library_call`: any method of spklib's API-SPEC. Blocks: call it from `spawn_blocking`. The
    /// error is the helper's own error object (`{code, message, data}`).
    pub fn call(&self, method: &str, mut params: Value) -> Result<Value, Value> {
        let host = self.host.as_ref().map_err(|reason| json!({"code": "unavailable", "message": reason, "data": null}))?;
        let expected = if let Some(value) = params.get_mut("library") {
            let (launch, handle) = value.as_str().and_then(|token| token.split_once(':'))
                .and_then(|(launch, handle)| Some((launch.parse::<u64>().ok()?, handle)))
                .filter(|(_, handle)| !handle.is_empty())
                .ok_or_else(|| json!({"code": "invalid_params", "message": "expected a launch-scoped library handle", "data": null}))?;
            *value = Value::String(handle.to_owned());
            Some(launch)
        } else {
            None
        };
        let (launch, mut result) = host.call_on_launch(method, params, expected)
            .map_err(|e| serde_json::to_value(e).unwrap_or(Value::Null))?;
        if let Some(Value::String(handle)) = result.get_mut("library") {
            *handle = format!("{launch}:{handle}");
        }
        Ok(result)
    }

    /// `library_state`: the README's `{running, version, launches, store, executable}`, plus
    /// `origin` (how the helper was found) and, with no helper, `reason`.
    pub fn state(&self) -> Value {
        match &self.host {
            Ok(host) => json!({
                "running": host.is_running(),
                "version": host.version(),
                "launches": host.launches(),
                "store": host.launch().store.display().to_string(),
                "executable": host.launch().executable.display().to_string(),
                "origin": self.origin,
            }),
            Err(reason) => json!({"running": false, "version": null, "launches": 0, "store": null,
                                  "executable": null, "origin": self.origin, "reason": reason}),
        }
    }

    pub fn shutdown(&self) {
        if let Ok(host) = &self.host {
            host.shutdown();
        }
    }
}
