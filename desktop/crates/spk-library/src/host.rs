//! The helper process: started on first use, one JSON request per line in, one
//! reply per line out, routed back by `id`; restarted by the next call after it
//! stops; shut down with the app. API-SPEC-library-helper.md §2-§3, and the
//! Mac's `LibraryHost.swift`, which this follows.

use crate::error::{ErrorCode, LibraryError};
use crate::paths;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

/// The ABI this client speaks (`sdk.version`'s `abi`). Any other is refused.
pub const ABI: i64 = 1;

/// Windows: no console window for the helper (it is a console program, and a
/// GUI app's child would otherwise get one).
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// A log line, from the helper's stderr or from this client.
pub type LogSink = Arc<dyn Fn(&str) + Send + Sync>;

/// Where the helper is, and where it keeps linked catalogs' mirrors.
#[derive(Clone)]
pub struct Launch {
    /// `spklib-host` (macOS) or `spklib-host.exe` (Windows).
    pub executable: PathBuf,
    /// The store, passed as `--store <dir>` (created if missing): where a
    /// linked Capture One catalog's mirror lives. [`default_store`] gives the
    /// platform's place (README).
    pub store: PathBuf,
    /// The default time a call may take before it fails as `Timeout`.
    pub call_timeout: Duration,
    /// How long the helper has to print its ready line.
    pub start_timeout: Duration,
    /// Every stderr line of the helper, and this client's own notes.
    pub log: Option<LogSink>,
}

impl Launch {
    pub fn new(executable: impl Into<PathBuf>, store: impl Into<PathBuf>) -> Self {
        Launch {
            executable: executable.into(),
            store: store.into(),
            call_timeout: Duration::from_secs(120),
            start_timeout: Duration::from_secs(10),
            log: None,
        }
    }
}

/// The store as each platform's app passes it, absolute (the helper expands
/// neither `%VAR%` nor `~`):
/// - Windows: `%LOCALAPPDATA%\SpektraLab\Libraries`. Local, not Roaming: the
///   mirrors can be rebuilt, can be large and use WAL, which must not sit on a
///   network share (spklib `docs/WINDOWS.md`).
/// - macOS: `~/Library/Application Support/SpektraLab/Libraries`, as the Mac app.
/// - Linux: `$XDG_DATA_HOME/SpektraLab/Libraries`, else `~/.local/share/...`.
///
/// `None` when the variable it needs is unset.
pub fn default_store() -> Option<PathBuf> {
    store_from(|k| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from))
}

fn store_from(var: impl Fn(&str) -> Option<PathBuf>) -> Option<PathBuf> {
    let base = if cfg!(windows) {
        var("LOCALAPPDATA")?
    } else if cfg!(target_os = "macos") {
        var("HOME")?.join("Library").join("Application Support")
    } else {
        var("XDG_DATA_HOME").or_else(|| var("HOME").map(|h| h.join(".local").join("share")))?
    };
    Some(base.join("SpektraLab").join("Libraries"))
}

type Reply = Result<Value, LibraryError>;

struct Shared {
    waiters: HashMap<u64, SyncSender<Reply>>,
    ready: Option<SyncSender<String>>,
    /// Set by the reader when stdout closes: the helper has gone.
    gone: bool,
    stderr_tail: VecDeque<String>,
}

struct Running {
    child: Child,
    stdin: Option<ChildStdin>,
    shared: Arc<Mutex<Shared>>,
    alive: Arc<AtomicBool>,
    version: String,
}

struct State {
    running: Option<Running>,
    launches: u64,
    next_id: u64,
}

/// One helper for the app. `Send + Sync`: share it in an `Arc` (Tauri state);
/// calls from several threads are serialised onto the helper's one stdin and
/// answered in order. Every method blocks; call it off the UI thread.
pub struct LibraryHost {
    launch: Launch,
    state: Mutex<State>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl LibraryHost {
    /// Nothing starts here: the first call starts the helper.
    pub fn new(launch: Launch) -> Self {
        LibraryHost { launch, state: Mutex::new(State { running: None, launches: 0, next_id: 1 }) }
    }

    pub fn launch(&self) -> &Launch {
        &self.launch
    }

    fn note(&self, line: &str) {
        if let Some(log) = &self.launch.log {
            log(line);
        }
    }

    /// How many helpers this host has started. A library handle (`"L1"`) from
    /// an earlier launch names nothing in this one: reopen the library by path.
    pub fn launches(&self) -> u64 {
        lock(&self.state).launches
    }

    /// The helper's ready line (`spklib 0.3.1+… (abi 1, schema 3)`), while one runs.
    pub fn version(&self) -> Option<String> {
        let mut st = lock(&self.state);
        Self::reap(&mut st);
        st.running.as_ref().map(|r| r.version.clone())
    }

    pub fn is_running(&self) -> bool {
        let mut st = lock(&self.state);
        Self::reap(&mut st);
        st.running.is_some()
    }

    /// The running helper's process id (diagnostics and tests).
    pub fn pid(&self) -> Option<u32> {
        let mut st = lock(&self.state);
        Self::reap(&mut st);
        st.running.as_ref().map(|r| r.child.id())
    }

    /// The last stderr lines of the current (or last) helper.
    pub fn stderr_tail(&self) -> Vec<String> {
        let st = lock(&self.state);
        st.running.as_ref().map(|r| lock(&r.shared).stderr_tail.iter().cloned().collect()).unwrap_or_default()
    }

    /// Forget a helper that has exited, failing nothing that is not already failed.
    fn reap(st: &mut State) {
        let dead = match st.running.as_mut() {
            None => false,
            Some(r) => !r.alive.load(Ordering::SeqCst) || matches!(r.child.try_wait(), Ok(Some(_))),
        };
        if dead {
            if let Some(mut r) = st.running.take() {
                drop(r.stdin.take());
                let _ = r.child.kill();
                let _ = r.child.wait();
            }
        }
    }

    /// Start the helper now (otherwise the first call does).
    pub fn start(&self) -> Result<(), LibraryError> {
        let mut st = lock(&self.state);
        self.ensure(&mut st)
    }

    fn ensure(&self, st: &mut State) -> Result<(), LibraryError> {
        Self::reap(st);
        if st.running.is_some() {
            return Ok(());
        }
        self.spawn(st)
    }

    fn spawn(&self, st: &mut State) -> Result<(), LibraryError> {
        let exe = &self.launch.executable;
        if !exe.is_file() {
            return Err(LibraryError::unavailable(format!("the library helper is not there ({})", exe.display())));
        }
        std::fs::create_dir_all(&self.launch.store).map_err(|e| {
            LibraryError::unavailable(format!("the library store cannot be made at {}: {e}", self.launch.store.display()))
        })?;
        let mut cmd = Command::new(exe);
        cmd.arg("--store").arg(&self.launch.store);
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }
        let mut child = cmd
            .spawn()
            .map_err(|e| LibraryError::unavailable(format!("the library helper could not be started: {e}")))?;
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let stdin = child.stdin.take();
        let (ready_tx, ready_rx) = mpsc::sync_channel::<String>(1);
        let shared = Arc::new(Mutex::new(Shared {
            waiters: HashMap::new(),
            ready: Some(ready_tx),
            gone: false,
            stderr_tail: VecDeque::new(),
        }));
        let alive = Arc::new(AtomicBool::new(true));
        st.launches += 1;
        let launch_no = st.launches;

        {
            let shared = shared.clone();
            let alive = alive.clone();
            let log = self.launch.log.clone();
            thread::Builder::new()
                .name(format!("spklib-host stdout #{launch_no}"))
                .spawn(move || reader(stdout, shared, alive, log))
                .map_err(|e| LibraryError::unavailable(format!("reader thread: {e}")))?;
        }
        {
            let shared = shared.clone();
            let log = self.launch.log.clone();
            thread::Builder::new()
                .name(format!("spklib-host stderr #{launch_no}"))
                .spawn(move || {
                    for line in BufReader::new(stderr).lines() {
                        let Ok(line) = line else { break };
                        if let Some(log) = &log {
                            log(&format!("spklib-host: {line}"));
                        }
                        let mut s = lock(&shared);
                        if s.stderr_tail.len() == 50 {
                            s.stderr_tail.pop_front();
                        }
                        s.stderr_tail.push_back(line);
                    }
                })
                .map_err(|e| LibraryError::unavailable(format!("stderr thread: {e}")))?;
        }
        st.running = Some(Running { child, stdin, shared, alive, version: String::new() });

        // `{"event":"ready",...}` is the first line; then `sdk.version` decides
        // whether this client may talk to it at all.
        let version = match ready_rx.recv_timeout(self.launch.start_timeout) {
            Ok(v) => v,
            Err(_) => {
                Self::kill(st);
                return Err(LibraryError::unavailable(format!(
                    "the library helper did not start within {} s",
                    self.launch.start_timeout.as_secs()
                )));
            }
        };
        let rx = match self.send(st, "sdk.version", json!({})) {
            Ok(rx) => rx,
            Err(e) => {
                Self::kill(st);
                return Err(e);
            }
        };
        let v = match rx.recv_timeout(self.launch.start_timeout) {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => {
                Self::kill(st);
                return Err(e);
            }
            Err(_) => {
                Self::kill(st);
                return Err(LibraryError::unavailable("the library helper did not answer sdk.version"));
            }
        };
        let abi = v.get("abi").and_then(Value::as_i64).unwrap_or(-1);
        if abi != ABI {
            Self::kill(st);
            return Err(LibraryError::unavailable(format!("the library helper speaks ABI {abi}; this client needs {ABI}")));
        }
        if let Some(r) = st.running.as_mut() {
            r.version = version.clone();
        }
        self.note(&format!("library helper started ({version}), launch {launch_no}"));
        Ok(())
    }

    fn kill(st: &mut State) {
        if let Some(mut r) = st.running.take() {
            drop(r.stdin.take());
            let _ = r.child.kill();
            let _ = r.child.wait();
        }
    }

    /// Write one request; the receiver gets its reply. Holding the state lock
    /// keeps ids and lines in step.
    fn send(&self, st: &mut State, method: &str, params: Value) -> Result<Receiver<Reply>, LibraryError> {
        let id = st.next_id;
        st.next_id += 1;
        let r = st.running.as_mut().ok_or_else(|| LibraryError::unavailable("the library helper is not running"))?;
        let (tx, rx) = mpsc::sync_channel::<Reply>(1);
        {
            let mut s = lock(&r.shared);
            if s.gone {
                return Err(LibraryError::unavailable("the library helper stopped"));
            }
            s.waiters.insert(id, tx);
        }
        let mut line = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .map_err(|e| LibraryError::new(ErrorCode::InvalidParams, format!("params do not serialise: {e}")))?;
        line.push(b'\n');
        let written = match r.stdin.as_mut() {
            Some(stdin) => stdin.write_all(&line).and_then(|_| stdin.flush()),
            None => Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stdin closed")),
        };
        if let Err(e) = written {
            lock(&r.shared).waiters.remove(&id);
            return Err(LibraryError::unavailable(format!("the library helper is not reading: {e}")));
        }
        Ok(rx)
    }

    /// One request, its `result` back -- or the helper's error, by code.
    /// Starts the helper if none is running (after a crash, a new one).
    pub fn call(&self, method: &str, params: Value) -> Result<Value, LibraryError> {
        self.call_with_timeout(method, params, self.launch.call_timeout)
    }

    pub fn call_with_timeout(&self, method: &str, params: Value, timeout: Duration) -> Result<Value, LibraryError> {
        let params = match params {
            Value::Null => Value::Object(Map::new()),
            p @ Value::Object(_) => p,
            _ => return Err(LibraryError::new(ErrorCode::InvalidParams, "params must be a JSON object")),
        };
        guard_capture_one(method, &params)?;
        let rx = {
            let mut st = lock(&self.state);
            self.ensure(&mut st)?;
            match self.send(&mut st, method, params.clone()) {
                Ok(rx) => rx,
                // The request never reached a helper that had just died: it is
                // safe to start a new one and send it once more.
                Err(e) if e.code == ErrorCode::Unavailable => {
                    Self::kill(&mut st);
                    self.spawn(&mut st)?;
                    self.send(&mut st, method, params)?
                }
                Err(e) => return Err(e),
            }
        };
        let deadline = Instant::now() + timeout;
        match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(reply) => reply,
            Err(mpsc::RecvTimeoutError::Timeout) => Err(LibraryError::new(
                ErrorCode::Timeout,
                format!("{method}: no reply within {} s", timeout.as_secs_f64()),
            )),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(LibraryError::unavailable("the library helper stopped")),
        }
    }

    /// `host.shutdown`, then stdin closed, then a kill if it is still there
    /// (§2 "Quitting"). Every write is committed before its reply, so nothing
    /// a reply confirmed is lost by any of the three. The process is reaped:
    /// none is left behind.
    pub fn shutdown(&self) {
        let mut st = lock(&self.state);
        Self::reap(&mut st);
        if st.running.is_none() {
            return;
        }
        if let Ok(rx) = self.send(&mut st, "host.shutdown", json!({})) {
            let _ = rx.recv_timeout(Duration::from_secs(2));
        }
        if let Some(mut r) = st.running.take() {
            drop(r.stdin.take());
            let until = Instant::now() + Duration::from_secs(2);
            loop {
                match r.child.try_wait() {
                    Ok(Some(_)) => break,
                    Ok(None) if Instant::now() < until => thread::sleep(Duration::from_millis(20)),
                    _ => {
                        let _ = r.child.kill();
                        let _ = r.child.wait();
                        break;
                    }
                }
            }
        }
        self.note("library helper shut down");
    }
}

impl Drop for LibraryHost {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Lines from stdout: replies to their waiter by id, the ready event to the
/// starter. At EOF every waiter fails as `Unavailable`.
fn reader(stdout: std::process::ChildStdout, shared: Arc<Mutex<Shared>>, alive: Arc<AtomicBool>, log: Option<LogSink>) {
    let mut lines = BufReader::new(stdout);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        match lines.read_until(b'\n', &mut buf) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if buf.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let msg: Value = match serde_json::from_slice(&buf) {
            Ok(v) => v,
            Err(_) => {
                if let Some(log) = &log {
                    let text = String::from_utf8_lossy(&buf[..buf.len().min(200)]).into_owned();
                    log(&format!("spklib-host wrote a line that is not JSON: {text}"));
                }
                continue;
            }
        };
        if let Some(id) = msg.get("id").and_then(Value::as_u64) {
            let reply = if let Some(err) = msg.get("error") {
                Err(LibraryError {
                    code: ErrorCode::parse(err.get("code").and_then(Value::as_str).unwrap_or("internal")),
                    message: err.get("message").and_then(Value::as_str).unwrap_or("").to_string(),
                    data: err.get("data").cloned().filter(|d| !d.is_null()),
                })
            } else {
                Ok(msg.get("result").cloned().unwrap_or(Value::Null))
            };
            if let Some(tx) = lock(&shared).waiters.remove(&id) {
                let _ = tx.send(reply);
            }
            continue;
        }
        if msg.get("event").and_then(Value::as_str) == Some("ready") {
            if let Some(tx) = lock(&shared).ready.take() {
                let _ = tx.send(msg.get("version").and_then(Value::as_str).unwrap_or("spklib").to_string());
            }
            continue;
        }
        if let Some(log) = &log {
            log(&format!("spklib-host wrote a line that is not a reply: {msg}"));
        }
    }
    alive.store(false, Ordering::SeqCst);
    let mut s = lock(&shared);
    s.gone = true;
    s.ready = None;
    for (_, tx) in s.waiters.drain() {
        let _ = tx.send(Err(LibraryError::unavailable("the library helper stopped")));
    }
}

/// R-B5, on this side too: a call that creates or writes at a path is refused
/// before it is sent when that path is inside a Capture One catalog or session.
/// The helper refuses these itself; the client does not ask. Reading a catalog
/// (`capture_one.probe`, `.link`'s and `.copy`'s `source`) is not writing.
fn guard_capture_one(method: &str, params: &Value) -> Result<(), LibraryError> {
    let target_keys: &[&str] = match method {
        "library.create" | "capture_one.copy" | "capture_one.link" | "folders.add" | "location.relink" => &["path"],
        "images.add" => &["destination"],
        _ => &[],
    };
    for key in target_keys {
        if let Some(p) = params.get(*key).and_then(Value::as_str) {
            if paths::inside_capture_one(p) {
                return Err(LibraryError::new(
                    ErrorCode::InvalidParams,
                    format!("{method}: '{key}' is inside a Capture One catalog or session, which SpektraLab never writes: {p}"),
                ));
            }
        }
    }
    Ok(())
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn the_store_is_where_the_mac_app_keeps_it() {
        let home = |k: &str| (k == "HOME").then(|| PathBuf::from("/Users/me"));
        assert_eq!(store_from(home), Some(PathBuf::from("/Users/me/Library/Application Support/SpektraLab/Libraries")));
        assert_eq!(store_from(|_| None), None);
    }

    #[test]
    fn writes_into_a_capture_one_package_are_refused_before_sending() {
        for (method, params) in [
            ("library.create", json!({"path": "/Users/me/Main.cocatalog/x.spkcatalog", "kind": "catalog"})),
            ("capture_one.copy", json!({"source": "/a/Main.cocatalog", "path": "/a/Main.cocatalog/Copy.spkcatalog"})),
            ("capture_one.link", json!({"source": "/a/Main.cocatalog", "path": "C:\\a\\Main.cocatalog\\m"})),
            ("folders.add", json!({"library": "L1", "path": "/a/Main.cocatalog/Originals"})),
            ("location.relink", json!({"library": "L1", "location": "x", "path": "/s/Shoot.cosessiondb"})),
            ("images.add", json!({"library": "L1", "items": [], "mode": "copy", "destination": "/a/X.cocatalog/in"})),
        ] {
            let e = guard_capture_one(method, &params).expect_err(method);
            assert_eq!(e.code, ErrorCode::InvalidParams, "{method}");
        }
        // Reading a catalog is how it is opened.
        guard_capture_one("capture_one.probe", &json!({"path": "/a/Main.cocatalog"})).unwrap();
        guard_capture_one("capture_one.link", &json!({"source": "/a/Main.cocatalog"})).unwrap();
        guard_capture_one("capture_one.copy", &json!({"source": "/a/Main.cocatalog", "path": "/b/Copy.spkcatalog"})).unwrap();
        guard_capture_one("images.add", &json!({"library": "L1", "items": ["/a/Main.cocatalog/Originals/x.NEF"], "mode": "reference"}))
            .unwrap();
    }
}
