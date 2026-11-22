//! T5b's self-test mode (PRD-W2 T5, phase 2): the real app, on this Mac, drives itself.
//!
//! Compiled only in a debug build or with the `selftest` feature, never in a release package
//! (`lib.rs` registers these commands only under the same `cfg`). Started with
//! `--selftest <raw> <outdir>` (or `SPEKTRALAB_SELFTEST=<raw>|<outdir>`). The webview's driver
//! (`src/app/selftest.ts`) asks `selftest_args`, opens the RAW, waits for the scheduler to report it
//! developed, writes the canvas as a PNG and the status line and job snapshots as JSON through
//! `selftest_write`, runs one export, and ends with `selftest_finish(code, reason)`: the app writes
//! `<outdir>/selftest-result.json` and exits with that code. A watchdog ends a run that never
//! finishes (`SPEKTRALAB_SELFTEST_TIMEOUT` seconds, default 300) with exit code 3: a timeout is a
//! failure with its reason, not a hang.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Manager, Runtime, State};

pub struct SelfTest {
    pub raw: PathBuf,
    pub out: PathBuf,
    started: Instant,
}

impl SelfTest {
    pub fn from_args(argv: &[String]) -> Option<SelfTest> {
        let (raw, out) = if let Some(i) = argv.iter().position(|a| a == "--selftest") {
            (argv.get(i + 1)?.clone(), argv.get(i + 2)?.clone())
        } else {
            let v = std::env::var("SPEKTRALAB_SELFTEST").ok()?;
            let (raw, out) = v.split_once('|')?;
            (raw.to_string(), out.to_string())
        };
        Some(SelfTest { raw: PathBuf::from(raw), out: PathBuf::from(out), started: Instant::now() })
    }

    fn write_result(&self, code: i32, reason: &str) {
        let _ = std::fs::create_dir_all(&self.out);
        let result = json!({"code": code, "ok": code == 0, "reason": reason,
                            "raw": self.raw.display().to_string(), "seconds": self.started.elapsed().as_secs_f64()});
        let _ = std::fs::write(self.out.join("selftest-result.json"), serde_json::to_vec_pretty(&result).unwrap());
        if code == 0 {
            log::info!(target: "selftest", "passed");
        } else {
            log::error!(target: "selftest", "FAILED ({code}): {reason}");
            eprintln!("selftest FAILED ({code}): {reason}");
        }
    }

    /// End a run that never reports: exit 3 with the reason.
    pub fn watchdog<R: Runtime>(app: AppHandle<R>) {
        let timeout = std::env::var("SPEKTRALAB_SELFTEST_TIMEOUT").ok().and_then(|v| v.parse().ok()).unwrap_or(300u64);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(timeout));
            if let Some(t) = app.try_state::<SelfTest>() {
                t.write_result(3, &format!("timed out after {timeout} s: the self-test never finished"));
            }
            app.exit(3);
        });
    }
}

fn safe_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) && !name.starts_with('.')
}

#[tauri::command]
pub fn selftest_args(t: State<'_, SelfTest>) -> Value {
    // The Library part, where the gate gives one: a folder to link and a Capture One catalog to read.
    let var = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    json!({"raw": t.raw.display().to_string(), "out": t.out.display().to_string(),
           "folder": var("SPEKTRALAB_SELFTEST_FOLDER"), "captureOne": var("SPEKTRALAB_SELFTEST_C1"),
           "captureOneRelink": var("SPEKTRALAB_SELFTEST_C1_RELINK"),
           "captureOneVerbatim": var("SPEKTRALAB_SELFTEST_C1_VERBATIM").as_deref() == Some("1"),
           "exerciseLibraryPreviews": var("SPEKTRALAB_SELFTEST_LIBRARY_PREVIEWS").as_deref() == Some("1"),
           "exerciseLibraryRestart": var("SPEKTRALAB_SELFTEST_LIBRARY_RESTART").as_deref() == Some("1"),
           "exerciseBatch": var("SPEKTRALAB_SELFTEST_BATCH").as_deref() == Some("1")})
}

/// A file of the run, the body as its bytes; the name in the `x-selftest-name` header.
#[tauri::command]
pub fn selftest_write(t: State<'_, SelfTest>, request: Request<'_>) -> Result<String, String> {
    let name = request.headers().get("x-selftest-name").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
    if !safe_name(&name) {
        return Err(format!("bad self-test file name {name:?}"));
    }
    let InvokeBody::Raw(bytes) = request.body() else { return Err("selftest_write takes a raw body".into()) };
    std::fs::create_dir_all(&t.out).map_err(|e| e.to_string())?;
    let path: PathBuf = Path::new(&t.out).join(&name);
    std::fs::write(&path, bytes).map_err(|e| format!("{}: {e}", path.display()))?;
    log::info!(target: "selftest", "wrote {} ({} bytes)", path.display(), bytes.len());
    Ok(path.display().to_string())
}

#[tauri::command]
pub fn selftest_finish(app: AppHandle, t: State<'_, SelfTest>, code: i32, reason: String) {
    t.write_result(code, &reason);
    app.exit(code);
}
