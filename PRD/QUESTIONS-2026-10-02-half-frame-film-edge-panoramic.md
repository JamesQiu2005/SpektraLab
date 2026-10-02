# Answer sheet: half frame, Film Edge, panoramic (2026-10-02)

**Every open question that blocks building, in one place.**
- **Owner:** fill in each **Answer:** line. "rec" is fine; it means take the recommendation.
- **Next session:** read this file before writing any code
  (`PRD/HANDOFF-2026-10-02-half-frame-pair-and-panoramic.md`). A question with a blank answer is still
  open. Ask about it; never guess it.

**Sources.**

| abbreviation | file |
|---|---|
| HFP | `modern_UI/design-proposals/half-frame-pair-2026-10-02/README.md` |
| R32 | `SpektraLab_mobile/rfc/RFC-032_Film_Overscan.md` |
| OV | `SpektraLab_mobile/design/overscan/README.md` |
| FL | `SpektraLab_mobile/design/flow/README.md` |
| R31 / R33 | `rfc/RFC-031-date-imprint.md` and `rfc/RFC-033-shooting-data-imprint.md` |
| DAS | `API-SPEC-callable-render-service.md` |
| MAS | `SpektraLab_mobile/API-SPEC.md` |

**The parts:**
- **A** must be answered before any code.
- **B** covers the half-frame pair.
- **C** covers panoramic.
- **D** covers Film Edge in general.
- **E** covers the date back and shooting data.
- **F** is mobile only; answer if you like.

---

## A. Scope and order (blocks everything)

**A1. What did "panavision" mean?** Nothing in either repo uses the word.
- (a) **The panoramic long formats:** XPan 24 × 65 on 135, 6×12, 6×17. These were proposed 2026-10-01
  (OV §10), and the desktop Format menu has a group named *Panoramic*.
- (b) **Panavision cine:** anamorphic 2.39:1 on 35 mm motion film, and Super 35. This is new. R32 defers a
  cine-35 family (R32:81, 597, 788), and only research notes mention it
  (`research/overscan/35mm_motion/notes.md`).
- (c) Both.

rec: (a), unless you meant cine. If (b) or (c), also answer C9–C12.
**Answer:**

**A2. Build order.**
- (a) **The half-frame pair without Film Edge first** (HFP phases P1–P4). It is Swift only, with no engine
  change, so it collides with nothing. Then the desktop overscan sync, then Film Edge pairs (P5) and
  panoramic.
- (b) **The desktop overscan sync first** (single-frame Film Edge and Date Back), then the pair with and
  without Film Edge.
- (c) Panoramic first.

rec: (a). The mobile engine is mid-merge on the other machine, and the sync can't start until it lands.
**Answer:**

**A3. Where does the new engine work get written?** That means the pair layout (E1), gate coverage out (E2),
the long-format fix and the carrier enum.
- (a) **In SpektraLab_mobile,** where overscan lives today, then synced to desktop with the rest
  (UPSTREAM.md).
- (b) In filmify first, then synced to mobile. RFC-032 §13's amendment says engine code is "written in
  filmify and synced", but overscan was in fact written in mobile.

rec: (a) for now, so all overscan code stays in one place until the sync. The rule needs restating either
way.
**Answer:**

**A4. The mobile session's merge.** On 2026-10-02, `SpektraLab_mobile` showed `UU
engine/src/pipeline/pipeline.cpp` and staged DI files. Should desktop engine work wait until that machine
pushes the merge, or will you tell the next session when it is safe?

rec: wait, and don't touch that tree.
**Answer:**

**A5. Desktop overscan sync scope.**
- (a) Everything UPSTREAM.md lists: overscan, date back, and the `data` face.
- (b) Overscan only, with the date and data later.

The sync rules hold either way: merge hunks, never copy files (copying reverts RFC-034); rerun
`overscan_checks.py`, all 34; check the off path's hash; prove each control is visible; show new tests
red first.

rec: (a).
**Answer:**

**A6. Review rhythm, since you are wary of bugs.**
- (a) You look at the running app after each phase (P1…P5) before the next starts.
- (b) Only at the end.

Each phase ends with tests, the app launched and looked at, `/code-review`, then commit and push, either
way.

rec: (a).
**Answer:**

**A7. Design tooling in the repo.** The drawing generators and render scripts are design-only Python, kept
beside the proposal in `tools/`. CLAUDE.md says "no Python" for building and running the product, and
`engine/tests` already uses it.
- (a) Keep them there.
- (b) Move them to SpektraLab_mobile/design/src, next to the Film Edge generator.
- (c) Delete them.

rec: (a), clearly marked design-only.
**Answer:**

---

## B. The half-frame pair (HFP §7; read HFP before answering)

**B1 (D1). Default exposure scope.**
- (a) **Frame** in every section.
- (b) **+ Overscan** for the Enlarger.

rec: (a).
**Answer:**

**B2 (D2). Which edits carry a scope?**
- (a) Film Exposure, plus the Enlarger's Brightness, Yellow, Magenta and Pre-flash.
- (b) Those, plus the Tone Mask.

rec: (a).
**Answer:**

**B3 (D3). What does "+ Overscan" do?**
- (a) Adds the same delta to the Overscan print.
- (b) Sets the Overscan equal to the hole's value.

rec: (a).
**Answer:**

**B4 (D4). Should single-frame Film Edge get the same scope control (frame vs rebate)?** It needs the engine.
- (a) Yes, with the sync.
- (b) Pairs only.

rec: (a).
**Answer:**

**B5 (D5). The shot (metering, Film Exposure, white balance, Scene Placement) lives in the frame's own
file,** so Film Exposure edited in a pair changes that frame everywhere.
- (a) Keep that.
- (b) Copy the shot into the hole when the frame is added.

rec: (a).
**Answer:**

**B6 (D6). Paper per hole.**
- (a) Free: each hole may use another paper.
- (b) Locked with the stock.

rec: (a).
**Answer:**

**B7 (D7). Can a frame be in several pairs?**
- (a) Yes.
- (b) One pair per frame.

rec: (a).
**Answer:**

**B8 (D8). Where does a pair sit in the filmstrip?**
- (a) After its left frame, with an empty pair at the end.
- (b) All pairs at the end.

rec: (a).
**Answer:**

**B9 (D9). Export with an empty hole.**
- (a) Not allowed: fill both holes first.
- (b) Export the empty hole as unexposed film.

rec: (a).
**Answer:**

**B10 (D10). Spacing between frames without Film Edge.**
- (a) 0.5–2.0 mm, default 1.0.
- (b) Fixed 1.0 mm.

With Film Edge, the camera decides it.

rec: (a).
**Answer:**

**B11 (D11). Names, English and zh-Hans.** The English names are *Half-Frame Pair*, *New Half-Frame Pair*
(⌘J), *Add Frame*, *Film / Left hole / Right hole* and *Applies to: Frame / + Overscan*. The Chinese
candidates are 半格双拼, 半格对, 双联 and 半格拼对, and *+ Overscan* also needs a Chinese name.
**Answer:**

**B12 (D12). Plus gating on desktop.**
- (a) None.
- (b) Follow mobile's Plus.

rec: (a).
**Answer:**

**B13 (D13). Grain and halation strengths with Film Edge on.**
- (a) Shared: it is one piece of film.
- (b) Per hole, from two film renders cut together. Halation would seam at the gap.

rec: (a).
**Answer:**

**B14 (D14). Scene Placement with Film Edge on.**
- (a) Shared until E3 (per-gate Scene Placement) exists.
- (b) Build E3 before shipping Film Edge pairs.

rec: (a).
**Answer:**

**B15 (D15). Which numbers does a pair take?**
- (a) The engine's grid decides (6 · 6A), and *Another* moves along the roll.
- (b) Also offer the pair that straddles a number (6A · 7).

rec: (a).
**Answer:**

**B16 (D16). Edge print text on desktop.**
- (a) The display name, `KODA GOLD 200`, as the Film Edge drawings use.
- (b) The real name, `KODAK GOLD 200`. RFC-032 §26 allows real marks on desktop.

rec: (a), unless you want real marks on desktop.
**Answer:**

**B17. Turned (stacked) pairs.**
- (a) In the first version, both with and without Film Edge. The scratch engine patch covers held level
  only.
- (b) Held level first, turned later.

rec: (b).
**Answer:**

**B18. Single half frames.** Should `135_half` also appear in the desktop Film Edge Format menu for a single
frame, not only in pairs?

rec: yes; it is already in the engine's format list.
**Answer:**

**B19. The `data` face on half frame** gets only the 1 mm gap, so its size must stay ≤ 1 (R32:1331,
MAS:333).
- (a) Allow it with the size capped.
- (b) Disable `data` on half frame.

rec: (a).
**Answer:**

**B20. The date back on a pair.** Each half frame was its own exposure, so does each carry its own date (two
dates on the strip)?

rec: yes, each from its own frame's EXIF and placed in its own gate. This is part of E1.
**Answer:**

---

## C. Panoramic long formats (OV §10; drawn in `overscan_long_check_v1.svg`)

**C1. Confirm the reversal of "nothing larger than 6×9."** The change would add `135_xpan` (24 × 65),
`120_6x12` (56 × 112) and `120_6x17` (56 × 168). The 6×9 limit is stated at R32 §29.1 (R32:982), MAS:227
and DAS:696; API-SPEC belongs to nobody in particular, so the edit is announced before it is made. A memory
note also asks: did "nothing larger than 6×9" ever mean "no date on 120"?
**Answer:**

**C2. The canvas-trim fix, for every format, not only long ones.**
- **The bug:** today the edge print can clip at one end, and a sliver of the holes' light can show past the
  film's edge. 6×17 clips on every frame.
- **The fix:** scan 0.40 mm past each long edge, and cap the tilt by how far it moves the film's ends.
- **The cost:** it changes all existing overscan renders, which were never under the byte-identical rule,
  and the reference renders need regenerating.

Accept?

rec: yes.
**Answer:**

**C3. What shows past the film's edge (the carrier).**
- (a) Black: `black` default, with an `open` enum value.
- (b) Open light by default.

rec: (a). This is RFC-032 §23's open decision 4.
**Answer:**

**C4. The tilt cap: 0.27 mm of end travel.** That keeps every existing format's 0.35°, and caps 6×12 at
0.27° and 6×17 at 0.18°.

rec: yes.
**Answer:**

**C5. Gate shapes.** Until XPan, Fuji GX617 and Linhof 617 scans are measured, the three gates are
`square`.
- (a) Ship with `square`.
- (b) Wait for references. If so, please supply scans, or approve a research session.

rec: (a).
**Answer:**

**C6. Spool leaks on long film.** The leak count is fixed, so leaks spread thin along 171 mm. Scale the
count with length?

rec: yes.
**Answer:**

**C7. Date back on panoramic.**
- (a) Off on all three until a source shows a date back on one of these cameras.
- (b) Allow it.

rec: (a).
**Answer:**

**C8. Is the XPan advance sprocket-locked?** That decides whether 135's small advance error applies. This
is a fact to check: do you know, or should a session research it?
**Answer:**

**C9. Desktop UI.**
- the Format menu gets a third group, *Panoramic*;
- Film Format reads *Set by Film Edge: XPan 65 × 24*;
- canvas fitting already handles 3:1.

Group name *Panoramic*, or another?
**Answer:**

**C10. Gating.** Mobile's Plus proposal makes every format past 135 Plus. Desktop?
- (a) Not gated, as for B12.
- (b) Gated.

rec: (a).
**Answer:**

**C11. Grain on a 48 MP 6×17 export (about 21 µm a pixel).** Measure it before shipping.

rec: yes, as a gate on shipping.
**Answer:**

**C12. Only if A1 is (b) or (c): Panavision cine.**
- **Formats:** anamorphic 4-perf 2.39:1 with a 2× squeeze; Super 35 3-perf; Techniscope 2-perf. Which?
- **The squeeze:** desqueeze on output, or show the squeezed negative?
- **The perforations:** cine 35 has BH/KS motion perforations and KeyKode, not DX. The research has
  notes; is a research session wanted first?
- **Stocks:** limit to the Vision3 cine stocks?

**Answer:**

---

## D. Film Edge in general (affects desktop)

**D1. A "lab scan" presentation.** This is a per-channel inversion that also shifts the picture's colour
(R32:968). Should the engine gain one, or stay print-only with white holes?

rec: not now.
**Answer:**

**D2. One nominal 135 width: 35.00 or 34.95 mm** (R32:763).

rec: 35.00.
**Answer:**

**D3. A per-stock catalogue of formats,** so the UI can grey out formats a stock was never made in
(R32:742, OV:148).
- (a) Build it before the desktop Format menu ships.
- (b) Later.

rec: (a). It is small, and greying a wrong format beats offering it.
**Answer:**

**D4. Before shipping: render every still negative's rebate on every path,** because some `base_density`
curves have NaN ranges and the rebate is pure base (R32:714). This is a must-do, not a question; confirm.
**Answer:**

**D5. Unverified references.** These ship as approximations unless you object:
- Helvetica stands in for Kodak's edge typeface;
- the 6×8 ears come from one back only;
- the 6×9 gate has no reference.

**Answer:**

**D6. `spk_overscan_geometry`** (the gate rectangles out of the engine). The desktop GUIDE mask, the crop
overlay, the histogram, tap-to-meter and the pair's E2 all need it. Build it in the sync?

rec: yes.
**Answer:**

**D7. `overscan_holes` as a print-layer field,** so White/Black changes with a reprint instead of a
re-develop (OV:230).

rec: yes.
**Answer:**

**D8. `overscan_turn` (auto | 0 | 90 | 180 | 270).** It is proposed in OV:199–226 but is in neither
API-SPEC nor the engine. Add it in the sync?

rec: yes.
**Answer:**

---

## E. Date back (RFC-031) and shooting data (RFC-033)

**E1. Date orders.** Which orders are offered, and is `dhm` (day, hour, minute) one of them (R31:142)?
Note that the engine takes the text already formatted by the host (MAS:244), not the R31 §5 formatter.
**Answer:**

**E2. A brightness control for the date** (R31:144). Desktop draws a Brightness row, and the wire has
`date_imprint_ev`. Keep it?

rec: yes.
**Answer:**

**E3. Date on 6×6 to 6×9.** Shown disabled, with the note *No 6×7 back printed a date* (OV:242).

rec: yes.
**Answer:**

**E4. Unverified date constants.** These are 2700 K, +3.5 EV, a 1.3 mm character, a (3, 2.4) mm inset, a
15 µm blur and an 8° slant. There is no tungsten reference. Ship them as they are?
**Answer:**

**E5. `spk_date_imprint_svg`** (R31:115) was never built; CoreText rasterising replaced it.
- (a) Drop it.
- (b) Build it so the UI can preview the glyphs.

rec: (a).
**Answer:**

**E6. Where shooting data goes: the gap, the rebate, or both?** The engine already draws it between 135
frames and in the 645 margin (R33:114).

rec: the gap on 135, the margin on 645.
**Answer:**

**E7. Shooting data fields.**
- **ISO:** offered? The engine's test text includes `ISO 200`, but R33:54 says "not by default".
- **A copyright or name line:** offered (R33:115)?

**Answer:**

**E8. Aperture in the shooting data.**
- (a) The real f-number.
- (b) A 135-equivalent.

rec: (a).
**Answer:**

**E9. The imprint records the camera's exposure, not the Film Exposure slider.** Confirm (R33:117).
**Answer:**

**E10. "No metadata makes pixels."** That is the `ImageDecoder.sourceEXIF` rule, and shooting data would
replace it. Accept that desktop code change (R33:38)?
**Answer:**

**E11. `data` on 645.** That goes beyond R31/R33's "135 only". Keep it?

rec: yes.
**Answer:**

**E12. The data face's colour.** Red-orange, as rendered, or the amber of the 645N reference?
**Answer:**

---

## F. Mobile only (answer if you like; these do not block desktop)

**F1. Default view on mobile.** Filed or Strip, once memory is measured (R32:753, OV:240)?
**Answer:**

**F2. Film budget.** 12 MP is a placeholder; measure on an iPhone 15 Pro (OV:239).
**Answer:**

**F3. Body default.** One phone = one body, or one per user (OV:241)?
**Answer:**

**F4. DX bars on mobile.** The bars carry the real DX number while the text shows the display name.
Acceptable (R32:1034)?
**Answer:**

**F5. Not drawn yet:** the Holes, Light and Body panels, Filed, disabled and error states, the export
sheet, zh-Hans. Draw them next?
**Answer:**

**F6. 48 MP on a phone.** The striped executor refuses overscan, so 48 MP is out of reach. Make it a
priority?
**Answer:**

**F7. When the Plus prompt appears.** OV:248 says before anything develops; the business analysis says at
export. Which?
**Answer:**

**F8. Tiers.** Free/Plus/Pro (decided 2026-10-02) against FL's single Plus. Should FL be updated, and the
Shoot page's `Pro` button renamed?
**Answer:**

**F9. Edge light in Plus,** and a free "SPEKTRALAB" edge text, replaceable in Plus (business analysis).
Adopt?
**Answer:**

**F10. Copy Settings.** Add a seventh group, *Film Edge & Date Back*? Copied by default?
**Answer:**
