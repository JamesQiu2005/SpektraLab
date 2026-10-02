# Handoff: half-frame pair, Film Edge on desktop, panoramic (2026-10-02)

**Start here.** The design work is done and committed. **Nothing is implemented.** The next step is
building, and building waits on the owner's answers.

**Why this lives in `PRD/` and not `handoff/`:** `handoff/` is gitignored (local-only, because the repo is
public), and the owner develops on two machines. A handoff that is not pushed never reaches the other
machine.

## 1. Read first, in this order

1. **`PRD/QUESTIONS-2026-10-02-half-frame-film-edge-panoramic.md`, the answer sheet.**
   - The owner answers it all at once.
   - **Part A** (scope and order) decides what you build first.
   - **A question with a blank Answer: line is open.** Ask the owner; never guess.
   - If the owner answered in chat instead, copy the answers into the sheet, commit and push, then go on.
2. **`modern_UI/design-proposals/half-frame-pair-2026-10-02/README.md`, the design.**
   - Its §7 decisions are the sheet's part B; §8 is the build plan, phases P1–P5, with the tests that gate
     each.
   - Look at `preview_desktop_v2.png`, `preview_edge_v2.png` and `sample_135_half_pair_6_6A.jpg`.
3. **`AGENTS.md`** (its traps section) and **`README.md`**, as always.
4. **Claude memory**, if your machine has it:
   - `half-frame-pair-proposal`;
   - `next-overscan-frontend-and-contract`;
   - `rfc032-overscan-engine-landed`;
   - `rfc034-area-multipliers-landed`;
   - `ui-drawings-real-tokens-real-images`;
   - `push-after-commit`.

## 2. Where things stand

| | state |
|---|---|
| Half-frame pair design | v2 plus the Film Edge path: `843c6c1` (v1, superseded), `8d7eb7c` (v2), `12a32e0` (Film Edge path) |
| Film Edge desktop design | `modern_UI/design-proposals/film-edge-2026-10-01/`, accepted as the layout |
| Overscan / date back engine | in `SpektraLab_mobile` (`051158c`, `371ad16`); **not synced to desktop**. Desktop still refuses the 20 wire names (API-SPEC §13) |
| Pair engine support (E1 layout, E2 gate coverage) | only as `pair_scratch.patch`, a scratch build, **applied nowhere** |
| Panoramic (XPan, 6×12, 6×17) | proposed in `SpektraLab_mobile/design/overscan/README.md` §10, with a prototyped fix (`research/overscan/engine_proto/long_formats_scratch.patch`). It reverses "nothing larger than 6×9" (answer sheet C1) |
| "Panavision" | the owner's word; the sheet's A1 asks whether they meant panoramic or anamorphic cine |

## 3. The owner's settled decisions (2026-10-02; do not reopen)

- **The pair is two neighbouring frames from one piece of film, placed together.** The film edge is
  available (Film Edge on), with the engine rendering half-frame numbers such as 6 / 6A.
- **The film is the canvas; frames are layers.** The empty piece comes first, and **Add Frame** fills each
  hole. A picture moves under its fixed hole. The canvas never resizes for a photo.
- **Only the film stock is shared;** everything else is adjustable per hole. Film-side effects lock to
  the pair with Film Edge on (answer B13).
- **Exposure edits carry a scope, Frame or + Overscan.** The owner raised this and called it an important
  decision.
- **The pair owns its settings;** the shot stays in the frame's sidecar (answer B5 confirms the
  consequence).
- **Drawings are at product fidelity:** the real tokens and real photos or engine renders, never
  wireframes.

## 4. How to work (and where it went wrong before)

- **Commit, then push at once.** On a machine where SSH to GitHub fails ("Host key verification failed"),
  push over HTTPS with gh:
  `git -c credential.helper= -c credential.helper='!gh auth git-credential' push https://github.com/JamesQiu2005/SpektraLab.git main:main`.
- **Never touch `SpektraLab_mobile`'s working tree** while another machine works in it. On 2026-10-02 it
  was mid-merge (`UU engine/src/pipeline/pipeline.cpp`). Read with `git show <commit>:path`; build from
  `git archive <commit> engine` in a scratch directory.
- **Engine builds need the Metal toolchain.** On the `/Volumes/Hanze_Qiu` Mac it was installed
  2026-10-02. They also need the sandbox disabled to reach the toolchain's mount. Memory
  `metal-toolchain-is-a-moving-mount` covers a different failure: a stale path on a machine that has it.
- **The desktop overscan sync** (when the answers allow it):
  - merge hunks, never copy files, because copying reverts RFC-034's √a radii and `glare_amount` 0–30;
  - rerun `engine/tests/overscan_checks.py` (34 checks) and the off-path hash check;
  - prove every control visible (fog, leaks, flare, ev, edge text, f-number);
  - show each new test red before it goes green (memory `guards-that-cannot-fire`).
- **Build in phases,** each ending with `xcodebuild test` green, the app launched and looked at,
  `/code-review`, then commit and push. If answer A6 says so, wait for the owner's look before the next
  phase. The owner is wary of bugs; HFP §8 lists the likely failures and their guards.
- **Redrawing after the answers:** the generators and render scripts are in
  `modern_UI/design-proposals/half-frame-pair-2026-10-02/tools/` (design only; see its README for the
  directory layout and run order).

## 5. What to do first once answered (if A2 = (a))

1. **P1:** the `Pair` model and store, the layers, the Overscan values, scope deltas and undo, with no UI.
   Tests as in HFP §8.
2. **P2–P4:** the filmstrip cell, ⌘J and Add Frame, the canvas compositor, picking a layer, placement
   under the hole, export.
3. **Then the desktop overscan sync** (A5 scope). Then E1/E2 in the engine (where A3 says), P5 (Film Edge
   pairs), and panoramic per part C.

## 6. State after 2026-10-03

The owner answered the sheet (build order (b): the sync first). Done and pushed:

| commit | what |
|---|---|
| `7ce3334` | the engine sync from `SpektraLab_mobile` `371ad16`, by hunks; `overscan_checks.py` 34/34, the parity harnesses, 18 off-path renders byte-identical, all 20 stocks' rebates without NaN |
| `7be561b` | the latitude probe switches overscan and the date off. **Written on desktop; it must cross to mobile at the next sync** |
| `68d249a` | the app: Film Edge and Date Back in the left rail, en and zh-Hans; 503 tests green |

**Waiting on engine work, which is written in the mobile repo first (answer A3):**
- `spk_overscan_geometry`. Until it exists, compare, the original and the white-balance picker are off on
  a film canvas, and the histogram counts the rebate.
- `overscan_turn`, holes as a print-layer field, the carrier enum, the data face's two colours (E12).
- The panoramic formats (the menu draws them disabled) and the canvas-trim fix (C2).
- Perforations in a Digital Intermediate: `spk_overscan_light` has no DI counterpart.
- The Frame / + Overscan scope for a single frame (B4), then the pair's E1 and E2.

**Still open with the owner:** B17 (turned pairs); E3's "No"; the clipboard group for Film Edge and Date
Back; whether cine stocks belong in the 135 formats (they are allowed now).

**Next:** the half-frame pair without Film Edge (HFP P1–P4, Swift only), which needs none of the above.
