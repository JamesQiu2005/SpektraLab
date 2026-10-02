# Half-frame pair on desktop (proposal v2, 2026-10-02)

Two neighbouring frames on one piece of half-frame film. **The film is the canvas, and each of its two
holes takes a frame as a layer.** For review; nothing is implemented.

v2 replaces v1 (`git show 843c6c1`) after the owner's corrections the same day:

- The two frames come from the same part of the film, shown placed together, with no film edge.
- Only the film stock is shared. Everything else is adjustable per hole, because it is digital.
- Exposure edits get a scope: the frame only, or the frame and the overscan.
- The pair owns its settings.
- Invert the canvas: the piece of film comes first, and frames are added into its empty holes.
- Later the same day: **an accurate film edge matters too.** The engine should render the real strip
  around the pair, with half-frame numbers such as 6 and 6A. §6 covers that path, with a real engine
  render.

| file | what |
|---|---|
| `pair_1_new_v2.svg` | a new pair from one picked frame: the right hole is empty and **Add Frame** is open |
| `pair_2_hole_v2.svg` | the right hole picked; its Enlarger +1.00 applied to the frame only |
| `pair_3_film_v2.svg` | the Film layer picked: the one stock, the piece, the overscan |
| `pair_4_place_v2.svg` | placing the right hole's picture: the hole stays, the picture moves |
| `pair_concept_v2.svg` | layers, exposure scope, what each layer holds, how it renders |
| `pair_5_film_edge_v2.svg` | **Film Edge on:** the pair as one strip, frames 6 and 6A, the Film layer picked |
| `pair_6_scope_edge_v2.svg` | **Film Edge on:** the right hole's print +1.00 at *+ Overscan* |
| `pair_concept_edge_v2.svg` | why one engine canvas; the scope on the strip, frame vs + overscan |
| `sample_135_half_pair_6_6A.jpg` | **the engine's render at full size** (3377 × 3087): street and snow on one Gold 200 strip |
| `sample_135_half_pair_6_6A_black_holes.jpg` | the same strip with black holes (a black backing, or a print of the strip) |
| `pair_scratch.patch` | the scratch engine change that rendered it, against SpektraLab_mobile `371ad16`. **Not applied anywhere** |
| `tools/` | the design-only scripts that drew and rendered all of this (README inside). Open questions for the owner: `PRD/QUESTIONS-2026-10-02-half-frame-film-edge-panoramic.md` |
| `preview_desktop_v2.png`, `preview_edge_v2.png`, `preview_concept_v2.png` | the first four screens 2×2, the two Film Edge screens, the concept sheet |

**How the drawings were made:**
- **The chrome** is the Film Edge proposal's desktop parts (`SpektraLab_mobile/design/src`: Theme.swift
  tokens, 1920 × 1080 pt, rails 254 / 288), checked against the running app's screenshot.
- **The pictures** are the owner's frames (`样片日志01`, decoded in `research/overscan/engine_proto/in/`)
  developed through filmify's own engine dylib: Kodak Gold 200 on Supra Endura, with grain at half-frame
  scale.
- **The gap and the empty hole** are renders of unexposed film, not a painted colour.
- The snow frame's original file name was not recorded with its decode, so it is labelled `snow.tif`.

## 1. Why

- **Half frame is thought of in pairs.** Two 18 × 24 mm frames sit on 37 mm of film, about 1 mm apart.
  The Pentax 17 (2024) brought the format back.
- **Labs sell the pair as a product.** A "2UP" scan is the two neighbours in one image, with the gap
  between them.
- **Fujifilm copies it digitally.** The X half's *2-in-1* joins two shots side by side, and its app
  re-pairs old ones. DPReview: it "encourages thinking about pairs of images".
- **RFC-032 left this to the owner** (§12, §22, §23). It said neighbours must be *real adjacent frames*,
  never invented. This proposal is that decision for half frame.

Sources:
[Pentax Forums](https://www.pentaxforums.com/articles/hands-on-reviews/pentax-17-first-impressions-review.html),
[DPReview, X half](https://www.dpreview.com/reviews/fujifilm-x-half-retro-compact-camera-review/),
[Fujifilm, 2-in-1](https://shopusa.fujifilm-x.com/discover/fujifilm-x-half-2-in-1-mode-explained/).

## 2. The model

A **Half-Frame Pair** is a piece of film with three layers, one picked at a time:

| layer | what it is | what it holds |
|---|---|---|
| **Film** | the piece: one stock, two 18 × 24 mm holes, the gap | film stock (**the only shared setting**), 135 half (fixed), camera held level / turned, spacing, swap holes, **Overscan** print (Brightness, Yellow, Magenta) |
| **Left hole** | a frame placed in the hole | the shot, the print, placement, masks, Post-Dev |
| **Right hole** | the same | the same, independently |

- **The canvas fits the piece, never a photo.** Adding, replacing or moving a picture cannot resize
  anything. Zoom and pan act on the piece.
- **An empty hole is unexposed film.** It shows as the base prints, near-black, with **Add Frame** over it.
  The overlay never exports.
- **A pair references frames; it does not consume them.** The frames stay in the filmstrip as themselves,
  and a frame can be in more than one pair.

## 3. The flow

1. **New Half-Frame Pair (⌘J)**, from the Frame menu or the filmstrip's menu. Picked frames fill the holes
   in capture order: two picked fill both, one fills Left, none leaves both empty. The pair is a new
   filmstrip cell after its left frame (an empty pair goes at the end). ⌘J is free today.
2. **Add Frame** on an empty hole opens a picker of the open folder's frames, drawn as the Browse grid
   draws them, with a name filter. A frame already in this pair is dimmed and labelled. Dragging a
   thumbnail from the filmstrip onto a hole also places it, or replaces what is there.
3. **Pick a layer.** The *Half-Frame Pair* section at the top of the left rail lists Film, Left hole and
   Right hole; the picked one gets the list's white capsule. On the canvas, a hole picks itself and the
   gap picks Film. Both rails then show that layer's controls, and the Parameters rail names it (thumbnail
   and file name), so an edit's target is never ambiguous.
4. **Edit a hole.** Print, Crop, Enlarger, Input / Camera, Scene Placement, masks and Post-Dev all act on
   that hole alone. Film reads *Kodak Gold 200 · set by pair*, and Film Format reads *set by pair*.
5. **Choose the exposure scope** (§4) in Input / Camera and in Enlarger: **Frame** or **+ Overscan**.
6. **Place the picture.** The crop tool on a hole moves and scales the picture *under the fixed hole*:
   drag to move, scroll to scale. 1.00× fills the hole, and it never goes below that, so no base shows.
   Straighten, rotate and flip work as on a frame. Return develops; Esc puts it back.
7. **Edit the Film layer.** Changing the stock develops both holes. *Camera* switches between held level
   (holes side by side) and turned (stacked). *Spacing* runs 0.5–2.0 mm (default 1.0). *Swap Left and
   Right*. *Overscan* is the print of the unexposed film.
8. **Film Edge** (a section of the Film layer, as in the Film Edge proposal) turns the piece into the real
   strip (§6), with *Format 135 half · pair*, *View*, *Holes*, *Numbers 6 · 6A* and *Body*. The canvas still
   fits the piece, now the film's full width, and the holes are still where frames are added.
9. **Export.** A pair is one item: the whole piece by default, or *Two halves*, or *Both*. Export waits
   until both holes are filled.

The hole's menu (right-click on it or its layer row) has *Replace Frame…*, *Remove Frame*, *Swap with
Other Hole*, *Reset Placement* and *Open Frame Alone*.

## 4. Exposure scope

**Every exposure edit in a hole says where it lands.** That covers Film Exposure (Input / Camera) and the
Enlarger's Brightness, Yellow, Magenta and Pre-flash. Temperature and Tint are not exposure; they are the
decode's white balance.

- **Frame:** only that hole's picture changes.
- **+ Overscan:** the same change also lands on the Film layer's **Overscan**, which prints the gap and any
  empty hole. Film Exposure moves the Overscan's Brightness by the same stops, and the filters move its
  filters.
- **It is a delta,** so both holes can push the Overscan, and the Film layer shows the sum, which can also
  be edited there directly.
- **Default: Frame,** so the two holes stay independent. The choice is remembered per hole per section.
  Holding ⌥ while dragging flips it for that one drag.

**Measured, through the engine.** Kodak Gold 200 on Supra Endura prints unexposed base at about
**5 %** (RGB 0.042 / 0.049 / 0.057 of full scale, slightly cool). +1.00 stop on the Overscan lifts it
to about **6.5 %**, and +1.50 to about 10 %. So on a print, *+ Overscan* moves the gap only a little,
because the base sits near the paper's black. That is the physics, and the drawings show it unexaggerated
(`pair_concept_v2.svg` §B has the gap at 6×).

**Film Edge on a single frame** should get the same control with the same meaning: the frame, or the
frame and the rebate. Unlike the pair, that needs the engine to print the frame and the rebate with
different values. It is a question for the overscan sync and API-SPEC §13, not for this proposal.

## 5. Rules

- **Storage: the pair owns the Film layer, each hole's print, placement, masks and Post-Dev.** It goes in a
  store of its own next to `Sidecars/`, naming its frames as `Sidecar.Source`, so a moved file is found
  the same way.
- **The shot stays the frame's.** Metering, Film Exposure, Temperature/Tint and Scene Placement live in
  the frame's own sidecar: it is the same shot wherever it appears. Editing Film Exposure in a pair edits
  the frame alone and in any other pair (§7 D5).
- **A new hole's print starts from the frame's own print,** so a frame looks the same the moment it is
  added. Only its stock changes to the pair's.
- **Grain is half-frame grain at any placement.** Each hole is sent `film_format_mm = 24 × source long
  edge ÷ the picture's long edge inside the hole`. That is the crop-is-the-frame formula the app already
  has (`Session.cropScale`), so scaling a picture up coarsens its grain the way an enlargement does.
- **Hole pixel size** is the smaller of the two pictures' source pixels across the hole, so neither is
  upscaled. The gap is H × spacing ÷ 24. The drawn pair (two 1600 × 2400 frames) is
  1600 + 89 + 1600 = **3289 × 2133**.
- **The filmstrip cell** is the piece in miniature, with an empty hole showing the base and a +. Selection
  marks are the same as for frames: the white frame and nothing else (PRD §5).
- **Before/after** acts on the whole piece. **Copy Settings** from a hole copies that hole. **Paste** onto
  a picked pair pastes onto both holes, and never onto the stock.

## 6. With Film Edge: one engine canvas

**With Film Edge on, the pair is one strip, rendered by the engine.** The camera exposes the same gate
twice, 19.00 mm apart (one advance of 4 perforations). `sample_135_half_pair_6_6A.jpg` is the engine's own
render of that, with nothing drawn by hand:

- **The film:** Kodak Gold 200 on Supra Endura, `135_half`, held level, camera No. 19.
- **The top band:** **6**, then the stock name.
- **The bottom band:** the DX code once per half frame, then **6** under the first frame and **6A →** under
  the second.
- **The rest:** eight perforations, the same gate shape and penumbra twice, and unexposed film between the
  frames.

**Why one canvas, not two renders butted together:**
- **Each render has its own scan rotation and weave,** so the strip's edges and perforations would step at
  the seam.
- **The numbers can't be made consecutive across two renders.** They walk in half-frame steps across one
  canvas (`half = 2·n0 + m` in `imprint_groups`), but the frame seed sets `n0` in whole frames.
- **Halation, edge fog and leaks cross the gap,** as they do on film.

**The scratch build** (`pair_scratch.patch`) is the mobile engine at `371ad16`, exported into a
scratchpad, plus one change:
- an `overscan_pair` flag;
- the input carries both pictures, the second starting 19.00 mm along the film;
- the gate stays 18 mm, and pixel pitch comes from 37 mm along the film instead of the 24 mm gate;
- the canvas kernel takes the union of the gate and the same gate one advance on.

It handles held level only and was never applied to either repo.

**Measured on the render:**
- each gate is 1,615 × 2,148 px: the 1,600 × 2,133 picture plus its penumbra;
- the gap is 75 px, 0.84 mm: the 1 mm between frames, less the soft edges;
- the canvas is 3,377 × 3,087 px from a 3,289 × 2,133 input.

**How each hole keeps its own settings on one canvas:**

- **Shot (per hole):** the app builds the engine's input with each picture under its gate.
  - White balance is applied at decode, which is already the app's job.
  - Exposure: the app meters each picture alone (`spk_solve("exposure")`), then applies that hole's gain
    and Film Exposure to its half of the input. The canvas renders with `auto_exposure` off, so the engine
    does not re-meter across both.
- **Print (per region):** a print-only change leaves the developed negative identical. So the left gate,
  the right gate and the overscan are each a **reprint of the same canvas**, cut together along the
  engine's own gate coverage. Paper, Enlarger, filters and pre-flash stay free per hole.
  `pair_6_scope_edge_v2.svg` and the concept sheet show exactly that composite, from engine renders. The
  masks were taken from the engine by rendering a flat input twice and differencing.
- **Film (shared, because it is one piece of film):** stock, grain and halation. Halation from the snow
  frame reaches into the gap, as it should. With Film Edge on, the per-hole grain and halation strengths
  of §5 lock to the pair (§7 D13).

**Exposure scope is plainly visible here.** With *+ Overscan*, the edge print, DX code and rebate lift with
the right frame's print, and the warm edge fog appears. The left frame is untouched. Without Film Edge,
the gap alone sits near paper black and barely moves (§4).

**Engine work this needs** (shared engine; it belongs with the overscan sync, after the mobile session's
current merge, and is not done here):

| # | what | why |
|---|---|---|
| E1 | `overscan_pair` for `135_half`: the same gate twice, one advance apart (plus the frame's advance error), held level and turned; the date back per frame | the strip itself; the scratch patch proves held level |
| E2 | Gate coverage out (the `spk_overscan_geometry` API-SPEC §13 proposes): canvas-space coverage of each gate | per-region reprints, and hit-testing holes on the canvas |
| E3 | Optional: per-gate Scene Placement | without it, Scene Placement is shared while Film Edge is on (§7 D14) |

API-SPEC §13 would gain these fields. API-SPEC belongs to nobody in particular, so say so before editing
it.

## 6a. Without Film Edge: no engine change

- **Each filled hole** is one ordinary engine render of its frame: its shot, the pair's stock, and the
  hole's print and effects.
- **The Overscan** is a render of unexposed film of the same stock at the gap's pixel size, so it carries
  the film's grain. It is cached per stock and Overscan values.
- **A pair compositor (Metal)** places the two hole renders and the gap patch into one image. The canvas
  and export draw that same image.
- **Nothing changes in `engine/`, on the wire, or in API-SPEC**, so the mobile engine port is untouched.
- **Memory:** a pair holds two developed frames, the same as A/B today (`DecodeResidency`, RFC-019 §7.1).
  Batch export develops a pair's holes, composes, writes, and releases both before the next item.

## 7. Decisions for the owner

| # | question | recommended | alternative |
|---|---|---|---|
| D1 | Scope default | **Frame** for every section | + Overscan for the Enlarger (closest to one print) |
| D2 | Which edits carry a scope | **Film Exposure; Enlarger Brightness, Yellow, Magenta, Pre-flash** | also the Tone Mask |
| D3 | What + Overscan does | **Adds the same delta** to the Overscan | sets the Overscan equal to the hole's value |
| D4 | Single-frame Film Edge gets the same scope | **Yes, later,** through the overscan sync (engine) | pairs only |
| D5 | The shot lives in the frame (your storage answer) | **Keep:** Film Exposure in a pair is the frame's everywhere | copy the shot into the hole at Add |
| D6 | Paper per hole | **Free:** each hole may use another paper | lock the paper with the stock |
| D7 | A frame in several pairs | **Yes** | one pair per frame |
| D8 | Where a pair sits in the filmstrip | **After its left frame;** an empty pair at the end | all pairs at the end |
| D9 | Export with an empty hole | **No:** fill both holes first | export the empty hole as unexposed film |
| D10 | Spacing | **0.5–2.0 mm, default 1.0** | fixed 1.0 mm |
| D11 | Names | **Half-Frame Pair, New Half-Frame Pair, Add Frame, Film / Left hole / Right hole, Applies to: Frame / + Overscan.** zh-Hans needs a choice: 半格双拼 / 半格对 / 双联 | — |
| D12 | Plus | **Not gated on desktop** | follow mobile's Plus |
| D13 | Grain / halation strengths with Film Edge on | **Shared:** one piece of film | per hole, from two film renders cut together (halation would seam at the gap) |
| D14 | Scene Placement with Film Edge on | **Shared until E3,** per hole after | build E3 first |
| D15 | Which number the left frame takes | **The engine's grid decides (6 · 6A).** *Another* moves along the roll | also offer the straddling pair (6A · 7) |
| D16 | Edge print text on desktop | **Display name** (`KODA GOLD 200`), as the Film Edge drawings do | the real name; desktop may print real marks (RFC-032 §26) |

## 8. Building it without breaking things

The work comes in phases, each small enough to review whole. Every phase ends with `xcodebuild test`
green, the app launched and looked at, a `/code-review` pass, then a commit that is pushed at once.

| phase | what | tests that gate it |
|---|---|---|
| P1 | `Pair` model and store, layers, the Overscan values, scope deltas, undo. No UI | create→fill→edit→undo restores the pair file byte for byte; a scope delta writes the hole and the Overscan or neither; a moved frame is found; a missing frame leaves an empty hole, never a crash |
| P2 | filmstrip/Browse cell, ⌘J, Add Frame picker and drag, the layer list | `framing(of:)` for pair cells; capture-order filling for 0/1/2 picked; dropping onto a hole replaces only that hole |
| P3 | canvas: compositor, picking a layer by click, placement under the hole, rails following the layer | hole and gap sizes (3289 × 2133, mixed sizes, turned); hit-testing holes vs gap; per-hole `film_format_mm` at 1.00× and 1.18×; switching layers mid-drag never writes the other hole |
| P4 | export of pairs | output size and metadata; One / Two halves / Both; export disabled with an empty hole; batch peak stays at two developed frames |
| P5 | Film Edge pairs, after E1/E2 land in the shared engine | the strip's numbers read back as N / NA; each gate's coverage matches its hole; per-region reprints leave the other regions bit-identical |

**What is most likely to break, and the guard for each:**

- **An edit landing on the wrong hole.** The picked layer is one value in `Session`, read by the canvas,
  both rails and every write. A test switches layers mid-edit and checks which record changed.
- **The shot and the print disagreeing about where they live.** There is one accessor per layer. Shot
  reads and writes go to the frame's sidecar; everything else goes to the pair. Each field is tested to
  have exactly one home.
- **A scope delta applied twice, or to the wrong side.** One write path writes the hole and the Overscan
  together, in one undo record.
- **Stale renders.** Each hole's render is keyed on its frame, shot, print and placement scale. A swap
  re-composes without re-developing. A placement commit re-develops only that hole. An Overscan change
  re-renders only the gap patch.
- **The filmstrip and Browse grid disagreeing.** Both draw from `framing(of:)`, as `FrameFraming`
  requires.

## 9. Not in this proposal

- Pairs on 120, or full-frame 135 neighbours (RFC-032 §23 open item 2).
- More than two frames, or contact sheets.
- Pairs in the CLI/MCP (RFC-026) or on mobile.
