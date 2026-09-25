# RFC-025 — Decoupled effect strengths

| | |
|---|---|
| **Status** | **Implemented 2026-09-25 on `main`.** Engine, wire, app and Settings all landed. The two engine promises in §4 are tested through the C ABI. The sliders have not been looked at on a real photograph yet (§7). |
| **Decision** | Each film effect gets a strength that multiplies what the chosen film would do. 1 is always "this film, as modelled", and every default is the engine's, so no existing frame changes. A Settings switch, **Decouple effects**, shows the strengths. It is a view preference, not an edit. |
| **Scope** | Grain, halation, halation's scatter, DIR couplers and glare: a strength for each, plus grain's sub-layer model as its own switch. |
| **Not in scope** | Changing any profile's effect parameters; per-channel strengths; lens blur (trap 22: it does nothing on the reference); a grain *size* control (§3.1). |
| **Related** | AGENTS.md trap 22; RFC-020 (seeds and strips); RFC-024 §11's "sent always" convention. |

## 0. Why

An outside contributor reported having "modified it so all effects could be
decoupled" in a local fork. That change was never published: their public
fork's `main` is our 55ebbe5 and PR #2 is a pure reskin. So this RFC is our
reading of the idea, not a port of their code.

Before this RFC the Film section had three switches, and they were coupled in
two ways:

1. **To the film.** How much halation, grain and coupler cross-talk a negative
   has comes from the stock: its antihalation tag (`apply_halation_preset`),
   its grain model, its DIR matrix (`apply_film_specifics`). The user's only
   control over any of it was off.
2. **To each other.** *Grain* set both `grain_active` and
   `grain_sublayers_active`. *Halation* turned off the back-reflection and the
   in-emulsion scatter together. The DIR couplers had no control at all.

## 1. The wire

Three wire fields are new. Three were already declared and are now sent.

| Wire field | Engine path | Layer | Range | Default | New? |
|---|---|---|---|---|---|
| `halation_amount` | `film_render.halation.halation_amount` | shoot | 0–4 | 1 | declared since RFC-014, first sent now |
| `halation_scatter_amount` | `film_render.halation.scatter_amount` | shoot | 0–1 | 1 | **new**, native-only |
| `grain_amount` | `film_render.grain.amount` | shoot | 0–2 | 1 | **new**, native-only, new param |
| `dir_couplers_active` | `film_render.dir_couplers.active` | shoot | bool | true | declared, first sent now |
| `dir_couplers_amount` | `film_render.dir_couplers.amount` | shoot | wire 0–4, **app 0–1.5** | 1 | declared, first sent now |
| `glare_amount` | `print_render.glare.amount` | print | 0–4 | 1 | **new**, native-only, new param |

The three new fields sit in `parity_schema.py`'s `NATIVE_ONLY` table, in
order, just before `preview_long_edge`, the same place RFC-023 and RFC-024
put theirs.

`grain_sublayers_active` is now sent as `grainActive && effects.grainLayered`.
With the sub-layer model left on, that is the value it always had, including
`false` when grain is off.

## 2. Engine arithmetic

**Grain** (`node_grain`) became a wrapper around the unchanged model, which is
now `grain_realise`:

```text
out = in + k · (grained − in)        in density, per channel
```

At `k == 1` the mix is not run, so the default path is the old node, unchanged.
At `k <= 0` the model is not run either, which makes strength 0 the same as
grain off. The mix is pointwise, so a strip's band mixes exactly as the full
plane would (RFC-020). The seed gate is untouched: it still keys on
`grain.active`.

**Glare** (`node_glare`) uses `percent · amount` wherever it used `percent`: the
field's mean, its spread (`roughness · percent`) and the seed gate in
`print_prefix`. The two stay in step, so strength 0 also draws no seed. × 1.0
is exact in floating point.

**Halation, scatter and couplers** needed no engine change. Their amounts
already existed as parameters, with guards that skip the work at 0.

## 3. Choices, and why

### 3.1 Strength, not size

Grain strength scales the grain's *deviation* and the node's blur together.
That is "less of this film's grain". A smaller particle would be a different
film, and `particle_area_um2` is the stock's. A size control is left out for
that reason.

### 3.2 The couplers stop at 1.5

AGENTS.md trap 22: above ≈ 1.736 on Portra 400, the coupler inverse's
exposure axis stops being monotonic, and the output is no longer the model's.
The wire still allows 4. The app clamps to `EffectStrengths.couplersRange`
(0–1.5), and a test pins that ceiling below 1.736.

### 3.3 The strengths belong to the frame, and the setting only shows them

`FilmParams.effects` is in the sidecar and on the wire whether or not
Settings → Decouple effects is on. Turning the setting off hides the sliders
and changes no picture. The alternative was to send 1.0 while the setting is
off. That would let an app preference silently re-render every frame made
with custom strengths, and make an export depend on a checkbox in another
window.

The cost is hidden state: with the setting off, a frame may carry strengths
the rail does not show. The Film section's menu shows *Reset effect strengths
to the film's own* whenever a frame carries any, so the state can always be
found and cleared.

### 3.4 Sent always

This follows RFC-024 §11. The picture of a legacy frame is unchanged, but its
`printStamp` is not: six new fields miss the disk cache once, as RFC-024's
did.

## 4. Tests

- `ParamsTests.testWireNamesMatchTheServiceSchema` lists the six names.
- `ParamsTests.testEffectStrengthsDefaultToTheFilmAndLegacyFramesDecode`
  checks two things. A sidecar with no `effects` key decodes to the default,
  and the default wire sends 1 / true. `grain_sublayers_active` still equals
  `grain_active` in both states.
- `ParamsTests.testEffectStrengthLayersAndTheCouplerCeiling`: glare is a print
  edit and the rest are shoot edits, and the coupler clamp holds.
- `EngineClientTests.testEffectStrengthsZeroIsOffAndOneIsTheFilm` runs through
  the C ABI at 4 mm on a 512 px frame, so the effects cover whole pixels.
  - Scatter at 0 changes the picture, and scatter back at 1 is byte-identical.
  - Grain on at strength 0 is byte-identical to grain off. Glare works the
    same way.
  - Grain at 0.5 and glare at 2 both change the picture.
  - The not-equal checks are there so the equalities cannot pass by measuring
    nothing.

`parity_schema.py` was updated but **not run**: it needs the Python reference
tree, which is not on this machine.

## 5. UI

In Settings → Rendering, **Decouple effects** is off by default. It is stored
under the `ui2.decoupleEffects` UserDefaults key.

With the setting on, the Film section's three switches become:

```text
Grain            [x]
  Strength       ───●──── 1.00×
Sub-layers       [x]         (greyed while Grain is off)
Halation         [x]
  Strength       ───●──── 1.00×
  Scatter        ───────● 1.00×
DIR Couplers     [x]
  Strength       ───●──── 1.00×
Glare            [x]
  Strength       ───●──── 1.00×
```

Each slider's neutral point (`zero`) is 1: the track marks the film's own value
with a tick while the knob is away from it, and a double-click resets to it.
The sliders use the rail's existing `ScrubSlider`; how they look waits on the
next hand-drawn reference. A slider greys,
rather than hides, while its effect is off. All strings are in both languages.

## 6. Not done

- API-SPEC has no §13 for these fields yet. That file belongs to nobody in
  particular, so it was left for a deliberate edit.
- The ranges above 1 (grain 2×, halation 4×, glare 4×) are the wire's. Nobody
  has yet judged where they stop being useful on a real photograph.

## 7. Verification still owed

Look at it. `--snapshot` with `ui2.decoupleEffects` set, then grain at 0 / 1 /
2 at 1:1 on a real ARW in the running app. The test proves the arithmetic.
It says nothing about whether 2× grain is a look anyone wants.
