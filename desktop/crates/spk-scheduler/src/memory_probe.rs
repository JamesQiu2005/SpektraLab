//! How much memory there is, read from the system (`MemoryProbe.swift`, RFC-036 §2.1).
//!
//! Two different questions:
//!
//! - **the app's allowance** (`app_available`): on a desktop there is no per-app limit. On the Mac it is
//!   what the host can give before it swaps — free + inactive + purgeable pages and half of what the
//!   compressor holds (`MemoryReading::mac`). On Windows it is the smaller of the physical memory
//!   available (which already counts the standby list) and the commit charge still available, because
//!   a Vulkan allocation past the commit limit fails rather than pages (`MemoryReading::windows`).
//! - **the machine's headroom** (`phone_headroom`, the Swift's name kept): free + inactive + purgeable
//!   on the Mac; available physical memory on Windows.
//!
//! The readings are a trait (`MemoryProbe`) with three implementations: `InjectedProbe` (tests: any
//! host in any state), `MacProbe` (`host_statistics64`, `proc_pid_rusage`) and `WindowsProbe`
//! (`GlobalMemoryStatusEx`, `K32GetProcessMemoryInfo`). **The Windows probe is compile-checked only**:
//! nothing in this crate can run it on the Mac that tests it.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// One reading of the host (`MemoryReading`). Keys as the Swift's `Codable` writes them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemoryReading {
    /// The app's remaining allowance, in bytes.
    pub app_available: u64,
    /// The host's page counts, in bytes.
    pub free: u64,
    pub inactive: u64,
    pub purgeable: u64,
    pub wired: u64,
    pub compressed: u64,
    /// The measured process's footprint (`phys_footprint` on the Mac; private commit on Windows).
    pub footprint: u64,
    /// **Desktop PC only**: what the GPU's own memory can still give the engine, where the GPU has
    /// memory of its own (`DevicePolicy::gpu_available`). Absent on the Mac and wherever the GPU's
    /// memory is unknown; then the budget is the Swift's two sides alone.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpu_available: Option<u64>,
}

impl MemoryReading {
    /// Reclaimable host pages: the budget's conservative starting point. Excludes compressed memory.
    pub fn phone_headroom(&self) -> u64 {
        self.free + self.inactive + self.purgeable
    }

    /// The share of the compressor's pages the Mac's allowance counts on
    /// (`BudgetTuning.askedCompressedShare`'s).
    pub const MAC_COMPRESSED_SHARE: f64 = 0.5;

    /// **The Mac's allowance**: what the host can give this app before it swaps.
    pub fn mac_allowance(free: u64, inactive: u64, purgeable: u64, compressed: u64) -> u64 {
        free + inactive + purgeable + (compressed as f64 * Self::MAC_COMPRESSED_SHARE) as u64
    }

    /// `MemoryProbe.reading(...)` on the Mac: the arithmetic of a read, apart from the system calls, so a
    /// check can hand it the pages of a Mac it is not running on.
    pub fn mac(free: u64, inactive: u64, purgeable: u64, wired: u64, compressed: u64, footprint: u64) -> Self {
        MemoryReading {
            app_available: Self::mac_allowance(free, inactive, purgeable, compressed),
            free,
            inactive,
            purgeable,
            wired,
            compressed,
            footprint,
            gpu_available: None,
        }
    }

    /// The same for Windows, from `MEMORYSTATUSEX` and the process's counters. **Unmeasured**: the
    /// mapping is the nearest analogue of the Mac's and no Windows host has calibrated it.
    ///
    /// - `free` is `ullAvailPhys`, which already includes the standby list (Windows' cache, what the Mac
    ///   calls inactive and purgeable), so `inactive` and `purgeable` are 0;
    /// - Windows does not report its compression store here: `compressed` is 0;
    /// - the allowance is the smaller of `ullAvailPhys` and `ullAvailPageFile` (the commit still
    ///   available): past the commit limit a Vulkan allocation fails ("Insufficient system commit
    ///   budget", `vulkan_gpu.cpp`) rather than pages.
    pub fn windows(avail_phys: u64, avail_commit: u64, footprint: u64) -> Self {
        MemoryReading {
            app_available: avail_phys.min(avail_commit),
            free: avail_phys,
            inactive: 0,
            purgeable: 0,
            wired: 0,
            compressed: 0,
            footprint,
            gpu_available: None,
        }
    }
}

/// A source of readings. `read` is called by the queue before every plan and every 50 ms while a
/// full-size job runs; it must be cheap and must not call back into the queue while it holds a lock
/// of its own.
pub trait MemoryProbe: Send + Sync {
    fn read(&self) -> MemoryReading;
}

/// Readings a test (or a tool) sets.
#[derive(Clone, Default)]
pub struct InjectedProbe {
    reading: Arc<Mutex<MemoryReading>>,
}

impl InjectedProbe {
    pub fn new(reading: MemoryReading) -> Self {
        InjectedProbe { reading: Arc::new(Mutex::new(reading)) }
    }
    pub fn set(&self, reading: MemoryReading) {
        *self.reading.lock().unwrap() = reading;
    }
}

impl MemoryProbe for InjectedProbe {
    fn read(&self) -> MemoryReading {
        *self.reading.lock().unwrap()
    }
}

/// A reading made of a closure, for a probe that composes others.
pub struct FnProbe<F: Fn() -> MemoryReading + Send + Sync>(pub F);

impl<F: Fn() -> MemoryReading + Send + Sync> MemoryProbe for FnProbe<F> {
    fn read(&self) -> MemoryReading {
        (self.0)()
    }
}

/// The system's own probe for this platform: `MacProbe` on macOS, `WindowsProbe` on Windows.
/// `pid` is the process whose footprint is reported (the engine host's; `None`: this process).
pub fn system_probe(pid: Option<u32>) -> Option<Box<dyn MemoryProbe>> {
    #[cfg(target_os = "macos")]
    {
        Some(Box::new(MacProbe { pid }))
    }
    #[cfg(windows)]
    {
        Some(Box::new(WindowsProbe { pid }))
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = pid;
        None
    }
}

#[cfg(target_os = "macos")]
pub use mac::MacProbe;

#[cfg(target_os = "macos")]
mod mac {
    use super::{MemoryProbe, MemoryReading};

    /// `host_statistics64(HOST_VM_INFO64)` and `proc_pid_rusage(RUSAGE_INFO_V2).ri_phys_footprint`.
    pub struct MacProbe {
        pub pid: Option<u32>,
    }

    #[repr(C)]
    #[derive(Default)]
    struct VmStatistics64 {
        free_count: u32,
        active_count: u32,
        inactive_count: u32,
        wire_count: u32,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: u32,
        speculative_count: u32,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: u32,
        throttled_count: u32,
        external_page_count: u32,
        internal_page_count: u32,
        total_uncompressed_pages_in_compressor: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct RusageInfoV2 {
        uuid: [u8; 16],
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        proc_start_abstime: u64,
        proc_exit_abstime: u64,
        child_user_time: u64,
        child_system_time: u64,
        child_pkg_idle_wkups: u64,
        child_interrupt_wkups: u64,
        child_pageins: u64,
        child_elapsed_abstime: u64,
        diskio_bytesread: u64,
        diskio_byteswritten: u64,
    }

    const HOST_VM_INFO64: i32 = 4;
    const RUSAGE_INFO_V2: i32 = 2;

    extern "C" {
        fn mach_host_self() -> u32;
        fn host_statistics64(host: u32, flavor: i32, info: *mut i32, count: *mut u32) -> i32;
        static vm_kernel_page_size: usize;
        fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut RusageInfoV2) -> i32;
        fn getpid() -> i32;
    }

    impl MacProbe {
        fn pages() -> (u64, u64, u64, u64, u64) {
            let mut stats = VmStatistics64::default();
            let mut count = (std::mem::size_of::<VmStatistics64>() / std::mem::size_of::<i32>()) as u32;
            // SAFETY: the buffer is a `vm_statistics64` of the size passed, as the call requires.
            let kr = unsafe {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    &mut stats as *mut VmStatistics64 as *mut i32,
                    &mut count,
                )
            };
            if kr != 0 {
                return (0, 0, 0, 0, 0);
            }
            // SAFETY: a constant the kernel exports.
            let page = unsafe { vm_kernel_page_size } as u64;
            (
                stats.free_count as u64 * page,
                stats.inactive_count as u64 * page,
                stats.purgeable_count as u64 * page,
                stats.wire_count as u64 * page,
                stats.compressor_page_count as u64 * page,
            )
        }

        fn footprint(pid: Option<u32>) -> u64 {
            let mut info = RusageInfoV2::default();
            // SAFETY: `info` is a `rusage_info_v2`, the flavor asked for.
            let pid = pid.map(|p| p as i32).unwrap_or_else(|| unsafe { getpid() });
            let rc = unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V2, &mut info) };
            if rc == 0 {
                info.phys_footprint
            } else {
                0
            }
        }
    }

    impl MemoryProbe for MacProbe {
        fn read(&self) -> MemoryReading {
            let (free, inactive, purgeable, wired, compressed) = Self::pages();
            MemoryReading::mac(free, inactive, purgeable, wired, compressed, Self::footprint(self.pid))
        }
    }
}

#[cfg(windows)]
pub use windows::WindowsProbe;

#[cfg(windows)]
mod windows {
    use super::{MemoryProbe, MemoryReading};
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::ProcessStatus::{
        K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
    };
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};

    /// `GlobalMemoryStatusEx` and `K32GetProcessMemoryInfo` (private commit). **Compile-checked
    /// only**: it has never run, and its mapping onto the Mac's reading is unmeasured.
    pub struct WindowsProbe {
        pub pid: Option<u32>,
    }

    impl WindowsProbe {
        fn status() -> Option<MEMORYSTATUSEX> {
            // SAFETY: a zeroed MEMORYSTATUSEX with its length set, as the call requires.
            let mut status: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
            status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
            let ok = unsafe { GlobalMemoryStatusEx(&mut status) };
            (ok != 0).then_some(status)
        }

        fn private_commit(pid: Option<u32>) -> u64 {
            // SAFETY: handles are closed where opened; the counters are the size passed.
            unsafe {
                let (process, owned) = match pid {
                    Some(pid) => (OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid), true),
                    None => (GetCurrentProcess(), false),
                };
                if process.is_null() {
                    return 0;
                }
                let mut counters: PROCESS_MEMORY_COUNTERS_EX = std::mem::zeroed();
                counters.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
                let ok = K32GetProcessMemoryInfo(
                    process,
                    &mut counters as *mut PROCESS_MEMORY_COUNTERS_EX as *mut PROCESS_MEMORY_COUNTERS,
                    counters.cb,
                );
                if owned {
                    CloseHandle(process);
                }
                if ok != 0 {
                    counters.PrivateUsage as u64
                } else {
                    0
                }
            }
        }

        /// Installed physical memory, for `DevicePolicy::desktop_pc`.
        pub fn installed_memory() -> u64 {
            Self::status().map(|s| s.ullTotalPhys).unwrap_or(0)
        }
    }

    impl MemoryProbe for WindowsProbe {
        fn read(&self) -> MemoryReading {
            let Some(status) = Self::status() else { return MemoryReading::default() };
            MemoryReading::windows(status.ullAvailPhys, status.ullAvailPageFile, Self::private_commit(self.pid))
        }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn the_mac_allowance_is_the_headroom_and_half_the_compressor() {
        let mb = 1u64 << 20;
        let r = MemoryReading::mac(700 * mb, 100 * mb, 50 * mb, 0, 1000 * mb, 0);
        assert_eq!(r.app_available, 850 * mb + 500 * mb);
        assert_eq!(r.phone_headroom(), 850 * mb);
    }

    #[test]
    fn the_windows_allowance_is_bound_by_the_commit_left() {
        let gb = 1u64 << 30;
        let r = MemoryReading::windows(12 * gb, 3 * gb, 0);
        assert_eq!(r.app_available, 3 * gb);
        assert_eq!(r.phone_headroom(), 12 * gb);
        assert_eq!(MemoryReading::windows(2 * gb, 9 * gb, 0).app_available, 2 * gb);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_mac_probe_reads_this_mac() {
        let r = MacProbe { pid: None }.read();
        // A reading, not a measurement: the machine has some memory and this process a footprint.
        assert!(r.phone_headroom() > 0 || r.wired > 0);
        assert!(r.footprint > 0);
    }
}
