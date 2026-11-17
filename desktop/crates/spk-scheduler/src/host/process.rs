//! A `spektralab-host` of the link's own (`spektralab-host --resources <dir>`), spoken to in
//! HOST-PROTOCOL.md §1 framing. For tests and tools: the app supplies its own `HostLink` over its
//! `HostManager`, so it keeps one host process.

use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{broadcast, oneshot};

use super::{framing, HostError, HostLink, HostReply};

type Pending = Arc<Mutex<HashMap<u32, oneshot::Sender<HostReply>>>>;

const STDERR_TAIL: usize = 80;

pub struct ProcessHostLink {
    stdin: tokio::sync::Mutex<Option<ChildStdin>>,
    pending: Pending,
    next_id: AtomicU32,
    events: broadcast::Sender<Value>,
    child: Mutex<Option<Child>>,
    alive: Arc<AtomicBool>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
}

impl ProcessHostLink {
    /// Start the host, from inside a tokio runtime (its reader tasks are spawned there). `env` is added to the child's environment (on macOS the MoltenVK build needs
    /// `DYLD_FALLBACK_LIBRARY_PATH`, which the caller passes).
    pub fn spawn(program: &Path, resources: &Path, env: &[(String, String)]) -> std::io::Result<Arc<Self>> {
        let mut cmd = Command::new(program);
        cmd.arg("--resources")
            .arg(resources)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        for (k, v) in env {
            cmd.env(k, v);
        }
        #[cfg(windows)]
        {
            // CREATE_NO_WINDOW, as v1's HostManager does.
            cmd.creation_flags(0x0800_0000);
        }
        let mut child = cmd.spawn()?;
        let stdin = child.stdin.take().expect("piped stdin");
        let mut stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let (events, _) = broadcast::channel(1024);
        let link = Arc::new(ProcessHostLink {
            stdin: tokio::sync::Mutex::new(Some(stdin)),
            pending: Arc::new(Mutex::new(HashMap::new())),
            next_id: AtomicU32::new(1),
            events: events.clone(),
            child: Mutex::new(Some(child)),
            alive: Arc::new(AtomicBool::new(true)),
            stderr_tail: Arc::new(Mutex::new(VecDeque::new())),
        });
        {
            let tail = link.stderr_tail.clone();
            tokio::spawn(async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    log::debug!(target: "host", "{line}");
                    let mut t = tail.lock().unwrap();
                    if t.len() >= STDERR_TAIL {
                        t.pop_front();
                    }
                    t.push_back(line);
                }
            });
        }
        {
            let pending = link.pending.clone();
            let alive = link.alive.clone();
            tokio::spawn(async move {
                let reason = loop {
                    match framing::read_frame(&mut stdout).await {
                        Ok(Some((header, payload))) => {
                            if let Some(id) = header.get("id").and_then(Value::as_u64) {
                                if let Some(tx) = pending.lock().unwrap().remove(&(id as u32)) {
                                    let _ = tx.send(Ok((header, payload)));
                                }
                            } else if header.get("event").is_some() {
                                let _ = events.send(header);
                            }
                        }
                        Ok(None) => break "the engine host exited".to_string(),
                        Err(e) => break format!("protocol error reading the host: {e}"),
                    }
                };
                alive.store(false, Ordering::SeqCst);
                let waiting: Vec<_> = pending.lock().unwrap().drain().collect();
                for (_, tx) in waiting {
                    let _ = tx.send(Err(HostError::new("host_exited", reason.clone())));
                }
            });
        }
        Ok(link)
    }

    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    /// The last lines of the host's stderr, where "no Vulkan device" shows up.
    pub fn stderr_tail(&self) -> Vec<String> {
        self.stderr_tail.lock().unwrap().iter().cloned().collect()
    }

    /// The host dies, as a driver fault would end it (tests: a host that dies mid-job).
    pub fn kill(&self) {
        if let Some(child) = self.child.lock().unwrap().as_mut() {
            let _ = child.start_kill();
        }
    }

    /// `shutdown`, then the child is reaped.
    pub async fn shutdown(&self) {
        let _ = self.request("shutdown", json!({}), Vec::new(), Duration::from_secs(5)).await;
        *self.stdin.lock().await = None;
        let child = self.child.lock().unwrap().take();
        if let Some(mut child) = child {
            if tokio::time::timeout(Duration::from_secs(5), child.wait()).await.is_err() {
                let _ = child.start_kill();
                let _ = child.wait().await;
            }
        }
    }
}

#[async_trait]
impl HostLink for ProcessHostLink {
    async fn request(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration) -> HostReply {
        if !self.is_alive() {
            return Err(HostError::new("not_running", "the engine host is not running"));
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let frame = framing::encode(&json!({"id": id, "method": method, "params": params}), &payload);
        let written = {
            let mut stdin = self.stdin.lock().await;
            match stdin.as_mut() {
                Some(w) => match w.write_all(&frame).await {
                    Ok(()) => w.flush().await.map_err(|e| e.to_string()),
                    Err(e) => Err(e.to_string()),
                },
                None => Err("the host's input is closed".into()),
            }
        };
        if let Err(e) = written {
            self.pending.lock().unwrap().remove(&id);
            return Err(HostError::new("host_exited", format!("writing to the engine host failed: {e}")));
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

    fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events.subscribe()
    }
}
