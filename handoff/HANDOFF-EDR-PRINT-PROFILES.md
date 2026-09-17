# EDR print-profile handoff

**Worktree:** `/private/tmp/filmify-edr`  
**Branch:** `experiment/edr`  
**Base:** `42db90f`

## Scope

This work carries only the Extended Dynamic Range print modification into the
product. It does not include the reverse-solved neutral reference image, film
positive mode, or any of the experimental inverse pipeline from
`experiment/film-positive`.

EDR is an opt-in SDR editability control for a selected print paper. HDR
display/output, automatic coupling to a future HDR switch, and HEIF work are
outside this launch change.

## Behaviour

- The Print panel contains `Extended Dynamic Range (EDR)` below the catalog
  list and above Process/Original, using the current rail-row layout.
- It defaults off. With it off, the engine bypasses the new node.
- It is a print-layer parameter, so a toggle reuses the cached negative and
  reprints it.
- `No Print Profile` disables the UI control and sends EDR false. The stored
  preference survives, so returning to a paper restores it.
- Old sidecars without the field decode it as false; existing sidecar fields
  retain their previous strict decoding contract.

## Curve design

The calibration used a deterministic Kodak Portra 400 neutral ramp rendered
through each of the eight shipped papers. For each paper it measured the
completed linear print-scan luminance, found toe and shoulder joins from the
local log-luminance slope, preserved the middle, and attached smooth tails.

The launch curve is SDR constrained:

- black floor: `2^-14`
- highlight ceiling: `1.0` linear reference white
- middle: identity between the paper-specific toe and shoulder joins
- colour: scale linear RGB together to retain chromaticity

Each paper stores a 256-sample uniform-log-luminance map in
`data.edr_tone_map`. The Metal node runs after gamut/spatial scanner
corrections and immediately before output transfer-function encoding. That
placement matches what was measured and prevents blur/unsharp from bending
the calibrated joins afterward.

**The calibration apparatus is not in this lane.** The measured joins and
their evidence (`handoff/edr-profile-calibration/`, ~6800 lines of neutral-axis
curves, CSV and results), the baker `engine/tools/bake_edr_profiles.py` and the
native gate `engine/tests/edr_profiles.py` stay on **`experiment/edr`**, commit
`26eab11`, which is where they were produced and where they still run.

What came across is the *result*: the eight calibrated profile JSONs are
tracked under `engine/resources/profiles/`, so the feature is reproducible from
this lane without them. Recover the apparatus with
`git checkout 26eab11 -- handoff/edr-profile-calibration engine/tools/bake_edr_profiles.py engine/tests/edr_profiles.py`
before re-deriving any curve.

## Implementation map

- `engine/src/core/params.*`: `extended_dynamic_range`, print layer, false.
- `engine/src/core/profile.*`: optional validated `edr_tone_map` profile data.
- `engine/src/pipeline/pipeline.*`: uploads the selected paper table and runs
  the EDR node only for an enabled paper print.
- `engine/src/shaders/nodes.metal`: luminance lookup and chromaticity-preserving
  RGB scale.
- `engine/resources/profiles/*.json`: calibrated maps for all eight papers.
- `modern_UI/.../Model/Params.swift`: sidecar/wire state and direct-scan guard.
- `modern_UI/.../PrintProfileSection.swift`: Print-panel toggle.
- `engine/tests/edr_profiles.py`: eight-paper native boundary gate — **on
  `experiment/edr` only**, see above.

## Verified state

Engine, all run against this worktree's `engine/` with `REF` set to the Python
reference checkout (`~/Documents/Summer 2026/spektrafilm`):

| gate | result |
|---|---|
| `engine/build.sh all` | passed (artifacts 2026-09-17 13:36) |
| `engine/build/gpu_smoke engine/resources/spektrafilm.metallib` | 0 failures |
| `engine/tests/check_math_guard.sh` | fast-math library rejected, shipped one reports `math mode is safe` |
| `parity_setup.py` | 227 quantities, 86 bit-exact, 0 failed |
| `parity_schema.py` | 0 failed; 42 engine fields, Python identical plus 1 pinned native extension |
| `parity_render.py --size 180` | 27 cases, 0 failed |
| `parity_session.py` | 42 fields, 0 failed |
| `parity_grain.py` | 9 levels, 0 failed |
| `parity_lut.py` | 8 stocks bit-exact out of the blob, 3 stocks image parity, 0 failed |
| `engine/tests/edr_profiles.py` | 8 papers finite/monotone/deterministic, middles identity, SDR peaks 0.926–0.990, No Print identity — **run on `experiment/edr`; the gate is not in this lane** |

App:

- macOS Debug build passed.
- Full `SpektrafilmTests` target: **353 tests, 0 failures, 414 s**, with
  `tests/` checked out so the fixture-dependent suites ran — no skips reported.

The engine artifacts predate the sources by one whitespace-only line in
`pipeline.hpp`; nothing else changed after the build.

### Environment notes

Two things about this machine, both environmental rather than caused by the
change:

- Xcode 27's Metal toolchain component stopped resolving partway through the
  session: `metal` reports "missing Metal Toolchain" even for the downloaded
  and mounted asset, so nothing that invokes the compiler through
  `xcrun`/`xcodebuild` can rebuild shaders. The toolchain is mounted at
  `/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain`
  and compiling with that compiler directly works. `check_math_guard.sh` was
  therefore replicated by hand with those binaries; every other gate above
  needs no compiler.
- The full test target was run with `test-without-building`, because building
  would recompile `Canvas/Shaders.metal`. The test bundle it ran
  (`.../SpektrafilmTests.xctest`, 13:39:51) is newer than every EDR source edit.

Both want a real fix before the next engine-side change: run
`xcodebuild -downloadComponent MetalToolchain` from an admin session that can
write `/Applications/Xcode.app/Contents/Developer/Toolchains` (it needs root to
link the mounted cryptex in), then re-run `engine/build.sh all`.

### Reproducing

```bash
cd /private/tmp/filmify-edr
export REF="$HOME/Documents/Summer 2026/spektrafilm"
export PYTHONPATH="$REF/src:engine/tests"
"$REF/.venv/bin/python" engine/tests/parity_setup.py
"$REF/.venv/bin/python" engine/tests/parity_schema.py
"$REF/.venv/bin/python" engine/tests/parity_render.py --size 180
"$REF/.venv/bin/python" engine/tests/parity_session.py
"$REF/.venv/bin/python" engine/tests/parity_grain.py
"$REF/.venv/bin/python" engine/tests/parity_lut.py      # needs ./src -> the reference's src
```

`parity_lut.py` reads data outside this worktree and needs a GPU; it is the one
that fails under a plain sandbox. `edr_profiles.py` did too, and is on
`experiment/edr` rather than here.
