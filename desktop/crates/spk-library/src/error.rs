//! What a call can fail with: the helper's own error codes
//! (API-SPEC-library-helper.md §3), or the transport failing under it.

use serde::{Serialize, Serializer};
use serde_json::Value;
use std::fmt;

/// The error codes, by name. `Unavailable` and `Timeout` are this client's
/// own: the helper could not be started, stopped, or did not answer in time.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ErrorCode {
    NotFound,
    InvalidParams,
    ReadOnly,
    LastVariant,
    Conflict,
    SourceBusy,
    Unsupported,
    Exists,
    InUse,
    Ambiguous,
    CrossVolume,
    Io,
    Internal,
    UnknownMethod,
    /// The helper could not be started, has stopped, or wrote something that is
    /// not a reply. A call that failed this way may be retried: the next call
    /// starts a new helper (and every library handle must be reopened by path).
    Unavailable,
    /// No reply within the call's timeout. The helper is left running: it
    /// answers in order, so the late reply is dropped when it arrives.
    Timeout,
    /// A code this client does not know (a newer helper); the string as sent.
    Other(String),
}

impl ErrorCode {
    pub fn as_str(&self) -> &str {
        match self {
            ErrorCode::NotFound => "not_found",
            ErrorCode::InvalidParams => "invalid_params",
            ErrorCode::ReadOnly => "read_only",
            ErrorCode::LastVariant => "last_variant",
            ErrorCode::Conflict => "conflict",
            ErrorCode::SourceBusy => "source_busy",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::Exists => "exists",
            ErrorCode::InUse => "in_use",
            ErrorCode::Ambiguous => "ambiguous",
            ErrorCode::CrossVolume => "cross_volume",
            ErrorCode::Io => "io",
            ErrorCode::Internal => "internal",
            ErrorCode::UnknownMethod => "unknown_method",
            ErrorCode::Unavailable => "unavailable",
            ErrorCode::Timeout => "timeout",
            ErrorCode::Other(s) => s,
        }
    }

    pub fn parse(s: &str) -> ErrorCode {
        match s {
            "not_found" => ErrorCode::NotFound,
            "invalid_params" => ErrorCode::InvalidParams,
            "read_only" => ErrorCode::ReadOnly,
            "last_variant" => ErrorCode::LastVariant,
            "conflict" => ErrorCode::Conflict,
            "source_busy" => ErrorCode::SourceBusy,
            "unsupported" => ErrorCode::Unsupported,
            "exists" => ErrorCode::Exists,
            "in_use" => ErrorCode::InUse,
            "ambiguous" => ErrorCode::Ambiguous,
            "cross_volume" => ErrorCode::CrossVolume,
            "io" => ErrorCode::Io,
            "internal" => ErrorCode::Internal,
            "unknown_method" => ErrorCode::UnknownMethod,
            "unavailable" => ErrorCode::Unavailable,
            "timeout" => ErrorCode::Timeout,
            other => ErrorCode::Other(other.to_string()),
        }
    }
}

impl Serialize for ErrorCode {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(self.as_str())
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Serialises as `{"code": "...", "message": "...", "data": ...}`, the
/// helper's own error object, so a Tauri command can hand it to the webview.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LibraryError {
    pub code: ErrorCode,
    pub message: String,
    pub data: Option<Value>,
}

impl LibraryError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        LibraryError { code, message: message.into(), data: None }
    }

    pub(crate) fn unavailable(message: impl Into<String>) -> Self {
        LibraryError::new(ErrorCode::Unavailable, message)
    }

    /// `data.revision` of a `conflict` from `edit.put`: the edit's current revision.
    pub fn conflict_revision(&self) -> Option<i64> {
        if self.code != ErrorCode::Conflict {
            return None;
        }
        self.data.as_ref()?.get("revision")?.as_i64()
    }
}

impl fmt::Display for LibraryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for LibraryError {}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn codes_round_trip_and_unknown_codes_survive() {
        for code in ["not_found", "invalid_params", "read_only", "last_variant", "conflict", "source_busy",
                     "unsupported", "exists", "in_use", "ambiguous", "cross_volume", "io", "internal",
                     "unknown_method", "unavailable", "timeout"] {
            assert_eq!(ErrorCode::parse(code).as_str(), code);
            assert!(!matches!(ErrorCode::parse(code), ErrorCode::Other(_)), "{code} is a known code");
        }
        assert_eq!(ErrorCode::parse("brand_new"), ErrorCode::Other("brand_new".into()));
        let e = LibraryError { code: ErrorCode::Conflict, message: "old".into(), data: Some(serde_json::json!({"revision": 4})) };
        assert_eq!(e.conflict_revision(), Some(4));
        assert_eq!(serde_json::to_value(&e).unwrap(),
                   serde_json::json!({"code": "conflict", "message": "old", "data": {"revision": 4}}));
    }
}
