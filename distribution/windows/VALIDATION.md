# Windows community port — validation, 2026-10-27

Base: `99c2d5c9883be485085895157279cc7c4eaa8db6`. App SHA256:
`c412a74091f1d09ca7d9df927f7054b88c9bafad553bdf11610580a075de6168`.
Native host SHA256: `3cba7a6827cb5f616ddcf8b73cbda194371881c1b2105d274aeb86ddc2311c46`.
Installer/docs are added around those accepted binaries without changing them.

| Layer | Actual evidence |
|---|---|
| Frontend | TypeScript/lint and107 regular unit tests passed;4 default optional realhost skips explicitly excluded.21 full browser regressions passed; synthetic/browser cases are not described as native UI acceptance. |
| Engine/host | CTest16/16 and Python tools47/47 passed; original36 B&W Vulkan checks, independent36 Scene Placement oracle cases, real host smoke and additional pair/date/DI/meter/cache checks passed at their implementation boundaries. |
| RAW | Authorised Sony ILCE-7M4 ARW, source untouched. Real Tauri→bundled host→NVIDIA Vulkan, full renders and saved/restarted sidecars observed in an isolated library. No private fixtures are published. |
| Edited GUI exports | Actual clicked7311×6786 JPEG/PNG/TIFF16, with nonneutral curves/colour balance/Film Edge; independent dimensions/ICC/uint16 readback. DisplayP3 JPEG, sRGB PNG, ProPhoto TIFF16.396,899,568 bytes in each direction over bounded IPC. |
| Pair | Real RAW frontend/native three-format4078×3769 with independent ROI oracle; actual native framing drag/wheel, save/history, B&W/DX, failure recovery and4086×3769 complete PNG click export. Per-hole print/grade controls were not exhaustively mouse-sampled. |
| Input/layout | Native C/Escape/CtrlE, sequential CtrlZ/redo single dispatch, slider and number Escape/Enter/undo; rail drag/reset/persistence; actual1100×680 client.130% Chinese layout additionally covered in browser. Current native input environment tested; not every IME enumerated. |
| Portable | ZIP637 files/636 manifest hashes and749 source entries verified; extracted GUI from an independent directory with Windows-only PATH and Windows Temp cwd used its bundled host. Actual4086×3769 JPEG,2520-byte DisplayP3 ICC and separate detail-bearing neutral ROIs passed independent decoding. |
| Protected originals | Original RAW, Phase1 ZIP and94-file manifest unchanged; tracked Mac app/base materials/LUT diff empty; original3 compatibility fixes retained. |

Original3 compatibility changes: Windows wrapper Vulkan-header parameter mapping,
Win10 declarations on the minimal Viewer target, and precise BT709 decode
breakpoint arithmetic to prevent unintended driver fusion. Equations/material
profiles/test tolerances were not altered to make the tests pass.

The shared numeric Escape bug and keyboard dispatch regressions were shown red
before green. Pair placement/geometry cases include independent hand oracles.
No complete Metal/Vulkan photograph pixel-parity claim is made. Full Swift/Xcode
tests and Python-reference parity were not rerun on Windows; no Mac source was
changed, and this is recorded rather than treated as a green Mac gate.

Known gaps: display-profile awareness, lens-profile correction, neutral picker,
straighten-by-line, filmstrip reordering, some Mac colour-wheel gestures, full
disk cache management and Mac CLI/MCP/Agents integration. Withdrawn Mac mask UI
stays hidden. Fonts differ from CoreText/Helvetica; portable Film Edge uses
unmodified TeX Gyre Heros with its licence.4 B&W profiles and silver paper are
the original product resources, not invented profile measurements.

Full corresponding source and dependency archives/licence texts ship in the
release `source/`.313 components have texts; one precise-release provenance
limitation (react-remove-scroll-bar2.3.8) remains explicit. Rebuild script syntax
was checked; a relocated fresh full toolchain rebuild was not performed.

See the release's checksum/installer acceptance files for packaging-only tests.
Local screenshots/logs of the private RAW remain private; they are not uploaded
as public evidence or distributed in the installer.
