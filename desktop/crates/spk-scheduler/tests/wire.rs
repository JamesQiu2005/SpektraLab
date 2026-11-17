//! T3 — the wire round-trips, and WIRE.md says what the code does.
//!
//! macOS only by design (README, "Tests"): the suite verifies the port on the Mac it was ported on.
#![cfg(target_os = "macos")]

use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use spk_scheduler::engine::{Delivery, RenderResult};
use spk_scheduler::job_log::{line, JobLogFile, JobSink};
use spk_scheduler::queue::JobOutcome;
use spk_scheduler::types::{JobId, JobRecord, PixelSize};
use spk_scheduler::wire::*;
use std::sync::Arc;

/// Every ```json wire-example <Type>``` block of WIRE.md, with its type's name.
fn examples() -> Vec<(String, Value)> {
    let text =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/WIRE.md")).expect("WIRE.md beside Cargo.toml");
    let mut out = vec![];
    let mut lines = text.lines();
    while let Some(l) = lines.next() {
        let Some(kind) = l.strip_prefix("```json wire-example ") else { continue };
        let mut body = String::new();
        for l in lines.by_ref() {
            if l.starts_with("```") {
                break;
            }
            body.push_str(l);
            body.push('\n');
        }
        let value: Value =
            serde_json::from_str(&body).unwrap_or_else(|e| panic!("WIRE.md's {kind} example is not JSON: {e}"));
        out.push((kind.trim().to_string(), value));
    }
    out
}

/// `small` is contained in `big`: every key it has, with the same value (an object may gain defaults).
fn contained(small: &Value, big: &Value) -> bool {
    match (small, big) {
        (Value::Object(a), Value::Object(b)) => a.iter().all(|(k, v)| b.get(k).is_some_and(|w| contained(v, w))),
        (Value::Array(a), Value::Array(b)) => a.len() == b.len() && a.iter().zip(b).all(|(x, y)| contained(x, y)),
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        _ => small == big,
    }
}

fn round_trip<T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug>(kind: &str, example: &Value) {
    let typed: T = serde_json::from_value(example.clone())
        .unwrap_or_else(|e| panic!("WIRE.md's {kind} example does not decode: {e}\n{example}"));
    let back = serde_json::to_value(&typed).unwrap();
    assert!(
        contained(example, &back),
        "{kind}: the example is not what the type writes\nexample: {example}\nwritten: {back}"
    );
    let again: T = serde_json::from_value(back).unwrap();
    assert_eq!(typed, again, "{kind} does not survive a round trip");
}

#[test]
fn every_wire_md_example_is_the_code() {
    let all = examples();
    let mut seen = std::collections::BTreeSet::new();
    for (kind, value) in &all {
        seen.insert(kind.clone());
        match kind.as_str() {
            "JobSpec" => round_trip::<JobSpec>(kind, value),
            "JobRequest" => round_trip::<JobRequest>(kind, value),
            "JobSnapshotWire" => round_trip::<JobSnapshotWire>(kind, value),
            "OutcomeWire" => round_trip::<OutcomeWire>(kind, value),
            "BudgetReadingWire" => round_trip::<BudgetReadingWire>(kind, value),
            "FrontendStateMsg" => round_trip::<FrontendStateMsg>(kind, value),
            "JobRecord" => round_trip::<JobRecord>(kind, value),
            other => panic!("WIRE.md has an example of {other}, which the test does not know"),
        }
    }
    for kind in [
        "JobSpec",
        "JobRequest",
        "JobSnapshotWire",
        "OutcomeWire",
        "BudgetReadingWire",
        "FrontendStateMsg",
        "JobRecord",
    ] {
        assert!(seen.contains(kind), "WIRE.md has no example of {kind}");
    }
}

#[test]
fn a_job_spec_takes_the_swift_defaults_and_refuses_what_cannot_be_priced() {
    let spec: JobSpec = serde_json::from_value(
        json!({"frameId": "f", "kind": "export", "tier": "full", "canvas": {"width": 6000, "height": 4000}}),
    )
    .unwrap();
    let job = spec.to_job().unwrap();
    assert!(
        job.bandable && job.gain_maps == 1 && job.print_layers == 0 && job.layers.is_empty() && job.request.is_none()
    );
    let neg: JobSpec = serde_json::from_value(json!({"frameId": "f", "kind": "export", "tier": "full",
        "canvas": {"width": 10, "height": 10}, "printLayers": -3, "scenePlanes": -1}))
    .unwrap();
    let j = neg.to_job().unwrap();
    assert_eq!((j.print_layers, j.scene_planes), (0, 0));
    let empty: JobSpec = serde_json::from_value(
        json!({"frameId": "f", "kind": "export", "tier": "full", "canvas": {"width": 0, "height": 4000}}),
    )
    .unwrap();
    assert!(empty.to_job().is_err());
    assert!(serde_json::from_value::<JobSpec>(
        json!({"frameId": "f", "kind": "print", "tier": "full", "canvas": {"width": 1, "height": 1}})
    )
    .is_err());
}

#[test]
fn every_snapshot_state_has_its_documented_shape() {
    use spk_scheduler::types::{RenderProgress, RenderStage, SnapshotState, WaitReason};
    let cases = [
        (SnapshotState::Queued, json!({"state": "queued"})),
        (
            SnapshotState::Waiting(WaitReason::Camera),
            json!({"state": "waiting", "reason": "camera", "text": "Waiting for the camera to free memory"}),
        ),
        (
            SnapshotState::Running(RenderProgress { stage: RenderStage::Print, fraction: 0.5, band: 1, band_count: 3 }),
            json!({"state": "running", "stage": "Print", "fraction": 0.5, "band": 1, "bandCount": 3}),
        ),
        (SnapshotState::Done, json!({"state": "done"})),
        (SnapshotState::Cancelled, json!({"state": "cancelled"})),
        (SnapshotState::Failed("x".into()), json!({"state": "failed", "message": "x"})),
    ];
    for (state, want) in cases {
        let w = serde_json::to_value(JobStateWire::from(&state)).unwrap();
        assert_eq!(w, want);
        let back: JobStateWire = serde_json::from_value(w).unwrap();
        assert_eq!(back, JobStateWire::from(&state));
    }
}

#[test]
fn an_outcome_carries_its_payload_once_and_its_ids_upper_case() {
    let id: JobId = "6f1d2c3b-8e2a-4a35-9c8b-2d7e5b1a0c11".parse().unwrap();
    assert_eq!(serde_json::to_value(id).unwrap(), json!("6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C11"));
    let mut r = RenderResult::new(0.2, PixelSize::new(4, 2), true);
    r.delivery = Some(Delivery {
        method: "thumbnail".into(),
        result: json!({"image": {"width": 4}}),
        payload: Arc::new(vec![7; 32]),
    });
    let (wire, payload) = OutcomeWire::of(id, &JobOutcome::Finished(r));
    assert_eq!(payload.unwrap().len(), 32);
    let v = serde_json::to_value(&wire).unwrap();
    assert_eq!(v["outcome"], "finished");
    assert_eq!(v["result"]["payloadBytes"], 32);
    assert_eq!(v["result"]["hostResult"]["image"]["width"], 4);
    let (failed, none) = OutcomeWire::of(id, &JobOutcome::Failed("engine_error: x".into()));
    assert!(none.is_none());
    assert_eq!(
        serde_json::to_value(failed).unwrap(),
        json!({"jobId": "6F1D2C3B-8E2A-4A35-9C8B-2D7E5B1A0C11", "outcome": "failed", "message": "engine_error: x"})
    );
}

#[test]
fn the_frontend_message_defaults_to_an_active_window() {
    let m: FrontendStateMsg = serde_json::from_value(json!({})).unwrap();
    assert!(m.foreground);
    let s = m.to_state();
    assert_eq!(s.text(), "camera off; active");
    let drag: FrontendStateMsg =
        serde_json::from_value(json!({"interaction": {"dragging": "print"}, "thermal": "serious", "lowPower": true}))
            .unwrap();
    assert_eq!(drag.to_state().text(), "camera off; dragging print; active; thermal 2; low power");
}

/// A record in the shape the Swift encoder writes it (`JSONEncoder`, `.sortedKeys`, `.iso8601`): integer
/// doubles written bare, a `UUID` upper case, nil fields omitted, a measurement with its own keys.
const SWIFT_LINE: &str = r#"{"appSideBytes":6273531904,"at":"2026-11-13T09:41:07Z","binding":"phone","budgetBytes":1258291200,"cameraReserveBytes":0,"frontend":"camera off; active","jobID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","kind":"canvasDevelop","tier":"live","measuredPeakBytes":1550000000,"measuredSeconds":1.9,"measurement":{"autoExposureEV":0.25,"decodeSeconds":1.1,"decodedBy":"Core Image","deliverSeconds":0.02,"engineHeldAfter":0,"footprintBefore":512000000,"fromRest":true,"highestWired":3000000000,"idlePoolBefore":0,"lowestAppAvailable":9000000000,"lowestPhoneFree":2000000000,"lowestPhoneHeadroom":7000000000,"openPeakFootprint":2000000000,"openSeconds":0.3,"opened":{"height":1707,"width":2560},"peakFootprint":2062000000,"phoneHeadroomBefore":9000000000,"poolHighWater":300000000,"renderSeconds":0.5},"megapixels":4,"mode":"whole","outcome":"done","phoneSideBytes":1400000000,"predictedPeakBytes":2002000000,"predictedPhoneBytes":2054000000,"predictedSeconds":1.35,"ran":"whole","reading":{"appAvailable":9000000000,"compressed":0,"footprint":512000000,"free":7000000000,"inactive":0,"purgeable":0,"wired":3000000000},"waits":[]}"#;

#[test]
fn a_swift_job_record_decodes_and_is_written_back_the_same() {
    let r: JobRecord = serde_json::from_str(SWIFT_LINE).expect("the Mac's line decodes");
    assert_eq!(r.job_id.to_string(), "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    assert_eq!(r.megapixels, 4.0);
    let m = r.measurement.as_ref().unwrap();
    assert_eq!(m.auto_exposure_ev, Some(0.25));
    assert_eq!(m.opened, Some(PixelSize::new(2560, 1707)));
    assert_eq!(m.decoded_by.as_deref(), Some("Core Image"));
    assert!(r.rendered_instead.is_none() && r.opened_instead.is_none());
    // Written back: the same keys and values (sorted, nil fields omitted, the date to the second).
    let ours: Value = serde_json::from_str(&line(&r)).unwrap();
    let theirs: Value = serde_json::from_str(SWIFT_LINE).unwrap();
    assert!(contained(&theirs, &ours) && contained(&ours, &theirs), "ours: {ours}\ntheirs: {theirs}");
    let keys: Vec<&String> = ours.as_object().unwrap().keys().collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(keys, sorted, "a line's keys are sorted");
}

#[test]
fn the_job_log_file_writes_a_line_a_record() {
    let dir = std::env::temp_dir().join(format!("spk-scheduler-log-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("scheduler-log.jsonl");
    let r: JobRecord = serde_json::from_str(SWIFT_LINE).unwrap();
    {
        let log = JobLogFile::open(&path, true).unwrap();
        log.append(&r);
        log.append(&r);
    }
    {
        let log = JobLogFile::open(&path, false).unwrap();
        log.append(&r);
    }
    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 3);
    for l in lines {
        assert_eq!(serde_json::from_str::<JobRecord>(l).unwrap(), r);
    }
    JobLogFile::open(&path, true).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "", "fresh starts the file again");
    std::fs::remove_dir_all(dir).unwrap();
}
