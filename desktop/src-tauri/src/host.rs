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
use tokio::io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, watch};

use crate::framing;

/// How many restarts inside `RESTART_WINDOW` before the core gives up and
/// shows the failure instead of looping on a host that cannot start.
const MAX_RESTARTS: usize = 3;
const RESTART_WINDOW: Duration = Duration::from_secs(120);
const HELLO_TIMEOUT: Duration = Duration::from_secs(45);
const STDERR_TAIL: usize = 80;
// Ordinary requests contain small JSON frames. Legacy pixel uploads may be
// larger, but a non-reading child must not hold the connection lock forever.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

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
    generation: u64,
    stop: oneshot::Sender<()>,
    exited: oneshot::Receiver<()>,
}

/// The caller may stop waiting before the native operation stops running.
/// Keep its workspace lease with the operation, including after a timeout or
/// a failed receiver. Only a response or an observed child exit completes it.
struct Pending {
    waiter: oneshot::Sender<Reply>,
    _lease: Option<Arc<crate::workspace::Guard>>,
}

#[derive(Default)]
struct Requests(HashMap<(u64, u32), Pending>);
impl Requests {
    fn complete(&mut self, generation: u64, id: u32, reply: Reply) {
        if let Some(pending) = self.0.remove(&(generation, id)) {
            let _ = pending.waiter.send(reply);
        }
    }
    fn exited(&mut self, generation: u64, reason: &str) {
        let ids: Vec<_> = self.0.keys().filter(|(g, _)| *g == generation).copied().collect();
        for (_, id) in ids {
            self.complete(generation, id, Err(HostError::new("host_exited", reason)));
        }
    }
}

async fn wait_child(mut child: Child, stop_requested: oneshot::Receiver<()>) -> std::io::Result<std::process::ExitStatus> {
    tokio::select! {
        result = child.wait() => result,
        _ = stop_requested => {
            // A cancelled stop sender also means its owner went away.
            // Always reap the process; dropping stdin is not completion.
            let _ = child.start_kill();
            child.wait().await
        }
    }
}

async fn write_frame<W: AsyncWrite + Unpin>(writer: &mut W, frame: &[u8], deadline: tokio::time::Instant) -> std::io::Result<()> {
    tokio::time::timeout_at(deadline, async {
        writer.write_all(frame).await?;
        writer.flush().await
    }).await.unwrap_or_else(|_| Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "engine host stopped accepting requests")))
}

pub struct HostManager {
    app: AppHandle<Wry>,
    conn: tokio::sync::Mutex<Option<Conn>>,
    pending: Mutex<Requests>,
    transition: tokio::sync::Mutex<()>,
    stopping: tokio::sync::Mutex<()>,
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
            pending: Mutex::new(Requests::default()),
            transition: tokio::sync::Mutex::new(()),
            stopping: tokio::sync::Mutex::new(()),
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
    pub fn is_busy(&self) -> bool { !self.pending.lock().unwrap().0.is_empty() }

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
        self.start_generation(None)
    }

    fn start_generation(self: &Arc<Self>, expected: Option<u64>) -> Pin<Box<dyn Future<Output = ()> + Send + 'static>> {
        let me = Arc::clone(self);
        Box::pin(async move {
            let _transition = me.transition.lock().await;
            if expected.is_some_and(|g| me.generation.load(Ordering::SeqCst) != g) { return; }
            me.start_inner().await
        })
    }

    async fn start_inner(self: &Arc<Self>) {
        if self.shutting_down.load(Ordering::SeqCst) { return; }
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
        if !launch.mock {
            let config = crate::diagnostics::configuration(&self.app);
            cmd.args(["--log-level", &config.level]);
            if config.per_node { cmd.env("SPEKTRAFILM_NODE_TIMINGS", "1"); }
            else { cmd.env_remove("SPEKTRAFILM_NODE_TIMINGS"); }
        }
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
        let (stop, stop_requested) = oneshot::channel();
        let (exited, exit_received) = oneshot::channel();
        *self.conn.lock().await = Some(Conn { stdin, generation, stop, exited: exit_received });

        // stderr: a free-form log, one line per entry. Kept as a tail for the
        // failure dialog.
        {
            let me = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    if line.starts_with("spektralab-host error:") { log::error!(target:"host", "{line}"); }
                    else if line.starts_with("spektralab-host debug:") { log::debug!(target:"host", "{line}"); }
                    else { log::info!(target: "host", "{line}"); }
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
                        Ok(Some((header, payload))) => me.dispatch(generation, header, payload),
                        Ok(None) => break,
                        Err(e) => {
                            log::error!(target: "host", "protocol error reading the host: {e}");
                            break;
                        }
                    }
                }
                // A closed/corrupt protocol cannot complete pending work.
                // Reap the matching child so no abandoned leases remain.
                me.stop_generation(Some(generation)).await;
            });
        }

        // The exit watcher owns the child.
        {
            let me = Arc::clone(self);
            tauri::async_runtime::spawn(async move {
                let status = wait_child(child, stop_requested).await;
                let status = status.map(|s| s.to_string()).unwrap_or_else(|e| e.to_string());
                // Serialize against a request still writing its frame. It
                // must be registered before this generation is drained, and
                // no new request may attach to the already exited child.
                let mut connection = me.conn.lock().await;
                if connection.as_ref().is_some_and(|c| c.generation == generation) { *connection = None; }
                drop(connection);
                me.pending.lock().unwrap().exited(generation, &format!("the engine host exited ({status})"));
                let _ = exited.send(());
                me.on_exit(generation, status).await;
            });
        }

        // hello
        match self.request_inner("hello", json!({}), Vec::new(), HELLO_TIMEOUT, None).await {
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
        self.stop_child().await;
        self.set_state(json!({"phase": "failed", "reason": reason, "detail": detail}));
    }

    fn dispatch(&self, generation: u64, header: Value, payload: Vec<u8>) {
        if let Some(id) = header.get("id").and_then(Value::as_u64) {
            self.pending.lock().unwrap().complete(generation, id as u32, Ok((header, payload)));
        } else if let Some(ev) = header.get("event").and_then(Value::as_str) {
            if generation != self.generation.load(Ordering::SeqCst) { return; }
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

    async fn stop_child(&self) {
        self.stop_generation(None).await;
    }

    async fn stop_generation(&self, expected: Option<u64>) {
        // Reader EOF and a user restart may arrive together. A second stop
        // must wait for the first one's child to be reaped, even when that
        // first caller has already taken the connection out of the slot.
        let _stopping = self.stopping.lock().await;
        let mut current = self.conn.lock().await;
        if expected.is_some_and(|g| current.as_ref().map_or(true, |c| c.generation != g)) { return; }
        let connection = current.take();
        drop(current);
        if let Some(conn) = connection {
            let _ = conn.stop.send(());
            drop(conn.stdin);
            // The watcher releases this generation's leases only after wait.
            let _ = conn.exited.await;
        }
    }

    async fn on_exit(self: &Arc<Self>, generation: u64, status: String) {
        // Publish lifecycle state under the same lock as user restarts. A
        // superseded exit must not replace a new host's ready state with its
        // delayed restarting banner. The watcher already signalled/reaped
        // the child before entering here, so this cannot block stop_child.
        let transition = self.transition.lock().await;
        if self.generation.load(Ordering::SeqCst) != generation {
            return; // superseded (restart or fail_and_kill)
        }
        let reason = format!("the engine host exited ({status})");
        log::warn!(target: "host", "{reason}");
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
        drop(transition);
        tokio::time::sleep(Duration::from_millis(400 * attempt as u64)).await;
        self.start_generation(Some(generation)).await;
    }

    /// Restart on request (menu: Restart Render Service). Resets the budget.
    pub async fn restart(self: &Arc<Self>) {
        let _transition = self.transition.lock().await;
        self.restarts.lock().unwrap().clear();
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.stop_child().await;
        self.set_state(json!({"phase": "restarting", "reason": "restart requested", "attempt": 0}));
        self.start_inner().await;
    }

    pub async fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::SeqCst);
        let _ = tokio::time::timeout(
            Duration::from_secs(2),
            self.request_inner("shutdown", json!({}), Vec::new(), Duration::from_secs(2), None),
        )
        .await;
        self.stop_child().await;
    }

    /// A request from the webview: waits for the host to be ready first, so a
    /// call made during a restart lands on the new host instead of failing.
    pub async fn request(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration,
                         lease: Option<crate::workspace::Guard>) -> Reply {
        let lease = lease.map(Arc::new);
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
        let job = matches!(method, "export_frame" | "export_cineon") && crate::diagnostics::configuration(&self.app).export_job_log;
        let snapshot = if job { Some(params.clone()) } else { None };
        let started = Instant::now();
        let reply = self.request_inner(method, params, payload, timeout, lease.clone()).await;
        if let (Some(snapshot), Ok((header, _))) = (snapshot, &reply) {
            if header["ok"] == json!(true) {
                let result = header["result"].clone();
                let elapsed = started.elapsed().as_millis();
                // Saving the requested log is part of this job's completion.
                // A log failure must not hide a successfully written image.
                let log_result = tauri::async_runtime::spawn_blocking(move || crate::diagnostics::write_job_log(&result, &snapshot, elapsed)).await;
                if !matches!(log_result, Ok(Ok(()))) { log::warn!(target:"export", "Export succeeded but writing its job log failed: {log_result:?}"); }
            }
        }
        reply
    }

    async fn request_inner(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration,
                           lease: Option<Arc<crate::workspace::Guard>>) -> Reply {
        let started = tokio::time::Instant::now();
        let deadline = started + timeout;
        let write_deadline = started + timeout.min(WRITE_TIMEOUT);
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        let frame = framing::encode(&json!({"id": id, "method": method, "params": params}), &payload);
        let generation;
        let write_error = {
            let mut guard = match tokio::time::timeout_at(write_deadline, self.conn.lock()).await {
                Ok(guard) => guard,
                // No bytes or pending operation exist yet for this request.
                Err(_) => return Err(HostError::new("timeout", "waiting to write to the engine host timed out")),
            };
            let Some(conn) = guard.as_mut() else {
                return Err(HostError::new("not_running", "the engine host is not running"));
            };
            generation = conn.generation;
            // Capture the connection generation under the same lock as its
            // write. A restart cannot attach an old request to a new child.
            self.pending.lock().unwrap().0.insert((conn.generation, id), Pending { waiter: tx, _lease: lease });
            write_frame(&mut conn.stdin, &frame, write_deadline).await.err()
        };
        if let Some(e) = write_error {
            // A partial frame may already have reached the child. Kill and
            // reap this generation; do not accidentally stop a new host.
            self.stop_generation(Some(generation)).await;
            let code = if e.kind() == std::io::ErrorKind::TimedOut { "timeout" } else { "host_exited" };
            return Err(HostError::new(code, format!("writing to the engine host failed: {e}")));
        }
        // Writing consumes the caller's original budget; it never starts a
        // second full timeout after a slow/large upload.
        match tokio::time::timeout_at(deadline, rx).await {
            Ok(Ok(reply)) => reply,
            Ok(Err(_)) => Err(HostError::new("host_exited", "the engine host went away")),
            Err(_) => {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{agent_files, workspace::Workspace};

    fn workspace() -> (PathBuf, Arc<Workspace>) {
        let root = std::env::temp_dir().join(format!("spk-host-lease-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        (root.clone(), Workspace::new(root))
    }

    #[tokio::test]
    async fn timeout_keeps_os_lease_until_native_completion() {
        let (root, workspace) = workspace();
        let (tx, rx) = oneshot::channel();
        let mut requests = Requests::default();
        requests.0.insert((4, 7), Pending { waiter: tx, _lease: Some(Arc::new(workspace.enter().unwrap())) });
        assert!(tokio::time::timeout(Duration::from_millis(5), rx).await.is_err());
        // The GUI has already received its timeout. Its actual native job is
        // still running and a second process must remain excluded.
        assert!(agent_files::acquire(&root).is_err());
        requests.complete(3, 7, Ok((json!({"ok":true}), vec![])));
        assert!(agent_files::acquire(&root).is_err());
        requests.complete(4, 7, Ok((json!({"ok":true}), vec![])));
        drop(agent_files::acquire(&root).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn partial_write_times_out_without_releasing_the_operation() {
        let (root, workspace) = workspace();
        let (tx, rx) = oneshot::channel();
        drop(rx);
        let mut requests = Requests::default();
        requests.0.insert((5, 3), Pending { waiter: tx, _lease: Some(Arc::new(workspace.enter().unwrap())) });
        // The peer remains alive but never drains its eight-byte pipe. This
        // reproduces a stalled child, including the dangerous partial frame.
        let (mut writer, mut peer) = tokio::io::duplex(8);
        let error = write_frame(&mut writer, &[7; 128], tokio::time::Instant::now() + Duration::from_millis(5)).await.unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        let mut received = [0; 8];
        tokio::io::AsyncReadExt::read_exact(&mut peer, &mut received).await.unwrap();
        assert_eq!(received, [7; 8]);
        assert!(agent_files::acquire(&root).is_err());
        // The write failure itself is not completion. Production kills and
        // waits for the child before calling this generation-exit boundary.
        requests.exited(5, "partial writer's child was reaped");
        drop(agent_files::acquire(&root).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn old_generation_exit_does_not_release_new_host_work() {
        let (root, workspace) = workspace();
        let mut requests = Requests::default();
        let (old_tx, old_rx) = oneshot::channel();
        let (new_tx, mut new_rx) = oneshot::channel();
        requests.0.insert((11, 1), Pending { waiter: old_tx, _lease: Some(Arc::new(workspace.enter().unwrap())) });
        requests.0.insert((12, 1), Pending { waiter: new_tx, _lease: Some(Arc::new(workspace.enter().unwrap())) });
        drop(old_rx); // receiver cancellation must not release its job
        assert!(agent_files::acquire(&root).is_err());
        requests.exited(11, "old host was reaped");
        assert_eq!(requests.0.len(), 1);
        assert!(new_rx.try_recv().is_err());
        assert!(agent_files::acquire(&root).is_err());
        // Late output from the old process must not settle the new request.
        requests.complete(11, 1, Ok((json!({"ok":true}), vec![])));
        assert!(new_rx.try_recv().is_err());
        requests.exited(12, "new host was reaped");
        assert_eq!(new_rx.await.unwrap().unwrap_err().code, "host_exited");
        drop(agent_files::acquire(&root).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[ignore = "child process fixture for stop_reaps_child_before_releasing_leases"]
    fn sleeping_child_fixture() { std::thread::sleep(Duration::from_secs(60)); }

    #[tokio::test]
    async fn stop_reaps_child_before_releasing_leases() {
        let (root, workspace) = workspace();
        let (tx, rx) = oneshot::channel();
        drop(rx);
        let mut requests = Requests::default();
        requests.0.insert((9, 2), Pending { waiter: tx, _lease: Some(Arc::new(workspace.enter().unwrap())) });
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args(["--exact", "host::tests::sleeping_child_fixture", "--ignored"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
        #[cfg(windows)] command.creation_flags(0x0800_0000);
        let child = command.spawn().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(wait_child(child, stopped));
        assert!(agent_files::acquire(&root).is_err());
        stop.send(()).unwrap();
        let status = tokio::time::timeout(Duration::from_secs(5), task).await.unwrap().unwrap().unwrap();
        assert!(!status.success());
        assert!(agent_files::acquire(&root).is_err());
        requests.exited(9, "wait confirmed child termination");
        drop(agent_files::acquire(&root).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }
}
