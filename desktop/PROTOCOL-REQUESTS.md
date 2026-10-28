# Protocol requests from the desktop frontend

The frontend (`desktop/`) appends here when it needs something from
`spektralab-host` that `HOST-PROTOCOL.md` does not yet say. The backend owns
`HOST-PROTOCOL.md`; nothing here is a contract until it lands there. Every
request is **additive** (new optional fields / new methods), and the frontend
codes defensively until it lands: it reads `hello.result.protocol` and the
presence of methods (an `unsupported` / `bad_request` error) and degrades.

Status markers: `[open]`, `[landed <commit>]`, `[declined: reason]`.

---

## R1 [landed 2e6f1ed] — Export with the app's geometry and Post-Dev (Layer 2)

**Why.** On macOS, crop/straighten/turns/flips and the Post-Dev rail (white
balance on the scan, exposure, curves, colour balance, vignette) are applied
*after* the engine, by the app (`ARCHITECTURE.md` §7.1, §7.2; `Exporter`
applies geometry to the returned print). `export_image` writes the engine's
print only, so an exported file would silently lose the crop and every Post-Dev
edit — exactly the trap-33 class of bug ("every surface that shows the frame
must show the canvas's frame").

**Preferred shape (keeps colour maths in the host, pixel maths in the app):**

1. `render` accepts `format: "rgba16"` together with
   `display: "srgb" | "display-p3" | "prophoto"` meaning "apply the output
   transform for that file colour space, keep 16 bits". Result `image.color_space`
   names the space. (Today `display` is described for `rgba8` only.)
2. A new method `write_image`:
   `{path, format: "tiff16"|"tiff8"|"jpeg"|"png", quality?, color_space,
     width, height, source_path?, overwrite?: bool}` + an `rgba16` payload
   (top row first, LE). The host embeds the ICC profile for `color_space`,
   copies EXIF from `source_path` when given (pixel dimensions rewritten),
   writes to a hidden `.<name>.partial-*` and renames into place (§7.8 "files
   land whole"). Result `{path, width, height, bytes}`.

The app then renders `full`/rgba16 in the recipe's space, applies Layer 2 and
geometry in TypeScript (`src/shared/layer2.ts`, `src/shared/geometry.ts`, the
same code the canvas shader mirrors and the surface-agreement test pins), and
hands the pixels to `write_image`.

**Acceptable alternative:** `export_image` accepts optional
`geometry: {crop: {x, y, width, height}, angle_deg, quarter_turns, flip_h, flip_v}`
(source-normalised, applied to the print after the engine, bilinear) and
`layer2: {...}` — but that duplicates Layer 2 in C++, so (1)+(2) is preferred.

**Until it lands** the export page writes with `export_image` and shows a
visible notice when the frame has a crop or Post-Dev edits that the file will
not carry.

## R2 [landed 950dd47 — white balance + redecode; lens correction declined: LibRaw has no lens profiles] — Camera white balance and lens correction at decode

**Why.** Camera Temperature / Tint / Lens Correction are *decode* settings on
macOS (`DecodeSettings`, re-decode then render). The protocol's `open.decode`
only has `raw_mode`.

**Shape:** `open.decode` (and a new `redecode {session, decode}` that keeps the
session's params and cached state where it can) accepts
`white_balance: {mode: "as_shot"|"custom", temperature_k?: number, tint?: number}`
and `lens_correction?: bool`. `probe` / `open` metadata gains
`as_shot: {temperature_k, tint}` so the rail can show the As Shot values.
Return `unsupported` for any key the decoder cannot honour.

**Until it lands** the Temperature/Tint/Lens Correction rows are shown disabled
with the reason "this host cannot change white balance at decode".

## R3 [landed 2e6f1ed] — `thumbnail` honours EXIF orientation

The filmstrip draws what `thumbnail` returns. Please return it already rotated
to the camera's orientation (as `open` does for the decode), or report
`orientation` in the result so the app can turn it.

---

## R4 [open] — "Don't Apply Film Simulation" in `export_frame` / `render_proof` (1.3.4)

**Why.** 1.3.4's Film section menu has *Don't Apply Film Simulation*
(`Sidecar.noFilm`, `Exporter.filePixels` on the Mac): the frame is the
**decode** at its own pixels, in the working space, with the Post-Dev grade
(Layer 2) and the frame's geometry on it -- on the canvas, the thumbnail and
the exported file. The film settings stay in the sidecar. The canvas and the
filmstrip are frontend-only here (`render_source` + the GLSL Layer 2 pass), but
a file at full resolution needs the host.

**Shape (additive).**

1. `export_frame` and `render_proof` accept `no_film: boolean` (absent =
   false). When true the host skips the film/print render and feeds the
   session's decoded source (the pixels `render_source` reads, at native size,
   in the working ProPhoto space) into the same post path it already runs:
   Layer 2 `adjustments`, `geometry` (with `source_geometry` ignored -- no film
   canvas exists), the output transform for `color_space`, encode, EXIF.
   `params` may still be sent and are ignored for the pixels.
2. `no_film: true` with `export_cineon` / `format: "di"` is `bad_request`
   (the Digital Intermediate *is* the film's negative).
3. `hello.frame_options: ["no-film"]` advertises it.

**Until it lands** the frontend refuses to write or proof a frame with the flag
on and says why (`exporter.ts` `noFilmSupported`): a host that ignored the
unknown field would write the film print, which is not the canvas's frame
(trap 33). The mock host implements the shape (`mock-host/core.ts`).
