# PARITY — the macOS app (`modern_UI/Spektrafilm`) → `desktop/`

What of the SwiftUI/Metal app this TypeScript (Tauri 2) port carries, area by
area. **ported** = the behaviour is here; **partial** = present with a stated
gap; **stub** = the controls are drawn and disabled with the reason;
**skipped** = deliberately not carried, with why.

Owner's scope decision (2026-10-06): the Linux/Windows engine refuses the
contrast mask, scene latitude mapping, the Cineon DI, film edge/overscan, date
back and the half-frame pair in this version; their sections are cheap UI
only — present, disabled with a tooltip driven by
`capabilities.backend.unsupported_features` — so enabling them later is a
wiring job. `params.wire()` omits their rows while the host cannot do them
(the settings stay in the sidecar).

| Swift area | port | status | notes |
|---|---|---|---|
| `SpektrafilmApp.swift` window, menus, shortcuts | `windows/menus.ts`, `windows/keys.ts`, `main.tsx` | ported | Native menu bar built in TS (localised). Ctrl for ⌘. Capture One mapping: Ctrl+O/E, Ctrl+Z (+Ctrl+Shift+Z/Ctrl+Y redo — the Mac has no redo), Ctrl+Shift+C/V settings, Ctrl+A, Ctrl+=/−/0, Ctrl+B, Ctrl+Shift+F/B, Ctrl+Alt+[ ]/R, V/H/C, ←/→, `,` `.`, Y, Space (original). Single keys are not accelerators (trap 32, below). Full screen is F11 (⌃⌘F on the Mac). |
| `Windows/TypingKeyGuard.swift` (trap 32) | `windows/keys.ts` `isTypingKey` + `keys.test.ts` | ported | A focused text field gets characters, arrows and delete; Ctrl/Alt chords, Enter/Esc/Tab still reach the shortcuts. |
| `Windows/EditorWindow.swift`, `TopBar.swift` | `windows/EditorWindow.tsx`, `TopBar.tsx` | ported | v4 bar order. Native title bar (see NOTES "Decisions"), so no traffic-light clearance logic. Rails fold to zero; no drag-resize of rail widths yet. |
| `Windows/SettingsWindow.swift` | `windows/Dialogs.tsx` `SettingsDialog` | partial | General (language, interface scale 100/115/130 %, reset layout), Rendering (preview edge, crop re-maps, decouple effects, DI blue compensation — disabled while the DI is refused), Diagnostics (versions, GPU, unsupported features, log/sidecar folders, host diagnostics, restart). Memory, disk cache, log retention, diagnostic bundle, update check and Agents pages skipped (brief §6). An in-window dialog, not a second window (one webview = one session store). |
| `Windows/AboutWindow.swift` | `Dialogs.tsx` `AboutDialog` | ported | GPL + CC BY-SA attribution texts (copied from the Mac bundle by `scripts/copy-assets.mjs`). |
| `Windows/BootWindow.swift` | `HostFailure` banner/dialog | partial | No boot window; the canvas says "waiting for the engine", the failure dialog names the reason, shows the host's stderr tail and a Vulkan hint. |
| `Localization/Strings.swift` (264 keys, en + zh-Hans) | `i18n/en.json`, `zh-Hans.json` via `scripts/extract-strings.mjs` | ported | Generated, not hand-copied. Point-of-use `L(_, zh:)` pairs are `tz(en, zh)` and were translated where the port shows them. |
| `Theme/Theme.swift` | `styles/theme.css` | ported | Colours, two section-title sizes, rail metrics. System fonts (Segoe UI Variable / Noto Sans / Noto Sans CJK SC / Microsoft YaHei); nothing bundled. |
| `Model/Params.swift` (FilmParams, wire, delta, layers) | `shared/params.ts` + test | ported | Wire names pinned against the engine's `kFields` (`mock-host/schema-fields.json`, extracted from `engine/src/core/params.cpp`). Feature gate drops refused rows. |
| `Model/Adjustments.swift`, `CurveMath.swift`, `Shaders.metal` `layer2` | `shared/adjustments.ts`, `canvas/glRenderer.ts` | ported | One GLSL pass = Layer 2 + geometry + compare. The CPU twin (`layer2Pixel`) is what the export uses. Mid-grey pivot follows the encoding (sRGB on the canvas, ROMM for a ProPhoto file). Masks skipped (withdrawn on the Mac too: `FeatureFlags.masks = false`). |
| `Model/Geometry.swift` | `shared/geometry.ts` + test | ported | Same maps (`sourcePoint`, `outputPoint`, `uniform`, straighten/fit/resize/aspect locks). The test pins the GLSL transliteration to the model. |
| `Canvas/CropOverlay.swift`, crop tool | `canvas/Canvas.tsx` `CropOverlay` | partial | Handles, thirds, move/resize with aspect locks, straighten by slider. The photograph is shown level with the crop drawn rotated (the Mac turns the photograph under a level crop); no straighten-by-line gesture yet. |
| `Canvas/Renderer.swift`, `MetalCanvasView`, `ViewportState` | `canvas/Canvas.tsx`, `glRenderer.ts` | ported | Fit / 100 % / zoom steps / wheel zoom about the pointer / pan (Hand, middle button, or drag when zoomed). Zoom is native px per device px, so 100 % is the frame's own pixels at any tier. Pan/zoom are hand-written pointer handling rather than d3-zoom: the view state has to be the session's (zoom pill, menu, navigator), and d3-zoom's transform would be a second owner of it. |
| `Canvas/CompareOverlay.swift` | `Canvas.tsx` compare line | ported | Split with a draggable line; Before = the host's embedded/fast decode preview. |
| tiers, `full` badge (§7.3) | `state/session.ts` scheduler | ported | Every edit renders `live` at the preview edge; the original-resolution render starts 400 ms after the last edit and is dropped if anything moved; badge `preview` → `full`. One in flight, sent-vs-wanted coalescing; print-only deltas use `reprint`. |
| histogram | `canvas/histogram.ts` (+ worker) | ported (fixed) | Counts the canvas's **output** (geometry + Layer 2), unlike the Mac's known defect (§7.7). |
| `Panels/Sections/NavigatorSection.swift` | `LeftRail.tsx` | ported | Shows the cropped, turned output (the same offscreen render as the histogram — trap 33), the visible rectangle when zoomed, click/drag to pan. |
| `ClipboardSection`, `Model/SettingsClipboard.swift` | `shared/clipboard.ts` + test, `LeftRail.tsx` | ported | Six groups (masks group omitted with masks). Copy / Paste (to picked) / Sync. |
| `FilmSection`, `PrintProfileSection`, `StockCatalog` | `LeftRail.tsx`, `StockList.tsx`, `shared/stocks.ts` | ported | Mac `StockCatalog.json` + film covers. Positive/Negative, Still/Cine, Digital (stub), No Print Profile, Print Effects, EDR. A slide film greys the papers with the reason. |
| `FilmEdgeSection`, `DateBackSection` | `LeftRail.tsx` | stub | Main switches + a few controls, disabled by `unsupported_features`. |
| `CropSection` | `LeftRail.tsx` | ported | Aspect (+ portrait), straighten, rotate/flip, output size readout. |
| `EnlargerSection` | `LeftRail.tsx` | ported | Brightness (stops), Y/M filter shifts with print-colour tracks, pre-flash. Pair scope skipped (no pairs). |
| `LatitudeSection` | `RightRail.tsx` | partial | The host *measures* (`scene_latitude` works); the plot shows the scene histogram over the medium's range with below/within/above. Separation ramp and pull-back overlay not drawn. |
| `CameraSection`, `WhiteBalanceRows`, `WhiteBalanceBoxes` | `RightRail.tsx`, `shared/whiteBalance.ts` | partial | Metering pill (Custom = meter off), Film Exposure + As Shot, Vignetting (Layer 2). Camera Temperature / Tint at decode with the two As Shot boxes (the Mac's rules, unit-tested) and the presets in the section's "•••"; an edit re-decodes through `redecode` (R2, landed 950dd47), debounced 350 ms, one undo step; RAW only (a raster greys the rows with the Mac's reason). **Lens Correction stays disabled**: R2 declined it (LibRaw has no lens profiles). The neutral picker (eyedropper) is not ported. |
| `FilmFormatSection` (ParameterSections.swift) | `RightRail.tsx` | ported | Size (cine pills) / Side / Side Length + unit, effect toggles, anti-halation layer, decoupled strengths (Settings), sub-layer grain in the menu. Film format derived from the photograph's aspect. |
| `ScenePlacementSection`, `ToneMaskSection` | `RightRail.tsx` | stub | Scene Placement disabled (mapping refused). Tone Mask hidden as on the Mac (`FeatureFlags.toneMask = false`). |
| Post-Dev `RightSections.swift` | `RightRail.tsx`, `CurveEditor.tsx` | partial | White Balance, Exposure (8 sliders), Curve (5 channels, add/move/remove points, histogram behind), Color Balance as a hue/saturation disc + three sliders per zone (the Mac's `ColorWheel` has more affordances). |
| `Panels/Filmstrip.swift`, `CropMaskedThumbnail` | `windows/Filmstrip.tsx`, `shared/surfaces.ts` + test | ported | Whole photograph, turned/flipped, outside of the crop under an 82 % mask; live geometry for the open frame, saved for the rest; print thumbnail replaces the embedded one after a full render. Click / Ctrl-click picks. Drag-to-reorder (`FrameOrder`) skipped. |
| `Model/Session.swift` select / develop / undo / save | `state/session.ts` | ported | Undo (60 steps, 0.5 s coalescing) + redo. Host restart re-opens the frame from its sidecar. |
| `Model/Sidecar.swift` | `shared/sidecar.ts` + test, `src-tauri/src/files.rs` + test | ported | `<app data>/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`, Mac JSON shape, unknown keys (masks, heldCrop…) carried through, neighbour migration, moved-file fingerprint (inode on Linux; not on Windows). |
| `Import/*` (decode, ThumbnailCache, FramePipeline, disk cache) | host `thumbnail`/`open` | partial | Decoding is the host's (LibRaw / raster). Thumbnails cached in memory per folder; no disk cache. |
| open folder / files / drop / open-with / single instance | `platform/*`, `files.rs`, `lib.rs` | ported | RAW + TIFF/JPEG/PNG. A second launch hands its paths to the running window. |
| `Export/ExportPage.swift`, `ExportRecipe.swift`, `Exporter.swift` | `export/*` + test | partial | Recipes (4 built-ins, editable, stored in app data), location, existing-file policy, naming tokens + sample, format/depth/space/quality/long edge, batch holding the frame (trap 34), Stop between frames, .cube from the page menu, DI recipe (refused by this engine). The file is the canvas's frame via R1 `write_image` (verified with the real host). The strip shows each frame turned with its crop mask. The proof is the canvas output at 1400 px, not at file resolution; Open With, grid view and job log skipped. |
| trap 33 surface agreement | `shared/surfaces.test.ts`, `geometry.test.ts` | ported | Crop + quarter turn: export pixels = shader map; filmstrip outline = canvas output corners. |
| `Agent/`, `Updates/`, `Diagnostics/` bundle & memory | — | skipped | Brief §6. Logging is `tauri-plugin-log` (rotating, 4 MB × 5) in the OS log dir; the host's stderr goes there too. |
| `Model/HalfFramePair.swift`, `PairSection`, `PairComposer` | — | skipped | Engine refuses pairs in this version (owner's scope). |
| `Model/Mask.swift`, `MasksSection` | — | skipped | Withdrawn on the Mac as well. |
| `Canvas/ColourManagement.swift`, soft proof | host `display: "srgb"` | partial | The host performs the output transform to sRGB for the canvas. No display-profile awareness (wide-gamut monitors see sRGB). |
