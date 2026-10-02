# Half-frame pair on desktop (proposal, 2026-10-02)

Two frames become one strip of half-frame film: one cell in the filmstrip, one canvas, one export.
For review. Nothing is implemented; the owner's decisions (§5) come before any code.

| file | what |
|---|---|
| `pair_1_pick_v1.svg` | pick two frames, *Pair as Half Frames* (⌘J) |
| `pair_2_one_look_v1.svg` | the one-roll-one-look sheet, shown only when the two disagree |
| `pair_3_open_v1.svg` | the pair open: one canvas, one half picked, linked sections |
| `pair_4_frame_half_v1.svg` | framing a half inside its fixed slot |
| `pair_flow_v1.svg` | states, what is shared, how it renders, geometry, export |
| `preview_desktop_v1.png`, `preview_flow_v1.png` | the four screens 2×2, and the flow sheet, flattened |

The drawings are wireframes in the v3 tokens with placeholder pictures, not engine renders.

## 1. Why

- **Half frame is thought of in pairs.** Two 18 × 24 mm frames sit on one 36 mm stretch of film, about
  1 mm apart. The Pentax 17 (2024) brought the format back, and shooters post its frames as diptychs.
- **Labs sell the pair as a product.** Most labs scan half frame either one frame at a time or **"2UP"**:
  the whole 36 mm frame in one scan, so each image is a diptych of two neighbours with the black gap
  between them, often for a surcharge.
- **Digital cameras now copy it.** Fujifilm's X half (2025) has a *2-in-1* mode: shoot, pull the frame
  lever, and the next shot is joined to it side by side. Three files are kept: the two halves and the
  joined one. Its app re-pairs old shots and sets the divider's colour and width. A setting chooses
  whether the first shot goes left or right. DPReview's verdict: it "encourages thinking about pairs
  of images".
- **SpektraLab already models the film itself.** That covers the stock, the print, grain at the format's
  scale, and (specified) Film Edge with `135_half`. A pair is the missing piece between "a picture that
  looks like film" and "a strip of film". RFC-032 §12, §22 and §23 left this open: neighbours on the
  strip should be *real adjacent library frames*, never invented ones, and it is "a product decision"
  the owner had not made. This proposal is that decision for half frame.

Sources: [Pentax Forums, Pentax 17 first impressions](https://www.pentaxforums.com/articles/hands-on-reviews/pentax-17-first-impressions-review.html),
[Pentax 17 diptychs](https://www.flickr.com/photos/jsollows/54555024562),
[DPReview, X half review](https://www.dpreview.com/reviews/fujifilm-x-half-retro-compact-camera-review/),
[Fujifilm, 2-in-1 mode](https://shopusa.fujifilm-x.com/discover/fujifilm-x-half-2-in-1-mode-explained/),
[35mmc, diptychs on the Pen FT](https://www.35mmc.com/26/10/2020/shooting-diptychs-with-the-olympus-pen-ft-by-noel-roque/).
The research folder for Film Edge has a real half-frame strip:
`SpektraLab_mobile/research/overscan/135/half-frame-vs-standard-135.jpg`.

## 2. The flow

1. **Pick two.** Click a frame and ⌘-click a second. This is the existing pick (`Session.togglePick`);
   nothing new to learn.
2. **Pair them.** *Pair as Half Frames*, ⌘J, from the filmstrip's menu or the Frame menu. It is enabled
   only with exactly two frames picked, neither already in a pair. ⌘J is free today.
3. **One roll, one look.** If the two frames' shared groups (§3) differ *and both were developed*, a
   sheet asks whose look the pair takes. The left card is the default. Cancel makes no pair. If one
   frame was never developed, it takes the other's look silently. If both match, there is no sheet.
4. **The pair opens.** One canvas shows both halves and the gap. **One half is always picked**, marked
   with the open-frame mark. Click the other half, or press ⇥, to switch. There is no "both" mode, so
   every control has exactly one meaning at any moment.
5. **Edit.** Linked sections (chain glyph) change both halves. The rest changes the picked half. The
   panel header says which half, with the file name.
6. **Frame a half.** The crop tool on a pair moves and scales the picked half's picture *inside its fixed
   slot* (3:4 side by side, 4:3 stacked). Return develops; Esc puts it back.
7. **Export.** A picked pair is one item. It writes one composed file by default (§5 D8).
8. **Unpair.** The two frames come back as two cells, keeping the pair's look. Every step is one undo
   step, and undoing *Pair* restores both sidecars exactly, including a look the sheet replaced.

**Later, not in v1:** *Pair the Picked Frames in Order* (a whole roll paired 1–2, 3–4, …), drag a
thumbnail onto another to pair, and the Film Edge strip (§4).

## 3. Rules

**What is shared and what is per half** (`pair_flow_v1.svg` §B)

| | scope | why |
|---|---|---|
| Film stock, Print stock, Film Format, Enlarger | shared | one roll, one paper |
| Grain / halation / glare strengths, Film Edge, Date Back face and size | shared | one development, one camera back |
| Exposure, metering, white balance, Scene Placement, Latitude | per half | each shot had its own light |
| Crop in the slot, straighten, flips | per half | stored in the pair, not in the frame |
| Masks, Post-Dev | per half | local edits are local |
| Order, layout, gap colour and width | pair | stored in the pair |

- **Shared groups live in both frames' sidecars.** An edit in a linked section writes both sidecars in
  one step. There is no third copy of the look, so a frame opened alone after Unpair looks as it did in
  the pair.
- **The pair stores only what is the pair's:** its two frames (as `Sidecar.Source`, so a moved file is
  found the same way), the order, the layout, the gap, and each half's slot geometry. It goes in a store
  of its own next to `Sidecars/`.
- **Film Format reads *Set by Pair*:** 135 half, 18 × 24 mm, a new `FilmFrame` still preset. Grain and
  halation are at half-frame scale. The engine is given `film_format_mm` per half so that **the slot's**
  long edge is 24 mm (24 × source long edge ÷ slot long edge), because geometry is applied after the
  engine. A tighter crop in the slot therefore means coarser grain, as an enlargement does.
- **Layout from the pictures:** both portrait → side by side (camera held level), both landscape →
  stacked (camera turned). Mixed → side by side, and the landscape one starts centred in its portrait
  slot. Nothing is ever stretched.
- **Pixel size:** slot height H is the smaller of the two cropped heights, so neither half is upscaled.
  Gap = H × width_mm ÷ 24. Two 4000×6000 portraits give 4000 + 222 + 4000 = **8222 × 5333** (44 MP).
  Export's long edge sizes the whole pair.
- **The gap** is the film between frames. Unexposed base prints black, so *Black, 1.0 mm* is the
  default. *White* is the lab-print look and *None* is the plain diptych.
- **Before/after, zoom and pan** act on the whole pair. Copy Settings copies the picked half. Paste onto
  a picked pair pastes onto both halves; the shared groups stay equal by construction.
- **Selection marks stay the only marks** (PRD §5). A pair cell is told apart by its shape: two halves
  and a gap, with no badge. The Browse grid draws the same cell through `Session.framing(of:)`.
- **If a frame goes missing,** the pair shows a placeholder half and does not develop. Unpair still
  works.
- **If the two sidecars disagree on a shared group,** a banner offers *Use the left's* / *Use the
  right's* when the pair opens. That can happen if a sidecar was edited outside the pair (CLI/MCP,
  RFC-026, or by hand). It is never fixed silently.

## 4. How it renders, and what it does not touch

Each half is an ordinary single-frame render through today's path: its own sidecar, its own engine
session, unchanged engine code. A new **pair compositor** in Swift/Metal crops each result to its slot,
adds the gap, and hands one texture to the canvas and to export.

- **No engine field, no API-SPEC change, no RFC-032 change.** Nothing here touches `engine/`, so
  nothing collides with the mobile engine port running on the other machine.
- **Memory:** a pair holds two developed frames, which is what `DecodeResidency` (RFC-019 §7.1)
  already keeps for A/B. Batch export develops a pair's two halves, composes, writes, and releases both
  before the next item.
- **Later, with Film Edge on desktop:** each half renders with `135_half` overscan, and the two canvases
  abut into one strip. The canvas along the film is the frame plus about 0.45 mm a side, so two of them
  abut with the real ~0.9 mm gap and rebate. That step needs consecutive edge numbers (`12`, `12A`)
  across the halves, an engine-side question for RFC-032. It is not designed here.

## 5. Decisions for the owner

Each has a recommendation; the drawings follow it.

| # | question | recommended | alternative |
|---|---|---|---|
| D1 | Do a pair's frames still show as their own cells? | **No:** one pair cell where the earlier frame was | show all three, as the X half keeps three files |
| D2 | Can one frame be in two pairs? | **No.** One pair per frame, so a shared edit has one meaning | yes, with a copy of the frame per pair |
| D3 | Default order | **Earliest capture on the left** (reading order), *Swap* to change | as on the negative. Which side that is depends on the camera; the X half makes it a setting |
| D4 | Shared vs per half | **The table in §3** | also share Post-Dev; or share nothing and use the clipboard |
| D5 | Different looks at pairing | **Ask, only when both were developed** | always take the left's; or keep both and drop the link |
| D6 | Gap | **Black / White / None, 0–3 mm, Black 1.0 mm default** | a fixed 1 mm black gap only |
| D7 | Pair crop vs the frame's own crop | **Separate:** the pair's slot framing never changes the frame's crop | one crop shared by both views |
| D8 | Export default | **One composed image.** *Two halves* and *Both* on the export page | always both |
| D9 | Names | **Half-Frame Pair; Pair as Half Frames; Unpair.** zh-Hans needs a choice: 半格双拼 / 半格对 / 双联 | — |
| D10 | Plus | **Not gated on desktop.** Mobile's Plus proposal makes half frame a Plus format; the pair would follow it there | gate it with Film Edge's half frame |
| D11 | v1 scope | **Pick two only.** Roll pairing and drag-to-pair come later | all three in v1 |
| D12 | After Unpair | **The frames keep the pair's look,** 135-half Film Format included. Undo restores the old one | restore each frame's pre-pair look on Unpair |

## 6. Building it without breaking things

The work splits into phases, each small enough to review whole. Each phase ends the same way:
`xcodebuild test` green, the app launched and looked at, a `/code-review` pass, then commit and push.

| phase | what | tests that gate it |
|---|---|---|
| P1 | `Pair` model, pair store, linked-group write, undo. No UI | pair→unpair→undo leaves both sidecars byte-identical; a shared edit writes both or neither; a frame can't join a second pair; a moved file is found; diverged sidecars are detected |
| P2 | filmstrip and Browse pair cell, ⌘J and menus, the look sheet | `framing(of:)` for pair cells; pick rules (⌘J enabled only for exactly two unpaired frames); the sheet's three cases (differ / one untouched / same) |
| P3 | canvas: two renders, compositor, picking a half, panel target, framing in the slot | slot and gap pixel sizes (the 8222 × 5333 case, mixed sizes, stacked); hit-testing halves and the gap; per-half `film_format_mm`; switching halves never writes the wrong sidecar |
| P4 | export of pairs | output size and metadata; *One image / Two halves / Both*; batch peak memory stays at two developed frames |

**What is most likely to break, and the guard for each:**

- **An edit landing on the wrong half.** The picked half is one value in `Session`, read by the canvas,
  the panel and every write. A test switches halves mid-edit and checks which sidecar changed.
- **The two sidecars drifting apart.** There is one write path for shared groups (both or neither),
  plus the open-time check and banner.
- **Undo restoring half a change.** Each user action is one undo record covering both sidecars and
  the pair file.
- **The filmstrip and Browse grid disagreeing.** Both read the same `framing(of:)`, as `FrameFraming`
  already requires.
- **Stale renders after a swap or a re-frame.** Each half's render is keyed on its frame, so a swap
  re-composes and does not re-develop. A slot re-frame re-develops only that half.

## 7. Not in this proposal

- Pairing more than two frames, contact sheets, or 135 full-frame neighbours (RFC-032 §23 open item 2).
- Pairs in the CLI/MCP (RFC-026). Pairs on mobile.
- The Film Edge strip for pairs (§4), which waits for overscan on desktop.
