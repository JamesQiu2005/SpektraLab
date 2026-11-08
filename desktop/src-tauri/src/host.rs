//! The engine host as a child process (HOST-PROTOCOL.md).
//!
//! One `spektralab-host` per app. The core owns its lifetime: it spawns it,
//! says `hello`, relays requests from the webview with a request-id map, turns
//! unsolicited frames into Tauri events, and restarts it when it dies — a GPU
//! driver fault takes down the host, not the window holding the user's edits.
//!
//! Pixels never pass through JSON. A reply goes back to the webview as one
//! binary `tauri::ipc::Response` in the protocol's own framing (header JSON +
//! payload), which `src/shared/framing.ts` splits on the other side.
//!
//! The state the webview sees is a small JSON value (`HostState` in
//! `src/shared/protocol.ts`): `starting`, `ready` (with the `hello` reply),
//! `restarting`, or `failed` (with the reason and the tail of the host's
//! stderr, which is where "no Vulkan device" shows up).

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use std::future::Future;
use std::pin::Pin;

use tauri::{AppHandle, Emitter, Manager, Runtime, Wry};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, watch};

use crate::framing;

/// How many restarts inside `RESTART_WINDOW` before the core gives up and
/// shows the failure instead of looping on a host that cannot start.
const MAX_RESTARTS: usize = 3;
const RESTART_WINDOW: Duration = Duration::from_secs(120);
const HELLO_TIMEOUT: Duration = Duration::from_secs(45);
const STDERR_TAIL: usize = 80;

/// A reply as the core hands it on: the full response header and the payload.
pub type Reply = Result<(Value, Vec<u8>), HostError>;

#[derive(Debug, Clone)]
pub struct HostError {
    pub code: String,
    pub message: String,
}

impl HostError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }
    pub fn to_header(&self) -> Value {
        json!({"ok": false, "error": {"code": self.code, "message": self.message}})
    }
}

/// What to launch, and how it was found (shown in diagnostics).
#[derive(Debug, Clone)]
pub struct Launch {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub mock: bool,
    pub origin: String,
}

struct Conn {
    stdin: ChildStdin,
}

pub struct HostManager {
    app: AppHandle<Wry>,
    conn: tokio::sync::Mutex<Option<Conn>>,
    pending: Mutex<HashMap<u32, oneshot::Sender<Reply>>>,
    next_id: AtomicU32,
    generation: AtomicU64,
    shutting_down: AtomicBool,
    stderr_tail: Mutex<VecDeque<String>>,
    restarts: Mutex<Vec<Instant>>,
    state_tx: watch::Sender<Value>,
    launch: Mutex<Option<Launch>>,
}

impl HostManager {
    pub fn new(app: AppHandle<Wry>) -> Arc<Self> {
        let (state_tx, _) = watch::channel(json!({"phase": "starting"}));
        Arc::new(Self {
            app,
            conn: tokio::sync::Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_id: AtomicU32::new(1),
            generation: AtomicU64::new(0),
            shutting_down: AtomicBool::new(false),
            stderr_tail: Mutex::new(VecDeque::new()),
            restarts: Mutex::new(Vec::new()),
            state_tx,
            launch: Mutex::new(None),
        })
    }

    pub fn state(&self) -> Value {
        self.state_tx.borrow().clone()
    }

    fn set_state(&self, v: Value) {
        log::info!(target: "host", "state -> {}", v["phase"]);
        self.state_tx.send_replace(v.clone());
        let _ = self.app.emit("host-state", v);
    }

    pub fn diagnostics(&self) -> Value {
        let launch = self.launch.lock().unwrap().clone();
        json!({
            "state": self.state(),
            "launch": launch.map(|l| json!({
                "program": l.program.display().to_string(),
                "args": l.args,
                "mock": l.mock,
                "origin": l.origin,
            })),
            "stderr_tail": self.stderr_tail.lock().unwrap().iter().cloned().collect::<Vec<_>>(),
        })
    }

    /// Spawn the host and say hello. Errors land in the state, not the caller.
    /// Boxed: the exit watcher restarts through here, and a boxed future is
    /// what breaks the start → watcher → start type cycle.
    pub fn start(self: &Arc<Self>) -> Pin<Box<dyn Future<Output = ()> + Send + 'static>> {
        let me = Arc::clone(self);
        Box::pin(async move { me.start_inner().await })
    }

    async fn start_inner(self: &Arc<Self>) {
        let launch = match resolve_launch(&self.app) {
            Ok(l) => l,
            Err(reason) => {
                self.set_state(json!({"phase": "failed", "reason": reason, "detail": ""}));
                return;
            }
        };
        log::info!(target: "host", "launching {:?} {:?} ({})", launch.program, launch.args, launch.origin);
        *self.launch.lock().unwrap() = Some(launch.clone());

        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let mut cmd = Command::new(&launch.program);
        cmd.args(&launch.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        #[cfg(windows)]
        {
            // CREATE_NO_WINDOW: the host is a console program; without this a
            // console window flashes up beside the app on every start.
            cmd.creation_flags(0x0800_0000);
        }
        let mut child: Child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                self.set_state(json!({
                    "phase": "failed",
                    "reason": format!("could not start the engine host: {e}"),
                    "detail": launch.program.display().to_string(),
                }));
                return;
            }
        };
        let stdin = child.stdin.take().expect("piped stdin");
        let mut stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        *self.conn.lock().await = Some(Conn { stdin });

        // stderr: a free-form log, one line per entry. Kept as a tail for the
        // failure dialog.
        {
            let me = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    log::info!(target: "host", "{line}");
                    let mut tail = me.stderr_tail.lock().unwrap();
                    if tail.len() >= STDERR_TAIL {
                        tail.pop_front();
                    }
                    tail.push_back(line);
                }
            });
        }

        // stdout: frames. A response settles its waiter; an event is emitted.
        {
            let me = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                loop {
                    match framing::read_frame(&mut stdout).await {
                        Ok(Some((header, payload))) => me.dispatch(header, payload),
                        Ok(None) => break,
                        Err(e) => {
                            log::error!(target: "host", "protocol error reading the host: {e}");
                            break;
                        }
                    }
                }
            });
        }

        // The exit watcher owns the child.
        {
            let me = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                let status = child.wait().await;
                me.on_exit(generation, status.map(|s| s.to_string()).unwrap_or_else(|e| e.to_string()))
                    .await;
            });
        }

        // hello
        match self.request_inner("hello", json!({}), Vec::new(), HELLO_TIMEOUT).await {
            Ok((header, _)) if header["ok"] == json!(true) => {
                let mut hello = header["result"].clone();
                if launch.mock {
                    hello["mock"] = json!(true);
                }
                self.set_state(json!({"phase": "ready", "hello": hello}));
            }
            Ok((header, _)) => {
                let msg = header["error"]["message"].as_str().unwrap_or("hello refused").to_string();
                self.fail_and_kill(format!("the engine host refused to start: {msg}")).await;
            }
            Err(e) => {
                // The exit watcher may already have reported the death.
                if self.generation.load(Ordering::SeqCst) == generation
                    && self.state()["phase"] != json!("failed")
                {
                    self.fail_and_kill(format!("the engine host did not answer: {}", e.message)).await;
                }
            }
        }
    }

    async fn fail_and_kill(self: &Arc<Self>, reason: String) {
        let detail = self.stderr_tail.lock().unwrap().iter().cloned().collect::<Vec<_>>().join("\n");
        // Bump the generation first so the exit watcher does not restart it.
        self.generation.fetch_add(1, Ordering::SeqCst);
        *self.conn.lock().await = None; // closing stdin ends a well-behaved host
        self.fail_pending("host_exited", &reason);
        self.set_state(json!({"phase": "failed", "reason": reason, "detail": detail}));
    }

    fn dispatch(&self, header: Value, payload: Vec<u8>) {
        if let Some(id) = header.get("id").and_then(Value::as_u64) {
            let waiter = self.pending.lock().unwrap().remove(&(id as u32));
            match waiter {
                Some(tx) => {
                    let _ = tx.send(Ok((header, payload)));
                }
                None => log::warn!(target: "host", "reply for unknown request {id}"),
            }
        } else if let Some(ev) = header.get("event").and_then(Value::as_str) {
            if ev == "log" {
                let msg = header["message"].as_str().unwrap_or("");
                match header["level"].as_str().unwrap_or("info") {
                    "error" => log::error!(target: "host", "{msg}"),
                    "warn" | "warning" => log::warn!(target: "host", "{msg}"),
                    _ => log::info!(target: "host", "{msg}"),
                }
            }
            let _ = self.app.emit("host-event", header);
        } else {
            log::warn!(target: "host", "frame with neither id nor event");
        }
    }

    fn fail_pending(&self, code: &str, message: &str) {
        let drained: Vec<_> = self.pending.lock().unwrap().drain().collect();
        for (_, tx) in drained {
            let _ = tx.send(Err(HostError::new(code, message)));
        }
    }

    async fn on_exit(self: &Arc<Self>, generation: u64, status: String) {
        if self.generation.load(Ordering::SeqCst) != generation {
            return; // superseded (restart or fail_and_kill)
        }
        *self.conn.lock().await = None;
        let reason = format!("the engine host exited ({status})");
        log::warn!(target: "host", "{reason}");
        self.fail_pending("host_exited", &reason);
        if self.shutting_down.load(Ordering::SeqCst) {
            return;
        }
        let attempt = {
            let mut r = self.restarts.lock().unwrap();
            let now = Instant::now();
            r.retain(|t| now.duration_since(*t) < RESTART_WINDOW);
            r.push(now);
            r.len()
        };
        if attempt > MAX_RESTARTS {
            let detail = self.stderr_tail.lock().unwrap().iter().cloned().collect::<Vec<_>>().join("\n");
            self.set_state(json!({
                "phase": "failed",
                "reason": format!("{reason}; it was restarted {MAX_RESTARTS} times and keeps failing"),
                "detail": detail,
            }));
            return;
        }
        self.set_state(json!({"phase": "restarting", "reason": reason, "attempt": attempt}));
        tokio::time::sleep(Duration::from_millis(400 * attempt as u64)).await;
        self.start().await;
    }

    /// Restart on request (menu: Restart Render Service). Resets the budget.
    pub async fn restart(self: &Arc<Self>) {
        self.restarts.lock().unwrap().clear();
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Some(mut c) = self.conn.lock().await.take() {
            let _ = c.stdin.shutdown().await;
        }
        self.fail_pending("host_exited", "the engine host was restarted");
        self.set_state(json!({"phase": "restarting", "reason": "restart requested", "attempt": 0}));
        self.start().await;
    }

    pub async fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        let _ = tokio::time::timeout(
            Duration::from_secs(2),
            self.request_inner("shutdown", json!({}), Vec::new(), Duration::from_secs(2)),
        )
        .await;
        *self.conn.lock().await = None;
    }

    /// A request from the webview: waits for the host to be ready first, so a
    /// call made during a restart lands on the new host instead of failing.
    pub async fn request(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration) -> Reply {
        let mut rx = self.state_tx.subscribe();
        let ready = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let phase = rx.borrow().get("phase").and_then(Value::as_str).unwrap_or("").to_string();
                match phase.as_str() {
                    "ready" => return Ok(()),
                    "failed" => return Err(HostError::new("not_running", "the engine host is not running")),
                    _ => {}
                }
                if rx.changed().await.is_err() {
                    return Err(HostError::new("not_running", "the engine host is gone"));
                }
            }
        })
        .await
        .unwrap_or_else(|_| Err(HostError::new("timeout", "the engine host did not become ready")));
        ready?;
        self.request_inner(method, params, payload, timeout).await
    }

    async fn request_inner(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration) -> Reply {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let frame = framing::encode(&json!({"id": id, "method": method, "params": params}), &payload);
        {
            let mut guard = self.conn.lock().await;
            let Some(conn) = guard.as_mut() else {
                self.pending.lock().unwrap().remove(&id);
                return Err(HostError::new("not_running", "the engine host is not running"));
            };
            if let Err(e) = conn.stdin.write_all(&frame).await {
                self.pending.lock().unwrap().remove(&id);
                return Err(HostError::new("host_exited", format!("writing to the engine host failed: {e}")));
            }
            let _ = conn.stdin.flush().await;
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(reply)) => reply,
            Ok(Err(_)) => Err(HostError::new("host_exited", "the engine host went away")),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                Err(HostError::new("timeout", format!("{method} took longer than {} s", timeout.as_secs())))
            }
        }
    }
}

fn exe_name() -> &'static str {
    if cfg!(windows) {
        "spektralab-host.exe"
    } else {
        "spektralab-host"
    }
}

fn platform_dir() -> &'static str {
    if cfg!(windows) {
        "host-win-x64"
    } else {
        "host-linux-x64"
    }
}

fn launch_in_dir(dir: &Path, origin: &str) -> Option<Launch> {
    let program = dir.join(exe_name());
    if !program.is_file() {
        return None;
    }
    let resources = dir.join("engine");
    let mut args = vec!["--resources".to_string(), resources.display().to_string()];
    if let Ok(device) = std::env::var("SPEKTRALAB_HOST_DEVICE") {
        args.push("--device".into());
        args.push(device);
    }
    Some(Launch { program, args, mock: false, origin: origin.into() })
}

/// Where the host is, in order:
///
/// 1. `SPEKTRALAB_MOCK_HOST=1` — the TypeScript mock (`desktop/mock-host`),
///    run with `node`; `SPEKTRALAB_MOCK_HOST_SCRIPT` overrides the script.
/// 2. `SPEKTRALAB_HOST_DIR` — a staged host directory (development).
/// 3. The bundled sidecar: `spektralab-host[.exe]` beside the app's own
///    executable (Tauri `externalBin`), resources at `<resource_dir>/host/engine`.
/// 4. A checkout's `build/host-<os>-x64/` above the executable (a dev build).
pub fn resolve_launch<R: Runtime>(app: &AppHandle<R>) -> Result<Launch, String> {
    if std::env::var("SPEKTRALAB_MOCK_HOST").map(|v| v == "1").unwrap_or(false) {
        let script = std::env::var("SPEKTRALAB_MOCK_HOST_SCRIPT").map(PathBuf::from).unwrap_or_else(|_| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("mock-host").join("main.ts")
        });
        let node = std::env::var("SPEKTRALAB_NODE").unwrap_or_else(|_| "node".into());
        return Ok(Launch {
            program: PathBuf::from(node),
            args: vec![script.display().to_string()],
            mock: true,
            origin: "SPEKTRALAB_MOCK_HOST".into(),
        });
    }
    if let Ok(dir) = std::env::var("SPEKTRALAB_HOST_DIR") {
        return launch_in_dir(Path::new(&dir), "SPEKTRALAB_HOST_DIR")
            .ok_or_else(|| format!("SPEKTRALAB_HOST_DIR={dir} has no {}", exe_name()));
    }
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    if let Some(dir) = &exe_dir {
        let program = dir.join(exe_name());
        if program.is_file() {
            let resources = app
                .path()
                .resource_dir()
                .map(|r| r.join("host").join("engine"))
                .unwrap_or_else(|_| dir.join("engine"));
            let mut args = vec!["--resources".to_string(), resources.display().to_string()];
            if let Ok(device) = std::env::var("SPEKTRALAB_HOST_DEVICE") {
                args.push("--device".into());
                args.push(device);
            }
            return Ok(Launch { program, args, mock: false, origin: "bundled sidecar".into() });
        }
        // Development: walk up to a checkout that has staged the host.
        let mut cur = Some(dir.as_path());
        while let Some(d) = cur {
            if let Some(l) = launch_in_dir(&d.join("build").join(platform_dir()), "checkout build/") {
                return Ok(l);
            }
            cur = d.parent();
        }
    }
    Err(format!(
        "SpektraLab could not find its engine host ({}). Reinstall the app, or set SPEKTRALAB_HOST_DIR.",
        exe_name()
    ))
}
