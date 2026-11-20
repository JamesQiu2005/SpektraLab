use std::{env, fs, path::PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        // Cargo's library test harness does not link Tauri's binary resources.
        // Its dialog dependency imports TaskDialogIndirect from Common Controls v6.
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'");
        // The desktop binary already embeds Tauri's manifest resource.
        println!("cargo:rustc-link-arg-bin=spektralab=/MANIFEST:NO");
    }
    if cfg!(windows)
        && env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("gnu")
        && !manifest_dir.to_string_lossy().is_ascii()
    {
        let original = manifest_dir.join("icons/icon.ico");
        let staged = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("spektralab-icon.ico");
        println!("cargo:rerun-if-changed={}", original.display());
        fs::copy(original, &staged).expect("stage the application icon for windres");
        let windows = tauri_build::WindowsAttributes::new().window_icon_path(staged);
        let attributes = tauri_build::Attributes::new().windows_attributes(windows);
        tauri_build::try_build(attributes).expect("build Tauri Windows resources");
    } else {
        tauri_build::build();
    }
}
