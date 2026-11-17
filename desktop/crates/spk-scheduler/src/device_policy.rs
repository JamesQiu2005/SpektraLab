//! The numbers that belong to the device, not to a picture (`DevicePolicy.swift`).
//!
//! An execution plan changes *how* a picture is made (memory reserve, band rows, preview size, cadence)
//! and never *which* picture. These are that plan's device-side numbers. Each says whether it was
//! measured and where.
//!
//! **The desktop PC** (R2) is a second kind of device beside the Mac. Its budget comes from installed
//! RAM and, where the GPU has memory of its own, from that memory as the host reports it — a discrete
//! GPU's memory is not system memory. **Every PC number below is a named constant that was not measured
//! on Windows**; `unmeasured()` lists them, and Settings shows the list.

use serde_json::Value;

/// What the GPU's memory is, as far as anyone has said.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum GpuMemory {
    /// Nobody said: the v1 host's `hello` does not report it. The budget then has no GPU side.
    #[default]
    Unknown,
    /// The GPU shares system memory (an integrated GPU, Apple silicon): the system's reading is the GPU's.
    Unified,
    /// The GPU has this much device-local memory of its own.
    Dedicated { device_local_bytes: u64 },
}

impl GpuMemory {
    /// From the host's `hello` reply. The v1 host reports neither field; they are the additive fields a
    /// host would send (`backend.device_local_bytes`, `backend.unified_memory`), read where present, so
    /// that nothing here changes when one does. Today this is always `Unknown`.
    pub fn from_hello(hello: &Value) -> GpuMemory {
        let backend = &hello["backend"];
        if backend["unified_memory"].as_bool() == Some(true) {
            return GpuMemory::Unified;
        }
        match backend["device_local_bytes"].as_u64() {
            Some(bytes) if bytes > 0 => GpuMemory::Dedicated { device_local_bytes: bytes },
            _ => GpuMemory::Unknown,
        }
    }
}

/// Which kind of machine the policy is for.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub enum DeviceClass {
    /// The Mac's numbers: the Swift's, unchanged.
    #[default]
    Mac,
    /// A Windows (or Linux) desktop: installed RAM and the GPU's memory.
    DesktopPc { installed_ram: u64, gpu: GpuMemory },
}

/// `DevicePolicy`.
#[derive(Clone, Debug, PartialEq)]
pub struct DevicePolicy {
    /// The largest frame this device develops. A larger file is decoded smaller and labelled.
    pub develop_cap_megapixels: f64,
    /// New-frame default preview long edge (a product size target).
    pub preview_long_edge: i64,
    /// Exposure is metered once per session at this size and applied to every tier.
    pub meter_long_edge: i64,
    /// A banded engine bands a full render above this many pixels…
    pub band_above_pixels: u64,
    /// …with planes of at most this many bytes, unless the scheduler says otherwise per job.
    pub default_band_budget_bytes: u64,
    /// This device's time against the reference device's, where the cost model's times were measured.
    pub time_ratio: f64,
    pub device: DeviceClass,
}

impl DevicePolicy {
    /// Settings › Develop › *Preview size*'s choices (2.4.0: up to 3,840 px).
    pub const PREVIEW_EDGES: [i64; 6] = [1600, 1920, 2400, 2560, 3200, 3840];

    /// `DevicePolicy(developCapMegapixels:)`: the Mac's, with this cap.
    pub fn with_cap(develop_cap_megapixels: f64) -> Self {
        DevicePolicy {
            develop_cap_megapixels,
            preview_long_edge: 1920,
            meter_long_edge: 1600,
            band_above_pixels: 20_000_000,
            default_band_budget_bytes: 1 << 30,
            time_ratio: 1.0,
            device: DeviceClass::Mac,
        }
    }

    /// The Mac's: the 6,144 MB allowance of a machine with 7 GB or more of memory.
    pub fn mac() -> Self {
        Self::with_cap(Self::ceiling(6_144.0))
    }

    /// The largest frame an allowance develops: less 1.5 GB for the app, at 40 bytes a pixel.
    pub fn ceiling(allowance_mb: f64) -> f64 {
        let mp = (allowance_mb - 1_536.0) * 1_048_576.0 / 40.0 / 1_000_000.0;
        ((mp / 4.0).floor() * 4.0).max(12.0)
    }

    // ---- the desktop PC (R2). None of these is measured on Windows. ----

    /// **Unmeasured.** The share of installed RAM the PC's develop cap is sized from: the Mac's
    /// 6,144 MB allowance is ~38 % of a 16 GB Mac; a PC has no unified GPU memory to share it with, so
    /// half. A placeholder until a Windows host is measured.
    pub const PC_ALLOWANCE_SHARE_OF_RAM: f64 = 0.5;
    /// **Unmeasured.** The allowance the cap is sized from is never below 4 GB (or the whole RAM, where
    /// that is less): on an 8 GB PC the cap is then `ceiling(4096)` = 64 MP.
    pub const PC_MIN_ALLOWANCE_MB: f64 = 4_096.0;
    /// **Unmeasured.** What the desktop compositor, the browser view and other applications are assumed
    /// to hold of a dedicated GPU's memory; the engine is planned against the rest.
    pub const PC_GPU_RESERVE_BYTES: u64 = 768 << 20;
    /// **Unmeasured.** A PC's render time against the reference device's. 1 until a Windows GPU is
    /// measured, as the Swift's `timeRatio` was before the M3 Max was.
    pub const PC_TIME_RATIO: f64 = 1.0;
    /// **Unmeasured.** Bytes a pixel of a whole full-size render the dedicated GPU must hold (the Mac's
    /// whole render measured 84-100 B a pixel of unified memory; the planes, not the decode, are on the GPU).
    pub const PC_GPU_BYTES_PER_PIXEL: f64 = 72.0;

    /// A Windows/Linux desktop with this much installed RAM and this GPU memory.
    pub fn desktop_pc(installed_ram: u64, gpu: GpuMemory) -> Self {
        let ram_mb = installed_ram as f64 / 1_048_576.0;
        let allowance_mb = (ram_mb * Self::PC_ALLOWANCE_SHARE_OF_RAM).max(Self::PC_MIN_ALLOWANCE_MB.min(ram_mb));
        let mut cap = Self::ceiling(allowance_mb);
        if let GpuMemory::Dedicated { device_local_bytes } = gpu {
            // The largest whole frame the GPU's own memory holds, beside its reserve.
            let usable = device_local_bytes.saturating_sub(Self::PC_GPU_RESERVE_BYTES) as f64;
            let gpu_mp = usable / Self::PC_GPU_BYTES_PER_PIXEL / 1_000_000.0;
            cap = cap.min(((gpu_mp / 4.0).floor() * 4.0).max(12.0));
        }
        DevicePolicy {
            develop_cap_megapixels: cap,
            time_ratio: Self::PC_TIME_RATIO,
            device: DeviceClass::DesktopPc { installed_ram, gpu },
            ..Self::with_cap(cap)
        }
    }

    /// What the GPU's own memory can still give the engine, for `MemoryReading::gpu_available`: the
    /// device-local memory, less the engine's own holdings (`memory_report.total_bytes`) and the
    /// reserve. `None` unless the GPU has dedicated memory and it is known.
    pub fn gpu_available(&self, engine_held_bytes: u64) -> Option<u64> {
        match self.device {
            DeviceClass::DesktopPc { gpu: GpuMemory::Dedicated { device_local_bytes }, .. } => {
                Some(device_local_bytes.saturating_sub(engine_held_bytes).saturating_sub(Self::PC_GPU_RESERVE_BYTES))
            }
            _ => None,
        }
    }

    /// "mac" or "desktopPc".
    pub fn device_name(&self) -> &'static str {
        match self.device {
            DeviceClass::Mac => "mac",
            DeviceClass::DesktopPc { .. } => "desktopPc",
        }
    }

    /// Every number of this policy that was not measured on this kind of machine.
    pub fn unmeasured(&self) -> Vec<String> {
        match self.device {
            // The Mac's own: its time ratio is 1 (the M3 Max measured ~0.3 and was not adopted), and
            // the budget's tuning is the reference device's.
            DeviceClass::Mac => vec!["timeRatio".into(), "budget tuning (the reference device's)".into()],
            DeviceClass::DesktopPc { gpu, .. } => {
                let mut v = vec![
                    "timeRatio".into(),
                    "allowance share of installed RAM".into(),
                    "budget tuning (the reference device's)".into(),
                    "Windows memory reading (GlobalMemoryStatusEx mapping)".into(),
                ];
                match gpu {
                    GpuMemory::Dedicated { .. } => {
                        v.push("GPU reserve".into());
                        v.push("GPU bytes a pixel".into());
                    }
                    GpuMemory::Unknown => v.push("GPU memory (the host does not report it)".into()),
                    GpuMemory::Unified => {}
                }
                v
            }
        }
    }
}

impl Default for DevicePolicy {
    fn default() -> Self {
        Self::mac()
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use serde_json::json;

    const GB: u64 = 1 << 30;

    #[test]
    fn the_mac_cap_is_120_mp() {
        assert_eq!(DevicePolicy::mac().develop_cap_megapixels, 120.0);
    }

    #[test]
    fn a_pc_is_capped_by_its_ram_and_by_a_dedicated_gpu() {
        let p16 = DevicePolicy::desktop_pc(16 * GB, GpuMemory::Unknown);
        assert_eq!(p16.develop_cap_megapixels, DevicePolicy::ceiling(8192.0));
        let p8 = DevicePolicy::desktop_pc(8 * GB, GpuMemory::Unknown);
        assert_eq!(p8.develop_cap_megapixels, DevicePolicy::ceiling(4096.0));
        let small_gpu = DevicePolicy::desktop_pc(64 * GB, GpuMemory::Dedicated { device_local_bytes: 4 * GB });
        assert!(
            small_gpu.develop_cap_megapixels
                < DevicePolicy::desktop_pc(64 * GB, GpuMemory::Unknown).develop_cap_megapixels
        );
        assert!(small_gpu.unmeasured().iter().any(|u| u == "GPU reserve"));
    }

    #[test]
    fn the_gpu_side_is_the_device_memory_less_the_engine_and_the_reserve() {
        let p = DevicePolicy::desktop_pc(32 * GB, GpuMemory::Dedicated { device_local_bytes: 8 * GB });
        assert_eq!(p.gpu_available(GB), Some(8 * GB - GB - DevicePolicy::PC_GPU_RESERVE_BYTES));
        assert_eq!(DevicePolicy::desktop_pc(32 * GB, GpuMemory::Unified).gpu_available(0), None);
        assert_eq!(DevicePolicy::mac().gpu_available(0), None);
    }

    #[test]
    fn the_v1_hello_reports_no_gpu_memory() {
        let hello = json!({"backend": {"api": "vulkan", "available": true, "device_name": "Apple M6"}});
        assert_eq!(GpuMemory::from_hello(&hello), GpuMemory::Unknown);
        let reported = json!({"backend": {"device_local_bytes": 8u64 << 30}});
        assert_eq!(GpuMemory::from_hello(&reported), GpuMemory::Dedicated { device_local_bytes: 8 * GB });
    }
}
