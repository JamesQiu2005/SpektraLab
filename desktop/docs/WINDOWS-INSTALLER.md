# Building the Windows installer on a Mac

The NSIS installer (`SpektraLab_<version>_x64-setup.exe`) cross-builds on macOS.
CI still builds it natively on `windows-latest` (MSVC) and installs it there;
this document covers the Mac path.

## One-time setup

```bash
brew install rustup makensis mingw-w64 sevenzip     # sevenzip only for checking the result
rustup default stable                               # if rustup has no toolchain yet
rustup target add x86_64-pc-windows-gnu
cd desktop && npm ci
```

Homebrew's `rust` formula can be installed alongside, but it has no Windows
target. `scripts/package.mjs` puts rustup's proxies (`~/.cargo/bin`,
`/opt/homebrew/opt/rustup/bin`) first on `PATH` and stops if the `rustc` it
finds is not rustup's.

## Build

```bash
cd desktop
node scripts/package.mjs windows --host-dir <dir with spektralab-host.exe + engine/>
# or: SPEKTRALAB_HOST_DIR=<dir> npm run package:windows
# with no host argument it reads ../build/host-win-x64 (engine/build-windows-cross.sh output)
```

The output is `desktop/release/windows/SpektraLab_<version>_x64-setup.exe`.
The script refuses to run without `spektralab-host.exe` and its `engine/`
resources. It also refuses if any tool is missing (`makensis`,
`x86_64-w64-mingw32-gcc`, `x86_64-w64-mingw32-windres`, or the rustup target)
and names the command that installs it.

The first run downloads three things:
- crates;
- Tauri's NSIS plugin `nsis_tauri_utils.dll` (hash-checked by Tauri);
- Node v24.19.0's `win-x64/node.exe` for the bundled CLI, cached in
  `desktop/.cache/` and checked against the SHA-256 that nodejs.org publishes.
  A cross build cannot ship the Mac's own `node`, which the script used to do
  implicitly (`build-agent.mjs --target=win32`).

## Toolchain choice: `x86_64-pc-windows-gnu` (MinGW-w64)

This build uses MinGW-w64 rather than cargo-xwin/MSVC, for four reasons:

- **One toolchain.** The engine host (`engine/build-windows-cross.sh`) is
  already MinGW-built, and Homebrew's `mingw-w64` provides the linker and
  `windres` that `tauri-build` needs for the icon and manifest resource.
- **No Microsoft SDK download or licence step.** cargo-xwin fetches the MSVC
  CRT and the Windows SDK (about 1 GB) and accepts Microsoft's licence on your
  behalf at build time. The GNU path needs nothing beyond Homebrew and rustup.
- **No CRT redistributable.** The app imports only Windows system DLLs: the
  Universal CRT `api-ms-win-crt-*` sets, kernel32/user32 and friends. Nothing
  needs installing besides WebView2.
- **Cost.** WebView2's static loader is MSVC-only, so on GNU
  `webview2-com-sys` links `WebView2Loader.dll` dynamically. Tauri's NSIS
  bundler installs that DLL beside `spektralab.exe` for `-gnu` targets
  (`installer.nsi`: `File /oname=WebView2Loader.dll`), and uninstall removes
  it.

`SPEKTRALAB_WIN_TOOLCHAIN=msvc` selects Tauri's documented cargo-xwin path
(`--runner cargo-xwin`, needs `cargo install --locked cargo-xwin` and
`brew install llvm`). It is wired up but was not run for this build.

## WebView2

`tauri.conf.json` sets `bundle.windows.webviewInstallMode` to
`downloadBootstrapper` (silent). At install time the installer checks the
registry for the WebView2 runtime. Only if the runtime is missing does it
download Microsoft's bootstrapper (`go.microsoft.com/fwlink/p/?LinkId=2124703`)
and run it. Windows 11 and current Windows 10 already have the runtime. An
offline machine without it needs `offlineInstaller` instead (about 127 MB
larger).

## Checking the result without Windows

```bash
I=release/windows/SpektraLab_*_x64-setup.exe
file $I                                  # PE32 ... Nullsoft Installer self-extracting archive
7zz l $I                                 # Type = Nsis; spektralab.exe, spektralab-host.exe,
                                         # WebView2Loader.dll, host/engine/**, agents/node.exe
7zz x -oout $I && file out/spektralab.exe            # PE32+ executable (GUI) x86-64
x86_64-w64-mingw32-objdump -p out/spektralab.exe | grep 'DLL Name'   # system DLLs + WebView2Loader.dll
```

This only checks the installer's contents. Neither the installer nor the app
has been run here: there is no Windows machine and no wine. CI's
`package-windows` job is what installs it silently on Windows. The installer
is unsigned (`bundle.windows.signCommand` is unset).
