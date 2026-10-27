# SpektraLab Windows community build

[中文安装说明](README.windows.zh-CN.md) · [Downloads](https://github.com/LUOJW5566/SpektraLab/releases/latest)

This is a community Windows port of [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab),
maintained in this fork by LUOJW5566. Original app: Hanze Qiu. Original spectral
model, measured profiles and print LUTs: Andrea Volpato's [spektrafilm](https://github.com/andreavolpato/spektrafilm).
It is not an official Windows release or an endorsement by either upstream author.

Download **Setup.exe**, open it, read the licence and click Install. It installs
for the current user with desktop/Start Menu shortcuts and an uninstaller.
Microsoft's signed WebView2 bootstrapper runs only if the runtime is absent
(internet required). No administrator, Python, Node or build tools are required.
Alternatively extract **Portable.zip** completely and run `SpektraLab.exe`.

Windows x64 and a working Vulkan compute driver are required. Actual hardware
acceptance: Windows11 / NVIDIA RTX3070Ti Laptop. Other GPUs/Windows10 are not
claimed as individually tested. There is no CPU fallback. The community app and
installer are unsigned; verify the Release checksums and keep Windows security
enabled. Failure to install WebView2 is reported instead of hiding the failure.

The native C++/Vulkan engine drives RAW edits, film/paper, curves, colour balance,
crop/compare, real Film Edge text/frame/DX, date back and half-frame per-hole
framing/print/Post-Dev. JPEG/PNG/TIFF exports carry the edits and ICC profiles.
See [validation and known gaps](distribution/windows/VALIDATION.md) and
[Mac parity table](desktop/PARITY.md). This release does not claim full Metal
image pixel parity, display-profile colour management or Mac CLI/MCP support.

Code: GPL-3.0-or-later. Profiles/LUTs: CC BY-SA4.0. Every package retains
attributions, full corresponding source/dependency source and licence texts in
`source/` and `host/licenses/`. The one precise-release licence provenance
limitation is explicitly retained in `source/LICENSE-REVIEW-GAPS.json`.
Installer source is in `distribution/windows/`; source build instructions are
included in the package's `source/README-SOURCE.txt` and `reproduce-editor.ps1`.

Uninstallation removes exact installed files and shortcuts; it retains sidecars,
preferences, WebView2 and foreign files. No photograph or validation library is
included. Report community Windows issues in this fork.
