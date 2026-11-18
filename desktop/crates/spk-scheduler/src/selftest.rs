//! `tools/scheduler_selftest.swift`, ported: the scheduler's rules, checked.
//!
//! Every check of the Swift's, in its order and with its numbers, on the simulated engine and injected
//! memory readings. Where the Swift slept on the wall clock this sleeps on tokio's clock, and the runner
//! (`run_all`, the unit tests, `scheduler-selftest`) pauses it: the rules run in virtual time, so nothing
//! here measures this machine and nothing waits on it.
//!
//! **A check that cannot fire is not a check.** `MUTATIONS` are the Swift's 26 broken rules; `run(m)`
//! runs the same checks with one of them broken, and the mutation run requires every one to make at
//! least one check fail.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::time::Instant;

use crate::budget::{Binding, BudgetTuning, MemoryBudget};
use crate::cost_model::{BandGeometry, ComposedOpen, CostModel, RawOpen};
use crate::device_policy::DevicePolicy;
use crate::memory_probe::MemoryReading;
use crate::planner::Planner;
use crate::prefetch::PrefetchPolicy;
use crate::queue::{JobOutcome, Pressure, RenderQueue};
use crate::simulated::SimulatedEngine;
use crate::types::{
    megabytes, Camera, CaptureRule, Composition, FrameId, FrontendState, JobId, JobKind, ParamLayer, PixelSize,
    RenderJob, RenderMode, RenderTier, Scene, SnapshotState, WaitReason,
};

/// The Swift's `Mutation.all`, by name.
pub const MUTATIONS: [&str; 26] = [
    "no-margin",
    "no-camera-reserve",
    "never-yield",
    "ignore-pressure",
    "free-memory",
    "never-trim",
    "wrong-capture-rule",
    "no-second-capture",
    "renders-as-asked",
    "camera-never-warm",
    "camera-stays-warm",
    "darkroom-open-beside-camera",
    "print-layers-free",
    "previews-wait-their-turn",
    "previews-jump-the-queue",
    "previews-not-coalesced",
    "double-open-unpriced",
    "double-hook-ignored",
    "raw-double-priced-as-heif",
    "raw-open-priced-as-heif",
    "prefetch-ignores-ram",
    "mac-allowance-constant",
    "idle-trims-at-once",
    "idle-never-trims",
    "mac-asked-starves",
    "scene-planes-free",
];

/// The checks' tally.
pub struct Checks {
    pub mutation: Option<&'static str>,
    pub passed: usize,
    pub failed: Vec<String>,
}

impl Checks {
    fn m(&self, name: &str) -> bool {
        self.mutation == Some(name)
    }

    fn expect(&mut self, ok: bool, what: impl Into<String>) {
        if ok {
            self.passed += 1;
        } else {
            let what = what.into();
            if self.mutation.is_none() {
                eprintln!("  FAIL  {what}");
            }
            self.failed.push(what);
        }
    }

    fn near(&mut self, a: f64, b: f64, tolerance: f64, what: &str) {
        self.expect((a - b).abs() <= tolerance * b.abs(), format!("{what}: {a:.1} against {b:.1}"));
    }
}

const MB: u64 = 1 << 20;
const FRAME48: PixelSize = PixelSize::new(8064, 6048);
const FRAME12: PixelSize = PixelSize::new(4032, 3024);
const CANVAS: PixelSize = PixelSize::new(2400, 1600);

fn reading(app: u64, phone: u64) -> MemoryReading {
    MemoryReading { app_available: app * MB, free: phone * MB, ..Default::default() }
}

/// The Swift's `job(...)` defaults.
#[derive(Clone)]
struct Opt {
    tier: RenderTier,
    frame: Option<FrameId>,
    layers: Vec<ParamLayer>,
    decodes: bool,
    bandable: bool,
    original: Option<PixelSize>,
    print_layers: i64,
}

fn o() -> Opt {
    Opt {
        tier: RenderTier::Full,
        frame: None,
        layers: vec![],
        decodes: false,
        bandable: true,
        original: None,
        print_layers: 0,
    }
}

fn live() -> Opt {
    Opt { tier: RenderTier::Live, ..o() }
}

fn job(kind: JobKind, size: PixelSize, opt: Opt) -> RenderJob {
    RenderJob::new(opt.frame.unwrap_or_else(FrameId::random), kind, opt.tier, size)
        .with_layers(&opt.layers)
        .with_what("test")
        .decoding(opt.decodes)
        .with_bandable(opt.bandable)
        .with_original(opt.original)
        .with_print_layers(opt.print_layers)
}

async fn sleep_ms(ms: u64) {
    tokio::time::sleep(Duration::from_millis(ms)).await;
}

fn since(t: Instant) -> f64 {
    Instant::now().saturating_duration_since(t).as_secs_f64()
}

fn state_of(s: &RenderQueue, id: JobId) -> Option<SnapshotState> {
    s.snapshot_of(id).map(|x| x.state)
}

fn running(s: &RenderQueue, id: JobId) -> bool {
    s.snapshot_of(id).is_some_and(|x| x.is_running())
}

fn gave_way(s: &RenderQueue, id: JobId) -> bool {
    s.records().iter().any(|r| r.job_id == id && r.outcome.contains("gave way"))
}

/// Whether the job finishes within two seconds: a check must fail on a broken rule, not wait for ever.
async fn finishes(s: &RenderQueue, id: JobId) -> bool {
    let until = Instant::now() + Duration::from_secs(2);
    while Instant::now() < until && s.contains(id) {
        sleep_ms(5).await;
    }
    if s.contains(id) {
        return false;
    }
    s.outcome(id).await.is_finished()
}

/// Megabytes an engine's pool holds idle, for a test to take back from another task (`Held`).
#[derive(Clone, Default)]
struct Held(Arc<AtomicU64>);

impl Held {
    fn new(v: u64) -> Self {
        Held(Arc::new(AtomicU64::new(v)))
    }
    fn value(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
    fn take(&self) -> u64 {
        self.0.swap(0, Ordering::SeqCst)
    }
    fn add(&self, n: u64) -> u64 {
        self.0.fetch_add(n, Ordering::SeqCst) + n
    }
    fn set(&self, v: u64) {
        self.0.store(v, Ordering::SeqCst)
    }
}

/// Every check, with `mutation` broken (`None`: none).
pub async fn run(mutation: Option<&'static str>) -> Checks {
    let mut c = Checks { mutation, passed: 0, failed: vec![] };
    let policy = DevicePolicy::with_cap(48.0);
    let model = CostModel::new(policy.clone());
    let mut tuning = BudgetTuning::default();
    if c.m("no-margin") {
        tuning.margin = -2.0;
    }
    if c.m("no-camera-reserve") {
        tuning.camera_growth_at_48mp = 0;
        tuning.camera_growth_at_12mp = 0;
    }

    // ---- the budget (RFC-036 §6.3) ----
    let idle = FrontendState::default();
    let b1 = MemoryBudget::compute(&reading(3365, 2000), &idle, &tuning, false, false);
    c.near(megabytes(b1.bytes), (2000.0 - 600.0) * 0.85, 0.001, "budget: min(A - r_app, P - r_floor) x (1 - m)");
    c.expect(b1.binding == Binding::Phone, "budget: the phone binds when it is the tighter side");
    let b2 = MemoryBudget::compute(&reading(1000, 6000), &idle, &tuning, false, false);
    c.expect(b2.binding == Binding::Allowance, "budget: the allowance binds when it is the tighter side");
    let shooting =
        FrontendState { camera: Camera::Live { photo_megapixels: 48.0 }, captures_in_flight: 1, ..Default::default() };
    let b3 = MemoryBudget::compute(&reading(6133, 3000), &shooting, &tuning, false, false);
    c.near(
        megabytes(b3.bytes),
        (3000.0 - 2.0 * 750.0 - 600.0) * 0.85,
        0.001,
        "budget: the camera's growth (750 MB at 48 MP) is reserved per capture, plus one",
    );
    let b3warm = MemoryBudget::compute(&reading(6133, 3000), &shooting, &tuning, true, false);
    c.near(
        megabytes(b3warm.bytes),
        (3000.0 - 2.0 * 420.0 - 600.0) * 0.85,
        0.001,
        "budget: once the camera has delivered a photo, the next one's growth is reserved at 420 MB",
    );
    c.expect(
        tuning.camera_growth(12.0, true) == tuning.camera_growth(12.0, false),
        "budget: at 12 MP the reserve is 420 MB before the first photo and after",
    );
    let b4 = MemoryBudget::compute(&reading(6133, 200), &shooting, &tuning, false, false);
    let ok = b4.bytes == 0 || c.m("no-camera-reserve");
    c.expect(ok, "budget: never negative, and nothing is left when the phone has nothing");

    // ---- the cost model against RFC-036 §2.2's table ----
    let full48 = job(JobKind::Export, FRAME48, o());
    let full12 = job(JobKind::Export, FRAME12, o());
    let bands = |rows| RenderMode::Bands { rows };
    c.near(
        megabytes(model.seed(&full48, &bands(1120)).peak_bytes),
        1484.0,
        0.03,
        "cost: 48 MP in 1,120-row bands peaks at ~1,484 MB",
    );
    c.near(
        megabytes(model.seed(&full48, &bands(280)).peak_bytes),
        1019.0,
        0.03,
        "cost: 48 MP in 280-row bands peaks at ~1,019 MB",
    );
    c.near(
        megabytes(model.seed(&full12, &bands(1512)).peak_bytes),
        804.0,
        0.04,
        "cost: 12 MP in 1,512-row bands peaks at 786-822 MB (iPhone 17)",
    );
    c.near(
        megabytes(model.seed(&full12, &bands(280)).peak_bytes),
        402.0,
        0.04,
        "cost: 12 MP in 280-row bands peaks at 398-407 MB (iPhone 17)",
    );
    c.near(
        megabytes(model.seed(&full48, &RenderMode::Whole).peak_bytes),
        3239.0,
        0.03,
        "cost: 48 MP whole peaks at ~3,239 MB",
    );
    c.near(
        megabytes(model.seed(&full12, &RenderMode::Whole).peak_bytes),
        1004.0,
        0.03,
        "cost: 12 MP whole peaks at ~1,004 MB",
    );
    c.near(
        model.seed(&full48, &bands(1120)).seconds,
        2.28 + 0.137 * 6.0,
        0.03,
        "cost: time is t0 + c_band x bands (48 MP on the iPhone 17: 2.28 s + 137 ms a band)",
    );
    c.near(
        model.seed(&full12, &RenderMode::Whole).seconds,
        0.69 + 0.060,
        0.03,
        "cost: a whole render is one band (12 MP on the iPhone 17: 0.75 s)",
    );
    let mut slower = policy.clone();
    slower.time_ratio = 2.0;
    c.near(
        CostModel::new(slower).seed(&full48, &bands(1120)).seconds,
        2.0 * (2.28 + 0.137 * 6.0),
        0.03,
        "cost: another device's times are the iPhone 17's by its ratio",
    );
    let print = vec![ParamLayer::Print];
    let shoot = vec![ParamLayer::Shoot];
    c.near(
        model
            .seed(
                &job(JobKind::CanvasReprint, PixelSize::new(2560, 1920), Opt { layers: print.clone(), ..live() }),
                &RenderMode::Whole,
            )
            .seconds,
        0.055,
        0.05,
        "cost: a reprint at 2,560 px is ~55 ms (iPhone 17)",
    );
    c.near(
        model
            .seed(
                &job(JobKind::CanvasDevelop, PixelSize::new(2560, 1920), Opt { layers: shoot.clone(), ..live() }),
                &RenderMode::Whole,
            )
            .seconds,
        0.21,
        0.05,
        "cost: a film-side develop at 2,560 px is ~210 ms (iPhone 17)",
    );
    c.near(
        megabytes(model.seed(&job(JobKind::Export, FRAME48, Opt { decodes: true, ..o() }), &bands(280)).peak_bytes),
        1181.0,
        0.03,
        "cost: a 48 MP HEIF in 280-row bands peaks at ~1,181 MB (iPhone 17), which is its open",
    );
    c.near(
        megabytes(model.seed(&job(JobKind::Export, FRAME48, Opt { decodes: true, ..o() }), &bands(1008)).peak_bytes),
        1585.0,
        0.03,
        "cost: and in 1,008-row bands at ~1,585 MB, which is its render with what the decode leaves behind",
    );
    c.near(
        megabytes(model.seed(&job(JobKind::Shot, FRAME12, Opt { decodes: true, ..o() }), &bands(144)).peak_bytes),
        394.0,
        0.06,
        "cost: a 12 MP HEIF's open is 355-406 MB (iPhone 17)",
    );
    c.near(
        BandGeometry::new(FRAME48).bytes_per_row as f64 / MB as f64,
        0.554,
        0.01,
        "cost: a band row is 6 planes x 12 B x width (0.554 MB at 48 MP)",
    );

    // ---- Settings' Preview size up to 3,840 px ----
    let edges = DevicePolicy::PREVIEW_EDGES;
    c.expect(
        edges.contains(&3840) && edges.iter().max() == Some(&3840),
        format!("preview: Settings offers 3,840 px, and it is the largest ({edges:?})"),
    );
    let mut sorted = edges;
    sorted.sort();
    c.expect(edges.contains(&2560) && edges == sorted, "preview: 2,560 px is still offered, and the list is in order");
    c.expect(
        edges.iter().all(|e| (800..=8192).contains(e)),
        "preview: every size is one the wire takes (preview_long_edge 800...8192)",
    );
    let page2560 = PixelSize::new(2560, 1920);
    let page3840 = PixelSize::new(3840, 2880);
    let dev2560 =
        model.seed(&job(JobKind::CanvasDevelop, page2560, Opt { layers: shoot.clone(), ..live() }), &RenderMode::Whole);
    let dev3840 =
        model.seed(&job(JobKind::CanvasDevelop, page3840, Opt { layers: shoot.clone(), ..live() }), &RenderMode::Whole);
    c.near(
        dev3840.peak_bytes as f64 / dev2560.peak_bytes as f64,
        2.25,
        0.01,
        "preview: a 3,840 px develop is forecast at 2.25x the memory of a 2,560 px one",
    );
    c.near(dev3840.seconds / dev2560.seconds, 2.25, 0.01, "preview: and at 2.25x its time");
    let raw_job = |canvas: PixelSize| {
        job(
            JobKind::CanvasDevelop,
            canvas,
            Opt { layers: shoot.clone(), decodes: true, original: Some(PixelSize::new(8256, 5504)), ..live() },
        )
        .with_raw_decode(true)
    };
    let raw3840 = model.seed(&raw_job(PixelSize::new(3840, 2560)), &RenderMode::Whole);
    let raw2560 = model.seed(&raw_job(PixelSize::new(2560, 1707)), &RenderMode::Whole);
    let raw_alone = RawOpen::BASE + RawOpen::BYTES_PER_PIXEL * 8256.0 * 5504.0;
    c.expect(
        raw2560.peak_bytes == raw_alone as u64,
        format!(
            "preview: a 45 MP RAW's first open at 2,560 px is the decode's price alone ({} MB)",
            megabytes(raw2560.peak_bytes)
        ),
    );
    c.near(
        megabytes(raw3840.peak_bytes),
        raw_alone / 1_048_576.0 + 560.0 * (3840.0 * 2560.0 / (2560.0 * 1920.0)) - 560.0,
        0.01,
        "preview: at 3,840 px it is that and the canvas's growth over 2,560 x 1,920 (measured 2,024-2,230)",
    );
    c.expect(
        megabytes(raw3840.peak_bytes) >= 2230.0,
        "preview: never under the measured 45 MP first open at 3,840 px (2,230 MB)",
    );

    // ---- a pair's frames that print as their own (`RenderJob.printLayers`) ----
    let own = |n: i64| if mutation == Some("print-layers-free") { 0 } else { n };
    let page = PixelSize::new(2560, 1920);
    let page_pixels = 2560u64 * 1920;
    let one_print =
        model.seed(&job(JobKind::CanvasReprint, page, Opt { layers: print.clone(), ..live() }), &RenderMode::Whole);
    let one_own = model.seed(
        &job(JobKind::CanvasReprint, page, Opt { layers: print.clone(), print_layers: own(1), ..live() }),
        &RenderMode::Whole,
    );
    let two_own = model.seed(
        &job(JobKind::CanvasReprint, page, Opt { layers: print.clone(), print_layers: own(2), ..live() }),
        &RenderMode::Whole,
    );
    c.expect(one_own.peak_bytes == one_print.peak_bytes + 8 * page_pixels,
        format!("layers: a job with a frame's own print holds one more result, 8 B a pixel of its canvas ({} MB against {})",
            megabytes(one_own.peak_bytes), megabytes(one_print.peak_bytes)));
    c.expect(
        two_own.peak_bytes == one_own.peak_bytes,
        "layers: and no more for a second: one layer's print is alive at a time",
    );
    c.expect(
        one_own.phone_bytes - one_own.peak_bytes == one_print.phone_bytes - one_print.peak_bytes,
        "layers: the source plane is the job's, whatever it prints",
    );
    c.near(one_own.seconds - one_print.seconds, 0.055, 0.02, "layers: one is a reprint more (55 ms at 2,560 px)");
    c.near(two_own.seconds - one_print.seconds, 0.110, 0.02, "layers: two are two");
    c.expect(
        model.seed(
            &job(JobKind::CanvasReprint, page, Opt { layers: print.clone(), print_layers: 0, ..live() }),
            &RenderMode::Whole,
        ) == one_print,
        "layers: a job with none costs what it did",
    );
    c.expect(
        job(JobKind::CanvasReprint, page, Opt { print_layers: -3, ..live() }).print_layers == 0,
        "layers: there are never fewer than none",
    );
    let export12 = job(JobKind::Export, FRAME12, Opt { decodes: true, ..o() });
    let export12own = job(JobKind::Export, FRAME12, Opt { decodes: true, print_layers: own(2), ..o() });
    let pixels12 = 4032u64 * 3024;
    c.expect(
        model.seed(&export12own, &RenderMode::Whole).peak_bytes
            == model.seed(&export12, &RenderMode::Whole).peak_bytes + 8 * pixels12,
        "layers: an export's second result is 8 B a pixel too (93 MB at 12 MP)",
    );
    c.near(
        model.seed(&export12own, &RenderMode::Whole).seconds - model.seed(&export12, &RenderMode::Whole).seconds,
        2.0 * 0.055 * 12.19 / 4.9152,
        0.02,
        "layers: whole, an export's layer is a reprint at its size",
    );
    let bands12 = bands(760);
    c.near(
        model.seed(&export12own, &bands12).seconds - model.seed(&export12, &bands12).seconds,
        2.0 * (0.69 + 0.060 * BandGeometry::new(FRAME12).band_count(760) as f64),
        0.02,
        "layers: in bands each layer is the develop again (t0 + c_band x bands)",
    );

    // ---- a double exposure's open (`RenderJob.composition`, RFC-048 §5) ----
    let composed = |j: RenderJob, decodes: Vec<PixelSize>, scratch: u64| {
        if mutation == Some("double-open-unpriced") {
            j
        } else {
            j.composed(Some(Composition { decodes, scratch_bytes: scratch, raw: false }))
        }
    };
    {
        let mp48 = FRAME48.pixels() / 1e6;
        let mp12 = FRAME12.pixels() / 1e6;
        let px48 = FRAME48.pixels();
        let px12 = FRAME12.pixels();
        let photo = job(JobKind::Export, FRAME48, Opt { decodes: true, original: Some(FRAME48), ..o() });
        let double = composed(photo.clone(), vec![FRAME48, FRAME48], 64 * MB);
        for mode in [bands(280), RenderMode::Whole] {
            let p = model.seed(&photo, &mode);
            let d = model.seed(&double, &mode);
            let open = ComposedOpen::FULL_PIECE_BYTES_PER_PIXEL * px48
                + ComposedOpen::FULL_OTHER_BASE
                + ComposedOpen::FULL_OTHER_BYTES_PER_PIXEL * px48;
            c.expect(d.peak_bytes == p.peak_bytes.max(open as u64 + 64 * MB),
                format!("double: two 48 MP exposures open at the piece, one decode and the scratch band, {} ({} MB against {})",
                    mode.name(), megabytes(d.peak_bytes), megabytes(p.peak_bytes)));
            c.near(
                d.seconds - p.seconds,
                2.0 * ComposedOpen::FULL_OTHER_SECONDS_PER_MP * mp48 - 0.009 * mp48,
                0.001,
                &format!("double: and both decodes' time, {}", mode.name()),
            );
            c.expect(
                d.phone_bytes - d.peak_bytes == p.phone_bytes - p.peak_bytes,
                format!("double: the source plane is the frame's, {}", mode.name()),
            );
        }
        let small = job(JobKind::Export, FRAME12, Opt { decodes: true, original: Some(FRAME48), ..o() });
        let mixed = composed(
            job(JobKind::Export, FRAME12, Opt { decodes: true, original: Some(FRAME48), ..o() }),
            vec![FRAME48, FRAME12],
            64 * MB,
        );
        let mixed_open = ComposedOpen::FULL_PIECE_BYTES_PER_PIXEL * px12
            + ComposedOpen::FULL_OTHER_BASE
            + ComposedOpen::FULL_OTHER_BYTES_PER_PIXEL * px48;
        c.expect(model.seed(&mixed, &bands(280)).peak_bytes == model.seed(&small, &bands(280)).peak_bytes.max(mixed_open as u64 + 64 * MB),
            "double: a 48 MP and a 12 MP exposure open at the larger decode's peak and the scratch, not the sum of both");
        c.near(
            model.seed(&mixed, &RenderMode::Whole).seconds - model.seed(&small, &RenderMode::Whole).seconds,
            ComposedOpen::FULL_OTHER_SECONDS_PER_MP * (mp48 + mp12) - 0.009 * mp12,
            0.001,
            "double: their decodes' times are summed, each at its own size",
        );
        let noted = |tier: RenderTier, bottom_raw: bool, edge: Option<i64>| {
            vec![
                Composition::decode(tier, FRAME48, FRAME48, edge, bottom_raw),
                Composition::decode(tier, FRAME12, FRAME12, None, false),
            ]
        };
        c.expect(
            noted(RenderTier::Full, true, Some(4032)) == vec![FRAME48, FRAME12],
            "double: a 48 MP RAW bottom asked at 4032 px is priced whole, as Core Image holds it",
        );
        c.expect(
            noted(RenderTier::Full, false, Some(4032)) == vec![FRAME12, FRAME12],
            "double: a 48 MP HEIF bottom asked at 4032 px is priced at that size, as ImageIO reduces it",
        );
        c.expect(
            noted(RenderTier::Full, true, None) == vec![FRAME48, FRAME12]
                && noted(RenderTier::Full, false, None) == vec![FRAME48, FRAME12],
            "double: a decode made whole is priced whole, RAW or not",
        );
        c.expect(
            noted(RenderTier::Live, true, Some(4032)) == vec![FRAME48, FRAME12]
                && noted(RenderTier::Preview, false, Some(4032)) == vec![FRAME48, FRAME12],
            "double: below the full tier each decode is priced by its original, RAW or not",
        );
        let raw_double =
            job(JobKind::Export, FRAME12, Opt { decodes: true, original: Some(FRAME48), ..o() }).composed(Some(
                Composition { decodes: noted(RenderTier::Full, true, Some(4032)), scratch_bytes: 64 * MB, raw: false },
            ));
        let heif_double =
            job(JobKind::Export, FRAME12, Opt { decodes: true, original: Some(FRAME48), ..o() }).composed(Some(
                Composition { decodes: noted(RenderTier::Full, false, Some(4032)), scratch_bytes: 64 * MB, raw: false },
            ));
        c.expect(
            model.seed(&raw_double, &bands(280)) == model.seed(&mixed, &bands(280)),
            "double: the darkroom's composition of a 48 MP RAW over a 12 MP photo is the one priced above",
        );
        let raw_open = model.seed(&raw_double, &bands(280)).peak_bytes as f64;
        let heif_open = model.seed(&heif_double, &bands(280)).peak_bytes as f64;
        c.near(
            raw_open - heif_open,
            ComposedOpen::FULL_OTHER_BYTES_PER_PIXEL * (px48 - px12),
            0.001,
            "double: a decode made whole is priced by its whole original, dearer than ImageIO's reduced one",
        );
        let raw_full = job(JobKind::Export, FRAME12, Opt { decodes: true, original: Some(FRAME48), ..o() }).composed(
            Some(Composition { decodes: noted(RenderTier::Full, true, Some(4032)), scratch_bytes: 64 * MB, raw: true }),
        );
        c.near(
            model.seed(&raw_full, &bands(280)).peak_bytes as f64 - raw_open,
            ComposedOpen::FULL_RAW_BASE - ComposedOpen::FULL_OTHER_BASE
                + (ComposedOpen::FULL_RAW_BYTES_PER_PIXEL - ComposedOpen::FULL_OTHER_BYTES_PER_PIXEL) * px48,
            1.0,
            "double: a RAW's full open is Core Image's whole decode, priced apart from a HEIF's",
        );
        let page = PixelSize::new(1280, 960);
        let preview = job(JobKind::CanvasDevelop, page, Opt { decodes: true, original: Some(FRAME48), ..live() });
        let preview_double = composed(preview.clone(), vec![FRAME48, FRAME12], 1280 * 960 * 16);
        let pp = model.seed(&preview, &RenderMode::Whole);
        let pd = model.seed(&preview_double, &RenderMode::Whole);
        c.expect(pd.peak_bytes == (ComposedOpen::BELOW_OTHER_BASE + ComposedOpen::BELOW_OTHER_BYTES_PER_PIXEL * px48) as u64 + 1280 * 960 * 16,
            format!("double: a page's open of two exposures is the dearer original's and the scratch band ({} MB against {})",
                megabytes(pd.peak_bytes), megabytes(pp.peak_bytes)));
        c.near(
            pd.seconds - pp.seconds,
            ComposedOpen::BELOW_OTHER_SECONDS_PER_MP * (mp48 + mp12) - 0.003 * mp48,
            0.001,
            "double: and both decodes' time, by their originals",
        );
        let key_double = CostModel::key(&double, &RenderMode::Whole);
        c.expect(
            key_double != CostModel::key(&photo, &RenderMode::Whole) && key_double.ends_with("|double"),
            format!("double: its open's corrections are learned apart ({key_double})"),
        );
        c.expect(
            !CostModel::key(&photo, &RenderMode::Whole).contains("double"),
            "double: a photograph's key is what it was",
        );
        let mut raw_composition =
            Composition { decodes: vec![FRAME48, FRAME12], scratch_bytes: 1280 * 960 * 16, raw: true };
        if mutation == Some("raw-double-priced-as-heif") {
            raw_composition.raw = false;
        }
        let preview_raw = preview.composed(Some(raw_composition));
        let pr = model.seed(&preview_raw, &RenderMode::Whole);
        c.near(
            pr.peak_bytes as f64 - pd.peak_bytes as f64,
            ComposedOpen::BELOW_RAW_BASE - ComposedOpen::BELOW_OTHER_BASE
                + (ComposedOpen::BELOW_RAW_BYTES_PER_PIXEL - ComposedOpen::BELOW_OTHER_BYTES_PER_PIXEL) * px48,
            1.0,
            "double: a RAW's page open is priced as Core Image's decode, over a HEIF's",
        );
        let key_raw = CostModel::key(&preview_raw, &RenderMode::Whole);
        c.expect(
            key_raw != CostModel::key(&preview_double, &RenderMode::Whole) && key_raw.ends_with("|double|raw"),
            format!("double: a RAW's open is learned apart from a HEIF's ({key_raw})"),
        );
        c.expect(
            !CostModel::key(&preview_double, &RenderMode::Whole).contains("raw"),
            "double: a HEIF double's key is what it was",
        );
        let reprint = job(JobKind::CanvasReprint, page, Opt { layers: print.clone(), ..live() });
        let reprint_double =
            reprint.composed(Some(Composition { decodes: vec![FRAME48, FRAME12], scratch_bytes: 64 * MB, raw: false }));
        c.expect(
            model.seed(&reprint_double, &RenderMode::Whole) == model.seed(&reprint, &RenderMode::Whole)
                && CostModel::key(&reprint_double, &RenderMode::Whole) == CostModel::key(&reprint, &RenderMode::Whole),
            "double: a job that opens nothing costs what any reprint does",
        );
        c.expect(
            model.seed(&photo.composed(None), &RenderMode::Whole) == model.seed(&photo, &RenderMode::Whole),
            "double: a job with no composition costs what it did",
        );
    }

    // ---- a photograph's RAW, first opened below the full tier (`RenderJob.rawDecode`, `RawOpen`) ----
    {
        let page = PixelSize::new(2560, 1707);
        let measured: [(&str, PixelSize, f64); 7] = [
            ("8 MP ORF (decoder 7)", PixelSize::new(3264, 2448), 320.0),
            ("24 MP A7 III ARW", PixelSize::new(6000, 4000), 573.0),
            ("24 MP S1M2 RW2", PixelSize::new(6000, 4000), 977.0),
            ("45 MP Z7 II NEF", PixelSize::new(8256, 5504), 922.0),
            ("60 MP A7R V ARW", PixelSize::new(9504, 6336), 706.0),
            ("60 MP Q3 DNG", PixelSize::new(9520, 6336), 2317.0),
            ("102 MP GFX100RF RAF", PixelSize::new(11648, 8736), 2385.0),
        ];
        let raw_flag = mutation != Some("raw-open-priced-as-heif");
        for (what, original, mb) in measured {
            let first = job(JobKind::CanvasDevelop, page, Opt { decodes: true, original: Some(original), ..live() })
                .with_raw_decode(raw_flag);
            let priced = megabytes(model.seed(&first, &RenderMode::Whole).peak_bytes);
            c.expect(priced >= mb && priced <= 3.5 * mb,
                format!("raw open: a {what}'s first open is priced at or over what it took, and under 3.5x ({} MB against {})", priced as i64, mb as i64));
        }
        let raw = job(
            JobKind::CanvasDevelop,
            page,
            Opt { decodes: true, original: Some(PixelSize::new(6000, 4000)), ..live() },
        )
        .with_raw_decode(raw_flag);
        let heif = job(
            JobKind::CanvasDevelop,
            page,
            Opt { decodes: true, original: Some(PixelSize::new(6000, 4000)), ..live() },
        );
        let key = CostModel::key(&raw, &RenderMode::Whole);
        c.expect(
            key != CostModel::key(&heif, &RenderMode::Whole) && key.ends_with("|raw"),
            format!("raw open: learned apart from a HEIF's of the same size ({key})"),
        );
        c.expect(!CostModel::key(&heif, &RenderMode::Whole).contains("raw"), "raw open: a HEIF's key is what it was");
        let mut learner = CostModel::new(policy.clone());
        learner.learn(&raw, &RenderMode::Whole, 4 * model.seed(&raw, &RenderMode::Whole).peak_bytes, 0.5);
        c.expect(
            learner.estimate(&heif, &RenderMode::Whole) == model.estimate(&heif, &RenderMode::Whole),
            "raw open: a first open's measurement leaves a HEIF's price alone",
        );
    }

    // ---- scene layers: a job's planes (`RenderJob.scenePlanes`, RFC-052 §8.5) ----
    {
        let mbf = 1_048_576.0;
        let full = PixelSize::new(8256, 5504);
        let plane: i64 = 4096 * 2731 * 2;
        let free = mutation == Some("scene-planes-free");
        let layered = |n: i64, tier: RenderTier, canvas: PixelSize| {
            let kind = if tier == RenderTier::Full { JobKind::Export } else { JobKind::CanvasDevelop };
            let opt = Opt {
                tier,
                decodes: tier == RenderTier::Full,
                original: (tier == RenderTier::Full).then_some(full),
                ..o()
            };
            job(kind, canvas, opt)
                .with_scene_planes(if free { 0 } else { n }, if free { 0 } else { (n * plane) as u64 })
        };
        for (tier, canvas) in [(RenderTier::Live, PixelSize::new(2560, 1707)), (RenderTier::Full, full)] {
            let none = model.seed(&layered(0, tier, canvas), &RenderMode::Whole);
            for n in [1i64, 4, 8] {
                let with = model.seed(&layered(n, tier, canvas), &RenderMode::Whole);
                let added = with.peak_bytes as f64 - none.peak_bytes as f64;
                c.expect(
                    (added - (n * plane) as f64).abs() < mbf && (n * plane) as f64 / mbf <= 22.0 * n as f64,
                    format!(
                        "scene layers: {n} plane(s) at the {} tier add their {} MB ({} MB)",
                        tier.raw_value(),
                        (n * plane) >> 20,
                        (added / mbf) as i64
                    ),
                );
                c.expect(
                    with.seconds > none.seconds,
                    format!("scene layers: {n} at the {} tier take the node's time", tier.raw_value()),
                );
            }
        }
        let node8 = model.seed(&layered(8, RenderTier::Full, full), &RenderMode::Whole).seconds
            - model.seed(&layered(0, RenderTier::Full, full), &RenderMode::Whole).seconds;
        c.expect(
            free || (node8 > 0.005 && node8 < 0.02),
            format!("scene layers: eight at 45 MP, the node's 8.0–8.5 ms measured ({:.1} ms)", node8 * 1000.0),
        );
    }

    // ---- the full-size prefetch, by the machine's memory (`PrefetchPolicy`) ----
    {
        let gb: u64 = 1 << 30;
        let ram = |b: u64| if mutation == Some("prefetch-ignores-ram") { 36 * gb } else { b };
        let small = PrefetchPolicy::new(ram(16 * gb));
        let smaller = PrefetchPolicy::new(ram(8 * gb));
        let large = PrefetchPolicy::new(36 * gb);
        c.expect(small.offsets(1, 2) == vec![1], format!("prefetch: 16 GB makes +1 only ({:?})", small.offsets(1, 2)));
        c.expect(
            small.offsets(-1, 2) == vec![-1],
            format!("prefetch: 16 GB, going back, makes the frame behind only ({:?})", small.offsets(-1, 2)),
        );
        c.expect(
            smaller.offsets(1, 2) == vec![1],
            format!("prefetch: 8 GB makes +1 only ({:?})", smaller.offsets(1, 2)),
        );
        c.expect(
            PrefetchPolicy::new(ram(17_179_869_184)).offsets(1, 2) == vec![1],
            "prefetch: a 16 GB Mac's physical memory as it reports it (17,179,869,184 B) is a 16 GB Mac",
        );
        c.expect(
            large.offsets(1, 2) == vec![1, -1, 2, -2],
            format!("prefetch: 36 GB keeps +1, -1, +2, -2 ({:?})", large.offsets(1, 2)),
        );
        c.expect(large.offsets(-1, 2) == vec![-1, 1, -2, 2], "prefetch: 36 GB going back keeps -1, +1, -2, +2");
        let cost = 2 * gb;
        c.expect(
            !small.allows(cost, cost + small.floor_bytes - 1),
            "prefetch: none when the headroom left would be under the floor",
        );
        c.expect(small.allows(cost, cost + small.floor_bytes), "prefetch: one when the headroom left is the floor");
        c.expect(!large.allows(cost, cost + large.floor_bytes - 1), "prefetch: above 16 GB too, none under the floor");
        c.expect(
            small.floor_bytes >= 2 * gb,
            format!(
                "prefetch: the floor holds the critical level and a first open ({} MB)",
                megabytes(small.floor_bytes)
            ),
        );
    }

    // ---- the band arithmetic against the engine's (probes/engine/band_asked.py, 2026-10-03) ----
    let engine_cuts =
        |g: &BandGeometry, budget: u64, overhead: i64| (((budget / g.bytes_per_row) as i64 - overhead) / 8 * 8).max(8);
    let upright48 = PixelSize::new(6048, 8064);
    let upright12 = PixelSize::new(3024, 4032);
    for (size, overhead) in [(FRAME48, 722), (FRAME12, 426), (upright48, 722), (upright12, 426)] {
        let g = BandGeometry::new(size);
        for mode in Planner::ladder(&job(JobKind::Export, size, o())) {
            let RenderMode::Bands { rows } = mode else { continue };
            let cut = engine_cuts(&g, g.engine_budget_bytes(rows), overhead);
            c.expect(
                cut == rows,
                format!(
                    "bands: {} x {}, {rows} rows asked is {rows} rows cut (the engine would cut {cut})",
                    size.width, size.height
                ),
            );
            c.expect(
                g.band_count(cut) == g.band_count(rows),
                format!(
                    "bands: {} x {}, {rows} rows is {} bands predicted and {} run",
                    size.width,
                    size.height,
                    g.band_count(rows),
                    g.band_count(cut)
                ),
            );
        }
    }

    // ---- the planner (§6.4, §6.7) ----
    let no_margin = mutation == Some("no-margin");
    let budget = |mb: u64| {
        MemoryBudget::compute(
            &reading(100_000, mb),
            &idle,
            &BudgetTuning::with(0, 0, if no_margin { -2.0 } else { 0.0 }),
            false,
            false,
        )
    };
    let plan = |j: &RenderJob, b: &MemoryBudget, f: &FrontendState| Planner::plan_default(j, b, f, &model);
    c.expect(plan(&full12, &budget(1445), &idle).mode == RenderMode::Whole, "plan: 12 MP runs whole when it fits");
    let plane48 = (12u64 * 8064 * 6048) as f64 / MB as f64;
    c.near(
        megabytes(model.seed(&full48, &bands(1008)).phone_bytes)
            - megabytes(model.seed(&full48, &bands(1008)).peak_bytes),
        plane48,
        0.001,
        "cost: a 48 MP job takes 558 MiB more from the phone than its footprint shows",
    );
    let p48 = plan(&full48, &budget(2003), &idle);
    if let RenderMode::Bands { rows } = p48.mode {
        c.expect(p48.budget.fits(&p48.estimate, 1.0), "plan: the chosen mode's cost fits the budget");
        c.expect(
            rows == 1008,
            format!("plan: 48 MP in 2,003 MB of phone takes the largest band that fits (6 of 1,008 rows), got {rows}"),
        );
    } else {
        c.expect(false, format!("plan: 48 MP in 2,003 MB runs in bands, got {}", p48.mode.name()));
    }
    c.expect(
        plan(&full48, &budget(1445), &idle).mode == RenderMode::Wait(WaitReason::Memory),
        "plan: the phone's side counts the source plane (48 MP does not fit in 1,445 MB of phone)",
    );
    c.expect(
        plan(&full48, &budget(1900), &idle).mode == bands(760),
        "plan: and in 1,900 MB it is 760-row bands, not the 1,008 its footprint alone would allow",
    );
    let tight = MemoryBudget::compute(
        &reading(1650, 100_000),
        &idle,
        &BudgetTuning::with(150, 0, if no_margin { -2.0 } else { 0.0 }),
        false,
        false,
    );
    c.expect(
        plan(&full48, &tight, &idle).mode == bands(1008),
        "plan: the allowance's side is the footprint alone (1,008-row bands in 1,500 MB of allowance)",
    );
    c.expect(
        plan(&full48, &budget(200), &idle).mode == RenderMode::Wait(WaitReason::Memory),
        "plan: a job that cannot fit waits; it does not gamble",
    );
    let floor = BandGeometry::new(FRAME48).floor_rows;
    c.expect(
        Planner::ladder(&full48).iter().all(|m| if let RenderMode::Bands { rows } = m { *rows >= floor } else { true }),
        "plan: no band is shorter than its own halo's floor (~280 rows at 48 MP)",
    );
    c.expect(
        Planner::ladder(&job(JobKind::CanvasDevelop, CANVAS, live())) == vec![RenderMode::Whole],
        "plan: a canvas is one piece",
    );
    let fits_whole = megabytes(model.seed(&export12, &RenderMode::Whole).phone_bytes).ceil() as u64 + 1;
    c.expect(plan(&export12, &budget(fits_whole), &idle).mode == RenderMode::Whole && plan(&export12own, &budget(fits_whole), &idle).mode != RenderMode::Whole,
        format!("layers: a pair that prints a frame for itself is planned with its second result (whole without, not whole with, in {fits_whole} MB)"));
    let cropped = job(JobKind::Export, FRAME48, Opt { bandable: false, ..o() });
    c.expect(Planner::ladder(&cropped) == vec![RenderMode::Whole], "plan: a frame the engine cannot band is one piece");
    c.expect(
        plan(&cropped, &budget(1500), &idle).mode == RenderMode::Wait(WaitReason::Memory),
        "plan: a cropped 48 MP frame waits in 1,500 MB; it is not planned as bands the engine would not cut",
    );
    c.expect(
        plan(&cropped, &budget(3900), &idle).mode == RenderMode::Whole,
        "plan: and runs whole when a whole render fits",
    );
    let live48 = FrontendState { camera: Camera::Live { photo_megapixels: 48.0 }, ..Default::default() };
    let decodes = Opt { decodes: true, ..o() };
    c.expect(
        plan(&job(JobKind::Shot, FRAME48, decodes.clone()), &budget(8000), &live48).mode
            == RenderMode::Wait(WaitReason::Camera),
        "plan: a 48 MP shot waits while the camera is live (the kill, twice)",
    );
    c.expect(
        plan(&job(JobKind::Shot, FRAME12, decodes.clone()), &budget(8000), &live48).mode
            != RenderMode::Wait(WaitReason::Camera),
        "plan: a 12 MP shot develops behind the viewfinder",
    );
    c.expect(
        plan(&full12, &budget(8000), &live48).mode == RenderMode::Wait(WaitReason::Camera),
        "plan: an export waits while the camera is live",
    );
    let in_flight = FrontendState { captures_in_flight: 1, ..live48.clone() };
    c.expect(
        plan(&job(JobKind::Shot, FRAME12, o()), &budget(8000), &in_flight).mode
            == RenderMode::Wait(WaitReason::Capture),
        "plan: everything holds while a photo is in flight",
    );
    let wrong_rule = mutation == Some("wrong-capture-rule");
    let rule = |r: CaptureRule| {
        if wrong_rule {
            if r == CaptureRule::Shares {
                CaptureRule::Stops
            } else {
                CaptureRule::Shares
            }
        } else {
            r
        }
    };
    let preview = job(JobKind::Shot, CANVAS, Opt { tier: RenderTier::Preview, decodes: true, ..o() });
    let plan_r = |j: &RenderJob, b: &MemoryBudget, f: &FrontendState, r: CaptureRule| {
        Planner::plan(j, b, f, &model, 1.0, r, true)
    };
    c.expect(
        plan_r(&preview, &budget(8000), &in_flight, rule(CaptureRule::Stops)).mode
            == RenderMode::Wait(WaitReason::Capture),
        "capture: under `stops` no develop starts while a photo is in flight",
    );
    c.expect(
        plan_r(&preview, &budget(8000), &in_flight, rule(CaptureRule::Holds)).mode
            == RenderMode::Wait(WaitReason::Capture),
        "capture: under `holds` none starts either",
    );
    c.expect(
        plan_r(&preview, &budget(8000), &in_flight, rule(CaptureRule::Shares)).mode == RenderMode::Whole,
        "capture: under `shares` a preview develops beside a photo in flight when the budget has room",
    );
    c.expect(
        plan_r(&job(JobKind::Shot, FRAME12, decodes.clone()), &budget(8000), &in_flight, CaptureRule::Shares).mode
            == RenderMode::Wait(WaitReason::Capture),
        "capture: a full-size job never starts under a photo, whatever the rule",
    );
    c.expect(
        plan_r(&preview, &budget(300), &in_flight, CaptureRule::Shares).mode == RenderMode::Wait(WaitReason::Camera),
        "capture: and under `shares` a preview that does not fit waits for the camera",
    );
    let shot_preview =
        job(JobKind::Shot, PixelSize::new(2400, 1800), Opt { tier: RenderTier::Preview, decodes: true, ..o() });
    let shot_cost = model.seed(&shot_preview, &RenderMode::Whole);
    c.expect(megabytes(shot_cost.peak_bytes) >= 455.0 && megabytes(shot_cost.peak_bytes) <= 455.0 * 1.25,
        format!("cost: a shot's preview at 2,400 px is predicted at or over its measured peak (394-455 MB) and within a quarter of it, got {}", megabytes(shot_cost.peak_bytes) as i64));
    c.near(shot_cost.seconds, 0.45, 0.25, "cost: and at about its measured time (0.33-0.56 s)");
    let shot12 = job(
        JobKind::Shot,
        PixelSize::new(2400, 1800),
        Opt { tier: RenderTier::Preview, decodes: true, original: Some(FRAME12), ..o() },
    );
    let shot48 = job(
        JobKind::Shot,
        PixelSize::new(2400, 1800),
        Opt { tier: RenderTier::Preview, decodes: true, original: Some(FRAME48), ..o() },
    );
    let cost12 = megabytes(model.seed(&shot12, &RenderMode::Whole).peak_bytes);
    let cost48 = megabytes(model.seed(&shot48, &RenderMode::Whole).peak_bytes);
    c.expect(
        (588.0..=588.0 * 1.05).contains(&cost48),
        format!(
            "cost: a 48 MP photo's preview is priced at the dearest open measured (588 MB, by Core Image), got {}",
            cost48 as i64
        ),
    );
    c.expect(
        (456.0..=456.0 * 1.25).contains(&cost12),
        format!("cost: a 12 MP photo's at its render (360-456 MB measured), got {}", cost12 as i64),
    );
    c.near(
        model.seed(&shot48, &RenderMode::Whole).seconds,
        0.55,
        0.25,
        "cost: a 48 MP photo's preview takes 0.35-0.64 s",
    );
    let mut taught = CostModel::new(policy.clone());
    for _ in 0..10 {
        taught.learn(&shot12, &RenderMode::Whole, 360 * MB, 0.4);
    }
    c.expect(
        taught.estimate(&shot12, &RenderMode::Whole).peak_bytes < model.seed(&shot12, &RenderMode::Whole).peak_bytes,
        "learn: a 12 MP photo's previews teach the model what a 12 MP photo's preview costs",
    );
    c.expect(
        taught.estimate(&shot48, &RenderMode::Whole).peak_bytes == model.seed(&shot48, &RenderMode::Whole).peak_bytes,
        "learn: and nothing about a 48 MP photo's: the small decode's cost is the original's",
    );
    let after_photos = MemoryBudget::compute(&reading(6085, 2011), &live48, &tuning, false, false);
    c.expect(plan(&shot_preview, &after_photos, &live48).mode == RenderMode::Whole,
        "plan: a shot's preview develops beside a camera live at 48 MP, the phone as it was after photos (2,011 MB of headroom)");
    let tighter = MemoryBudget::compute(&reading(6085, 1900), &live48, &tuning, false, false);
    c.expect(
        plan(&shot_preview, &tighter, &live48).mode == RenderMode::Wait(WaitReason::Camera),
        "plan: and waits for the camera when the phone has 1,900 MB and the camera has yet to take its first photo",
    );
    let warmed = MemoryBudget::compute(&reading(6085, 1850), &live48, &tuning, true, false);
    c.expect(plan(&shot48, &warmed, &live48).mode == RenderMode::Whole,
        "plan: once the camera has delivered a photo, a 48 MP shot's preview develops beside it with 1,850 MB of headroom");
    let spent = MemoryBudget::compute(&reading(6085, 1519), &live48, &tuning, true, false);
    c.expect(
        plan(&shot48, &spent, &live48).mode == RenderMode::Wait(WaitReason::Camera),
        "plan: and still waits with 1,519 MB, where the phone was just after the first photos",
    );
    let unwarmed = MemoryBudget::compute(&reading(6085, 1850), &live48, &tuning, false, false);
    c.expect(
        plan(&shot48, &unwarmed, &live48).mode == RenderMode::Wait(WaitReason::Camera),
        "plan: with the first photo's growth reserved it waits at 1,850 MB too (a whole run of the phone, before this)",
    );
    let away = FrontendState { scene: Scene::Background, ..Default::default() };
    c.expect(
        plan(&full12, &budget(8000), &away).mode == RenderMode::Wait(WaitReason::Background),
        "plan: nothing renders in the background",
    );

    // ---- the cost model learns (R9) ----
    let mut learning = CostModel::new(policy.clone());
    let predicted = learning.estimate(&full12, &RenderMode::Whole).seconds;
    for _ in 0..20 {
        learning.learn(&full12, &RenderMode::Whole, 0, predicted * 1.25);
    }
    c.near(
        learning.estimate(&full12, &RenderMode::Whole).seconds,
        predicted * 1.25,
        0.10,
        "learn: after 20 jobs a 25 % slow engine is predicted within 10 %",
    );
    c.expect(
        learning.estimate(&full12, &RenderMode::Whole).peak_bytes
            == CostModel::new(policy.clone()).estimate(&full12, &RenderMode::Whole).peak_bytes,
        "learn: a peak that was not measured leaves the peak's prediction alone",
    );

    // ---- the queue (§6.9), over the simulated engine ----
    let free_memory = mutation == Some("free-memory");
    let never_yield = mutation == Some("never-yield");
    let policy_q = policy.clone();
    let scheduler = move |speed: f64, memory: Arc<dyn Fn() -> MemoryReading + Send + Sync>| {
        let engine = Arc::new(SimulatedEngine::new(policy_q.clone(), speed));
        let memory: Arc<dyn Fn() -> MemoryReading + Send + Sync> =
            if free_memory { Arc::new(|| reading(100_000, 100_000)) } else { memory };
        let s = RenderQueue::new(engine, policy_q.clone(), None, memory);
        s.configure(|cfg| {
            cfg.replan_interval = 0.02;
            cfg.pressure_recovery = 0.3;
            if never_yield {
                cfg.yield_threshold = f64::INFINITY;
            }
        });
        s
    };
    let roomy = || -> Arc<dyn Fn() -> MemoryReading + Send + Sync> { Arc::new(|| reading(6000, 6000)) };
    let shoot_live = Opt { layers: shoot.clone(), ..live() };
    let print_live = Opt { layers: print.clone(), ..live() };

    // Latest wins: five canvas edits on one frame end as one or two renders.
    {
        let s = scheduler(50.0, roomy());
        let f = FrameId::random();
        let mut ids = vec![];
        for _ in 0..5 {
            ids.push(s.submit(job(
                JobKind::CanvasReprint,
                CANVAS,
                Opt { frame: Some(f.clone()), ..print_live.clone() },
            )));
        }
        let mut finished = 0;
        for id in &ids {
            if s.outcome(*id).await.is_finished() {
                finished += 1;
            }
        }
        c.expect(
            s.outcome(*ids.last().unwrap()).await != JobOutcome::Cancelled,
            "queue: the newest canvas edit is the one that renders",
        );
        c.expect(
            finished <= 2,
            format!("queue: superseded canvas work is cancelled, not finished ({finished} of 5 ran)"),
        );
        c.expect(s.is_idle(), "queue: nothing is left behind");
    }
    // An export gives way to a canvas edit, and still finishes.
    {
        let s = scheduler(50.0, roomy());
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(20).await;
        let edit = s.submit(job(JobKind::CanvasDevelop, CANVAS, shoot_live.clone()));
        let edit_done = s.outcome(edit).await;
        let export_still_waiting = s.contains(export);
        c.expect(
            edit_done != JobOutcome::Cancelled && export_still_waiting,
            "queue: an export gives way to a canvas edit",
        );
        let export_done = s.outcome(export).await;
        c.expect(export_done.is_finished(), "queue: an export that gave way still finishes");
        c.expect(
            s.records().iter().any(|r| r.outcome.contains("gave way")),
            "log: a job that gave way says so in its record",
        );
    }
    // A job that cannot fit waits, says why, and runs when memory comes back.
    {
        let free = Held::new(300);
        let f2 = free.clone();
        let s = scheduler(50.0, Arc::new(move || reading(6000, f2.value())));
        let id = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(60).await;
        let waiting = state_of(&s, id) == Some(SnapshotState::Waiting(WaitReason::Memory));
        c.expect(waiting, "queue: with 300 MB free a 48 MP export waits for memory, and says so");
        free.set(6000);
        let done = s.outcome(id).await;
        c.expect(done.is_finished(), "queue: a waiting job runs once memory returns");
        c.expect(
            s.records().last().is_some_and(|r| r.waits.iter().any(|w| w == "memory")),
            "log: a job's waits are in its record",
        );
    }
    // A job waits for memory the engine's own idle pool is holding: the pool is given back, and it runs.
    {
        let held = Held::new(2000);
        let engine = Arc::new(SimulatedEngine::new(policy.clone(), 50.0));
        let h = held.clone();
        engine.set_on_trim(move || h.take() * MB);
        let h2 = held.clone();
        let s = RenderQueue::new(engine, policy.clone(), None, Arc::new(move || reading(6000, 4000 - h2.value())));
        s.configure(|cfg| cfg.replan_interval = 0.02);
        if c.m("never-trim") {
            s.configure(|cfg| {
                cfg.trims_when_waiting = false;
                cfg.reclaims_for_asked = false;
            });
        }
        let id = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        let mut ran = false;
        for _ in 0..150 {
            if ran {
                break;
            }
            sleep_ms(10).await;
            ran = !s.contains(id);
        }
        c.expect(ran, "wait: a job waiting for memory has the engine's idle pool given back, and runs");
        let ok = held.value() == 0 || c.m("never-trim");
        c.expect(ok, "wait: the pool was trimmed");
        s.cancel(id);
    }
    // The queue idle: the engine's pool goes back once it has stayed idle a spell, not at every gap.
    {
        let held = Held::new(300);
        let count = Held::new(0);
        let engine = Arc::new(SimulatedEngine::new(policy.clone(), 50.0));
        let (h, n) = (held.clone(), count.clone());
        engine.set_on_trim(move || {
            n.add(1);
            h.take() * MB
        });
        let s = RenderQueue::new(engine, policy.clone(), None, roomy());
        let after = if c.m("idle-trims-at-once") {
            0.0
        } else if c.m("idle-never-trims") {
            30.0
        } else {
            0.3
        };
        s.configure(|cfg| cfg.idle_trim_after = after);
        let first = s.submit(job(JobKind::CanvasReprint, CANVAS, print_live.clone()));
        let _ = s.outcome(first).await;
        sleep_ms(100).await;
        c.expect(
            count.value() == 0,
            format!(
                "idle: the pool is not given back the moment the queue empties ({} trims after 0.1 s)",
                count.value()
            ),
        );
        let second = s.submit(job(JobKind::CanvasReprint, CANVAS, print_live.clone()));
        let _ = s.outcome(second).await;
        sleep_ms(200).await;
        c.expect(count.value() == 0, format!("idle: a job inside the spell starts it again ({} trims)", count.value()));
        sleep_ms(400).await;
        c.expect(
            count.value() == 1 && held.value() == 0,
            format!(
                "idle: after the spell the pool is given back, once ({} trims, {} MB left)",
                count.value(),
                held.value()
            ),
        );
    }
    // Critical pressure: the job is cancelled and runs again in a smaller mode.
    {
        let s = scheduler(50.0, Arc::new(|| reading(6000, 3400)));
        let id = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(15).await;
        let first = s.snapshot_of(id).and_then(|x| x.mode);
        if !c.m("ignore-pressure") {
            s.memory_pressure(Pressure::Critical);
        }
        let done = s.outcome(id).await;
        let modes: Vec<String> = s.records().iter().filter(|r| r.job_id == id).map(|r| r.mode.clone()).collect();
        c.expect(
            modes.len() >= 2 && modes.first() != modes.last(),
            format!("pressure: the job runs again in a smaller mode ({})", modes.join(" then ")),
        );
        c.expect(done.is_finished(), "pressure: the job still finishes");
        c.expect(first.is_some(), "pressure: the job was running when the pressure came");
    }
    // The background: a running export stops, waits, and finishes when the app is back.
    {
        let s = scheduler(50.0, roomy());
        let id = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(15).await;
        s.update_frontend(|f| f.scene = Scene::Background);
        sleep_ms(80).await;
        c.expect(
            state_of(&s, id) == Some(SnapshotState::Waiting(WaitReason::Background)),
            "background: an export stops and says it is paused",
        );
        s.update_frontend(|f| f.scene = Scene::Active);
        c.expect(s.outcome(id).await.is_finished(), "background: it finishes when the app is back");
    }
    // The camera: an export waits while it is live, and a capture in flight holds a shot's develop.
    {
        let s = scheduler(50.0, roomy());
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 12.0 });
        let export = s.submit(job(JobKind::Export, FRAME12, decodes.clone()));
        let shot = s.submit(job(JobKind::Shot, FRAME12, Opt { tier: RenderTier::Preview, decodes: true, ..o() }));
        c.expect(s.outcome(shot).await.is_finished(), "camera: a 12 MP shot develops while the camera is live");
        c.expect(
            state_of(&s, export) == Some(SnapshotState::Waiting(WaitReason::Camera)),
            "camera: an export waits while the camera is live",
        );
        s.update_frontend(|f| f.camera = Camera::Off);
        c.expect(s.outcome(export).await.is_finished(), "camera: the export runs once the camera is off");
    }
    // A photo taken while a shot's preview develops, under each capture rule (the engine at a tenth of
    // the usual test speed, so a develop lasts long enough to be interrupted).
    let while_shooting = |r: CaptureRule| {
        let s = scheduler(5.0, roomy());
        s.configure(|cfg| cfg.capture_rule = rule(r));
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 12.0 });
        s
    };
    c.expect(
        scheduler(50.0, roomy()).config().capture_rule == CaptureRule::Holds,
        "capture: by default a develop under way finishes under a photo and none starts under one (the owner's flow)",
    );
    {
        // stops: the develop is cancelled when the photo is taken, and runs again once it lands.
        let s = while_shooting(CaptureRule::Stops);
        let id = s.submit(preview.clone());
        sleep_ms(25).await;
        s.update_frontend(|f| f.captures_in_flight = 1);
        sleep_ms(120).await;
        let waits_for_it = state_of(&s, id) == Some(SnapshotState::Waiting(WaitReason::Capture));
        c.expect(
            gave_way(&s, id) && waits_for_it,
            "capture, stops: a photo stops the develop, which waits for it to land",
        );
        s.update_frontend(|f| f.captures_in_flight = 0);
        c.expect(finishes(&s, id).await, "capture, stops: the develop runs again once the photo has landed");
    }
    {
        // holds: the develop finishes under the photo; the next one waits for the photo to land.
        let s = while_shooting(CaptureRule::Holds);
        let id = s.submit(preview.clone());
        sleep_ms(25).await;
        s.update_frontend(|f| f.captures_in_flight = 1);
        let next = s.submit(job(JobKind::Shot, CANVAS, Opt { tier: RenderTier::Preview, decodes: true, ..o() }));
        let finished = finishes(&s, id).await;
        let still_in_flight = s.frontend().captures_in_flight == 1;
        c.expect(
            finished && !gave_way(&s, id) && still_in_flight,
            "capture, holds: a develop under way finishes under the photo",
        );
        sleep_ms(40).await;
        c.expect(
            state_of(&s, next) == Some(SnapshotState::Waiting(WaitReason::Capture)),
            "capture, holds: the next develop waits for the photo to land",
        );
        s.update_frontend(|f| f.captures_in_flight = 0);
        c.expect(finishes(&s, next).await, "capture, holds: and runs once it has");
        s.cancel(id);
        s.cancel(next);
    }
    {
        // shares: a develop starts and finishes with the photo still in flight; a full-size shot does not start.
        let s = while_shooting(CaptureRule::Shares);
        s.update_frontend(|f| f.captures_in_flight = 1);
        let id = s.submit(preview.clone());
        let full = s.submit(job(JobKind::Shot, FRAME12, decodes.clone()));
        let finished = finishes(&s, id).await;
        let still_in_flight = s.frontend().captures_in_flight == 1;
        c.expect(
            finished && !gave_way(&s, id) && still_in_flight,
            "capture, shares: a preview develops while the photo is in flight",
        );
        sleep_ms(40).await;
        c.expect(
            state_of(&s, full) == Some(SnapshotState::Waiting(WaitReason::Capture)),
            "capture, shares: a full-size shot still waits for the photo",
        );
        s.cancel(full);
        s.cancel(id);
    }
    {
        // The budget kept one capture's growth aside. A second photo in flight is more than that.
        let s = while_shooting(CaptureRule::Holds);
        let id = s.submit(preview.clone());
        sleep_ms(25).await;
        let n = if c.m("no-second-capture") { 1 } else { 2 };
        s.update_frontend(|f| f.captures_in_flight = n);
        sleep_ms(120).await;
        c.expect(
            gave_way(&s, id),
            "capture: a develop goes on under the captures its budget kept aside, and gives way to one more",
        );
        s.update_frontend(|f| f.captures_in_flight = 0);
        c.expect(finishes(&s, id).await, "capture: and it finishes once they have landed");
    }
    // The darkroom closed to a live camera (`develops_beside_camera` false).
    let closed = mutation != Some("darkroom-open-beside-camera");
    c.expect(
        scheduler(50.0, roomy()).config().develops_beside_camera,
        "darkroom: open beside a camera unless the host closes it",
    );
    for (kind, tier) in [
        (JobKind::Shot, RenderTier::Preview),
        (JobKind::ImportDevelop, RenderTier::Preview),
        (JobKind::CanvasDevelop, RenderTier::Live),
        (JobKind::CanvasReprint, RenderTier::Live),
        (JobKind::Export, RenderTier::Full),
    ] {
        let j = job(
            kind,
            if tier == RenderTier::Full { FRAME12 } else { CANVAS },
            Opt { tier, decodes: kind != JobKind::CanvasReprint, ..o() },
        );
        c.expect(
            Planner::plan(&j, &budget(8000), &live48, &model, 1.0, CaptureRule::Shares, !closed).mode
                == RenderMode::Wait(WaitReason::Camera),
            format!(
                "darkroom, closed: {} waits for the camera with 8 GB to spare and under `shares`",
                kind.raw_value()
            ),
        );
        c.expect(
            Planner::plan(&j, &budget(8000), &idle, &model, 1.0, CaptureRule::Holds, !closed).mode
                != RenderMode::Wait(WaitReason::Camera),
            format!("darkroom, closed: {} does not wait for a camera that is off", kind.raw_value()),
        );
    }
    c.expect(
        Planner::gate(
            &job(JobKind::Thumbnail, CANVAS, Opt { tier: RenderTier::Preview, ..o() }),
            &live48,
            &policy,
            CaptureRule::Holds,
            !closed,
        )
        .is_none(),
        "darkroom, closed: a thumbnail is not a develop",
    );
    {
        // A shot taken with the page open waits; it is developed when the camera has stopped.
        let s = scheduler(5.0, roomy());
        s.configure(|cfg| cfg.develops_beside_camera = !closed);
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 12.0 });
        let shot = s.submit(preview.clone());
        sleep_ms(150).await;
        c.expect(
            state_of(&s, shot) == Some(SnapshotState::Waiting(WaitReason::Camera)) && s.records().is_empty(),
            "darkroom, closed: a shot's develop does not start while the camera is live",
        );
        s.update_frontend(|f| f.camera = Camera::Off);
        c.expect(finishes(&s, shot).await, "darkroom, closed: it is developed once the camera has stopped");
    }
    {
        // The Shoot page opens while the queue is developing: the job gives way, at once.
        let s = scheduler(5.0, roomy());
        s.configure(|cfg| cfg.develops_beside_camera = !closed);
        let id = s.submit(job(JobKind::ImportDevelop, CANVAS, Opt { tier: RenderTier::Preview, decodes: true, ..o() }));
        sleep_ms(25).await;
        let was_running = running(&s, id);
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 48.0 });
        sleep_ms(120).await;
        c.expect(
            was_running && gave_way(&s, id) && state_of(&s, id) == Some(SnapshotState::Waiting(WaitReason::Camera)),
            "darkroom, closed: a develop under way gives way when the camera goes live, and waits for it",
        );
        s.update_frontend(|f| f.camera = Camera::Off);
        c.expect(finishes(&s, id).await, "darkroom, closed: and runs again once the camera has stopped");
    }
    {
        // A camera session starting is when the closed darkroom gives back what it holds — once.
        let s = scheduler(50.0, roomy());
        s.configure(|cfg| cfg.develops_beside_camera = !closed);
        let trims = Held::new(0);
        let t = trims.clone();
        s.set_hooks(|h| {
            h.on_trim_caches = Some(Arc::new(move || {
                t.add(1);
            }))
        });
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 48.0 });
        c.expect(
            trims.value() == 1,
            format!(
                "darkroom, closed: the frontend's caches are given back when a camera session starts, got {}",
                trims.value()
            ),
        );
        s.update_frontend(|f| f.captures_in_flight = 1);
        s.update_frontend(|f| f.captures_in_flight = 0);
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 12.0 });
        c.expect(
            trims.value() == 1,
            format!("darkroom, closed: and not again while the session runs, got {}", trims.value()),
        );
        s.update_frontend(|f| f.camera = Camera::Off);
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 12.0 });
        c.expect(
            trims.value() == 2,
            format!("darkroom, closed: the next session gives them back again, got {}", trims.value()),
        );
    }

    // The scheduler knows the camera has delivered a photo from the captures it is told of.
    {
        let s = scheduler(50.0, roomy());
        if c.m("camera-never-warm") {
            s.configure(|cfg| cfg.tuning.camera_warm_seconds = -1.0);
        }
        let reserve = |s: &RenderQueue| s.budget_now(false).0.camera_reserve / MB;
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 48.0 });
        c.expect(
            reserve(&s) == 750,
            format!(
                "camera: before its first photo the reserve is the first photo's growth (750 MB at 48 MP), got {}",
                reserve(&s)
            ),
        );
        s.update_frontend(|f| f.captures_in_flight = 1);
        c.expect(reserve(&s) == 1500, format!("camera: with that photo in flight, twice it, got {}", reserve(&s)));
        s.update_frontend(|f| f.captures_in_flight = 0);
        c.expect(
            reserve(&s) == 420,
            format!("camera: once it has landed, the next one's (420 MB), got {}", reserve(&s)),
        );
        s.update_frontend(|f| f.camera = Camera::Off);
        s.update_frontend(|f| f.camera = Camera::Live { photo_megapixels: 48.0 });
        c.expect(
            reserve(&s) == 750,
            format!("camera: a session started again has yet to take its first, got {}", reserve(&s)),
        );
        s.update_frontend(|f| f.captures_in_flight = 1);
        s.update_frontend(|f| f.captures_in_flight = 0);
        let warm = if c.m("camera-stays-warm") {
            f64::INFINITY
        } else if c.m("camera-never-warm") {
            -1.0
        } else {
            0.03
        };
        s.configure(|cfg| cfg.tuning.camera_warm_seconds = warm);
        sleep_ms(60).await;
        c.expect(
            reserve(&s) == 750,
            format!("camera: and one that has taken none for a while is reserved its first again, got {}", reserve(&s)),
        );
    }
    // The picture is the size that was asked for and priced.
    {
        let engine = Arc::new(SimulatedEngine::new(policy.clone(), 50.0));
        if !c.m("renders-as-asked") {
            engine.set_renders(|j| if j.kind == JobKind::Shot { PixelSize::new(3400, 2267) } else { j.canvas });
        }
        let s = RenderQueue::new(engine, policy.clone(), None, roomy());
        let id = s.submit(preview.clone());
        let _ = s.outcome(id).await;
        c.expect(
            s.records().last().and_then(|r| r.rendered_instead.clone()) == Some("3400x2267".into()),
            "log: a render that is not the size the job asked for says so in its record",
        );
        c.expect(
            !s.cost_model().corrections().contains_key(&CostModel::key(&preview, &RenderMode::Whole)),
            "learn: a render that was not the job priced teaches the cost model nothing",
        );
        let edit = job(JobKind::CanvasDevelop, CANVAS, live());
        let eid = s.submit(edit.clone());
        let _ = s.outcome(eid).await;
        c.expect(
            s.records().last().is_some_and(|r| r.rendered_instead.is_none()),
            "log: and a render of the size asked says nothing",
        );
        c.expect(
            s.cost_model().corrections().contains_key(&CostModel::key(&edit, &RenderMode::Whole)),
            "learn: and one that was is learned from",
        );
        let over = preview.is_over_asked(PixelSize::new(3400, 2267));
        let rounded = preview.is_over_asked(PixelSize::new(2399, 1601));
        let smaller = preview.is_over_asked(PixelSize::new(1600, 1067));
        c.expect(
            over && !rounded && !smaller,
            "log: larger than asked is over; the canvas to a pixel's rounding, or a smaller frame, is not",
        );
    }

    // A double exposure's job is told what its open composes when it is submitted.
    {
        let engine = Arc::new(SimulatedEngine::new(policy.clone(), 50.0));
        let s = RenderQueue::new(engine, policy.clone(), None, roomy());
        let double_frame = FrameId::random();
        let told = Composition { decodes: vec![FRAME48, FRAME12], scratch_bytes: 64 * MB, raw: true };
        if !c.m("double-hook-ignored") {
            let (f, t) = (double_frame.clone(), told.clone());
            s.set_hooks(move |h| h.composition = Some(Arc::new(move |j| (j.frame_id == f).then(|| t.clone()))));
        }
        let page = PixelSize::new(1280, 960);
        let asked = job(
            JobKind::CanvasDevelop,
            page,
            Opt { frame: Some(double_frame.clone()), decodes: true, original: Some(FRAME48), ..live() },
        );
        let photo = job(JobKind::CanvasDevelop, page, Opt { decodes: true, original: Some(FRAME48), ..live() });
        let id = s.submit(asked);
        let other = s.submit(photo);
        c.expect(
            s.snapshot_of(id).and_then(|x| x.job.composition) == Some(told.clone()),
            "double: a double's job is priced with what its open composes, told when it is submitted",
        );
        c.expect(
            s.snapshot_of(other).is_some_and(|x| x.job.composition.is_none()),
            "double: and a photograph's is not",
        );
        let _ = s.outcome(id).await;
        let _ = s.outcome(other).await;
        let records = s.records();
        let a = records.iter().rev().find(|r| r.job_id == id);
        let b = records.iter().rev().find(|r| r.job_id == other);
        match (a, b) {
            (Some(a), Some(b)) => c.expect(
                a.predicted_peak_bytes > b.predicted_peak_bytes,
                format!(
                    "double: its record predicts the composed open's peak, over the photograph's ({} MB against {})",
                    megabytes(a.predicted_peak_bytes),
                    megabytes(b.predicted_peak_bytes)
                ),
            ),
            _ => c.expect(false, "double: both jobs ran and were recorded"),
        }
        c.expect(
            s.cost_model().corrections().keys().any(|k| k.ends_with("|double|raw")),
            "double: and what it teaches is learned under its own key",
        );
    }

    // ---- Develop's strips: a stock's preview ----
    let card_canvas = PixelSize::new(800, 600);
    let card_opens = PixelSize::new(1600, 1200);
    let card = |frame: Option<FrameId>, slot: &str, decodes: bool, original: Option<PixelSize>| {
        RenderJob::new(frame.unwrap_or_else(FrameId::random), JobKind::StockPreview, RenderTier::Live, card_canvas)
            .with_what("card")
            .decoding(decodes)
            .with_original(original)
            .with_opens(Some(card_opens))
            .with_slot(Some(slot.to_string()))
    };
    let (wait_their_turn, jump_the_queue, not_coalesced) =
        (c.m("previews-wait-their-turn"), c.m("previews-jump-the-queue"), c.m("previews-not-coalesced"));
    let preview_scheduler = |speed: f64, memory: Arc<dyn Fn() -> MemoryReading + Send + Sync>| {
        let s = scheduler(speed, memory);
        s.configure(|cfg| {
            if wait_their_turn {
                cfg.previews_give_way_at_once = false;
            }
            if jump_the_queue {
                cfg.previews_wait_for_the_queue = false;
            }
            if not_coalesced {
                cfg.previews_coalesce = false;
            }
        });
        s
    };
    c.expect(JobKind::ALL.iter().filter(|k| k.is_asked() || **k == JobKind::Shot).all(|k| k.priority() < JobKind::StockPreview.priority())
        && JobKind::StockPreview.priority() < JobKind::ImportDevelop.priority()
        && JobKind::StockPreview.priority() < JobKind::Thumbnail.priority(),
        "previews: a stock's preview comes after the page, the shots and the exports, and before the library's own develops");
    c.expect(
        Planner::gate(&card(None, "film:a", false, None), &live48, &policy, CaptureRule::Holds, true)
            == Some(WaitReason::Camera),
        "previews: a card waits for a live camera even where the darkroom is open beside one",
    );
    c.expect(
        Planner::ladder(&card(None, "film:a", false, None)) == vec![RenderMode::Whole],
        "previews: a card is one piece",
    );
    let card_cost = model.seed(&card(None, "film:a", false, None), &RenderMode::Whole);
    c.expect(
        card_cost.phone_bytes - card_cost.peak_bytes == 12 * 1600 * 1200,
        format!(
            "previews: the source plane is priced by the frame opened (1,600 px), got {} MB",
            megabytes(card_cost.phone_bytes - card_cost.peak_bytes)
        ),
    );
    let decoding_card = model.seed(&card(None, "film:a", true, Some(FRAME48)), &RenderMode::Whole);
    c.expect(
        decoding_card.peak_bytes > card_cost.peak_bytes,
        "previews: the card that decodes the strip's picture is priced for the decode",
    );
    c.expect(
        CostModel::key(&card(None, "film:a", true, Some(FRAME48)), &RenderMode::Whole)
            != CostModel::key(
                &job(JobKind::CanvasDevelop, card_canvas, Opt { decodes: true, original: Some(FRAME48), ..live() }),
                &RenderMode::Whole,
            ),
        "previews: a card teaches the cost model nothing about the page's develop",
    );
    let k = card(None, "film:a", false, None);
    c.expect(
        k.opened_instead(card_opens).is_none() && !k.is_over_opened(card_opens) && k.is_over_opened(FRAME48),
        "previews: opening 1,600 px is what a card was priced for; opening the original is not",
    );
    {
        // The page's develop is submitted while a card runs: the card gives way at once.
        let s = preview_scheduler(0.18, roomy());
        let preview = s.submit(card(None, "film:a", false, None));
        sleep_ms(40).await;
        let was_running = running(&s, preview);
        let asked = Instant::now();
        let develop = s.submit(job(JobKind::CanvasDevelop, CANVAS, shoot_live.clone()));
        let mut started: Option<f64> = None;
        for _ in 0..100 {
            if started.is_some() {
                break;
            }
            if running(&s, develop) || s.records().iter().any(|r| r.job_id == develop) {
                started = Some(since(asked));
            } else {
                sleep_ms(5).await;
            }
        }
        c.expect(
            was_running && started.unwrap_or(9.0) < 0.1,
            format!(
                "previews: the page's develop starts at once over a running card ({:.0} ms)",
                started.unwrap_or(9.0) * 1000.0
            ),
        );
        c.expect(
            s.records().iter().any(|r| r.job_id == preview && r.outcome.contains("gave way")),
            "previews: the card says it gave way",
        );
        let develop_done = s.outcome(develop).await;
        let preview_done = s.outcome(preview).await;
        c.expect(
            develop_done.is_finished() && preview_done.is_finished(),
            "previews: the develop finishes, and the card after it",
        );
    }
    // ---- reclaim before waiting ----
    {
        let mut r = reading(6000, 1500);
        r.compressed = 1000 * MB;
        let strict = MemoryBudget::compute(&r, &FrontendState::default(), &BudgetTuning::default(), false, false);
        let asked = MemoryBudget::compute(&r, &FrontendState::default(), &BudgetTuning::default(), false, true);
        c.expect(
            asked.phone_side / MB == 1500 + 500 - 450 && strict.phone_side / MB == 1500 - 600,
            format!(
                "asked: the phone side counts half the compressed memory and a 450 MB floor ({} MB, strict {})",
                asked.phone_side / MB,
                strict.phone_side / MB
            ),
        );
        let live_cam = FrontendState { camera: Camera::Live { photo_megapixels: 12.0 }, ..Default::default() };
        c.expect(
            MemoryBudget::compute(&r, &live_cam, &BudgetTuning::default(), false, true)
                == MemoryBudget::compute(&r, &live_cam, &BudgetTuning::default(), false, false),
            "asked: with the camera live nothing is loosened",
        );
        c.expect(asked.app_side == strict.app_side, "asked: the app's own allowance is never loosened");
    }
    {
        // An export that does not fit: the frontend's caches go first, and what they free lets it start.
        let phone = Held::new(500);
        let reclaims = Held::new(0);
        let p = phone.clone();
        let s = scheduler(50.0, Arc::new(move || reading(6000, p.value())));
        let (p2, r2) = (phone.clone(), reclaims.clone());
        s.set_hooks(move |h| {
            h.on_reclaim = Some(Arc::new(move || {
                r2.add(1);
                p2.set(6000);
            }))
        });
        let started = Instant::now();
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        let out = s.outcome(export).await;
        if out.is_finished() {
            c.expect(
                reclaims.value() == 1 && since(started) < 1.0,
                format!(
                    "reclaim: a waiting export has the caches given back and starts ({} reclaim, {:.2} s)",
                    reclaims.value(),
                    since(started)
                ),
            );
        } else {
            c.expect(false, "reclaim: the export finishes once the caches are given back");
        }
    }
    let smallest48 = Planner::ladder(&job(JobKind::Export, FRAME48, decodes.clone())).last().map(|m| m.name());
    {
        // Nothing to give back: the export starts in its smallest mode against the allowance alone.
        let s = scheduler(50.0, Arc::new(|| reading(6000, 700)));
        s.configure(|cfg| cfg.force_after = 0.2);
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(100).await;
        let waited = state_of(&s, export) == Some(SnapshotState::Waiting(WaitReason::Memory));
        let out = s.outcome(export).await;
        let mode = s.records().iter().find(|r| r.job_id == export && r.outcome == "done").map(|r| r.mode.clone());
        if out.is_finished() {
            c.expect(waited && mode == smallest48,
                format!("reclaim: with nothing left to give back an export waits a moment, then runs in its smallest mode ({mode:?})"));
        } else {
            c.expect(false, "reclaim: the export runs in the end");
        }
    }
    {
        // **The desktop's forced start is held to the host**: the allowance is the host's headroom and
        // half its compressor (`MemoryReading::mac`), not the physical memory.
        let headroom_only = MemoryReading::mac(700 * MB, 0, 0, 0, 0, 0);
        let constant = c.m("mac-allowance-constant");
        let tight = if constant { MemoryReading { app_available: 36 << 30, ..headroom_only } } else { headroom_only };
        c.expect(
            tight.app_available == 700 * MB || constant,
            format!(
                "mac: the allowance is the host's headroom, not the physical memory ({} MB)",
                megabytes(tight.app_available)
            ),
        );
        let s = scheduler(50.0, Arc::new(move || tight));
        s.configure(|cfg| {
            cfg.force_after = 0.05;
            cfg.force_anyway_after = Some(30.0);
        });
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(400).await;
        c.expect(
            state_of(&s, export) == Some(SnapshotState::Waiting(WaitReason::Memory))
                && !s.records().iter().any(|r| r.job_id == export),
            "mac: a job someone waits on is not forced past what the host has left",
        );
        let frame = s.snapshot_of(export).map(|x| x.job.frame_id).unwrap_or_else(FrameId::random);
        s.cancel_all(&frame, |_| true);
        {
            // **But it never starves**: once it has waited `force_anyway_after` it starts anyway.
            let t = scheduler(50.0, Arc::new(move || tight));
            let starves = c.m("mac-asked-starves");
            t.configure(|cfg| {
                cfg.force_after = 0.05;
                cfg.force_anyway_after = if starves { None } else { Some(0.6) };
            });
            let started = Instant::now();
            let held = t.submit(job(JobKind::Export, FRAME48, decodes.clone()));
            sleep_ms(300).await;
            c.expect(
                !t.records().iter().any(|r| r.job_id == held),
                "mac: not forced before the longer bound (at 0.3 s)",
            );
            let mut ran = None;
            for _ in 0..300 {
                if ran.is_some() {
                    break;
                }
                sleep_ms(10).await;
                ran = t.records().into_iter().find(|r| r.job_id == held && r.outcome == "done");
            }
            let at = ran.as_ref().map(|_| since(started));
            c.expect(
                ran.is_some() && at.unwrap_or(-1.0) >= 0.6,
                format!(
                    "mac: a job someone waits on starts by the bound however tight the host ({:.2} s)",
                    at.unwrap_or(-1.0)
                ),
            );
            c.expect(
                ran.as_ref().map(|r| r.mode.clone()) == smallest48,
                format!("mac: and in its smallest mode ({:?})", ran.map(|r| r.mode)),
            );
            let frame = t.snapshot_of(held).map(|x| x.job.frame_id).unwrap_or_else(FrameId::random);
            t.cancel_all(&frame, |_| true);
        }
        let roomy_mac = MemoryReading::mac(700 * MB, 0, 0, 0, 8 << 30, 0);
        c.expect(
            roomy_mac.app_available == 700 * MB + (4 << 30),
            format!("mac: half of the compressor's pages count ({} MB)", megabytes(roomy_mac.app_available)),
        );
        let r = scheduler(50.0, Arc::new(move || roomy_mac));
        r.configure(|cfg| cfg.force_after = 0.05);
        let started = r.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        let out = r.outcome(started).await;
        c.expect(out.is_finished(), format!("mac: a forced start the host can hold still runs ({out:?})"));
    }
    {
        // Not past the allowance: an export the app's own allowance cannot hold still waits.
        let s = scheduler(50.0, Arc::new(|| reading(300, 700)));
        s.configure(|cfg| cfg.force_after = 0.05);
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        sleep_ms(400).await;
        c.expect(
            state_of(&s, export) == Some(SnapshotState::Waiting(WaitReason::Memory))
                && !s.records().iter().any(|r| r.job_id == export),
            "reclaim: a job the app's allowance cannot hold is never forced",
        );
        let frame = s.snapshot_of(export).map(|x| x.job.frame_id).unwrap_or_else(FrameId::random);
        s.cancel_all(&frame, |_| true);
    }
    {
        // A canvas job whose open takes the host's headroom under the watch's line must still land:
        // the watch is for full-size jobs, never the page's own picture.
        let s = scheduler(2.0, Arc::new(|| reading(6000, 1800)));
        let weak = s.downgrade();
        if !free_memory {
            s.set_read_memory(move || {
                let busy = weak.upgrade().is_some_and(|q| !q.is_idle());
                reading(6000, if busy { 300 } else { 1800 })
            });
        }
        let f = FrameId::random();
        let canvas = s.submit(job(JobKind::CanvasDevelop, CANVAS, Opt { frame: Some(f.clone()), ..live() }));
        sleep_ms(2000).await;
        let records = s.records();
        let landed = records.iter().any(|r| r.job_id == canvas && r.outcome == "done");
        let cancels = records.iter().filter(|r| r.job_id == canvas && r.outcome.contains("pressure")).count();
        c.expect(landed && cancels == 0,
            format!("watch: the page's picture lands under a dip in headroom, never cancelled by the watch (landed {landed}, {cancels} cancels)"));
        s.cancel_all(&f, |_| true);
    }
    {
        // The operating system's own critical warning during the page's picture: it still lands.
        let s = scheduler(1.0, roomy());
        let f = FrameId::random();
        let canvas = s.submit(job(JobKind::CanvasDevelop, CANVAS, Opt { frame: Some(f.clone()), ..live() }));
        sleep_ms(30).await;
        s.memory_pressure(Pressure::Critical);
        sleep_ms(1500).await;
        let records = s.records();
        let landed = records.iter().any(|r| r.job_id == canvas && r.outcome == "done");
        c.expect(
            landed && !records.iter().any(|r| r.job_id == canvas && r.outcome.contains("pressure")),
            format!("pressure: a critical warning does not cancel the page's picture (landed {landed})"),
        );
        s.cancel_all(&f, |_| true);
    }
    {
        // A frame's cards under a library of develops still land.
        let s = preview_scheduler(0.5, roomy());
        let lib = Opt { tier: RenderTier::Preview, ..o() };
        let library: Vec<JobId> = (0..12).map(|_| s.submit(job(JobKind::ImportDevelop, CANVAS, lib.clone()))).collect();
        sleep_ms(20).await;
        let preview = s.submit(card(None, "film:a", false, None));
        let out = s.outcome(preview).await;
        let left = library.iter().filter(|id| s.contains(**id)).count();
        if out.is_finished() {
            c.expect(left >= 8, format!("previews: a card lands ahead of the library's develops of other frames ({left} of 12 still waiting)"));
        } else {
            c.expect(false, "previews: the card lands");
        }
        for id in &library {
            s.cancel(*id);
        }
        // Asked twice before it starts, a frame's develop is one job.
        let f = FrameId::random();
        let a = s.submit(job(JobKind::ImportDevelop, CANVAS, Opt { frame: Some(f.clone()), ..lib.clone() }));
        let b = s.submit(job(JobKind::ImportDevelop, CANVAS, Opt { frame: Some(f.clone()), ..lib.clone() }));
        let first = s.outcome(a).await;
        c.expect(
            (first == JobOutcome::Cancelled && s.contains(b)) || s.records().iter().any(|r| r.job_id == b),
            "coalesce: a frame's develop asked twice before it starts is one job",
        );
        s.cancel(b);
        // A frame's preview develop and its full-size prefetch are two jobs of two sizes.
        let g = FrameId::random();
        let small = s.submit(job(JobKind::ImportDevelop, CANVAS, Opt { frame: Some(g.clone()), ..lib.clone() }));
        let full = s.submit(job(JobKind::ImportDevelop, CANVAS, Opt { frame: Some(g.clone()), ..o() }));
        let small_out = s.outcome(small).await;
        let full_out = s.outcome(full).await;
        c.expect(small_out.is_finished() && full_out.is_finished(),
            format!("coalesce: a frame's preview develop and its full-size prefetch both land ({small_out:?}, {full_out:?})"));
    }
    {
        // A 48 MP export waits for memory a card would fit in: the card does not start beside it.
        let free = Held::new(1500);
        let f2 = free.clone();
        let s = preview_scheduler(50.0, Arc::new(move || reading(6000, f2.value())));
        let export = s.submit(job(JobKind::Export, FRAME48, decodes.clone()));
        let preview = s.submit(card(None, "film:a", true, Some(FRAME12)));
        sleep_ms(80).await;
        let export_waits = state_of(&s, export) == Some(SnapshotState::Waiting(WaitReason::Memory));
        let preview_held = s.contains(preview) && !s.records().iter().any(|r| r.job_id == preview);
        c.expect(
            export_waits && preview_held,
            "previews: a card does not start while a job ahead of it waits for memory",
        );
        free.set(6000);
        let _ = s.outcome(export).await;
        let preview_done = s.outcome(preview).await;
        let order: Vec<String> = s.records().iter().filter(|r| r.outcome == "done").map(|r| r.kind.clone()).collect();
        c.expect(
            order == vec!["export".to_string(), "stockPreview".to_string()],
            format!("previews: the job ahead runs first, then the card ({})", order.join(", ")),
        );
        c.expect(preview_done.is_finished(), "previews: and the card finishes");
    }
    {
        // Two cards for one slot: the newer replaces the older, queued or running.
        let s = preview_scheduler(0.18, roomy());
        let f = FrameId::random();
        let first = s.submit(card(Some(f.clone()), "film:a", false, None));
        sleep_ms(30).await;
        let queued_other = s.submit(card(Some(f.clone()), "film:b", false, None));
        let queued_same = s.submit(card(Some(f.clone()), "film:b", false, None));
        let newer = s.submit(card(Some(f.clone()), "film:a", false, None));
        let first_out = s.outcome(first).await;
        let queued_out = s.outcome(queued_other).await;
        let same_out = s.outcome(queued_same).await;
        let newer_out = s.outcome(newer).await;
        c.expect(
            first_out == JobOutcome::Cancelled,
            "previews: a running card is replaced by a newer one for its slot",
        );
        c.expect(
            queued_out == JobOutcome::Cancelled,
            "previews: a queued card is replaced by a newer one for its slot",
        );
        c.expect(same_out.is_finished() && newer_out.is_finished(), "previews: the newer cards finish");
        c.expect(s.records().iter().filter(|r| r.outcome == "done").count() == 2, "previews: two slots, two renders");
    }
    {
        // Scrolled away: a card queued or running is cancelled, and nothing of it is left behind.
        let s = preview_scheduler(0.18, roomy());
        let a = s.submit(card(None, "film:a", false, None));
        let b = s.submit(card(None, "film:b", false, None));
        sleep_ms(30).await;
        s.cancel(b);
        s.cancel(a);
        let a_out = s.outcome(a).await;
        let b_out = s.outcome(b).await;
        c.expect(
            a_out == JobOutcome::Cancelled && b_out == JobOutcome::Cancelled && s.is_idle(),
            "previews: a card cancelled, queued or running, is gone",
        );
        c.expect(
            s.records().iter().find(|r| r.job_id == a).map(|r| r.outcome.clone()) == Some("cancelled".into()),
            "previews: and the running one says it was cancelled",
        );
    }
    c
}

/// One run, on a paused clock of its own: the rules in virtual time.
pub fn run_paused(mutation: Option<&'static str>) -> Checks {
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().start_paused(true).build().expect("a runtime");
    rt.block_on(run(mutation))
}

/// The mutation run: each broken rule, and whether some check caught it.
pub fn mutation_run() -> Vec<(&'static str, Checks)> {
    MUTATIONS.iter().map(|m| (*m, run_paused(Some(m)))).collect()
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    /// T1: every check of `scheduler_selftest.swift` passes.
    #[test]
    fn every_check_passes() {
        let r = run_paused(None);
        assert!(r.passed > 250, "the checks ran ({} passed)", r.passed);
        assert!(r.failed.is_empty(), "{} check(s) failed:\n  {}", r.failed.len(), r.failed.join("\n  "));
    }

    /// T2: the checks' own check — every broken rule makes at least one check fail.
    #[test]
    fn every_mutation_is_caught() {
        let not_caught: Vec<&str> =
            mutation_run().into_iter().filter(|(_, r)| r.failed.is_empty()).map(|(m, _)| m).collect();
        assert!(not_caught.is_empty(), "mutations no check caught: {not_caught:?}");
    }
}
