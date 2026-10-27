# PRD — SpektraLab 1.4.0

**Date:** 2026-10-16 · **Author:** session notes from the owner's list of 2026-10-16
**Status:** nothing here is built. This is the record of what the release is meant to be, what
already exists toward it, and what must be decided before anyone writes code.
**Baseline:** `main` at `6a347d57 chore(release): 1.3.3 (18)`.

The owner's own numbering (0–7) is kept, so his list and this document line up; items 3 and 4 share
one section because they are one system. Seven decisions were taken in the sessions that wrote and
reviewed this (§8); everything else marked **Decision** is a proposal, and **Open** is the owner's to
answer.

Related reading: `rfc/RFC-016-diagnostics-and-logging.md` (logs), `rfc/RFC-021-update-check.md`
(the update check), `rfc/RFC-028-digital-demask-and-invert.md` §13 (the DI and the blue
compensation), `handoff/edr-profile-calibration/README.md` (each paper's measured ceiling),
`PRD/PRD-export-page-v2.md` (the export page, and the RFC-017 line this PRD keeps),
`handoff/HANDOFF-EDR-PRINT-PROFILES.md` (what the EDR node is and is not),
and the mobile repo's `server/logs/README.md` (the log server, its contract and its limits).

---

## The rules this release is bound by

These are not restated per feature; they are assumed by all eight.

1. **Do not pollute the material model to fix a rendering problem** (`AGENTS.md`): a profile is
   measured capability, not a control surface. Output headroom belongs after the print; the look
   belongs in Layer 2.
2. **The product edits the physical process** (`ARCHITECTURE.md` §7): no post-print editing.
   Anything that composes after the print — a contact sheet — must be argued as a darkroom
   artifact or it contradicts the positioning.
3. **One frame at a time.** The engine session holds one frame; `spk_reprint` /
   `spk_render` / `spk_render_digital_intermediate` take one frame and return one image. There is
   no composite in the engine, and the only composite in the app is `Import/PairComposer.swift`
   (two holes, Core Image, in Swift, before the engine sees one image).
4. **RFC-017 (batch processing / apply-to-all) stays unimplemented**, and the export run "must not
   grow into it" (`PRD/PRD-export-page-v2.md` §15). Any feature below that walks a set of frames
   renders each frame as it already is; none of them apply an edit to a set.
5. **Export must match the canvas** — with exactly one exception requested in §2, which needs the
   owner's word.
6. **A wire change edits `API-SPEC-callable-render-service.md` in the same commit**, and
   `parity_schema.py` learns the field. The mobile `API-SPEC.md` takes the same text at the next
   sync.
7. **Measure, then claim.** Every number below is either cited from the repository or marked as
   something to measure.
8. **Nothing is sent anywhere without the user.** Until 1.4.0 the app's only network call is a
   button (`Updates/UpdateCheck.swift`). 1.4.0 adds two, both with consent (§0, §1), and the
   sentences that promise otherwise change in the same release.

---

## 0. Feedback: the log to `logs.spektralab.app`, and "Send feedback" (item 0)

### 0.1 What exists today

**The server is live.** Cloudflare Worker `spektralab-logs`, custom domain `logs.spektralab.app`
(zone `spektralab.app`), compatibility date 2026-10-06, store `LOGS_KV` (Workers KV — R2 was not
enabled on the account), secrets `INGEST_KEY` (compiled into the phone app) and `ADMIN_KEY` (the
owner's). Source: the mobile repo, `server/logs/` (on this Mac it is in the `testflight`
worktree; `main` there is 56 commits behind and has no `server/logs/`). The deployed Worker's
versions run to 8 (2026-10-10); the script on Cloudflare was last modified 2026-10-15.

The contract, which is what the desktop side must satisfy:

| | |
|---|---|
| `PUT /v1/logs/{install}/{session}` | the session's `.jsonl` bytes; `Authorization: Bearer <INGEST_KEY>`; `Content-Type: application/x-ndjson`; `X-SpektraLab-Build` ≤ 64 chars; 204 on success |
| ids | `install` is a UUID; `session` matches `^\d{8}T\d{6}Z-[0-9a-f]{8}$` |
| limits | body ≤ 4 MiB (413), 30 uploads a minute per install (429), empty body 400, bad key 401/403, store down 503 + `Retry-After` |
| what is kept | the body's bytes, the build header, the two-letter country Cloudflare derived, the time of receipt. No IP, no user agent, nothing of the body in a log line |
| retention | 90 days from the last arrival, by the store's own TTL; a session sent again as it grows starts its 90 days again |
| reading it | `GET /v1/admin/logs?prefix=&limit=&cursor=`, `GET`/`DELETE /v1/admin/logs/{install}/{session}`, `DELETE /v1/admin/logs/{install}`, with `ADMIN_KEY`. `server/logs/pull.py` and `guard.sh` are the owner's tools |
| health | `GET /v1/health` |

**The phone's client is the model** (`app/SpektraLab/Sources/Diagnostics/LogShipping.swift`): an
endpoint read from the build (`SPKLogsURL`/`SPKLogsKey` in Info.plist — the secrets are *not* in
the repository), a per-session sent-ledger (`sent.json`, bytes as the server last took them), a
file is *due* when it has more bytes than were sent, the oldest first, stop at the first failure,
and the whole thing is fire-and-forget with a 20 s timeout. Failures are a line in the log and a
sentence in Settings, never a dialog.

**The desktop has all the pieces except the wire.** Logs are `~/Library/Logs/SpektraLab/*.jsonl`
(JSONL, one record per line, categories app/engine/open/render/export/memory/canvas/error,
`Diagnostics/LogFile.swift`), retention is settable in Settings ▸ Diagnostics, and
`Diagnostics/DiagnosticBundle.swift` already assembles a store-only zip of the last five sessions,
`capabilities.json`, `summary.json` (versions, machine, current settings, last error, previous
session's outcome) and a `README.txt` — with an **anonymiser** that replaces the `frame` and
`path` fields (the only fields carrying a name the user chose) with `frame-0001.NEF`-style
placeholders. That toggle defaults to **on** (`includeFileNamesInBundle ?? true`,
`Diagnostics.swift:388`). Today the bundle is written to a path the user chooses and nothing is
transmitted.

**What the desktop log contains that the phone's does not** — the reason this is not a copy-paste:
file names and paths of the user's images, and their folder structure. The mobile privacy policy
promises "never a photo file name".

### 0.2 What to build

1. **Settings ▸ Diagnostics gains a sharing group**, off by default:
   - a switch *Share logs with SpektraLab* (consent once, revocable, with the sentence that
     revoking stops future sends and does not delete what arrived — the mobile wording, restated
     for the desktop);
   - the installation's number (a UUID, generated on first consent, shown in clear, kept after
     sharing is off; turning sharing on again makes a new one and the page shows the old one too);
   - the last outcome in one line: *sent N sessions (M bytes)* / *nothing new* / *could not reach
     the server (reason)* / *the server refused this build's key*;
   - a *Send now* pill.
2. **An uploader actor** mirroring `LogShipper`: due = grew, oldest first, stop at the first
   failure, outcome as a log line and one sentence in Settings. It runs at launch (sessions before
   this one) and at quit (this one too, bounded), and after *Send now*. It never blocks a develop
   and never holds the app open — a bounded wait, then the file is due again next time.
3. **Determinism note for the tests**: `LogShipper` is testable because its transport is injected
   (`tools/log_selftest.swift` runs it against a transport of its own). The desktop actor takes the
   same shape, so the whole feature has tests that never touch the network.
4. **"Send feedback…"** — a row in the same group (and, if the app has a Help menu, the macOS
   convention is to duplicate it there). Decision taken 2026-10-16: **`mailto:` with a prefilled
   subject and body, and the diagnostic bundle written first and revealed in Finder to attach.**
   The body carries app version, build, engine version, macOS version, architecture, the
   installation number if sharing is on, and the user's own words. The caption says the bundle was
   written to disk and **not** sent, that attaching it is the user's act in their own mail client,
   and that the file names inside it are the ones the save-time toggle chose — the app does not
   anonymise a file the user is sending themselves. A
   `mailto:` cannot attach a file, and that is the price of working with any mail client; the
   alternatives (an in-app form posting to a new Worker route; `NSSharingService` handing the zip
   to Mail) are recorded here and in §9's first question, and are not chosen.
5. **Address.** The published contact today is `Hanze_Qiu@outlook.com` (privacy policy, deletion
   requests). **Open:** the same address for feedback, or a support alias.

### 0.3 Decisions this feature forces

- **What leaves the machine** (decided 2026-10-16): **the upload sends the anonymised log, always**
  — the same `Anonymiser` the bundle uses runs on the bytes before they go, whatever the bundle's
  file-names toggle says. One sentence in the policy is then true of both platforms: an upload
  carries never a file name, never a path, never a pixel.
  **The mail is a different story, and deliberately so.** A bundle the user attaches to their own
  message is their act, sent from their own mailbox, and the file-names toggle they saw at save time
  governs it — the app does not anonymise behind their back there. The policy and the two captions
  say exactly that, in those words: *what the app sends is anonymous; what you send is yours to
  choose.*
- **A session whose log is over the server's 4 MiB** (decided 2026-10-16): **send the tail** — the
  last 4 MiB of the file, dropping the first partial line so the body stays valid NDJSON, with the
  truncation and the byte count in the outcome line. The end of a session is where the failure is;
  the retention settings are what bound the file, and the Settings caption says a session over
  4 MiB is sent in part.
- **The policy must be rewritten before this ships.** The published page
  (`spektralab.app/privacy`, the `spektralab-privacy` Worker) says "This policy covers the
  SpektraLab beta for iPhone, which is distributed through Apple's TestFlight". It must cover the
  macOS app, its log's contents, the 90-day retention, the install number and the deletion route.
  The app should link it from Settings ▸ Diagnostics, as the phone does.
- **The phone and the desktop are one install each**, so one UUID never covers two devices, and
  the owner reading logs can tell them apart by the build string. The build header has 64
  characters: use them (`SpektraLab 1.4.0 (19) macOS 26.0 arm64`).

### 0.4 Acceptance

- With sharing off, no request is made at any point in a session (a test asserts the transport is
  never invoked).
- With sharing on, a session's file is uploaded once and re-uploaded only after it grows; the
  ledger survives a relaunch; a failure leaves it due.
- A log containing `path` fields is uploaded with those fields anonymised, and the test reads the
  bytes that went on the wire, not the file on disk.
- A session's log over 4 MiB goes as its last 4 MiB: the test parses every line of what was sent
  (the first, partial one is gone) and the outcome line says the session was sent in part.
- Turning the switch off stops future sends within the session.
- The outcome line reports each of: sent, nothing due, refused key, over the limit, unreachable —
  by injection, not by breaking the network.

---

## 1. "Automatically check for updates at launch" (item 1)

### 1.1 What exists today

RFC-021, implemented 2026-09-21 and shipping since 1.3.3: `Updates/UpdateCheck.swift` makes one
unauthenticated `GET https://api.github.com/repos/JamesQiu2005/SpektraLab/releases/latest` in an
ephemeral `URLSession` with a 5 s timeout and no cookies or cache, reads `tag_name`
(`spektralab-vX.Y.Z` by this project's convention), compares it numerically field by field against
`CFBundleShortVersionString` — not as strings, because `1.0.10` must beat `1.0.9` — and says one of
three things.

**It is manual only.** The sole call site is one button in Settings ▸ General ▸ *This session*
(`Windows/SettingsWindow.swift:639-643`), with a one-line summary beside it (`updateSummary`,
`:625-637`), an *Open release page* button, and a caption saying the request carries no identifier.
There is no launch-time check, no background check, no persisted state beyond the last result for
the current session.

**The failure discipline is the feature** (RFC-021 §4): offline, a timeout, a rate limit, a missing
release or an unparseable tag all render as *could not check* — never as *up to date*. The tests
that matter drive the injected response and assert that none of those paths produces the "newest
release" string. Whatever is added below inherits that bar and must be reachable through the same
injection.

**The promise this feature changes.** RFC-021 §3 refused an automatic check in these words: every
release note this project has published says *"the app asks for no network access at any point"*,
and "a button is a request the user made; a background check is one they did not". It also required
that when the sentence stops being true, **it changes in the same release, not afterwards**. The
Settings caption makes the same promise and changes with it. (Item 0 breaks the same sentence more
loudly; the two land together, §7.)

**One fact RFC-021 stands on has changed.** §3 refused a self-updater on licensing grounds: the app
was ad-hoc signed, so a build it downloaded would carry the quarantine attribute and macOS would
refuse it exactly as it refuses the zip. Since 1.3.3 (2026-10-09) a release is a Developer
ID-signed, notarised DMG (`modern_UI/Spektrafilm/Tools/package.sh`: archive → export → verify →
floor → DMG → notarise → `spctl`, with the `SPEKTRAFILM_NOTARY` profile). **A downloaded, notarised
DMG opens without the `xattr` dance.** The objection is stale — which does not put self-updating in
1.4.0 (§7), but it does mean RFC-021 should be corrected rather than quoted. (Two documents still
describe the old world: `AGENTS.md`'s "Releases are ad-hoc zips" and the README's `xattr -d -r
com.apple.quarantine` install step.)

### 1.2 What to build

1. **A switch in the same group**: *Check for updates automatically at launch*, with its own
   caption. **Open:** its default (a version check is the least intrusive network call the app could
   make — one public read, no identifier, no version — but the app's public story has been
   "nothing leaves the machine", and the first launch after this release is not the moment to
   surprise anyone).
2. **The check itself**, in the same `UpdateCheck` type with the same comparator and the same
   failure mapping:
   - once per launch, in the background, never on the open path and never blocking the canvas;
   - **at most once per 24 h**, from a persisted last-check time — a launch-heavy day is not sixty
     requests;
   - no retry loop; a failure is silent and lands in the Settings line, not in a dialog;
   - cancellable at quit, like every other background job in the app.
3. **What the user sees.** Never a modal sheet. The Settings ▸ *This session* row is the surface: it
   shows the last result whether the check was automatic or pressed. If a newer version exists, the
   row says so with the release-page button; a **persisted "seen version"** means a version the user
   has already been told about is not announced again. If the owner wants one more affordance, the
   cheapest honest one is a dot on the Settings entry — the app has no menu-bar extra — and it must
   follow the same seen-version rule rather than blinking on every launch. **Open.**
4. **The manual button keeps its meaning**: pressing it checks now, updates the same row, and
   restarts the 24 h window. The two paths share one state, so RFC-021 §6's question — does the
   About panel get the same row? — becomes a one-line decision instead of a second implementation.
5. **The rate limit gets a line of its own** in the automatic path too: unauthenticated GitHub
   allows 60 requests an hour per IP, and a shared address can exhaust it, so a `403` with
   `X-RateLimit-Remaining: 0` says *try again later* rather than *could not check*, and is not
   retried inside the 24 h window.
6. **Text that changes in this release**: the release-notes sentence, the Settings caption (which
   now says what the automatic check does when it runs *and* what it sends: the question, the app's
   name in the User-Agent, and nothing else — no version, no machine, no install number), and the
   privacy policy's network section (§0.3). GitHub learns an IP address asking about a public
   repository; a browser visiting the releases page tells it the same thing.

### 1.3 Acceptance

- Toggle off: a launch makes no request. Asserted through an injected transport, not by observation.
- Toggle on: exactly one request per launch, and none within 24 h of the last one; the state
  survives a relaunch.
- Every failure path — offline, timeout, 403 rate limit, no releases, an unparseable tag — renders
  as *could not check*, and the test that asserts it runs through the **automatic** entry point,
  not only the button's.
- A newer version already seen does not re-announce; a newer version not yet seen does.
- Pressing the button during a launch-check window does not produce two requests.

---

## 2. Apple-device HDR (item 2) — the extended-range canvas

### 2.1 What exists today

**The canvas is deliberately SDR.** `Canvas/MetalCanvasView.swift:765-771` sets
`layer.colorspace = ImageDecoder.workingSpace` (ROMM/ProPhoto) and
`layer.wantsExtendedDynamicRangeContent = false`, with the comment that ROMM γ1.8 is a plain 0–1
curve with no headroom to want. The drawable is `.rgba16Float` (`Canvas/Renderer.swift:400`), so
the surface *could* carry values above 1.0 — the layer flag and the encoding are what stop it.
There is no `NSScreen` headroom query anywhere in the app, no `maximumExtendedDynamicRangeColorComponentValue`,
no HDR10/PQ/HLG, no dynamic EDR metadata. Export destinations are Display P3 / sRGB / Adobe RGB /
ProPhoto / BT.2020 (`Canvas/ColourManagement.swift:126-130`), 8- or 16-bit PNG/TIFF
(`Export/ExportPage.swift:968-974`).

**The engine's EDR node is not HDR.** `node_edr` (`pipeline.cpp:1688`) is an opt-in *editability*
curve: a per-paper 256-sample table (`data.edr_tone_map`) fitted from a Kodak Portra 400 neutral
ramp, with a black floor of 2⁻¹⁴ and a ceiling of **1.0 reference white**, applied immediately
before the transfer function (`pipeline.cpp:1994-2005`). It is refused for `scan_film`, for a DI and
for a monochrome print (`pipeline.cpp:374`, `Model/Params.swift:565`), and the calibration README
keeps it inapplicable to *No Print Profile*, which is not a paper and has no calibration.
`HANDOFF-EDR-PRINT-PROFILES.md`
says exactly this: "EDR is an opt-in SDR editability control… HDR display/output… are outside this
launch change."

**The measurement that makes a real ceiling possible already exists** (`handoff/edr-profile-calibration/`,
local-only, untracked; `evidence/results.json` and the neutral-axis curves). Per paper, the toe and
shoulder joins and a measured **HDR peak**: Crystal Archive 2.211×, Vision 2383 2.278×, Vision
Premier 2393 2.384×, Ektacolor Edge 2.292×, Endura Premier 2.506×, Portra Endura 2.103×, Supra
Endura 2.231×, Ultra Endura 2.599×. The same README's rule: **"the HDR ceiling is a limit, not a
brightness target."** That is 1.07–1.38 stops above reference white — the honest size of this
feature.

### 2.2 What to build (decision 2026-10-16: display first)

1. **Ask the display.** Query `NSScreen`'s extended-range headroom for the screen the canvas is on,
   and observe changes (the window moves between screens; a display's headroom changes with its
   brightness). Headroom is expressed in stops and passed to the engine as a parameter — the
   engine stays deterministic, and every parity harness can test the whole feature at fixed
   headroom values.
2. **One new wire field**, e.g. an output-layer `display_headroom_stops` (native-only, print layer),
   defaulting to 0.0. At 0.0 the pipeline is bit-identical to 1.3.3 — that is the test.
3. **Allocate the headroom after the print, before the transfer function** — in the EDR node's
   neighbourhood, never in the paper profile (rule 1). The measured per-paper ceiling says how much
   of the print actually lies above white; the display's headroom says how much of it can be shown.
   Where the ceiling is under the available headroom, nothing is compressed; where it is over,
   a monotonic shoulder maps the top of the print into the headroom, with the same C1 discipline the
   calibration used.
4. **The canvas**: `wantsExtendedDynamicRangeContent = true`, an extended-range colour space on the
   layer, the drawable unchanged at `.rgba16Float`. The rails, the chrome, the text and the
   filmstrip stay SDR — only the canvas is handed to the EDR path.
5. **A switch in Settings ▸ Rendering**, beside the existing EDR row, with the caption saying what it
   needs (an XDR display) and what it does not change (the file).

### 2.3 The two rules this feature bends, and how

- **"Export must match the canvas."** With HDR display, the canvas shows values above white that the
  8/16-bit SDR file cannot carry. The framing proposed here: the export is unchanged and **the file
  is the SDR print** — the extended range is a property of looking at the print on a specific
  display, not of the print. **The owner left the export question open on 2026-10-16**: display-first
  HDR ships with the file as it is, and whether an extended-range file ever exists is §9's to
  answer. It should be answered *before* this feature ships rather than after, because until it is,
  the canvas and the file differ above white by design, and that is a promise the app has not made
  before.
- **The colour space.** The working space is ROMM/ProPhoto. macOS composites EDR content in an
  extended-range space (`extendedLinearDisplayP3`, `extendedLinearSRGB`, or an extended ROMM if the
  display allows it). Which one, and whether the matrix from ROMM is done in the layer's colour
  space or in the shader, is a design decision to settle with a measurement on a real XDR display —
  a probe, not an argument.

### 2.4 What it will and will not look like

Real: on an XDR display, the top ~1 stop of a print's highlights carries more light than the rest of
the interface, and a specular highlight reads as a highlight rather than a white patch. Small: the
paper's own response tops out at 0.93–0.99 in SDR, and its measured ceiling is 2.1–2.6×. Where the
paper is glossy and the frame has a real specular (the halation-prone frames the roadmap already
cares about), the difference is visible; on a flat frame in a bright room it is not. **The PRD's
standing instruction: measure it on hardware before it appears in any release note.**

Out of scope, explicitly: HDR export files (HEIF/AVIF gain map, HDR PNG, 10-bit), HDR on iPhone
and iPad (the same wire field and the same design should serve them later through the mobile
repo — that is why the headroom is a parameter), and any automatic coupling of this switch to the
existing SDR EDR toggle.

### 2.5 Verification

- Headroom 0.0: `parity_render` unchanged, and a canvas snapshot byte-identical to 1.3.3.
- Headroom as a fixed parameter: a new parity case with a monotonicity and neutrality bar, exactly
  as the EDR calibration did.
- Live: `Tools/capture-live.sh` on an XDR display is the only way to see the feature; the capture
  must show the same frame at headroom 0 and headroom N, and the SDR half must be unchanged.
- The histogram, the Navigator and the filmstrip must be unaffected (they read the SDR print).

---

## 3. The light table, and the contact sheet it enables (items 3 and 4)

These are one system with two surfaces: the table on screen is the sheet, scaled to fit. The owner's
words, 2026-10-16: *"a very restrained feature that enables user to have a light table (copy the same
feature into the desktop app, use one system to copy basic required view, and a full export for the
view deck)"*. Read here as: bring the website's table into the app, one layout system serving both
the on-screen view and a full-size export of the deck. If that reading is wrong, the correction is
§9's sixth question and it changes this section, not the rest of the document.

### 3.1 What exists today

- **There is no grid in the app.** The Browse grid was deleted on 2026-09-17 (`Model/Session.swift:683-691`
  explains why: opening a folder must not spend seven seconds and 363 MB developing whichever frame
  sorts first). What is left is the filmstrip (`Panels/Filmstrip.swift` — one lazy row, drag to
  reorder, ⌘-click to pick, and the order is kept per folder) and the export page's grid, which
  renders `session.selectedFrames` only (`Export/ExportPage.swift`).
- **Thumbnails are ImageIO embedded previews, never the engine** (`Import/ThumbnailCache.swift`,
  320 px, 256 MB arena, no disk cache); once a frame develops, its rendered print thumbnail replaces
  the embedded one (`Session.swift:2515-2543`).
- **No path renders a small version of every photo in a folder.** The CLI/MCP has thirteen
  single-image commands; the closest is `preview --long-edge`. There is no batch, no folder, no
  sheet command.
- **The reference already exists and it is on the website**: `/lighttable/` — an A4 (297 × 210 mm,
  √2 : 1) backlit table, measured in millimetres with a printed scale, films as transparencies
  multiplied onto the light, a pile, a loupe, and a Share picture. Its formats come from **the
  engine's own geometry** (`src/lightpad/formats.js` reads `overscan.cpp`): a Film Edge strip is the
  film's width across (35 mm, 61 mm on 120), a filed frame is the gate plus ~1.1 mm of carrier, a
  plain export is the gate (36 × 24 for 135). That page is the design reference for this feature,
  not the code to port.
- **The mobile app's Library** (grid, day-grouped, select-many → export, one job per frame,
  `Features/Library/LibraryScreen.swift`) is the closest family member and the constraint that
  matters most over there: "a page never calls the engine and never loops a render" (RFC-036).

### 3.2 The feature

**A Light Table window.** Opened from the Window menu and a top-bar button, on a key the app has
free; it shows the open folder's frames lying on a backlit panel at **true millimetres**.

- **What lies on the table is the negative, not a thumbnail**: with Film Edge on, the strip, at the
  film's width; with it off, the gate; the crop is the framing in the gate. A half-frame pair is
  **one item** — it is one item in the filmstrip, it exports as one picture, and it lies on the
  table as one piece of film.
- **The layout is the sheet's layout.** The table declares a paper (a short list: A4 portrait and
  landscape, A3, US Letter — the website's A4 landscape is the default), margins, a gutter, and a
  caption row; frames fill left to right in the folder's own order (the filmstrip's order).
  On screen the sheet is drawn scaled to fit, with the panel's light behind it and the paper's edge
  around it. There is no free placement, no rotation, no loupe — **that is the restraint**: the
  website may be a workbench, the app is a sheet.
- **One system, two surfaces.** The layout is described once (paper, margins, gutter, true-mm frame
  rectangles, captions) and rendered twice: at screen resolution for the table, and at export
  resolution for the sheet. The same code decides where the twelfth frame goes in both.

**The contact sheet** (item 4) is the export of that surface: **one image at a real paper size and
print resolution** (A4 at 300 dpi by default), frames at their true millimetres, a caption row per
frame (frame number, file name, film and paper), and a footer naming the set. Written through
ImageIO as TIFF or PNG like every other export (decision 2026-10-16: no PDF — that would be a new
writer, and the app has none).

### 3.3 How it is made (and what it must not become)

- **Each frame is rendered by the existing one-frame path** at the full tier, from its own sidecar,
  exactly as a batch export does (`ExportPage.run()`: select → ensureDeveloped → export → restore
  the home frame, under `session.batchExporting`).
- **The composition is Swift's**, as `PairComposer` already does it: the engine returns pixels for
  one frame and Swift lays them on the sheet and writes it. The engine gains no composite and no
  file writer (`ARCHITECTURE.md` §8.8).
- **No edits are applied to a set.** Each frame prints as it already is. The sheet does not grow
  into RFC-017 (rule 4).
- **Cost, measured before it ships:** a full render is 0.87 s and a reprint 0.17 s at 45 MP on the
  M3 Max, so a 36-frame sheet is tens of seconds and must show progress and be cancellable; the run
  moves the open frame and therefore holds `batchExporting` (trap 34) and restores the home frame.
  Memory is one frame at a time plus the sheet itself — the sheet at A4/300 dpi is 3508 × 2480 ×
  4 channels × 2 bytes ≈ 70 MB, and larger papers must be refused with a sentence rather than
  allowed to push the app into swap.
- **Frames never developed:** the run develops them, as the export page does. The on-screen table,
  which is a browsing surface and must appear at once, shows the ImageIO thumbnail for a frame that
  has no print yet and the print thumbnail once it has one — and it says so (a hairline mark rather
  than a lie). **Open:** whether the table is allowed to render lightweight previews of its own for
  frames that were never developed; the answer decides whether the table is instant or a slow
  surface, and it is the one place this feature could grow into batch rendering.
- **Film Edge and the sheet.** Open: whether a sheet of Film Edge frames shows the strips (true to
  the table) or the gates (true to a darkroom contact sheet, which is made from negatives on paper).
  The website's answer is the strip; the darkroom's answer is the frame. **Open.**

### 3.4 Acceptance

- A `SurfaceAgreementTests` case (trap 33) for the table: the same frame drawn on the table and on
  the canvas agree on geometry, and the histogram/crop defect pinned there stays pinned.
- The sheet's geometry is computed once and asserted: the twelfth frame's millimetre rectangle is
  identical in the on-screen layout and in the exported file, at two different paper sizes.
- A sheet export during a batch export is refused (or queued) by the same lock the export page uses.
- Opening a 500-frame folder shows the table without developing anything (a clock, not an
  impression: this is the test that keeps the deleted Browse grid's lesson).
- The export writes one file whose paper size, dpi and frame rectangles the test reads back from
  the file's own metadata.

---

## 4. More films (item 5)

### 4.1 What exists today

33 stocks in `Resources/StockCatalog.json` (generated by `Tools/gen-catalog.py`): **24 films** —
20 negatives (four of them the product's own black-and-white: Tri-X 400, T-Max 100, Neopan 100
Acros II, HP5 Plus 400) and 4 positives (Provia 100F, Velvia 100, Ektachrome 100, Kodachrome 64) —
and **9 papers** (8 colour plus Ilford Multigrade IV RC). Profile files:
`engine/resources/profiles/` (28 JSON, upstream spektrafilm, CC BY-SA 4.0, unmodified) and
`engine/resources_product/profiles/` (5 JSON, product-owned) plus `paper_grades.json` and
`neutral_print_filters.json`. Black and white is on in Release since 2026-10-09.

### 4.2 What adding one stock actually costs

No single document says this today; this list is assembled from `engine/resources_product/NOTICE.md`,
the `research/` write-ups and the test files, and **writing it down as a runbook is itself a
deliverable of 1.4.0**, because "more films" only scales if the process is a document rather than a
session's memory.

1. A profile JSON (`metadata`/`info`/`data`: `channel_density`, `base_density`, `log_sensitivity`,
   `density_curves`, `log_exposure`, the adaptation window, the channel model), every value tagged
   SHEET / MEASURED / ASSUMED. Traps: measured profiles contain NaN at unmeasured UV/IR wavelengths
   (trap 2 — neutralise at build, never with a branch in the loop); do not invent granularity
   (grain has no per-film data, and the repo's rule is to inherit honestly or measure).
2. A product-owned profile needs a `NOTICE.md` row naming its source, and must not derive from
   `engine/resources/`.
3. **A neutral filter row per (film, paper) pair** in `neutral_print_filters.json`, and
   `paper_grades.json` plus a print LUT for a new paper. This is the wall — see §4.3.
4. A Film Edge row (`overscan.cpp`'s `kEdgeLooks[]`, the edge-text map in
   `Model/Session+FilmEdge.swift`) and a layout if the gauge is new.
5. `FORMATS`/`COVERS` rows in `Tools/gen-catalog.py`, then regenerate `StockCatalog.json`.
6. Tests: `engine/tests/bw_checks.py` for black and white, `parity_schema.py`, `parity_lut.py`,
   `parity_setup.py`, and the Swift `StockListTests`. `Tools/gen-project.py` after adding any file.
7. A `research/` write-up with the measured tables.
8. A mobile sync if the engine or the resources move (`UPSTREAM.md` there), and a row in the
   phone's own display-name table (`STOCK-NAMES.md`, mobile-only, where a Kodak is a Koda).

### 4.3 The dependency that decides the size of this item

**A colour negative cannot print neutrally without a filter pack fitted per (film, paper) pair.**
The fitter for that is RFC-022, which is **not on `main`**: it lives on
`rfc-022-solved-neutral-profiles` (commit `96d083bb` — 71 of the 128 pairs solve; Portra Endura
16/16, Ektacolor Edge 15/16, Supra 15/16, Crystal Archive 14/16, Endura Premier 11/16, and
Ultra Endura / 2383 / 2393 **0/16**), together with `engine/tools/solve_neutral_profile.py` and
`make_neutral_profile.py`. `main` still carries the old measured table. Two consequences:

- A new colour negative needs either the solver on `main`, or an explicit decision to hand-measure
  its filter packs, or a paper set restricted to rows the current table already covers.
- Per RFC-022's own finding, **solved neutral profiles are film-coupled** — adding a film is not one
  file, it is a row per paper.
- **Decided 2026-10-16: new film and paper pairs are made RFC-022's way.** The solver, its method and
  its solved rows come to `main` as part of this work, so "which films" stops being the hard question
  and "does the pair solve" becomes a measured yes or no per pair — with RFC-022's own honest
  outcomes recorded (Ultra Endura, 2383 and 2393 solve 0 of 16, and a pair that does not solve ships
  no row rather than a guessed one).

Cheap-ish candidates (a profile exists upstream, or the film is a variation of one that does):
another colour negative in an existing family, a consumer 200/400, a faster 800, one more slide
film. Expensive candidates: any film whose spectral response must be measured from scratch, and any
new *paper* (a LUT, a grade table, a full filter matrix — 16 rows for the negatives alone).
**Open:** which films. The manner is settled above, so this is a list to choose and a pair-by-pair
"does it solve" answer, not an architectural question.

### 4.4 A recommendation for the release

Ship **one or two stocks end to end** plus the runbook, rather than ten profiles. The bottleneck is
the filter matrix and the tests, not the JSON, and a half-added stock that prints off-neutral is
worse than no stock — it is a wrong measured response, which is the one thing this repository
refuses to ship.

---

## 5. The blue and violet compensation, beyond the DI (item 6)

### 5.1 What exists today

`digital_intermediate_blue_compensation` — RFC-028 §13.3, **DI-only, off by default**, a print-layer
native-only bool. Its mechanism: at build, synthetic blues are generated in Oklab around the
blue–violet sector and run through the host film and the DI at 0 EV; the engine fits **one hue
rotation and one chroma scale per film** (`blue_delta_deg`, clamped ±30°, and `blue_kappa`, clamped
0.5–1.5; `core/digital_intermediate.cpp`), and the kernel applies them inside a raised-cosine window
centred at 280° Oklab with a ±55° half-width above a chroma floor of 0.02/0.08
(`core/digital_intermediate.hpp:61-68`) — so greys and every other hue are exact. Measured
(§13.3): Portra 400's blue `+13.0° / ×2.06` → `+5.7°`-class errors become `+1.5° / ×1.16`, ΔE00 mean
6.14 → 5.08; Ektar 100 `+17.8°` → `+5.7°`; skin, foliage and red unchanged to 0.1°.

**The cause is upstream of the DI**: the Hanatos reconstruction pushes energy below 430 nm (44 % of
a ColorChecker blue's energy versus 11 % in the real paint) and Portra's blue layer peaks at 400 nm
(§7.4). The owner's 2026-09-29 decision was to leave the adaptation window alone and compensate
after the film.

**Why "beyond DI" is a real gap:** a DI is its own encoded output and **skips the rest of the
pipeline** — the enlarger, the print curves, glare, the scan, gamut compression, EDR and the
transfer function (`pipeline.cpp:1968`, `:1978`, `:1995` return early). A user printing through a
paper, or scanning film with no print profile, gets the same film-chain blue error and **no
correction at all**.

### 5.2 The step this PRD insists on first: measure

The print path is not the DI path, and the DI's error is not the print's. On the same ColorChecker,
Portra 400's blue on the **print** reads **−8.4° / ×1.14** — the other direction — with ΔE00 mean
6.60 (§13.3's own table). So a straight re-fit is not obviously a win, and a compensation fitted on
one path and applied to the other would *double* the error. The deliverable of the first step is a
table, not code:

| to measure | per film | per path |
|---|---|---|
| blue hue drift, chroma error, ΔE00 mean | every negative in the catalog | print (paper), scan (*No Print Profile*), DI (today's fit, as the control) |
| what the fit would remove | the same | the same |

If the fit does not move ΔE00 on the print path, the honest outcome is **not to ship it** and to say
so — the DI's own compensation moved 6.14 → 5.08, which is real but modest, and hue-only correction
cannot fix a luminance or chroma error.

### 5.3 If it earns its place

- **Fit per path and per film**, exactly as the DI's is fitted, on the chain the user is actually
  looking at. The direction and the magnitude come from the measurement, never from the DI's numbers.
- **One new wire bool** for the film path (proposed name that says what it does, e.g.
  `blue_violet_compensation`, print layer, native-only, default off). **The existing DI field keeps
  its meaning**, because sidecars in the wild carry it and a paste or a sync must not silently change
  behaviour.
- **Share the constants**: move `kDiBlueHueCentre` / `kDiBlueHueHalfWidth` / the chroma floor out of
  `digital_intermediate.hpp` into shared colour code, so the window is defined once.
- **Apply after the film's curves and DIR couplers**, where Oklab is available and before the scan
  epilogue, so both the print path and the scan path can use it.
- Wire change ⇒ `API-SPEC-callable-render-service.md` in the same commit, `parity_schema.py`, the
  UI caption in Settings ▸ Rendering beside the DI toggle, and the clipboard's Film Effects group
  question (is this copied with Film & Paper, or not copied at all? — propose: Film Effects, since
  it is a property of the film chain, not of the paper).
- The UI wording must not promise more than the measurement: the DI's caption says the correction is
  "in the blue-to-violet hues only, by an amount the engine measures for each film on its own chain".
  The new one says the same thing about the print's chain.

---

## 6. zh-Hant and Japanese (item 7)

### 6.1 What exists today

A **hand-rolled** localization, deliberately not a String Catalog: `Localization/Localization.swift`'s
header says there is no `.xcstrings`, no `.lproj`, no `NSLocalizedString` — because the language
changes at runtime without a relaunch, and `Resources/` is a folder reference so a catalog placed
there would not be compiled. Three mechanisms, all in `Localization/Strings.swift`:

1. `enum S: String`, 54 cases, with **two exhaustive switches** (`english`, `simplifiedChinese`) and
   no `default:` — so a missing translation is a build error, which is the right property to keep;
2. **inline `L(_ english: String, zh chinese: String)`** — 183 call sites across 18 files;
3. patch dictionaries for the strings that live inside `Diagnostics.swift` and
   `DiagnosticBundle.swift` (`SettingsWindow.zh`, `logLevelZH`).

Selection is a pill in Settings ▸ General: System / English / 简体中文, persisted at `ui2.language`,
`@Observable` so a switch repaints live. Stock, paper and profile names are **not** translated, on
purpose ("a translated Kodak Portra 400 is a different product name"). The spec precedent is
`modern_UI/design/LOCALIZATION-zh-Hans.md`.

### 6.2 What two more languages cost

- **The two-argument `L()` has no room for a fourth language.** The signature becomes a lookup keyed
  by the English string with a value per locale (or a keyed enum with a generated table), and the
  183 call sites are rewritten mechanically. `enum S`'s switches become per-locale tables — keeping
  the "missing translation is a build error" property by making the table total, one exhaustive
  switch per locale, or a test that walks every key.
- **Order matters more than effort: this refactor is the first commit of the release.** The other
  seven items add a lot of new text (consent, feedback, update, HDR, light table, contact sheet,
  wire captions). Adding a locale after them means writing every new string twice; doing it first
  means writing each new string once in four languages.
- **The real work is terminology, not plumbing.** zh-Hant needs one convention chosen and held
  (Taiwan or Hong Kong: 底片/相紙/暗房 vs 菲林), and Japanese needs its own register for a darkroom
  product (フィルム, 印画紙, 粒子, ハレーション, 露光, 焼き付け, 中間子). Propose the website's own
  precedent as the form: a row-by-row table, English beside each translation
  (`docs/translation-zh-Hans.md` — the site is *built* from it), one document per locale, and a
  native reader for the Japanese before it ships. The app has real Japanese users; they are the
  reviewers, and §0's feedback row is how to reach them.
- **What is not translated**: product names, film/paper/profile names, the CLI and MCP tool
  descriptions (they are an API surface), the log's own JSONL keys and categories (the owner reads
  them), the licence and credits text, and the LUT file names.
- **Layout must be checked, not assumed**: `AGENTS.md`'s rule that no message may be truncated and
  no label may overflow (`.fixedSize()` on a message is a defect), at every interface scale the
  Settings ▸ General control offers, in all four languages — the longest label in the app is
  usually Japanese in kanji-heavy strings and Traditional Chinese in the Settings rails.

### 6.3 Scope

In: the whole interface — rails, Settings (all five pages), the export page, the About panel, the
new surfaces of this release, the diagnostic sentences. Out (unless the owner says otherwise): the
marketing site (`spektralab.app` has zh-Hans today; its own repo has the translation-table
machinery to add two more), the usage guide (untracked, and it documents 1.2.2 — it needs a version
sweep before it needs a language), and the mobile app (its own repo, its own zh-Hans, synced by
agreement).

---

## 7. Sequence, dependencies and gates

**Recommended order** (each step is a release-ready commit series, not a phase of one big 1.4.0):

1. **The localization table (§6).** First, because every later feature writes its strings once.
2. **The log server client and the feedback row (§0).** Smallest complete feature; it is also what
   makes the rest of 1.4.x learnable from real users.
3. **The automatic update check (§1).** Shares the privacy-policy and release-notes work with step
   2, so they land together.
4. **The blue/violet measurement, then the field (§5).** Research first; ship only if the fit earns it.
5. **Films and the runbook (§4).** RFC-022's solver comes to `main` first — the manner of making a
   pair is settled (§4.3); what is left is choosing the stocks and measuring whether each pair solves.
6. **HDR display (§2).** Needs XDR hardware to verify, no other dependency.
7. **The light table and the contact sheet (§3).** The largest, the only one needing new design, and
   the one that can move to 1.5.0 without holding anything else back.

**Things that must move in the same release as their feature:** the privacy policy (macOS coverage;
the log upload; the update check); the release notes' promise about network access, which today
reads "the app asks for no network access at any point" (`rfc/RFC-021-update-check.md` §3 — it must
change in the same release, not afterwards); the Settings captions that make the same promise; the
API spec and `parity_schema.py` for each new wire field; `Tools/gen-project.py` for every new file;
the README's screenshots (the owner's own captures — ask before replacing) and its stale lines
(it still describes ad-hoc signing and the `xattr` step; releases have been a Developer ID-signed,
notarised DMG through `Tools/package.sh` since 1.3.3); the website's `src/data/site.json` (version,
download, size, SHA) at the release; the mobile sync for anything touching the engine.

**Gate for every step:** the full `SpektrafilmTests` before a push; `parity_schema`, `parity_setup`,
`parity_render`, `parity_lut` for engine changes (with the reference `PYTHONPATH`, remembering that
`build.sh dylib` alone leaves the drivers stale); `SurfaceAgreementTests` for every new surface that
shows a frame; a `batchExporting` check for everything that moves the open frame; and a measurement,
not an adjective, for every speed or memory claim. Releases: `MARKETING_VERSION` 1.4.0 on the
release commit, the notarised DMG from `Tools/package.sh`.

**Not in 1.4.0, and deliberately:** self-updating (the notarised DMG makes it *possible* now — the
RFC-021 §3 licensing objection is stale — but it is its own release), HDR files, HDR on mobile,
RFC-017, free placement on the light table, presets (the clipboard's §7 list), and any post-print
editing.

---

## 8. Decisions taken on 2026-10-16

| # | Question | Decision |
|---|---|---|
| 1 | What is the light table in the desktop app? | An **in-app table of the folder**: the open folder's frames on a backlit panel at true millimetres, layout shared with the sheet. Not a plain thumbnail grid, not a separate window for finished exports. |
| 2 | What does the contact sheet produce? | **A paper-sized sheet at full resolution** (A4 at 300 dpi by default), frames at true millimetres, caption rows, written as TIFF/PNG. Not a PDF (no writer exists), not merely a picture of the screen. |
| 3 | How far does HDR go? | **Display first**: the display's EDR headroom and the paper's measured ceiling, no new file formats, no export change. |
| 4 | How does feedback leave the app? | **`mailto:` with a prefilled subject and body, plus the diagnostic bundle written to disk and revealed in Finder for the user to attach.** No in-app form, no automatic attachment. |
| 5 | What leaves the machine on an upload? | **Anonymous, always** — the app anonymises before the bytes go. A bundle the user mails themselves is a different story: it is their act and follows the file-names toggle they saw when they saved it. |
| 6 | A log larger than the server takes? | **Send the tail** — the last 4 MiB, first partial line dropped to keep the body valid NDJSON, truncation recorded in the outcome line. |
| 7 | How are new film and paper pairs made? | **RFC-022's way** — the per-pair neutral solver comes to `main`; a pair that does not solve ships no row rather than a guessed one. |

## 9. Still open for the owner

Three of the questions asked on 2026-10-16 are answered and are decisions now (§8, rows 5–7): what
leaves the machine, what happens to an oversized log, and how new pairs are made. What remains:

1. **Feedback address**: `Hanze_Qiu@outlook.com` (the published one), or a support alias?
2. **The update check's default**: on or off at first launch, and does the About panel get the same
   row (RFC-021 §6's open question, now answerable with one shared state)?
3. **HDR export** (left open on 2026-10-16): does an extended-range file ever exist (gain-map
   HEIF/AVIF, HDR PNG), and if not, is the owner content that the file and the canvas differ above
   white for as long as the extended-range display is on? Answer before the feature ships, not after.
4. **The light table**: which papers (A4 landscape only?), how many frames a sheet, does a
   never-developed frame show its thumbnail (instant, honest) or get a lightweight render?
5. **The contact sheet**: with Film Edge on, strips (true to the table) or gates (true to a
   darkroom sheet)? What exactly does a caption row carry?
6. **Films**: which stocks first?
7. **Languages**: zh-Hant in Taiwan or Hong Kong conventions, and who reads the Japanese before it
   ships?
8. **Does "more language support" include the website and the guide** in the same release?

## 10. What this PRD is not

It is not an RFC: no wire field is decided here, no measurement is claimed that the repository does
not already contain, and nothing in §0–§6 has been built. The next free RFC number on `main` is
**RFC-037** (022 lives on a branch; 032, 035 and 036 belong to the mobile repo). Each feature above
that survives §9 becomes an RFC, and the ones that touch the wire edit
`API-SPEC-callable-render-service.md` in the same commit.
