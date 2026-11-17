//! The engine host (`spektralab-host`, `desktop/HOST-PROTOCOL.md`) behind the scheduler.
//!
//! - [`HostLink`]: one request call shaped like v1's `HostManager::request` (`desktop/src-tauri/src/host.rs`)
//!   and a subscription to the host's unsolicited events. The app implements it over its own
//!   `HostManager` (one host process); [`ProcessHostLink`] spawns a host of its own, for tests and tools.
//! - [`HostEngine`]: the `DevelopEngine` conformer that maps a job to host requests.

pub mod engine;
pub mod framing;
pub mod process;

use std::time::Duration;

use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::broadcast;

pub use engine::HostEngine;
pub use process::ProcessHostLink;

/// A link-level failure (v1's `HostError`): the host could not be asked, or did not answer. A host that
/// answered with `ok: false` is not this: that is a reply, and its header carries the error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostError {
    /// `host_exited`, `not_running`, `timeout`, …
    pub code: String,
    pub message: String,
}

impl HostError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        HostError { code: code.into(), message: message.into() }
    }
}

impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for HostError {}

/// A reply as v1's core hands it on: the full response header (`{id, ok, result}` or
/// `{id, ok: false, error: {code, message}}`) and the binary payload.
pub type HostReply = Result<(Value, Vec<u8>), HostError>;

/// The scheduler's way to the host. `Send + Sync`; a request may be made from any task, and `cancel`
/// is sent while another request is in flight (the host answers it on its reader thread).
#[async_trait]
pub trait HostLink: Send + Sync {
    async fn request(&self, method: &str, params: Value, payload: Vec<u8>, timeout: Duration) -> HostReply;
    /// The host's unsolicited frames (`{"event": "progress", "session", "progress_id", "fraction", "stage"}`,
    /// `{"event": "log", …}`), each header as it arrived.
    fn subscribe(&self) -> broadcast::Receiver<Value>;
}
