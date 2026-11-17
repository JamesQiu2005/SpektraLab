//! `spk-library` -- the Windows/Linux app's client of SpektraLab's library
//! helper, `spklib-host` (MIT, the SpektraLab_library repository).
//!
//! The helper keeps libraries -- SpektraLab catalogs and sessions, and a
//! Capture One catalog read one way through a snapshot -- in its own process,
//! and the app talks to it with one compact JSON request per line on stdin and
//! one reply per line on stdout (API-SPEC-library-helper.md). This crate is
//! that conversation and nothing else: no tauri, no async runtime.
//!
//! - [`LibraryHost`]: spawn on first use (no console window on Windows),
//!   requests with ids, timeouts, a new helper after a crash, a clean shutdown
//!   (also on drop), the store directory passed as `--store`.
//! - [`LibraryHost::call`]: any method of spklib's `API-SPEC.md`.
//! - Typed calls for the Library pages ([`api`]), and the path rules ([`paths`]).
//!
//! The contract the app wires is `README.md` beside this file.

pub mod api;
pub mod error;
pub mod host;
pub mod paths;

pub use api::{
    AddItem, CaptureOneProbe, Collection, Edit, Facets, ImagePage, ImageQuery, ImageRow, LibraryInfo, Location,
    OpenedLibrary, SdkVersion, VariantRow, WatchedFolder,
};
pub use error::{ErrorCode, LibraryError};
pub use host::{default_store, Launch, LibraryHost, LogSink, ABI};
