//! Every job's record, in a file (`JobLogFile.swift`, RFC-036 R8).
//!
//! The queue keeps the last 200 records in memory and hands each to `on_record`; this is the copy that
//! survives the app being ended. One JSON object a line, keys sorted, dates ISO-8601 to the second — the
//! Mac's `scheduler-log.jsonl` line — written and flushed as the record is made.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::types::JobRecord;

/// Where records go (an injected sink: a file in the app, a vector in a test).
pub trait JobSink: Send + Sync {
    fn append(&self, record: &JobRecord);
}

/// A record as the Mac's log writes it: one line, keys sorted.
pub fn line(record: &JobRecord) -> String {
    // A `serde_json::Value` object is a sorted map, so going through one sorts every level's keys.
    let value = serde_json::to_value(record).expect("a job record always serialises");
    serde_json::to_string(&value).expect("a JSON value always serialises")
}

/// `JobLogFile`.
pub struct JobLogFile {
    pub path: PathBuf,
    file: Mutex<File>,
}

impl JobLogFile {
    /// `fresh` starts the file again; otherwise records are added to it.
    pub fn open(path: impl AsRef<Path>, fresh: bool) -> std::io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let file =
            if fresh { File::create(&path)? } else { OpenOptions::new().create(true).append(true).open(&path)? };
        Ok(JobLogFile { path, file: Mutex::new(file) })
    }
}

impl JobSink for JobLogFile {
    fn append(&self, record: &JobRecord) {
        let mut text = line(record);
        text.push('\n');
        let mut file = self.file.lock().unwrap_or_else(|e| e.into_inner());
        if file.write_all(text.as_bytes()).is_ok() {
            // A run the host ends still leaves its rows.
            let _ = file.sync_data();
        }
    }
}

/// Records kept in memory (tests, tools).
#[derive(Default)]
pub struct MemorySink(pub Mutex<Vec<JobRecord>>);

impl JobSink for MemorySink {
    fn append(&self, record: &JobRecord) {
        self.0.lock().unwrap().push(record.clone());
    }
}
