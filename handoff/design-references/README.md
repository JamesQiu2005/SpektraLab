# SpektraLab desktop frontend references

Generated with the built-in image generation tool from the two supplied frontend references and the product constraints in `../HANDOFF-SPEKTRALAB-FRONTEND-RECONSTRUCTION.md`.

## Current direction — v2

The original v1 images below are retained only as rejected exploration. Their rounded card stacks, heavy orange selection treatment and dashboard-like hierarchy are not the target aesthetic.

### Capture One Studio × Dehancer main editor

Output: `spektralab-desktop-editor-c1-dehancer-v2.png`

Prompt direction:

> Native macOS SpektraLab editor for a 32-inch 5K display. Use the supplied first screenshot only as a structural reference. Combine Capture One Studio's compact tool-tab rail, flat docked tools, dominant Viewer and narrow Browser with Dehancer Desktop's continuous collapsible film modules, enable/reset affordances and film-processing clarity. Use near-black graphite surfaces, 1 px separators, 11–12 pt typography, precise small controls and only a trace of amber for active state. No detached cards, thick outlines, gradients, glass, stage-number circles or touch-sized controls. Far-left tool-tab rail; flat Input/Film/Develop/Render tool column; huge panoramic viewer; right Grade tools with histogram, exposure, HDR, curve, color editor, color balance and layers; compact browser below the viewer. The photograph is the visual hero.

### Capture One Studio × Dehancer worklist/output

Output: `spektralab-desktop-worklist-c1-dehancer-v2.png`

Prompt direction:

> Native macOS SpektraLab worklist and output workspace for a 32-inch display. Use the supplied second screenshot only as a structural reference. Combine Capture One Studio's configurable tool tabs, large Viewer and narrow task Browser with Dehancer Desktop's flat film tool stack, effect enable/reset controls, histogram/waveform and filmstrip sensibility. Use continuous graphite surfaces, hairline dividers, compact typography and tiny amber selection accents. Left Darkroom/Grade/Output tool area with a subtle Input → Film → Develop → Render navigator; Render expanded for Paper, Portra Endura, Print Exposure, Warm/Cool and Tint; large portrait Viewer with before/after split; five-image task Browser; slim bottom inspector and export status. No rounded cards, orange boxes, DAM tree, giant export wizard or tablet framing.

Official visual references consulted: Capture One's interface overview and workspace model, plus Dehancer Desktop's editor, continuous tool modules, filmstrip and inspector.

## 1. Main editor

Output: `spektralab-desktop-editor-reference-v1.png`

Prompt:

> High-fidelity native macOS SpektraLab editing workspace for a 27–32 inch 5K display, using reference image 1 as the visual and layout reference. Preserve the dark professional photo-editor character, center canvas, left and right inspectors, thin macOS chrome, and restrained orange accent. Replace backend-category lists with a resizable 340 px left “Digital Darkroom” workflow: Input, Film, Develop, Render. Film is expanded with Kodak Portra 400, Film Exposure +0.3 EV, and physical frame 6×7 Fit. Develop exposes Standard, Grain, Halation. Render uses Reference / Paper / Cinema with Calibrated Reference v1 selected. A large center canvas displays a wide city panorama, a path pill “Portra 400 · Standard · Reference”, and a compact bottom filmstrip. A 360 px right “Adjustments” inspector contains histogram, Grade Exposure, Curve, Color Balance, Local. Film Exposure and Grade Exposure must be visibly distinct. Dense mouse/trackpad controls, splitters, shortcut hints, status bar, restrained SF-style typography, subtle 1 px dividers; no touch-sized controls, no DAM, no glassmorphism, no tablet framing.

## 2. Worklist and output

Output: `spektralab-desktop-worklist-output-reference-v1.png`

Prompt:

> High-fidelity native macOS SpektraLab worklist and output workspace for a 27–32 inch display, using reference image 2 as the visual and layout reference. Preserve its centered portrait image, left configuration inspector, right thumbnail worklist, dark macOS window, and restrained orange accent. Use four resizable desktop regions: 330 px left Digital Darkroom inspector, large flexible center viewer, 240 px task-scoped worklist, and 44 px bottom status/action bar. The left side has Darkroom / Output tabs and the Input → Film → Develop → Render flow. Film shows Kodak Portra 400, Film Exposure +0.3 EV, and 35 mm Fit. Render has Reference / Paper / Cinema with Paper selected, Portra Endura, Print Exposure, Warm / Cool, and Tint. The center shows a Shanghai street portrait with compare handle, path pill “Portra 400 · Standard · Portra Endura”, and proof/color-space status. The right worklist has five thumbnails, selected state, recipe dots, filter/sort, and Reveal in Finder, but no catalog or DAM. The bottom bar provides JPEG · Display P3 and Export. Dense mouse/trackpad controls, splitters, shortcut hints, restrained SF-style typography, subtle 1 px dividers; no touch-sized controls, no glassmorphism, no tablet framing.

These are product-design references, not implementation specifications. Text and geometry should be rebuilt as native components rather than copied from the raster output.
