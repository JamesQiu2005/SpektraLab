//! Predicted render memory and time, corrected by observed jobs (`CostModel.swift`).
//!
//! The starting coefficients come from the reference device's and the Mac's experiments; they are not
//! claims about a Windows PC (`DevicePolicy::time_ratio` scales the times, unmeasured there). The online
//! correction keeps an exponentially weighted ratio of measured to predicted peak and duration, learned
//! per job class (`CostModel::key`). A peak is learned only from a job that started from rest.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::device_policy::DevicePolicy;
use crate::types::{clamp, JobKind, RenderJob, RenderMode, RenderTier};

const MB: f64 = 1_048_576.0;

/// **A double exposure's composed open, as measured on the Mac** (2026-11-11, `ComposedOpen`).
pub struct ComposedOpen;

impl ComposedOpen {
    pub const FULL_PIECE_BYTES_PER_PIXEL: f64 = 64.0;
    pub const FULL_RAW_BASE: f64 = 2050.0 * MB;
    pub const FULL_RAW_BYTES_PER_PIXEL: f64 = 2.0;
    pub const FULL_OTHER_BASE: f64 = 220.0 * MB;
    pub const FULL_OTHER_BYTES_PER_PIXEL: f64 = 4.0;
    pub const FULL_RAW_SECONDS_PER_MP: f64 = 0.012;
    pub const FULL_OTHER_SECONDS_PER_MP: f64 = 0.006;
    pub const BELOW_RAW_BASE: f64 = 700.0 * MB;
    pub const BELOW_RAW_BYTES_PER_PIXEL: f64 = 62.0;
    pub const BELOW_OTHER_BASE: f64 = 200.0 * MB;
    pub const BELOW_OTHER_BYTES_PER_PIXEL: f64 = 3.5;
    pub const BELOW_RAW_SECONDS_PER_MP: f64 = 0.022;
    pub const BELOW_OTHER_SECONDS_PER_MP: f64 = 0.007;
}

/// **A photograph's RAW opened below the full tier with no proxy: its first open** (`RawOpen`,
/// measured on the Mac 2026-11-13: the envelope of seven cameras, never under, at most 3.3x over).
pub struct RawOpen;

impl RawOpen {
    pub const BASE: f64 = 600.0 * MB;
    pub const BYTES_PER_PIXEL: f64 = 30.0;
    /// 0.11 s (8 MP) to 1.7 s (102 MP) measured: ~0.017 s a megapixel of the original.
    pub const SECONDS_PER_MP: f64 = 0.017;
}

/// `CostEstimate`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CostEstimate {
    /// The job's peak over the app's resting footprint: what the allowance pays.
    pub peak_bytes: u64,
    /// What the host pays, which is more: the footprint's peak and the engine's source plane.
    pub phone_bytes: u64,
    pub seconds: f64,
}

/// Band-cost arithmetic retained by the planner (`BandGeometry`). The v1 host renders whole frames;
/// a banded plan is run whole and recorded as such.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BandGeometry {
    pub canvas: crate::types::PixelSize,
    /// 6 planes × 12 bytes × the canvas's width.
    pub bytes_per_row: u64,
    /// `above + halo`: measured 722 rows at 8,064 px on the long edge and 426 at 4,032; a line between.
    pub overhead_rows: i64,
    /// Below this the band is shorter than its own halo (~280 rows at 48 MP).
    pub floor_rows: i64,
}

impl BandGeometry {
    pub fn new(canvas: crate::types::PixelSize) -> Self {
        let edge = canvas.long_edge() as f64;
        BandGeometry {
            canvas,
            bytes_per_row: 6 * 12 * canvas.width.max(1) as u64,
            overhead_rows: ((426.0 + (722.0 - 426.0) * (edge - 4032.0) / 4032.0).round() as i64).max(1),
            floor_rows: ((280.0 * edge / 8064.0).round() as i64).max(64),
        }
    }

    pub fn band_count(&self, rows: i64) -> i64 {
        (self.canvas.height as f64 / rows.max(1) as f64).ceil() as i64
    }

    /// A height the engine can cut: a multiple of 8 rows.
    pub fn cuttable(rows: i64) -> i64 {
        ((rows + 7) / 8 * 8).max(8)
    }

    /// The estimated plane budget for bands of `rows`.
    pub fn engine_budget_bytes(&self, rows: i64) -> u64 {
        (rows + self.overhead_rows) as u64 * self.bytes_per_row
    }
}

/// measured ÷ predicted, smoothed (`CostModel.Correction`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Correction {
    pub peak: f64,
    pub time: f64,
    pub samples: i64,
}

impl Default for Correction {
    fn default() -> Self {
        Correction { peak: 1.0, time: 1.0, samples: 0 }
    }
}

/// `CostModel`.
#[derive(Clone, Debug)]
pub struct CostModel {
    pub policy: DevicePolicy,
    corrections: HashMap<String, Correction>,
    /// The weight of the newest sample.
    pub alpha: f64,
}

const LOW_MP: f64 = 12.19;
const HIGH_MP: f64 = 48.77; // 4032 × 3024 and 8064 × 6048
/// The bench's canvas: 2,560 × 1,920.
const CANVAS_PIXELS: f64 = 2560.0 * 1920.0;

fn lerp(a: f64, b: f64, mp: f64) -> f64 {
    a + (b - a) * (mp - LOW_MP) / (HIGH_MP - LOW_MP)
}

impl CostModel {
    pub fn new(policy: DevicePolicy) -> Self {
        CostModel { policy, corrections: HashMap::new(), alpha: 0.3 }
    }

    pub fn with_corrections(policy: DevicePolicy, corrections: HashMap<String, Correction>) -> Self {
        CostModel { policy, corrections, alpha: 0.3 }
    }

    pub fn corrections(&self) -> &HashMap<String, Correction> {
        &self.corrections
    }

    /// The cost before any correction.
    pub fn seed(&self, job: &RenderJob, mode: &RenderMode) -> CostEstimate {
        let pixels = job.canvas.pixels();
        // The frame the engine opens: the canvas, or larger on purpose (`RenderJob.opens`).
        let opened = pixels.max(job.priced_open().pixels());
        let mp = pixels / 1_000_000.0;
        if job.kind == JobKind::Thumbnail {
            return CostEstimate { peak_bytes: 24 << 20, phone_bytes: 24 << 20, seconds: 0.02 };
        }
        let mut peak: f64;
        let mut seconds: f64;
        if job.tier != RenderTier::Full {
            // A canvas session, measured on the host at 2,560 px and scaled by pixels.
            let s = pixels / CANVAS_PIXELS;
            peak = (560.0 * s).max(80.0) * MB;
            seconds = if job.is_reprint() {
                0.055 * s
            } else if job.layers.is_empty() {
                0.56 * s // the first develop of a session
            } else {
                0.21 * s
            };
        } else {
            // The render on the reference device: t0 + c_band × bands, and a whole one is one band.
            let t0 = lerp(0.69, 2.28, mp);
            let c = lerp(0.060, 0.137, mp);
            match mode {
                RenderMode::Whole | RenderMode::Wait(_) => {
                    peak = lerp(1004.0, 3239.0, mp) * MB;
                    seconds = (t0 + c) * self.policy.time_ratio;
                }
                RenderMode::Bands { rows } => {
                    let g = BandGeometry::new(job.canvas);
                    let floor = lerp(310.0, 870.0, mp) * MB;
                    let per_row = g.bytes_per_row as f64 * clamp(lerp(1.17, 1.0, mp), 1.0, 1.3);
                    peak = floor + per_row * *rows as f64;
                    seconds = (t0 + c * g.band_count(*rows) as f64) * self.policy.time_ratio;
                }
            }
            seconds = seconds.max(0.05);
        }
        if job.scene_planes > 0 {
            // Scene layers (RFC-052 §8.5): their planes on top, and the node's time.
            peak += job.scene_plane_bytes as f64;
            seconds += (0.096 + 0.011 * job.scene_planes as f64) * mp / 1000.0;
        }
        if job.watermark_bytes > 0 {
            peak += job.watermark_bytes as f64;
        }
        if job.print_layers > 0 {
            // One more result alive while a layer is made (rgba16, 8 B a pixel), and a print pass more
            // for each. Arithmetic, not a measurement.
            peak += 8.0 * pixels;
            let pass = if job.tier != RenderTier::Full {
                0.055 * pixels / CANVAS_PIXELS
            } else if let RenderMode::Bands { rows } = mode {
                let t0 = lerp(0.69, 2.28, mp);
                let c = lerp(0.060, 0.137, mp);
                (t0 + c * BandGeometry::new(job.canvas).band_count(*rows) as f64) * self.policy.time_ratio
            } else {
                0.055 * pixels / CANVAS_PIXELS * self.policy.time_ratio
            };
            seconds += job.print_layers as f64 * pass;
        }
        let composed = job.composition.as_ref().filter(|c| !c.decodes.is_empty());
        if job.decodes_original && job.tier == RenderTier::Full {
            if let Some(composed) = composed {
                // A double exposure's open at the full tier, re-fitted on the Mac (`ComposedOpen`).
                let largest = composed.decodes.iter().map(|d| d.pixels()).fold(f64::MIN, f64::max);
                let decode = if composed.raw {
                    ComposedOpen::FULL_RAW_BASE + ComposedOpen::FULL_RAW_BYTES_PER_PIXEL * largest
                } else {
                    ComposedOpen::FULL_OTHER_BASE + ComposedOpen::FULL_OTHER_BYTES_PER_PIXEL * largest
                };
                peak = (peak + 3.3 * pixels)
                    .max(ComposedOpen::FULL_PIECE_BYTES_PER_PIXEL * pixels + decode + composed.scratch_bytes as f64);
                let per_mp = if composed.raw {
                    ComposedOpen::FULL_RAW_SECONDS_PER_MP
                } else {
                    ComposedOpen::FULL_OTHER_SECONDS_PER_MP
                };
                seconds += composed.decodes.iter().map(|d| per_mp * d.pixels() / 1_000_000.0).sum::<f64>();
            } else {
                // The open (150 MB + 16 B + 5 B a pixel of the decode) against the render with what
                // the decoder leaves resident (3.3 B a pixel); HEIF through Core Image, the reference.
                let decoded = job.original.map_or(pixels, |o| o.pixels()).max(pixels);
                peak = (peak + 3.3 * pixels).max(150.0 * MB + 16.0 * pixels + 5.0 * decoded);
                seconds += 0.009 * mp;
            }
        } else if job.decodes_original && composed.is_some() {
            let composed = composed.unwrap();
            // A double exposure's open below the full tier (`ComposedOpen`).
            let largest = composed.decodes.iter().map(|d| d.pixels()).fold(f64::MIN, f64::max);
            let decode = if composed.raw {
                ComposedOpen::BELOW_RAW_BASE + ComposedOpen::BELOW_RAW_BYTES_PER_PIXEL * largest
            } else {
                ComposedOpen::BELOW_OTHER_BASE + ComposedOpen::BELOW_OTHER_BYTES_PER_PIXEL * largest
            };
            peak = (peak + 3.3 * opened).max(decode + composed.scratch_bytes as f64);
            let per_mp = if composed.raw {
                ComposedOpen::BELOW_RAW_SECONDS_PER_MP
            } else {
                ComposedOpen::BELOW_OTHER_SECONDS_PER_MP
            };
            seconds += composed.decodes.iter().map(|d| per_mp * d.pixels() / 1_000_000.0).sum::<f64>();
        } else if job.decodes_original && job.raw_decode {
            // A photograph's RAW with no proxy here (`RawOpen`), priced by the original's pixels.
            let from = job.original.unwrap_or(job.canvas).pixels();
            peak = (peak + 3.3 * opened).max(RawOpen::BASE + RawOpen::BYTES_PER_PIXEL * from);
            // Fitted at a 2,560 px canvas: a larger one adds its session's growth over the bench's.
            peak += ((560.0 * pixels / CANVAS_PIXELS).max(80.0) - 560.0).max(0.0) * MB;
            seconds += RawOpen::SECONDS_PER_MP * from / 1_000_000.0;
        } else if job.decodes_original {
            // Below the full tier the frame is decoded no larger than the canvas, priced at the dearer
            // decoder by the original's pixels: 240 MB + 7.6 B a pixel.
            let from = job.original.unwrap_or(job.canvas).pixels();
            peak = (peak + 3.3 * opened).max(240.0 * MB + 7.6 * from);
            seconds += 0.003 * from / 1_000_000.0;
        } else if job.opens.is_some() {
            // A frame handed over already decoded is opened again, which copies it into the engine's
            // own source.
            peak += 3.3 * opened;
        }
        if job.hdr_rendition {
            // A second render beside the first result, and the map: + 9 B a pixel, a render's time more.
            peak += 9.0 * pixels;
            seconds *= 2.0;
        }
        if job.gain_map {
            peak = peak.max(Self::gain_map_delivery(pixels, job.gain_maps));
        }
        // The source plane of the frame the job opens, which the footprint does not show.
        let source = 12.0 * opened;
        CostEstimate { peak_bytes: peak.max(0.0) as u64, phone_bytes: (peak.max(0.0) + source) as u64, seconds }
    }

    /// What ImageIO holds a pixel while a file with a gain map is written (`gainMapWriteBytesPerPixel`).
    pub const GAIN_MAP_WRITE_BYTES_PER_PIXEL: f64 = 9.6;
    /// Each copy of the map past the first (`extraMapBytesPerPixel`).
    pub const EXTRA_MAP_BYTES_PER_PIXEL: f64 = 1.25;

    /// A gain-map export's delivery (`gainMapDelivery`): 1.1 GB at 48 MP.
    pub fn gain_map_delivery(pixels: f64, maps: i64) -> f64 {
        64.0 * MB
            + pixels
                * (8.0
                    + 4.0
                    + Self::GAIN_MAP_WRITE_BYTES_PER_PIXEL
                    + (maps - 1).max(0) as f64 * Self::EXTRA_MAP_BYTES_PER_PIXEL)
    }

    /// The class a job's measurements are learned under (`CostModel.key`).
    pub fn key(job: &RenderJob, mode: &RenderMode) -> String {
        fn size_class(mp: f64) -> &'static str {
            if mp < 8.0 {
                "canvas"
            } else if mp < 18.0 {
                "12"
            } else if mp < 36.0 {
                "24"
            } else {
                "48"
            }
        }
        let from = if job.decodes_original && job.tier != RenderTier::Full {
            job.original.map(|o| format!("<{}", size_class(o.megapixels()))).unwrap_or_default()
        } else {
            String::new()
        };
        let size = if job.kind == JobKind::StockPreview { "card" } else { size_class(job.canvas.megapixels()) };
        let how = match mode {
            RenderMode::Whole | RenderMode::Wait(_) => {
                if job.is_reprint() {
                    "reprint"
                } else {
                    "whole"
                }
            }
            RenderMode::Bands { .. } => "bands",
        };
        let mut key = format!("{}|{}{}|{}", job.tier.raw_value(), size, from, how);
        if job.hdr_rendition {
            key += "|hdr";
        }
        if job.decodes_original && job.composition.is_some() {
            key += "|double";
        }
        if job.decodes_original && job.composition.as_ref().is_some_and(|c| c.raw) {
            key += "|raw";
        }
        if job.decodes_original && job.raw_decode && job.composition.is_none() && job.tier != RenderTier::Full {
            key += "|raw";
        }
        key
    }

    pub fn estimate(&self, job: &RenderJob, mode: &RenderMode) -> CostEstimate {
        let s = self.seed(job, mode);
        let Some(c) = self.corrections.get(&Self::key(job, mode)) else { return s };
        // The correction is the footprint's: the source plane is arithmetic, not a measurement to learn.
        let peak = (s.peak_bytes as f64 * c.peak) as u64;
        CostEstimate {
            peak_bytes: peak,
            phone_bytes: peak + (s.phone_bytes - s.peak_bytes),
            seconds: s.seconds * c.time,
        }
    }

    /// Take a finished job's measurements. A measured peak of 0 leaves the peak's correction alone.
    pub fn learn(&mut self, job: &RenderJob, mode: &RenderMode, measured_peak_bytes: u64, measured_seconds: f64) {
        let s = self.seed(job, mode);
        let k = Self::key(job, mode);
        let mut c = self.corrections.get(&k).copied().unwrap_or_default();
        let alpha = self.alpha;
        let samples = c.samples;
        let blend = |old: f64, ratio: f64| {
            // Keep one wild sample from moving the model far: 0.5…2.
            let r = clamp(ratio, 0.5, 2.0);
            if samples == 0 {
                r
            } else {
                old + alpha * (r - old)
            }
        };
        if measured_peak_bytes > 0 && s.peak_bytes > 0 {
            c.peak = blend(c.peak, measured_peak_bytes as f64 / s.peak_bytes as f64);
        }
        if measured_seconds > 0.0 && s.seconds > 0.0 {
            c.time = blend(c.time, measured_seconds / s.seconds);
        }
        c.samples += 1;
        self.corrections.insert(k, c);
    }
}

/// Where the corrections are kept across launches (the Mac's `UserDefaults` key
/// `scheduler.costCorrections.v1`).
pub trait CorrectionStore: Send + Sync {
    fn load(&self) -> HashMap<String, Correction>;
    fn save(&self, corrections: &HashMap<String, Correction>);
}

/// A JSON file of `{key: {peak, time, samples}}`, the same object the Mac stores.
pub struct FileCorrectionStore {
    pub path: std::path::PathBuf,
}

impl CorrectionStore for FileCorrectionStore {
    fn load(&self) -> HashMap<String, Correction> {
        std::fs::read(&self.path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
    fn save(&self, corrections: &HashMap<String, Correction>) {
        if let Ok(bytes) = serde_json::to_vec(corrections) {
            let partial = self.path.with_extension("partial");
            if std::fs::write(&partial, bytes).is_ok() {
                let _ = std::fs::rename(&partial, &self.path);
            }
        }
    }
}
