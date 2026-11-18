//! The app has no network capability, and the kernel enforces it.
//!
//! Nothing in the app needs the network: the engine host reads and writes local files, the
//! webview loads only the app's own bundled pages (`tauri://`, CSP `default-src 'self'`), and
//! the IPC between them is in-process or over pipes. To keep it that way even if a component
//! misbehaves -- above all the engine host, which parses untrusted RAW/TIFF/JPEG files -- `install`
//! puts a seccomp filter on the process before any thread, window or child exists. It is inherited
//! by every child: WebKit's web and network processes and `spektralab-host`.
//!
//! The filter is an allowlist on `socket(2)`'s domain: AF_UNIX (Wayland, X11, D-Bus, the portal)
//! and AF_NETLINK (local kernel messages: GLib's network monitor) are allowed; every other domain
//! -- AF_INET, AF_INET6, AF_PACKET, Bluetooth, VSOCK, ... -- fails with EACCES. `io_uring_setup`
//! fails with ENOSYS (an io_uring ring can create sockets without `socket(2)`), as does any syscall
//! from a foreign ABI (32-bit `int 0x80` and x32 on x86-64), so the domain check cannot be stepped
//! around. Once installed it cannot be removed, by this process or its children
//! (`PR_SET_NO_NEW_PRIVS`).
//!
//! `install` then proves it: opening an AF_INET socket must fail. If the filter cannot be
//! installed, or the probe succeeds, the app does not start.

#[cfg(target_os = "linux")]
pub fn install() -> Result<(), String> {
    use std::io::Error;

    // linux/filter.h, linux/seccomp.h, linux/audit.h
    const BPF_LD_W_ABS: u16 = 0x00 | 0x00 | 0x20;
    const BPF_JMP_JEQ_K: u16 = 0x05 | 0x10 | 0x00;
    const BPF_JMP_JGE_K: u16 = 0x05 | 0x30 | 0x00;
    const BPF_RET_K: u16 = 0x06 | 0x00;
    const SECCOMP_RET_ALLOW: u32 = 0x7fff_0000;
    const SECCOMP_RET_ERRNO: u32 = 0x0005_0000;
    const SECCOMP_MODE_FILTER: libc::c_ulong = 2;
    // struct seccomp_data { int nr; __u32 arch; __u64 instruction_pointer; __u64 args[6]; }
    const OFF_NR: u32 = 0;
    const OFF_ARCH: u32 = 4;
    const OFF_ARG0_LO: u32 = 16; // little-endian: the low half of args[0]

    #[cfg(target_arch = "x86_64")]
    const AUDIT_ARCH: u32 = 0xC000_003E;
    #[cfg(target_arch = "x86_64")]
    const FOREIGN_NR_FROM: u32 = 0x4000_0000; // __X32_SYSCALL_BIT
    #[cfg(target_arch = "aarch64")]
    const AUDIT_ARCH: u32 = 0xC000_00B7;
    #[cfg(target_arch = "aarch64")]
    const FOREIGN_NR_FROM: u32 = u32::MAX; // no second ABI on aarch64: never taken
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    compile_error!("no_network: add this architecture's AUDIT_ARCH");

    let socket = libc::SYS_socket as u32;
    let io_uring_setup = libc::SYS_io_uring_setup as u32;
    let af_unix = libc::AF_UNIX as u32;
    let af_netlink = libc::AF_NETLINK as u32;

    let st = |code: u16, k: u32| libc::sock_filter { code, jt: 0, jf: 0, k };
    let jmp = |code: u16, k: u32, jt: u8, jf: u8| libc::sock_filter { code, jt, jf, k };
    let filter = [
        /*  0 */ st(BPF_LD_W_ABS, OFF_ARCH),
        /*  1 */ jmp(BPF_JMP_JEQ_K, AUDIT_ARCH, 1, 0), // native ABI -> 3
        /*  2 */ st(BPF_RET_K, SECCOMP_RET_ERRNO | libc::ENOSYS as u32),
        /*  3 */ st(BPF_LD_W_ABS, OFF_NR),
        /*  4 */ jmp(BPF_JMP_JGE_K, FOREIGN_NR_FROM, 0, 1), // x32 -> 5, else 6
        /*  5 */ st(BPF_RET_K, SECCOMP_RET_ERRNO | libc::ENOSYS as u32),
        /*  6 */ jmp(BPF_JMP_JEQ_K, io_uring_setup, 0, 1), // -> 7, else 8
        /*  7 */ st(BPF_RET_K, SECCOMP_RET_ERRNO | libc::ENOSYS as u32),
        /*  8 */ jmp(BPF_JMP_JEQ_K, socket, 1, 0), // socket -> 10, else 9
        /*  9 */ st(BPF_RET_K, SECCOMP_RET_ALLOW),
        /* 10 */ st(BPF_LD_W_ABS, OFF_ARG0_LO),
        /* 11 */ jmp(BPF_JMP_JEQ_K, af_unix, 2, 0), // -> 14
        /* 12 */ jmp(BPF_JMP_JEQ_K, af_netlink, 1, 0), // -> 14
        /* 13 */ st(BPF_RET_K, SECCOMP_RET_ERRNO | libc::EACCES as u32),
        /* 14 */ st(BPF_RET_K, SECCOMP_RET_ALLOW),
    ];
    let prog = libc::sock_fprog { len: filter.len() as u16, filter: filter.as_ptr() as *mut libc::sock_filter };

    // SAFETY: plain prctl calls on this process; `prog` and `filter` outlive the call, which copies them.
    unsafe {
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
            return Err(format!("PR_SET_NO_NEW_PRIVS: {}", Error::last_os_error()));
        }
        if libc::prctl(libc::PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog as *const libc::sock_fprog, 0, 0) != 0 {
            return Err(format!("PR_SET_SECCOMP: {}", Error::last_os_error()));
        }
        // The proof: an internet socket must now be refused.
        for domain in [libc::AF_INET, libc::AF_INET6] {
            let fd = libc::socket(domain, libc::SOCK_STREAM, 0);
            if fd >= 0 {
                libc::close(fd);
                return Err(format!("a socket of domain {domain} was still allowed"));
            }
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn install() -> Result<(), String> {
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    // The filter is per process and permanent, so the check runs in a child: this test binary
    // re-run with one test selected and a marker in its environment.
    #[test]
    fn internet_sockets_are_refused_and_local_ones_are_not() {
        if std::env::var_os("SPK_NO_NETWORK_CHILD").is_some() {
            super::install().expect("install");
            unsafe {
                let inet = libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0);
                assert!(inet < 0, "AF_INET allowed");
                assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EACCES));
                assert!(libc::socket(libc::AF_INET6, libc::SOCK_DGRAM, 0) < 0, "AF_INET6 allowed");
                assert!(libc::socket(libc::AF_PACKET, libc::SOCK_RAW, 0) < 0, "AF_PACKET allowed");
                let unix = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
                assert!(unix >= 0, "AF_UNIX refused");
                libc::close(unix);
                // and the children inherit it
                // bash's /dev/tcp opens a real AF_INET socket (sh has no /dev/tcp, so it would
                // "refuse" for the wrong reason). The probe checks the socket call, not a listener.
                let out = std::process::Command::new("bash")
                    .args(["-c", "exec 3<>/dev/tcp/127.0.0.1/9 2>/dev/null; echo \"rc=$?\"; \
                                 python3 -I -c 'import socket; socket.socket()' 2>&1 | tail -1"])
                    .output()
                    .expect("bash");
                let text = String::from_utf8_lossy(&out.stdout);
                assert!(!text.contains("rc=0"), "a child connected: {text}");
                assert!(text.contains("PermissionError"), "a child could open an internet socket: {text}");
            }
            return;
        }
        let me = std::env::current_exe().unwrap();
        let status = std::process::Command::new(me)
            .args(["no_network::tests::internet_sockets_are_refused_and_local_ones_are_not", "--exact", "--nocapture"])
            .env("SPK_NO_NETWORK_CHILD", "1")
            .status()
            .unwrap();
        assert!(status.success(), "the filtered child failed");
    }
}
