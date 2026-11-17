# PARITY — the macOS app (`modern_UI/Spektrafilm`) → `desktop/`

## SpektraLab 2 (Mac v2 2.4.1 → Windows 2.0.0-alpha.1), phase 1 — 2026-11-17

The interface is v2's (NOTES.md, "SpektraLab 2 for Windows"); the engine is v1's.
**Built** = on screen and working on the mock backends and, for the editor,
against the v1 host. **Absent** = not on screen on purpose (R7: the v1 engine
cannot do it, or the HIG gates it), with the reason. **Not built** = the v2
app has it and the v1 engine could, but this phase did not build it.

| Mac v2 / Windows HIG | here | status | why / notes |
|---|---|---|---|
| one window, app-drawn 32 epx title bar, menu bar with access keys, caption buttons | `app/AppWindow`, `TitleBar` | built | Snap layouts on Maximise hover need `HTMAXBUTTON` from `WM_NCHITTEST`, which the webview cannot answer: not done; unverified on Windows |
| rails 320 (280–440, double-click 320, remembered), walls, filmstrip 80, toolbar 48, folding by width/height, F7/F8/Ctrl+B/Ctrl+Shift+F/F11 | `app/layout.ts`, `AppWindow` | built | full screen is the window's own `setFullscreen` |
| Library \| Edit workspaces, Go › Back (Alt+←) | `app/ui.ts` | built | state is kept across the switch |
| Develop rail: Navigator (Fit · 100 % · 200 %), Film & Paper cards, Film Exposure ruler, Format | `edit/rails.tsx` | built | the film filter menu (Negative / Positive / B&W / Cine) is not built: *All* only; Custom size is not offered on the cards (the v1 control remains in the data) |
| Edit rail: Latitude meter pinned, Adjust tiles, Darkroom tiles (Enlarger, Decode, Effects), Crop | `edit/rails.tsx` | built | Adjust: Brightness, Contrast, Tone, Colour Wheels, Saturation, Temperature, Curve, Vignette |
| Adjust: HSL, Channels, Vibrance | — | absent | v1's Layer 2 (`shared/adjustments.ts`, the host's `render_view`) has no maths for them |
| Film Edge, Date Back, Half-Frame Pair | v1 sections in their v2 places | gated | shown only when the host does not list `overscan` / `date_imprint`; the v1 Windows host's mock lists both; not redrawn as PC-E5 |
| Scene Placement, Digital Intermediate | Copy Settings, Recipes | gated | absent when the host lists `scene_latitude_mapping` / `digital_intermediate` |
| layers / doubles, masks, HDR / gain maps, history and variants, lens profiles beyond v1's Lensfun | — | absent | no v1 engine support (PRD-W2 R7) |
| Presets (··· › Presets ▸, Save as Preset…), Undo History, "Undo *Tone*" step names | — | not built | v1 has no presets or named undo steps |
| status line from the scheduler (waiting · running with elapsed · done · failed), last print stays, InfoBar + Try Again, engine card | `edit/EditWorkspace.tsx`, `edit/words.ts` | built | the controls keep the failed edit (so Try Again renders it); the HIG returns them to the shown print — a deviation |
| the embedded preview while a frame opens | `EmbeddedCapsule` | built | the capsule shows until the first print lands |
| Compare, the Original (hold Space / \\, latch by a short click) | v1 canvas | built | |
| right-click command bar flyout, ···, Copy Settings flyout | `EditWorkspace.tsx` | built | Copy Settings groups are v1's six (Scene Placement gated) |
| Library: first run, source well and menu, catalog / Capture One catalog / session / folder, grid by capture date, Info rail, picked frames, Develop ↵ | `library/*` | built on the mock | phase 1's `MockLibrary` answers spklib's method table; Capture One is read-only (rating keys say so); "Open in Capture One" is drawn and disabled; drive relink (Locate…), Recycle Bin, drag-out to File Explorer are not built |
| Light Table, Contact Sheet 135 | `LibraryWorkspace.tsx` | built (simplified) | the sheet's scale is not the display's; Actual Size has no display size in a webview (no 1:1 is claimed) |
| Export ContentDialog, exporting ring and flyout, Stop after this frame | `export/ExportDialog.tsx` over v1's page | built | v1's recipe editor inside; the dialog's left/right arrangement is CSS over v1's page |
| Settings: General, Recipes, Library, Rendering, Engine, Diagnostics | `settings/SettingsWindow.tsx` | built | drawn in the window (not a second Tauri window); Library pane shows fixed words |
| languages | `tz()` / i18n | English, 简体中文 | 繁體中文 and 日本語 are not built |
| contrast themes, Narrator names | — | partial | roles and names on the controls; no contrast-theme colours |

What of the SwiftUI/Metal app this TypeScript (Tauri 2) port carries, area by
area. **ported** = the behaviour is here; **partial** = present with a stated
gap; **stub** = the controls are drawn and disabled with the reason;
**skipped** = deliberately not carried, with why.

Source integration refreshed 2026-10-29: upstream PR #23 (`1e727cd`) merged with local memory milestone `bbf536d` and saved alignment/noFilm work `ec59666`. macOS 1.3.4 sources are included. See `docs/PR23-INTEGRATION-20261029.md` for current validation and intentional differences.
The 2026-10-06 refusal list is historical: scene placement, Cineon, film
edge, date back and pairs now have native implementations. Capability gates
still omit unsupported wire fields when an older host is used. Saved noFilm
ordinary output instead refuses an older host without `view_options: no_film`,
so it cannot silently return a film render.
Contrast mask remains unsupported by the current Vulkan backend and hidden
in the UI; its capability gate still applies to current hosts too.

These statuses describe source coverage, not newly passed platform or visual
acceptance. Historical runtime evidence is in
`engine/WINDOWS_MIGRATION_VALIDATION_20261018.md`; current gates and remaining
work are in [the alignment checklist](MACOS-MAIN-ALIGNMENT-CHECKLIST-20261028.md).

| Swift area | port | status | notes |
|---|---|---|---|
| `SpektrafilmApp.swift` window, menus, shortcuts | `windows/menus.ts`, `windows/keys.ts`, `main.tsx` | ported | Native menu bar built in TS (localised). Ctrl for ⌘. Capture One mapping: Ctrl+O/E, Ctrl+Z (+Ctrl+Shift+Z/Ctrl+Y redo — the Mac has no redo), Ctrl+Shift+C/V settings, Ctrl+A, Ctrl+=/−/0, Ctrl+B, Ctrl+Shift+F/B, Ctrl+Alt+[ ]/R, V/H/C, ←/→, `,` `.`, Y, Space (original). Single keys are not accelerators (trap 32, below). Full screen is F11 (⌃⌘F on the Mac). |
| `Windows/TypingKeyGuard.swift` (trap 32) | `windows/keys.ts` `isTypingKey` + `keys.test.ts` | ported | A focused text field gets characters, arrows and delete; Ctrl/Alt chords, Enter/Esc/Tab still reach the shortcuts. |
| `Windows/EditorWindow.swift`, `TopBar.swift` | `windows/EditorWindow.tsx`, `TopBar.tsx`, `controls/PanelResize.tsx` | partial | Native title bar; collapsible rails with persisted drag/keyboard widths, right minimum 280. Pair and preview-gamut entries exist. Section heights, initial folds and narrow-window visual alignment remain. |
| `Windows/SettingsWindow.swift` | `windows/Dialogs.tsx`, `SettingsPages.tsx`, `DiagnosticSettings.tsx` | ported | General, Rendering, Memory/cache, Diagnostics and Agents settings; diagnostic ZIP, retention and manual update check. An in-window dialog shares the session store. |
| `Windows/AboutWindow.swift` | `Dialogs.tsx` `AboutDialog` | ported | GPL + CC BY-SA attribution texts (copied from the Mac bundle by `scripts/copy-assets.mjs`). |
| `Windows/BootWindow.swift` | `HostFailure` banner/dialog | partial | No boot window; the canvas says "waiting for the engine", the failure dialog names the reason, shows the host's stderr tail and a Vulkan hint. |
| `Localization/Strings.swift` (264 keys, en + zh-Hans) | `i18n/en.json`, `zh-Hans.json` via `scripts/extract-strings.mjs` | ported | Generated, not hand-copied. Point-of-use `L(_, zh:)` pairs are `tz(en, zh)` and were translated where the port shows them. |
| `Theme/Theme.swift` | `styles/theme.css` | partial | Shared visual vocabulary with Windows system fonts. Exact rows, spacing, dimensions and bilingual scaling still require comparison with the running Mac app. |
| `Model/Params.swift` (FilmParams, wire, delta, layers) | `shared/params.ts`, `shared/sidecar.ts` + tests | partial | Wire names pinned against the engine's `kFields`; gates drop refused rows. Unknown nested params survive saving, but CineStill/highlightHeadroom behavior is not yet implemented. |
| `Model/Adjustments.swift`, `CurveMath.swift`, `Shaders.metal` `layer2` | `shared/adjustments.ts`, `canvas/glRenderer.ts`, native `view` | ported | Native render_view/export_frame own production grading, geometry and output conversion; the frontend handles already-processed host images and legacy/mock paths. CPU twins support fallback/reference tests. Masks remain hidden. |
| `Model/Geometry.swift` | `shared/geometry.ts` + test | ported | Same maps (`sourcePoint`, `outputPoint`, `uniform`, straighten/fit/resize/aspect locks). The test pins the GLSL transliteration to the model. |
| `Canvas/CropOverlay.swift`, crop tool | `canvas/Canvas.tsx` `CropOverlay` | partial | Handles, thirds, aspect locks, straighten slider and drag-line gesture exist. Photograph rotation under a level crop and viewport presentation still need alignment. |
| `Canvas/Renderer.swift`, `MetalCanvasView`, `ViewportState` | `canvas/Canvas.tsx`, `glRenderer.ts` | ported | Fit / 100 % / zoom steps / wheel zoom about the pointer / pan (Hand, middle button, or drag when zoomed). Zoom is native px per device px, so 100 % is the frame's own pixels at any tier. Pan/zoom are hand-written pointer handling rather than d3-zoom: the view state has to be the session's (zoom pill, menu, navigator), and d3-zoom's transform would be a second owner of it. |
| `Canvas/CompareOverlay.swift` | `Canvas.tsx` compare line | ported | Split with a draggable line; original preview follows the current decode settings through render_source. Embedded camera previews are separately identified during loading. |
| tiers, `full` badge (§7.3) | `state/session.ts` scheduler | ported | Every edit renders `live` at the preview edge; the original-resolution render starts 400 ms after the last edit and is dropped if anything moved; badge `preview` → `full`. One in flight, sent-vs-wanted coalescing; print-only deltas use `reprint`. |
| histogram | `canvas/histogram.ts` (+ worker) | ported (fixed) | Counts the canvas's **output** (geometry + Layer 2), unlike the Mac's known defect (§7.7). |
| `Panels/Sections/NavigatorSection.swift` | `LeftRail.tsx` | ported | Shows the cropped, turned output (the same offscreen render as the histogram — trap 33), the visible rectangle when zoomed, click/drag to pan. |
| `ClipboardSection`, `Model/SettingsClipboard.swift` | `shared/clipboard.ts` + test, `LeftRail.tsx` | ported | Six groups (masks group omitted with masks). Copy / Paste (to picked) / Sync. |
| `FilmSection`, `PrintProfileSection`, `StockCatalog` | `LeftRail.tsx`, `StockList.tsx`, `shared/stocks.ts` | partial | Film covers, positive/negative, still/cine, monochrome material pairing, recommended paper, direct scan, print effects and noFilm menu exist. CineStill 800T and the reset menu are integrated; other menu/Fast flip parity remains; see the film migration plan. |
| `Sidecar.noFilm`, session/renderer source choice | `shared/sidecar.ts`, `state/session.ts`, `shared/filmEdge.ts`, `canvas/Canvas.tsx`, export/agent/native view | ported (source) | Per-frame flag, save/reopen, undo/redo, stock-selection restore, clipboard exclusion and mode-specific cache/generation guards. Decoded source receives Post-Dev, geometry once and output conversion; dormant edge/date settings survive. Ordinary export/proof freeze selected and background modes; Cineon requires film simulation to be enabled, matching upstream R4. Pairs reject bypass; missing host capability refuses ordinary bypass. New-build RTX 5070 Ti GUI checks passed for toggle, Post-Dev exposure, film selection/undo, crop/rotation, JPEG/P3 and PNG/sRGB proof, one PNG export and restart persistence. GUI redo/pair/edge/date/DI, other GPUs and Mac visual comparison remain; see the checklist for separate automated/native evidence. |
| `FilmEdgeSection`, `DateBackSection` | `LeftRail.tsx`, `shared/filmEdge.ts`, native host | ported | Gate formats, held crop, seeds, date/data text and native preview/export paths are connected. Capability gates still handle older hosts. Date-only first-crop visual regression remains a separate acceptance item. |
| `CropSection` | `LeftRail.tsx` | ported | Aspect (+ portrait), straighten, rotate/flip, output size readout. |
| `EnlargerSection` | `LeftRail.tsx` | ported | Brightness, Y/M filters, pre-flash and pair scope are connected. |
| `LatitudeSection` | `RightRail.tsx` | partial | Measurement and placement fit are connected. Fixed EV axis, square-root heights, separation band, boundaries and out-of-range readouts remain. |
| `CameraSection`, `WhiteBalanceRows`, `WhiteBalanceBoxes` | `RightRail.tsx`, `shared/whiteBalance.ts` | ported | Metering, exposure, As Shot, re-decode WB, neutral picker and Lensfun correction with profile/host availability gating exist. Lensfun equivalence to Apple processing is not established. |
| `FilmFormatSection` (ParameterSections.swift) | `RightRail.tsx`, `state/session.ts` | partial | Edge-owned format locks controls without losing the stored frame; only Custom allows side-length edits. CineStill fixed-off anti-halation and 0–8 EV headroom controls are integrated. |
| `ScenePlacementSection`, `ToneMaskSection` | `RightRail.tsx` | partial | Scene placement, measured usable intervals and host mapping are connected. Tone Mask remains hidden as on the reference Mac. |
| Post-Dev `RightSections.swift` | `RightRail.tsx`, `CurveEditor.tsx` | partial | White Balance, Exposure (8 sliders), Curve (5 channels, add/move/remove points, histogram behind), Color Balance as a hue/saturation disc + three sliders per zone (the Mac's `ColorWheel` has more affordances). |
| `Panels/Filmstrip.swift`, `CropMaskedThumbnail` | `windows/Filmstrip.tsx`, `frameDrag.ts`, `shared/surfaces.ts` | partial | Turned/flipped crop-masked thumbnails, click/Ctrl-click, pointer reorder and persisted frame order exist. Per-photo context menu remains. |
| `Model/Session.swift` select / develop / undo / save | `state/session.ts` | ported | Undo (60 steps, 0.5 s coalescing) + redo. Host restart re-opens the frame from its sidecar. |
| `Model/Sidecar.swift` | `shared/sidecar.ts`, `src-tauri/src/files.rs` + tests | ported | App-data sidecars, neighbor migration and file identity including Windows. Unknown top-level and nested parameter fields survive saving; modeled current values win and explicitly cleared geometry/state fields stay deleted. This does not imply support for the unknown features. |
| `Import/*` (decode, ThumbnailCache, FramePipeline, disk cache) | host `thumbnail`/`open`, `state/displayCache.ts`, `previewQueue.ts` | ported | LibRaw/raster decode; bounded memory and disk display cache; embedded-only background preview preparation; generation-guarded fast selection. Cache visibility does not mean RAW decode is complete. |
| open folder / files / drop / open-with / single instance | `platform/*`, `files.rs`, `lib.rs` | ported | RAW, TIFF/JPEG/PNG, SDR HEIC and flat EXR input paths. A second launch hands its paths to the running window. Extension support is not universal camera/compression coverage. |
| `Export/ExportPage.swift`, `ExportRecipe.swift`, `Exporter.swift` | `export/*` + tests | partial | Recipes, naming, format/size, batch lock, stop, LUT and Cineon exist. Native export_frame/export_cineon/render_proof implement output and proof; proof processes file-sized pixels before display reduction. Grid/Viewer, Open With and exact export layout remain. |
| trap 33 surface agreement | `shared/surfaces.test.ts`, `geometry.test.ts` | ported | Crop + quarter turn: export pixels = shader map; filmstrip outline = canvas output corners. |
| `Agent/`, `Updates/`, `Diagnostics/` bundle & memory | `agent/*`, native agent/workspace services, `windows/*Settings*` | ported | Opt-in user CLI/MCP, permissions, workspace lock, conflict protection, diagnostics, bounded cache and manual update check. |
| `Model/HalfFramePair.swift`, `PairSection`, `PairComposer` | `panels/PairSection.tsx`, `shared/pair.ts`, session/host pair APIs | ported | Two-source composition, per-hole decode/crop/placement, scoped adjustments, swap, persistence and private export. noFilm is disabled for pairs; ordinary bypass requests are also rejected by the host and exporter. |
| `Model/Mask.swift`, `MasksSection` | — | skipped | Withdrawn on the Mac as well. |
| `Canvas/ColourManagement.swift`, soft proof | native view/proof, `canvas/colorSpace.ts`, `glRenderer.ts` | partial | Auto/sRGB/Display P3 preview, tagged canvas, 16-bit transfer and optional float16 framebuffer exist. True monitor-profile behavior, cross-display transitions and physical output bit depth still need hardware acceptance. |
