// Prevents an additional console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // No network capability, enforced by the kernel for this process and every child (WebKit's
    // processes, the engine host): first, before any thread or window exists. See no_network.rs.
    if let Err(e) = spektralab_lib::no_network::install() {
        eprintln!("Develop will not start: its no-network guard could not be put in place ({e}).");
        std::process::exit(1);
    }
    // WebKitGTK's DMABUF renderer crashed the web process on the first Linux test machine (Intel
    // UHD 620, Mesa, Wayland, WebKitGTK 2.52): a segfault in libc while full-resolution frames
    // (~97 MB each at 24 MP) were being drawn, which closes the window. Tauri's Linux graphics
    // guide (v2.tauri.app/develop/debug/linux-graphics) gives this switch as the fix for that class
    // of crash, set before any webview exists. The canvas draws with WebGL either way. A value the
    // user already set (e.g. 0, to compare) wins.
    #[cfg(target_os = "linux")]
    if std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
        // SAFETY: before any thread is started (no_network::install starts none).
        unsafe { std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1") };
    }
    spektralab_lib::run()
}
