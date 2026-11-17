//! How many of the develop page's neighbours a full-size inspection makes ahead (`PrefetchPolicy.swift`).
//!
//! - **The owner's decision (2026-11-13): on a machine with 16 GB or less, +1 only** — the next frame
//!   the way the person is going. Above 16 GB, +1, −1, +2, −2.
//! - **None below a floor of headroom** (`allows`): a prefetch is speculative work, so it starts only
//!   where the host's headroom, once the prefetch's own price is paid, keeps `floor_bytes`.
//! - The memory is injectable, so the 16 GB rule is checked on a machine with more.
//!
//! On a PC the same rule applies to installed RAM; the 16 GB line was the Mac owner's decision and is
//! not a Windows measurement.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PrefetchPolicy {
    /// The machine's physical memory (a 16 GB machine: 17,179,869,184 B).
    pub physical_memory: u64,
    /// What the host keeps once a prefetch is paid for: 600 MB (the critical level) + 2,400 MB (the
    /// dearest next develop measured: a RAW's first open).
    pub floor_bytes: u64,
}

impl PrefetchPolicy {
    /// 16 GB and less: +1 only.
    pub const SMALL_MACHINE_MEMORY: u64 = 16 << 30;

    pub fn new(physical_memory: u64) -> Self {
        PrefetchPolicy { physical_memory, floor_bytes: (600 + 2_400) << 20 }
    }

    /// This machine's, or — in a debug build — `SPK_SIMULATE_RAM_GB`, for a check of the 16 GB rule on
    /// a machine with more.
    pub fn current(physical_memory: u64) -> Self {
        #[cfg(debug_assertions)]
        if let Some(gb) = std::env::var("SPK_SIMULATE_RAM_GB").ok().and_then(|t| t.parse::<f64>().ok()) {
            if gb > 0.0 {
                return Self::new((gb * 1_073_741_824.0) as u64);
            }
        }
        Self::new(physical_memory)
    }

    /// Whether this is a machine of 16 GB or less (`isSmallMac`).
    pub fn is_small_machine(&self) -> bool {
        self.physical_memory <= Self::SMALL_MACHINE_MEMORY
    }

    /// The neighbours made ahead, as steps from the frame shown, in the order they are made.
    pub fn offsets(&self, direction: i64, reach: i64) -> Vec<i64> {
        let d = if direction >= 0 { 1 } else { -1 };
        if self.is_small_machine() {
            return vec![d];
        }
        let mut out = Vec::new();
        for k in 1..=reach.max(1) {
            out.push(d * k);
            out.push(-d * k);
        }
        out
    }

    /// Whether a prefetch priced at `cost` bytes of the host may start with `headroom`.
    pub fn allows(&self, cost: u64, headroom: u64) -> bool {
        headroom >= cost.wrapping_add(self.floor_bytes)
    }
}
