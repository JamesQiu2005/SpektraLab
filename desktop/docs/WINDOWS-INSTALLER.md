# Building the Windows v2 installer

The per-user x64 installer installs **SpektraLab v2** with `spektralab-v2.exe`,
its own Start menu folder and the application ID `app.spektralab.desktop.v2`.
It leaves RAW and TIFF associations and the Windows 1.x data directory alone.
See [upgrade and rollback](WINDOWS-RELEASES.md) before replacing a test build.

## Build on Windows

Use Node 24 with npm, a Rust Windows toolchain, and a staged Windows Vulkan host.
The manual GitHub workflow builds the host with MinGW-w64 and uses MSVC for the
Tauri app. It runs on `Windows_Linux_v2` and uploads the tested installer and
portable ZIP as Actions artifacts.

For a local build, follow [Windows engine build and staging](../../engine/WINDOWS.md)
to produce the host from this checkout. Its staging directory must have
`spektralab-host.exe`, `engine/` with the SPIR-V shaders and resources, and
`licenses/`. Start in the repository root in PowerShell:

```powershell
$hostStage = (Resolve-Path -LiteralPath './build/host-win-x64').Path
Set-Location desktop
npm ci
npm run package:win -- --host-dir $hostStage
```

Use an MSVC developer environment with Rust's `x86_64-pc-windows-msvc` target,
or set `SPEKTRALAB_WIN_TOOLCHAIN=gnu` for a local build with the
`x86_64-pc-windows-gnu` Rust target and MinGW's compiler and resource tools on
PATH. A GNU package carries `WebView2Loader.dll` beside the application.

If the checkout path contains non-ASCII characters, set `CARGO_TARGET_DIR`
to an absolute, writable path containing only ASCII characters before building.
The build stages the application icon there so MinGW windres can read it.

The bundled CLI uses the published [Node v24.19.0 Windows x64 runtime](https://nodejs.org/en/blog/release/v24.19.0).
The build uses that executable from PATH when it matches, or you can set
`SPEKTRALAB_NODE_RUNTIME` to the absolute path of the official x64 `node.exe`
before packaging. The CLI staging script checks its SHA-256.

## Output and verification

The installer is `desktop/release/windows/SpektraLab v2_<version>_x64-setup.exe`.
It carries the rendering and library helpers, engine resources, the CLI
runtime and the verified Windows dependency notice archive under
`host/licenses/windows-v2-runtime-notices.zip`. The library helper's SHA-256
is checked against the pin in `vendor/spklib/windows-x64/`.

Follow [the Windows package check](WINDOWS-RELEASES.md) to install in a test
directory, check both helpers and notices, verify the portable ZIP and uninstall.
The installer downloads Microsoft's WebView2 bootstrapper when the test account
does not already have the runtime. A Windows Vulkan driver is required to render.

For a content-only inspection with `file` and 7-Zip, run
`npm run check:installer -- "<installer path>"` from `desktop/`.

## Cross-build a Windows installer from macOS

Use the Windows GNU Rust target, MinGW-w64, NSIS and the tools listed in
[`engine/build-windows-cross.sh`](../../engine/build-windows-cross.sh).
After `npm ci` in `desktop/`, `npm run package:win` builds the Windows host
from this tree and downloads the pinned Windows Node binary when necessary.
Pass `--host-dir` to use an existing staged Windows host. Verify the resulting
package on Windows using the same checks above.
