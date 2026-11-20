# Windows v2 test packages

Windows v2 has an independent version line. The Windows 1.x prereleases remain available to users who need to roll back. The v2 development branch does not publish public releases.

1. Run `npm run check` in `desktop/` and review the [first-run checklist](WINDOWS-V2-CHECKLIST.md).
2. On GitHub, run the packaging workflow for `Windows_Linux_v2`. It checks the frontend and scheduler, builds the engine with MSVC and MinGW, and makes a Windows NSIS installer. The runner installs in a fresh directory, checks both installed helpers, verifies the extracted portable ZIP against its manifest, and starts its render host. It verifies that both desktop executables load the main window in WebView2 and close cleanly before uninstalling the test copy. The installer and ZIP upload only after those checks pass. The verification step has a 10-minute limit. On failure, look for the `spektralab-windows-package-logs` artifact with the build and verification output captured so far.
3. On a Windows PC with a Vulkan GPU, verify install, RAW editing, export, library data and uninstall. Extract the portable to a new directory and verify that it starts and renders. A hosted runner does not replace these tests.
4. Before a public release, verify data migration and rollback, the reproducibility of the library helper and legal notices. Keep the exact source, versioned filenames, checksums and notes with the artifact.

See [Windows installer](WINDOWS-INSTALLER.md) for local packaging instructions. The dependency archives follow the npm and Rust lockfiles; rebuild the notices when the locks change. Never overwrite a published version or attach Windows binaries to a macOS tag.

Windows installers built from a Git checkout contain a build record at `host/windows-build.json`. The portable packager checks it against the source tree, version and installed render host before copying any files. The portable `BUILD-MANIFEST.json` records the source tree ID and render host SHA-256 alongside the base commit.

To repeat the package check from the repository root in PowerShell 7, use a test Windows account without a v2 installation and an empty output directory. Use Python 3 and Node.js on PATH, and run `npm ci` in `desktop/` first to install the Playwright client. Use an interactive Windows session with WebView2 installed.

```powershell
$out = New-Item -ItemType Directory -Path "$env:TEMP\spk-verified-artifacts"
./.github/scripts/windows-package-check.ps1 -Installer '<path to the v2 setup.exe>' `
  -ArtifactDirectory $out.FullName -ScratchRoot $env:TEMP -VerifyDesktop
```

## Upgrade and roll back a test build

1. Close SpektraLab and back up the v2 library and its referenced RAW files. Keep the installer for the current version.
2. Run the newer installer and use the existing install location. Reopen the test library and verify an existing edit and rating. Open and render a referenced RAW.
3. To roll back, close SpektraLab, uninstall the newer build with the app data checkbox clear, and install the saved older build. Verify the restored version and reopen the test library. Use the pre-upgrade backup when the newer build has changed the catalog schema.

## Try a saved Windows 1.x edit

Copy the RAW to a test folder. Find its saved edit under `%APPDATA%\app.spektralab.desktop\Sidecars` by matching the JSON's `source.path`. Copy that JSON beside the test photo as `<filename-with-extension>.spektra.json`. Open the copy in v2. On first read, v2 imports the edit into its own app data. The adjacent file stays available, and subsequent edits go to the v2 copy. Check the crop, exposure and export against the old build before using the same edit in production.

