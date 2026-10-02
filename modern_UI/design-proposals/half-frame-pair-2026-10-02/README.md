# Half-frame pair on desktop (proposal v2, 2026-10-02)

Two neighbouring frames on one piece of half-frame film. **The film is the canvas, and each of its two
holes takes a frame as a layer.** For review; nothing is implemented.

v2 replaces v1 (`git show 843c6c1`) after the owner's corrections the same day:

- The two frames come from the same part of the film, shown placed together, with no film edge.
- Only the film stock is shared. Everything else is adjustable per hole, because it is digital.
- Exposure edits get a scope: the frame only, or the frame and the overscan.
- The pair owns its settings.
- Invert the canvas: the piece of film comes first, and frames are added into its empty holes.

| file | what |
|---|---|
| `pair_1_new_v2.svg` | a new pair from one picked frame: the right hole is empty and **Add Frame** is open |
| `pair_2_hole_v2.svg` | the right hole picked; its Enlarger +1.00 applied to the frame only |
| `pair_3_film_v2.svg` | the Film layer picked: the one stock, the piece, the overscan |
| `pair_4_place_v2.svg` | placing the right hole's picture: the hole stays, the picture moves |
| `pair_concept_v2.svg` | layers, exposure scope, what each layer holds, how it renders |
| `preview_desktop_v2.png`, `preview_concept_v2.png` | the four screens 2×2, and the concept sheet, flattened |

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
8. **Export.** A pair is one item: the whole piece by default, or *Two halves*, or *Both*. Export waits
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

## 6. How it renders: no engine change

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

## 8. Building it without breaking things

The work comes in phases, each small enough to review whole. Every phase ends with `xcodebuild test`
green, the app launched and looked at, a `/code-review` pass, then a commit that is pushed at once.

| phase | what | tests that gate it |
|---|---|---|
| P1 | `Pair` model and store, layers, the Overscan values, scope deltas, undo. No UI | create→fill→edit→undo restores the pair file byte for byte; a scope delta writes the hole and the Overscan or neither; a moved frame is found; a missing frame leaves an empty hole, never a crash |
| P2 | filmstrip/Browse cell, ⌘J, Add Frame picker and drag, the layer list | `framing(of:)` for pair cells; capture-order filling for 0/1/2 picked; dropping onto a hole replaces only that hole |
| P3 | canvas: compositor, picking a layer by click, placement under the hole, rails following the layer | hole and gap sizes (3289 × 2133, mixed sizes, turned); hit-testing holes vs gap; per-hole `film_format_mm` at 1.00× and 1.18×; switching layers mid-drag never writes the other hole |
| P4 | export of pairs | output size and metadata; One / Two halves / Both; export disabled with an empty hole; batch peak stays at two developed frames |

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

- The film edge (sprockets, rebate, edge print) around a pair. The owner chose none.
- More than two frames, contact sheets, and 135 full-frame neighbours.
- Pairs in the CLI/MCP (RFC-026) or on mobile.
