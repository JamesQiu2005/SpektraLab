# Packaging the verified Windows editor

The NSIS installer wraps an already verified runtime; it does not compile or
replace the spectral engine. Preserve the supplied runtime/dependency source
and licences inside the payload. Never include RAWs, sidecars, test exports,
logs, access tokens or `.env` files.

Use a current NSIS3 Unicode compiler and a Microsoft-signed Evergreen WebView2
bootstrapper from https://go.microsoft.com/fwlink/p/?LinkId=2124703 .
Verify the NSIS archive against its upstream release digest and the bootstrapper
with Authenticode. `build-installer.ps1` refuses a bad Microsoft signature,
verifies every payload manifest entry and refuses an existing output.

```powershell
./distribution/windows/build-installer.ps1 -Payload D:/release/payload -MakeNSIS D:/tools/nsis/makensis.exe -WebViewBootstrapper D:/tools/MicrosoftEdgeWebview2Setup.exe -Output D:/release/SpektraLab-Windows-Setup.exe
```

The installer requests `user` execution, writes HKCU/current-user shortcuts and
installs into LocalAppData/Programs/SpektraLab-Community. On a missing runtime it
runs the Microsoft bootstrapper `/silent /install` and rechecks the registry.
An offline/failed runtime install aborts before the app payload is written.
Vulkan/GPU drivers remain the user's responsibility; no CPU fallback is hidden.

Uninstaller commands are generated from exact payload files and bottom-up empty
directories. There is no recursive directory deletion, photo/settings deletion
or uninstall of Microsoft's shared runtime. Installation does not change file
associations or the machine PATH. Close the app normally before updating.

The app keeps the acceptance build's independent identifier
`app.spektralab.validation.gestures` to retain the tested executable. This is
documented as a community namespace; no official app settings are migrated.

Runtime source build: the release includes `source/reproduce-editor.ps1` with
explicit CMake/MinGW/Vulkan/LibRaw paths, Node/npm and Rust/MSVC prerequisites.
Use Cargo/package locks, one compiler job, and copy the generated engine
resources (including original product B&W resources) with their notice.

Test a new exact installer with `/S /D=<new isolated directory>` (D last), verify
payload hashes/shortcuts/HKCU entries and run the installed binary/native host.
Exercise uninstall with an extra foreign file and verify it and existing
preferences remain. Record missing-WebView bootstrap as untested if the host
already has it; do not remove a user's runtime just to exercise that branch.

NSIS documentation: https://nsis.sourceforge.io/Docs/Chapter4.html .
Microsoft deployment: https://learn.microsoft.com/microsoft-edge/webview2/concepts/distribution .
The community installer is unsigned; do not suppress Windows security checks.
