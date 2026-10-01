# RFC-034: Effect strengths are area multipliers

| | |
|---|---|
| **Status** | **Implemented 2026-10-01** on `main` (engine, app, tests, parity). §3's glare range is the owner's to confirm. |
| **Amends** | RFC-025, whose decoupled strengths this redefines for the two that are a *glow*: halation and glare. Grain, scatter and the couplers are untouched. |
| **Decision** | The strength is an **area multiplier**. 1 is the film's (or paper's) own, 0 is off, and `a` covers `a` times the area — the light scales with the number and so does the area it lands on, so every sigma takes its **square root**. 2 is twice the area; doubling the radius instead would be four times it. |
| **Scope** | `halation_amount` (engine arithmetic + wire meaning), `glare_amount` (arithmetic + range 4 → 30), the app's two sliders, the parity harness's divergence list. |
| **Related** | RFC-025 (the strengths), RFC-008/RFC-001 (glare is the stochastic stage), AGENTS.md trap 22 (why the couplers stop at 1.5). |

## 1. Why — the owner's report, and what it turned out to be

With *Decouple effects* on, dragging Glare Strength and Halation Strength moved
nothing the owner could see, while Grain Strength worked. Measured through the
shipping dylib on a 3000 px frame at the live tier (2560), Portra 400 + Supra
Endura, auto-exposure and grain off for the A/B:

| change | mean Δ (of 255) | max | pixels touched |
|---|---|---|---|
| `grain_amount` 0→1 | **2.41** | 32 | 92 % |
| `halation_amount` 1→2 | 0.020 | 8 | 4.7 % |
| `glare_amount` 1→2 | 0.13 | 1.5 | — |
| `halation_scatter_amount` 0→1 | **2.25** | 199 | 87 % |

Glare's 1→2 change is *smaller than glare's own render-to-render noise* (per-pixel
std 0.09–0.18 counts, max 1.9–3.6 across six renders at one setting), so it was
not merely hard to see — it was unfalsifiable by eye.

The wiring was correct everywhere: the sliders write `FilmParams.effects`, the
wire sends the six fields, the scheduler diffs them, `spk_set_params` applies
them (the engine echoes each value back), and the layer split works. What was
wrong was the magnitudes, which RFC-025 §6 had already flagged as unjudged
("the ranges above 1 are the wire's") and §7 as unverified ("look at it").

## 2. The rule

The owner's decision of 2026-10-01: *"0 means no such effect, and 2 means
doubling the effect in terms of area, not radius"*, with 1 as the scale at the
selected film format.

That is one statement, not two. The light an effect throws and the area it
lands on are the same quantity — a halo's own intensity is the film's, and what
the number buys is how far it reaches — so the light and the area scale
together, and every sigma takes `sqrt(a)`. Scaling the radius by `a` would be
the mistake the owner named: 2 would mean four times the effect.

## 3. Glare — the half the rule cannot buy

The paper's own glare is a whisper, and that is the reference's own model, not
a port error: `GlareParams::percent` is 0.03 and both engines divide the field
by 100 where it is added, so 1 is a 3-part-in-10 000 veil of the illuminant.
The reference's own calibration sweep (`spektrafilm/utils/calibration_targets.py`,
`glare_ramp`, titled "Amount of Glare Light (%)") never asks for more than
0.4 percent — 13 times the default. Measured at the live tier:

| multiplier | veil | mean Δ (of 255) | pixels moved > 1 count |
|---|---|---|---|
| ×1 (the paper's own) | 0.03 % | — | — |
| ×4 (RFC-025's old ceiling) | 0.12 % | 0.65 | 5 % |
| ×13 (the reference's strongest sweep value) | 0.4 % | 1.9 | 60 % |
| ×30 (the new ceiling) | 0.9 % | 4.0 | 86 % |

So a ceiling of 4 could not be seen at all, and `glare_amount`'s range is now
**0…30**: the veil at the top lifts the frame by ~4 counts of 255 and moves a
third of its pixels by more than 4 — a haze, not a whisper. The slider is
honest about what it multiplies, which puts the film's own value (1) near the
left end of the track; the alternative — a nonlinear track with the same
range — was left alone because it would make the displayed number stop being
the multiplier.

**Still the owner's call, in one line each:** (a) keep 0…30; (b) compress the
range onto a perceptual curve above 1, so that 2 is already visible, at the
price of the number no longer being the multiplier; (c) raise the *model's*
glare default (e.g. `percent` 0.03 → 0.3), which makes 1 faintly visible and
the rule literal everywhere, at the price of changing every frame's picture and
diverging from the reference at 1.0 as well.

## 4. The engine

**Halation** (`pipeline.cpp`, `halation_blurs`). `a_tot` still multiplies
`halation_strength` (RFC-025, unchanged); `sigma_h` — and the bounces built on
it — is multiplied by `sqrt(halation_amount)`. Measured on the shadow side of a
blown disc, 4 mm of film on a 384 px frame, against the halo switched off:

| amount | peak | pixels moved > 3 counts | halo radius |
|---|---|---|---|
| 1 | 3 counts | 188 | ~6 px |
| 2 | 5 | 540 (2.9×) | ~9 px |
| 4 | 6 | 1212 (6.4×) | ~12 px |

**Glare** (`node_glare`). `percent` and its spread still scale with the amount;
`blur` — pixels at the full tier — takes its square root.

Both are exact at 1.0 (× 1.0 is the identity, as in RFC-025) and both are
structural bypasses at 0.

**Wire.** `halation_amount` keeps its name, type and 0…4 range; its *meaning*
changes, which is a deliberate divergence from the reference (see §6).
`glare_amount`'s range becomes 0…30, in `params.cpp` and in
`parity_schema.py`'s NATIVE_ONLY table together.

**Not touched.** `halation_spatial_scale` and `scatter_spatial_scale` remain
unwired internals with the reference's linear meaning; `scatter_amount`
(0…1 mix weight) and `grain_amount` (density mix) are not spatial and keep
RFC-025's arithmetic.

## 5. What holds it

- `EngineClientTests.testHalationStrengthIsAnAreaMultiplier` — the footprint
  grows by more than 1.5× per step over 1 → 2 → 4 and by less than 10× over the
  whole span: a radius multiplier would land at 16×, which is the property that
  distinguishes the two readings. 1 is still byte-identical.
- `EngineClientTests.testEffectStrengthsZeroIsOffAndOneIsTheFilm` — unchanged,
  plus glare's top of range must lift the frame by more than 3 counts of 255
  and by more than four times what ×4 manages. `NotEqual` alone, which is what
  RFC-025 shipped, passes on a single count.
- `ParamsTests.testTheGlowEffectSlidersAreAreaMultipliersWithReachableRanges` —
  pins 4 and 30, with the reasons.
- `parity_render.py` — 27 cases, 0 failed; `halation_amount` off 1.0 is the
  third `expect_divergence` case, and the harness fails if the two engines ever
  agree there. `parity_schema.py` — 0 failures with the new range.

## 6. The divergence, and why it is the honest one

The reference's `halation_amount` scales the light only. This engine's scales
the light *and* the area. A frame rendered at 1.0 is identical in both (which
is why every other parity case still agrees); off 1.0 they must not agree, and
the harness now asserts that they do not. The alternative — a new native-only
field carrying only the spatial half — would have left the app sending two
fields per slider and the CLI and MCP with a meaning no user-facing control
had.

## 7. Not done

- The desktop app's own drawing for a 0…30 slider (RFC-025 §5's table assumes
  0…4 for every strength). The knob's neutral sits near the left end.
- Mobile: `SpektraLab_mobile`'s engine copy has neither this nor RFC-032's
  overscan sync.
- API-SPEC has no row for these fields yet (RFC-025 §6 said the same).
