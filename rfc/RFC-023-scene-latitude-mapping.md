# RFC-023 — Scene Latitude Mapping: fitting a modern scene into an unchanged film/print model

| | |
|---|---|
| **Status** | **Engine implemented 2026-09-24 (§17), off by default, no UI yet.** Research / design proposed 2026-09-21. §15 runs the design on a real RAW through the shipping dylib; three claims in §5, §11 and §12 did not survive it and are corrected in place. |
| **Date** | 2026-09-21. **Revised the same day**, at the user's direction, on three points: the branch must have *curvature* at the progressive ends rather than a corner (§5.4–§5.5, §7.3); the construction should follow camera log curves' implementation logic (§5.7, §2.12); and the signal must never be log-encoded, with the controls expressed as highlight/shadow pull-back after the subject's exposure is set (§5.6, §9.2). All three changed the model. |
| **Author** | Research session, at the user's request, from the report that *"jpg 进去效果比 raw 好，因为曝光的原因"* |
| **Supersedes in spirit** | RFC-022's premise — not RFC-022's findings. §13.4 says exactly what is and is not retracted. |
| **Scope** | One optional, pointwise, scene-referred transform placed before spectral upsampling; a measured latitude descriptor; a Fit policy; the wire and UI contract. |
| **Out of scope** | Any change to film, negative, coupler, enlarger, paper, scan or EDR mathematics. Local (neighbourhood) tone mapping — §14.3 says why it is the *next* question and not this one. |
| **Companion data** | Curve tables in §6–§7 reproduced by `rfc/probes/` methodology; profile statistics in §8.2 computed from `engine/resources/profiles/*.json` as shipped. |

---

## 0. The observation this starts from, and why it is evidence rather than an anecdote

The user's report is that a **JPEG** put through SpektraLab often looks better
than the **RAW** of the same frame, and that the reason is exposure.

That is not a defect report about the JPEG path. It is a measurement of the
thesis:

- A camera JPEG has already had a display-referred tone curve applied in-camera
  — a toe, a shoulder, and typically 5–8 stops of usable range in the encoded
  signal. Core Image decodes it back to something nominally "scene-linear", but
  the *shape* of the camera's curve survives the round trip. What arrives at
  `node_upsample` is a scene that has already been compressed to roughly the
  latitude of a print.
- A RAW arrives at `node_upsample` carrying 12–15 stops with no shoulder at all.

So the JPEG is already getting Scene Latitude Mapping — an uncontrolled,
unmeasured, camera-vendor-specific version of it, chosen by Canon or Nikon or
Sony for a display, not for a piece of Endura. The product currently has two
input paths with wildly different scene-referred behaviour and no way for the
photographer to see or control the difference.

**The conclusion is not "make the RAW look like the JPEG". It is: the thing the
JPEG path does by accident should be done on purpose, in one place, with named
parameters, and identically for every input.**

---

## 1. Executive conclusion

**Recommended for V1: a two-sided, asymmetric, piecewise curve on the log₂
exposure *axis*, consisting of an exact-identity core and one smooth-minimum
compression branch per side, leaving the identity with zero curvature and
saturating onto an exact asymptote.** The branch, with `Δ` the distance past the
knee:

$$
g_m(\Delta)=\frac{\Delta\,H}{\left(H^{m}+\Delta^{m}\right)^{1/m}},\qquad
f(E)=\begin{cases}
K_s-g_m(K_s-E) & E<K_s\quad\text{(shadow branch)}\\[1ex]
E & K_s\le E\le K_h\quad\text{(identity core)}\\[1ex]
K_h+g_m(E-K_h) & E>K_h\quad\text{(highlight branch)}
\end{cases}
$$

Five parameters, all in stops except one: a shadow knee `K_s` and depth `H_s`, a
highlight knee `K_h` and height `H_h`, and a shared **roll-off order `m`**
(default **2**). The curve has hard asymptotes at `K_s − H_s` and `K_h + H_h`
that no input can cross, an exactly-identity midsection, `f' > 0` everywhere,
and it is exactly the identity when both knees are pushed outside the scene.

`m` is the answer to "the curve must not be mechanical". `g_m` matches the
identity to **order `m`** at the knee: its expansion is
`Δ − Δ^{m+1}/(mH^m) + …`, so for `m ≥ 2` the branch leaves the straight core
with **zero curvature**, and curvature then builds up and decays smoothly with
no step anywhere. `m = 1` recovers the plain hyperbola (Michaelis–Menten /
Reinhard), which is C¹ only — a *corner in curvature* sitting exactly where the
picture lives. `m = 2` is the shipped default and costs one `rsqrt`:

$$g_2(\Delta)=\frac{\Delta H}{\sqrt{H^2+\Delta^2}},\quad
g_2'=\frac{H^3}{(H^2+\Delta^2)^{3/2}},\quad
g_2''=\frac{-3H^3\Delta}{(H^2+\Delta^2)^{5/2}},\quad g_2''(0)=0$$

**Raising `m` is not a trade of smoothness against quality — it is better on
both counts.** At an identical highlight pull-back (the scene's top landing at
exactly the same place, `+3.950 EV`), on the 15 EV → 8.5 EV case:

| `m` | knee `K_h` | `H_h` | identity core | slope at +8 EV | peak \|f''\| | where |
|---:|---:|---:|---:|---:|---:|---:|
| 1.0 | +2.944 | 1.256 | **6.13 st** | 0.0396 | **1.592** (a step) | at the knee |
| 1.5 | +2.114 | 2.086 | 4.62 st | 0.0544 | 0.439 | 0.57 st past |
| **2.0** | **+1.231** | **2.969** | **3.01 st** | **0.0648** | **0.289** | **1.48 st past** |
| 3.0 | −0.602 | 4.802 | — | 0.0784 | 0.206 | 3.54 st past |

Going from `m=1` to `m=2` cuts peak curvature by **5.5×** *and* increases the
extreme-highlight slope by **64 %** — smoother transition **and** more texture
in the brightest 0.1 %. What it costs is the width of the exactly-untouched
core (6.13 → 3.01 stops), because a gentler departure has to start earlier.
**That is the real trade, and it is the photographer's to make**, which is
exactly why §9 makes it a control rather than a constant.

Why this and not a famous operator:

1. **Every operator in the literature list is a *display* transform.** Reinhard,
   Drago, Hable, ACES, AgX and darktable's `sigmoid` all map an unbounded scene
   onto a bounded display with a *global* sigmoid — which means they compress
   *everywhere*, including the midtones, because their job includes setting
   contrast and placing white. SpektraFilm already has something whose job is to
   set contrast and place white: **the film and the paper.** Importing a display
   sigmoid in front of the film means two shoulders in series and two opinions
   about midtone contrast. §2 traces each one to the assumption that makes it
   wrong here.
2. **The requirement "midtone slope exactly 1" is not a property any sigmoid
   has.** It is a property of a *piecewise* curve with a genuine linear segment.
   Only darktable's `filmic rgb` has that segment (the "latitude"/"linear
   region"), and it is the single closest prior art (§2.6) — but its segment has
   slope = *contrast*, not 1, because it too is a display transform.
3. **The smooth-minimum branch is the smallest function that satisfies all
   thirteen properties in the brief simultaneously**, with monotonicity
   (`g_m' = (1+(Δ/H)^m)^{-(m+1)/m} > 0`) and the asymptote structural rather
   than fitted. No spline, and no monotonicity repair pass — which matters,
   because *monotonicity repair is where filmic v3 actually failed* (§2.6).

Three constraints were added by the user after the first draft, and each one
changed the design rather than decorating it:

- **"The curve must not be mechanical — it must have curvature at the
  progressive ends."** The first draft's C¹ hyperbola has a curvature *step* at
  the knee, which §7.3 then had to measure and apologise for. The `m` family
  above removes the step outright and, as the table shows, is better in the
  tail as well. §5.5.
- **"Borrow the implementation logic of camera log curves."** Adopted
  literally, and it is a better template than any of the tone-mapping
  operators: a cut point, constants *solved from photographic anchors* rather
  than tuned, exact value-and-slope match at the cut, and a stated coverage in
  stops. §5.7.
- **"The one thing we must not do is log-domain input."** Agreed, and made
  structural rather than a matter of care: the signal is scene-linear from end
  to end, log₂ appears only as the axis on which a *scalar gain* is computed,
  there is no normalised log window, and the kernel computes the curve as a
  **delta** `δ(E) = f(E) − E` so that the identity core is **bit-exact**, not
  approximately exact. §5.6.

Two secondary conclusions that are, in the author's view, more load-bearing
than the choice of curve:

- **The magnitude should be `Y`, not `b = X+Y+Z`** — not for spectral reasons
  (§5.2 proves the two are structurally interchangeable here), but because the
  metering path that defines the reference already uses `Y`, and using a
  different quantity for the axis than for its own origin is how an EV scale
  quietly stops meaning stops. §5.2.
- **The architecture is even smaller than proposed.** Because
  `spk_lut2d_cubic` returns `acc(tc)·b` and `tc` depends only on chromaticity,
  a pre-upsample per-pixel scalar `k` is **algebraically identical** to a
  post-upsample scalar `k` (§12.2, with the exact conditions under which the
  identity holds). The new node is therefore provably outside the film model —
  it is the same kind of object as the existing `node_exposure`, which already
  sits there — and a later optimisation can fuse it into the upsample kernel
  for **zero extra passes and zero extra planes**. §10.3.

---

## 2. Literature review — what applies, and what is superficially similar

For each operator: what it is, and the specific assumption that does or does not
survive being moved in front of a film model.

### 2.1 Reinhard, Stark, Shirley & Ferwerda 2002 — *Photographic Tone Reproduction for Digital Images*

[SIGGRAPH '02, ACM](https://dl.acm.org/doi/10.1145/566570.566575) ·
[PDF](https://www.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf)

Global operator: `L_d = L/(1+L)`, extended to
`L_d = L(1 + L/L_white²)/(1+L)`. Plus a *local* dodge-and-burn stage built on a
scale-space measure of local contrast.

- Global / local: **both**, as two separable halves.
- Two-sided: **no.** It is a pure shoulder. `L/(1+L)` has slope 1 only at
  `L=0`, so it starts compressing immediately — the midtones lose contrast by
  construction, which is exactly what a film model must not have done to its
  input.
- Midtone unit slope: **no**, not without renormalisation.
- EV parameterisation: **no** — `L_white` is in linear luminance.
- Monotone, asymptotic, C^∞: yes.
- Aesthetic baggage: the operator *is* Adams' Zone System rendered as
  arithmetic — key value, dodge and burn, print. Every one of those decisions
  is one SpektraFilm has already made in the profile layer.

**Verdict: mathematical inspiration only.** The rational form
`Δ·H/(H+Δ)` in §5 is the Reinhard/Michaelis–Menten algebra, moved to the log
domain and confined to one branch so it cannot touch the midtones. The
`L_white` idea survives as the asymptote `K+H`. Notably, the same "extended
Reinhard with `W = gain`" form was already prototyped in this codebase for
Layer 2's exposure slider and shown to be the **exact** identity at EV 0 where
every fixed-knee shoulder was not — see the `layer2-exposure-clips` note. That
is independent, in-house evidence that this family is the one that can be
turned on without changing an existing edit.

### 2.2 Drago, Myszkowski, Annen & Chiba 2003 — Adaptive Logarithmic Mapping

Logarithmic compression with a bias function that varies the log base with
luminance; explicitly parameterised by `L_wmax` and a display maximum in cd/m².

- Two-sided: **no.** Log mapping is a highlight compressor; it *expands*
  shadows uncontrollably as `L→0`.
- The bias parameter `b` is a perceptual dial tuned against a display's
  absolute luminance. There is no display here.
- Its shadow behaviour is unbounded: `log(L)→−∞`.

**Verdict: rejected.** The one durable idea — that compression should be done
in a log domain, not a linear one — is already the premise of this RFC.

### 2.3 Durand & Dorsey 2002 — Fast Bilateral Filtering for HDR Display

Decomposes into a bilateral-filtered base layer and a detail layer, compresses
only the base.

- **Neighbourhood-dependent.** Disqualified by constraint 10 in the brief and by
  RFC-020's memory architecture: a bilateral filter at 102 MP is a
  full-resolution intermediate, which is the thing this codebase spent RFC-019
  and RFC-020 removing.
- It is also the *correct* long answer to the part of the problem a global curve
  cannot solve. See §14.3.

**Verdict: out of scope for V1, in scope for the roadmap.**

### 2.4 Hable 2010 — the Uncharted 2 "filmic" operator

The well-known rational
`((x(Ax+CB)+DE)/(x(Ax+B)+DF)) − E/F`, normalised by its value at a white point.

- Two-sided: nominally yes — `A..F` include toe strength and toe numerator
  terms — but the parameters are **not separable**: changing the toe moves the
  shoulder and the midtone slope, which is why in practice people tune it by
  eye against a reference image.
- Midtone unit slope: not guaranteed, not even nameable.
- Monotonicity: **not guaranteed for arbitrary `A..F`.** It is a ratio of two
  quadratics; nothing in the formulation stops the derivative changing sign.
- Its whole purpose is to *look like film*.

**Verdict: rejected, and specifically rejected for the reason the brief
anticipates.** "Filmic" here means "a curve that imitates what SpektraFilm
computes from measured sensitometry". Putting an imitation of film in front of
the film is the single clearest way to get two shoulders and a muddy midtone.

### 2.5 ACES 2.0 output transform — the "Daniele Evo" tone scale

[ACES documentation, Tone Mapping](https://docs.acescentral.com/system-components/output-transforms/technical-details/tone-mapping/) ·
[the VWG thread where it was derived](https://community.acescentral.com/t/output-transform-tone-scale/3498)

Built on the Michaelis–Menten form, parameterised so that most control values
derive from a single peak-luminance parameter `N_r`; applied to `J` in a JMh
representation rather than to RGB.

The design requirement list is worth quoting because it is the closest thing
the field has to a spec, and this RFC's §5 satisfies all of it *except* the
S-shape: "an S-shaped curve with a toe and shoulder", "continuously increasing
over the domain", "no vertical or horizontal asymptotes", "defined for all
float values", "log-log slope through 18 % mid-grey less than 1.55".

Two of those are *display* requirements that must **not** be imported:

- **"log-log slope through mid-grey < 1.55"** is a statement about how much
  contrast a display rendering should add. SpektraFilm's required slope through
  mid-grey is **1.0**, because the contrast is the paper's job.
- **"no horizontal asymptotes"** is there because a display transform must keep
  producing distinguishable code values arbitrarily far up. Here, a horizontal
  asymptote is a *feature*: it is the guarantee that no pixel can be driven past
  the paper's white. §5.4.

**Verdict: the Michaelis–Menten algebra is adopted; the parameterisation and
the requirement list are not.** Applying the curve to `J` in JMh is also
instructive and rejected in §13.2.

### 2.6 darktable `filmic rgb` — the closest prior art

[User manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/filmic-rgb/) ·
source `src/iop/filmicrgb.c`

This is the one operator in the list whose *parameterisation* is the one the
brief asks for:

- **white relative exposure** and **black relative exposure**, both in EV
  relative to scene mid-grey — i.e. exactly "source meaningful range";
- **contrast** — the slope of the middle, *linear* part of the curve;
- **linear region** (formerly "latitude") — "the range around middle-gray that
  is mapped with the slope set by contrast, expressed as a percentage of the
  dynamic range";
- **shadows ↔ highlights balance** — shifts that linear region toward either
  extreme. This is the brief's "shadow/highlight balance", already shipped and
  already validated on millions of photographs.

And its construction is the brief's §6 abstraction: "a linear middle part and
two ends that transition smoothly to the limits."

Three things stop it being the answer:

1. **The middle segment's slope is `contrast`, not 1**, and the whole curve
   works on a *normalised* log axis where the scene's `[black EV, white EV]`
   becomes `[0,1]`. "Identity" is not expressible.
2. **It is display-referred by construction** — the output axis is display
   luminance, and the `hardness`/`target black/white/grey` parameters are
   display quantities.
3. **The toe and shoulder are fitted polynomial splines, and monotonicity is not
   structural.** darktable's own history is the evidence: filmic v3's spline
   could go non-monotonic and the v4/v5 work added *tension* settings
   (`soft`/`hard`/`safe`) precisely to keep the extrapolation under control.
   A curve family that needs a repair pass to stay monotone is a worse
   engineering object than one that cannot fail.

**Verdict: adopt the parameter vocabulary wholesale. Reject the
implementation.** The names the UI should use — *black/white relative exposure,
linear region, balance* — are filmic's, and using the same words as the tool
this product's users already know is worth more than novelty.

### 2.7 darktable `sigmoid` — the best-specified implementation, and the wrong shape

[User manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/sigmoid/) ·
source `src/iop/sigmoid.c`, function `_generalized_loglogistic_sigmoid`

```c
const float film_response  = powf(film_fog + clamped_value, film_power);
const float paper_response = magnitude * powf(film_response / (paper_exp + film_response), paper_power);
```

i.e. `f(v) = M · [ (φ+v)^γ / (P + (φ+v)^γ) ]^p`, a generalized log-logistic
whose parameter names — `film_fog`, `film_power`, `paper_exposure`,
`paper_power` — are *derived from a film-plus-paper model*. `commit_params`
solves for those four so that `f(0) = black target`, `f(grey) = grey`,
`f(∞) = white target`, and **the slope at mid-grey depends only on `contrast`
and not on `skew`** — an admirable piece of parameterisation, and the best
worked example available of decoupling an asymmetry control from a midtone
control.

Why it is nevertheless the wrong shape here: it is a *sigmoid*. It compresses
everywhere. `f'(grey) = contrast`, and there is no value of the parameters for
which any interval maps 1:1. Applied before the film, it would ask the
photographer to undo its midtone contrast with the film's.

**But two things from this file should be copied nearly verbatim** (§11):

- `_desaturate_negative_values` — the negative-RGB policy (§11.2);
- `process_loglogistic_rgb_ratio` — the ratio-preserving application
  `scaling_factor = mapped_luma / luma`, which is *exactly* the `k` of this
  RFC, together with the guard `if(luma > 1e-9)` and the documented consequence
  ("desaturating bright colorful pixels along spectral lines").

### 2.8 AgX

[sobotka/AgX](https://github.com/sobotka/AgX) ·
[Blender's parameterised implementation](https://projects.blender.org/blender/blender/pulls/147770)

Log₂-encode the scene over a fixed window (≈16.5 stops), apply a sigmoid on the
log axis, apply per-channel, and — crucially — *inset* the primaries toward
achromatic before the per-channel curve and rotate them to compensate for Abney,
then partially un-inset afterwards. darktable's `sigmoid` adopted the inset
matrix and cites AgX for it (`_calculate_adjusted_primaries`).

- The **log-domain sigmoid** is a good idea and is half of this RFC's premise.
- The **per-channel application plus primary inset** is a solution to a problem
  SpektraFilm does not have and must not import: it is how you keep saturated
  highlights from turning into hue-shifted mush *when a per-channel display
  curve is the last thing that touches them*. SpektraFilm's per-channel
  non-linearity is the **film's own three density curves**, computed from
  measured sensitivity — that is the product. Insetting primaries before it
  would be pre-desaturating the scene to flatter a curve that is downstream and
  physical.
- AgX's window (`-10 … +6.5` stops) is a display-rendering choice.

**Verdict: the log-domain framing is adopted, the colour machinery is
explicitly rejected.** §13.2.

### 2.9 Mantiuk, Daly & Kerofsky 2008 — Display Adaptive Tone Mapping

[SIGGRAPH '08](https://dl.acm.org/doi/10.1145/1399504.1360667) ·
[PDF](https://www.cl.cam.ac.uk/~rkm38/pdfs/mantiuk08datm.pdf)

The most directly relevant paper in the list, and the one the brief does not
name. It formulates tone mapping as: *given a model of the output medium and the
image's own statistics, find the tone curve that minimises visible contrast
distortion* — solved as a quadratic program over a **piecewise-linear curve in
the log-luminance domain**, weighted by an HVS contrast-visibility model, and
constrained by an explicit **display model**.

Three things it establishes that this RFC leans on:

1. **"Fit the scene into the medium, given a measured model of the medium" is a
   published, defensible framing** — not an ad-hoc product idea. §8's
   `ProfileLatitudeDescriptor` is a display model in Mantiuk's sense, for a
   medium that happens to be paper.
2. **The optimal curve is derived from the image's own log-luminance
   histogram**, which is what §9's Fit does.
3. **The curve is piecewise in the log domain**, not a closed-form sigmoid.

Why the full method is not adopted: it needs a per-image quadratic program and
an HVS model calibrated in absolute cd/m², neither of which belongs in a
pointwise Metal pass, and its objective ("minimise visible contrast distortion
against the original") is not the photographer's objective here.

**Verdict: adopted as the framing and the justification for §8 and §9; the
solver is not adopted.** Worth revisiting if "Fit" ever needs to be smarter than
percentiles — Larson, Rushmeier & Piatko's 1997 histogram-adjustment operator
with a contrast ceiling is the cheaper half of the same idea.

### 2.10 The dynamic-range compressor, from audio

Giannoulis, Massberg & Reiss, *Digital Dynamic Range Compressor Design — A
Tutorial and Analysis*, JAES 60(6), 2012
([AES](https://aes2.org/publications/elibrary-page/?id=16354)).

Not an imaging paper, and the most useful one. A feed-forward compressor's
**gain computer** operates in the **log (dB) domain** and is, in its standard
soft-knee form:

$$
y = \begin{cases}
x & 2(x-T) < -W\\
x + (1/R - 1)\dfrac{(x-T+W/2)^2}{2W} & |2(x-T)| \le W\\
T + \dfrac{x-T}{R} & 2(x-T) > W
\end{cases}
$$

This is *precisely* the brief's §6 "soft window" abstraction, half a century
older than the imaging versions: exact identity below threshold, a quadratic
knee of controllable width that is C¹ at both joins, and a constant-ratio branch
above. The paper's recommendation — level detection in the log domain, after the
gain computer, because it "generates a smooth envelope … and a variable knee
width" — is the same conclusion §5 reaches from imaging first principles.

**Verdict: adopted as the structural template (identity core + knee + branch),
with two changes.** The constant-ratio branch has *constant* slope `1/R`, which
violates requirement 3/4 of the brief ("`f'` decreases *progressively* toward
the extremes") and has no asymptote, so extreme inputs still run away; `g_m`
(§5.4) replaces it with progressive slope decay and a hard bound. And the
quadratic knee is C¹ only — it removes the *slope* discontinuity a hard-knee
compressor has, but leaves a curvature step, which is exactly the artifact
`m ≥ 2` exists to remove. **The audio literature's knee is the right idea one
order of contact too low**, for the same reason the camera log curves' cut is
(§5.7): in audio the knee sits at a threshold the programme material crosses
transiently, not at a level the listener is staring at.

### 2.11 Sensitometry — ISO 6846 and what "latitude" already means

[ISO 6846:1992](https://www.iso.org/standard/13355.html), *Photography —
Black-and-white continuous-tone papers — Determination of ISO speed and ISO
range for printing.* The concept the standard formalises is the **log exposure
range (LER)**: the difference in log exposure between two specified densities on
the paper's characteristic curve, and the criterion that "highly acceptable
prints are generally obtained if the log exposure range of the paper equals the
effective density range of the negative."

That last clause is this entire RFC in one sentence, written in 1983, about
paper. §8 is its implementation.

The density criteria themselves are behind the paywall; the conventional pair
used throughout the trade literature (and by Ilford's own
[Multigrade technical data](https://www.ilfordphoto.com/wp/wp-content/uploads/2021/01/MULTIGRADE-IV-RC-Papers-060619.pdf))
is **Dmin + 0.04** for the highlight end and **0.90 × Dmax** for the shadow end.
§8.2 computes it over the shipped profiles on that basis and flags it as a
convention, not a citation.

### 2.12 Camera log encodings — the construction template

Sony S-Log3, ARRI LogC3 and LogC4, RED Log3G10, Canon Log 2/3, Panasonic V-Log.
All are published as equations with their constants stated, all are piecewise
(a linear segment and a logarithmic segment meeting at a cut), and all derive
those constants from photographic anchors rather than from fitting.

They are **not** tone-mapping operators and are not candidates for `f`. What is
adopted is their *construction discipline*, which §5.7 sets out point by point,
and one requirement where this node must go further than they do: every one of
them is only C¹ at its cut, which is acceptable because the cut sits deep in the
toe, and is not acceptable here because the knee sits in the picture.

Primary sources worth having open while implementing:
ARRI's [LogC4 specification](https://www.arri.com/resource/blob/278790/dc29f7399c1dc9553d329e27f1409a89/2022-05-arri-logc4-specification-data.pdf)
(the constants are derived in the document, which is what makes it the best of
the set to read), and Sony's and RED's published S-Log3 and Log3G10 technical
notes.

---

## 3. Open-source implementations worth reading, ranked by usefulness

| Repo / file | What to read it for | Adapt or inspire? |
|---|---|---|
| `darktable/src/iop/sigmoid.c` — `_desaturate_negative_values` (line ~495) | The negative-RGB policy: desaturate toward the achromatic mean rather than clip. Four lines, exactly right. | **Adapt** (§11.2) |
| `darktable/src/iop/sigmoid.c` — `process_loglogistic_rgb_ratio` (line ~566) | The ratio-preserving application and its `luma > 1e-9` guard; the `luma = (R+G+B)/3` choice and its documented desaturation consequence. | **Adapt the structure**, change the norm (§5.2) |
| `darktable/src/iop/sigmoid.c` — `commit_params` (line ~325) | How to solve curve parameters so that one control (skew) cannot move another (midtone slope). The cleanest worked example of orthogonal parameterisation in the field. | **Inspire** |
| `darktable/src/iop/filmicrgb.c` | The EV-domain parameter set, the "linear region" and the balance control; and the spline tension machinery that exists because monotonicity was not structural. | **Inspire** (and a cautionary tale) |
| `sobotka/AgX`, Blender's `AgX View Transform` node | Log-domain sigmoid; primary inset/rotation. Read to understand what we are deliberately *not* doing and why. | **Neither** |
| ACES `output-transforms` reference implementations (CTL/`aces-core`) | The Daniele tone scale's Michaelis–Menten parameterisation, and the JMh application. | **Inspire** |
| `pfstools` / `pfstmo_mantiuk08` | A readable implementation of display-adaptive tone mapping, including how a "display model" is represented and consumed. | **Inspire** (§8) |
| **This repo: `engine/src/shaders/nodes.metal`, `spk_edr` (line 344)** | **The single most useful file.** See §12.3 — the shape this RFC proposes is already implemented in this codebase, on the output side. | **Adapt directly** |

---

## 4. Mathematical comparison

Columns: **2-sided** = independent toe and shoulder; **id core** = an interval
where `f(E)=E` exactly; **C¹/C²** = derivative continuity; **asym** = shadow and
highlight independently controllable; **EV** = natively parameterised in stops;
**mono** = monotonicity structurally guaranteed (not merely typical); **cost** =
per-pixel ALU after the log₂/exp₂ that every candidate needs; **legible** =
parameters a photographer can name.

| Family | 2-sided | id core | C¹ | C² | asym | EV | mono | bound | cost | legible |
|---|---|---|---|---|---|---|---|---|---|---|
| Reinhard `L/(1+L)` | no | no | yes | yes | no | no | **yes** | asympt. | 1 div | partly |
| Reinhard extended (`L_white`) | no | no | yes | yes | no | no | yes | **exact** | 1 div | partly |
| Drago adaptive log | no | no | yes | yes | no | no | yes | asympt. | log+pow | no |
| Hable / Uncharted 2 | nominal | no | yes | yes | **coupled** | no | **no** | exact | 2 div | no |
| ACES 2.0 Daniele | yes (S) | **no** | yes | yes | yes | partly | yes | by design none | ~3 pow | partly |
| darktable `sigmoid` | yes (S) | **no** | yes | yes | **yes** | no | yes | exact | 3 pow | yes |
| darktable `filmic rgb` | **yes** | slope≠1 | yes | at joins | **yes** | **yes** | **fitted** | exact | spline | **yes** |
| AgX | yes (S) | no | yes | yes | partly | yes | yes | exact | pow+matrices | no |
| tanh / softsign in EV | yes | no | yes | yes | no | yes | yes | exact | 1 exp | no |
| Softplus smooth-min/max | yes | **no** (≈) | yes | **yes** | yes | **yes** | **yes** | asympt. | 2 exp+2 log | partly |
| Audio soft-knee compressor | yes | **yes** | **yes** | no | **yes** | **yes** | **yes** | **none** | 1 mul | **yes** |
| Identity core + hyperbola = `m=1` | yes | **yes** | **yes** | no (2 pts) | **yes** | **yes** | **yes** | **exact** | 1 div | **yes** |
| Identity core + exponential saturation | yes | yes | yes | no (2 pts) | yes | yes | yes | exact | 1 exp | yes |
| Identity core + `tanh` branch | yes | yes | yes | **yes** | yes | yes | yes | exact | 1 exp | yes |
| **Identity core + smooth-min `g_m` (§5.4)** | **yes** | **yes** | **yes** | **yes (`m≥2`)** | **yes** | **yes** | **yes** | **exact** | **1 sqrt at `m=2`** | **yes** |

Reading the table: **the identity-core families are the only ones with a true
identity midsection**, and within them the choice is decided by two things the
table cannot show — the **contact order at the knee** (`m ≥ 2` and `tanh` leave
no curvature step; `m = 1` and the exponential do) and **whether the family has
a parameter to move along the core-width-vs-extreme-slope trade at all** (`g_m`
does, via `m`; `tanh` and the exponential are single fixed points). §7.4
measures all five at an equal landing point, and includes a correction to an
argument the first draft got wrong.

---

## 5. The recommended model

### 5.1 The axis

Let the working-space scene-linear triple after geometry, auto-exposure and
white balance be `RGB`. Define a scalar magnitude `n(RGB)` (§5.2) and a
reference `n_ref` (§5.3). Then

$$E = \log_2\!\left(\frac{n}{n_{\text{ref}}}\right) \quad\text{[stops relative to metered mid-grey]}$$

Film Exposure — today `params.camera.exposure_compensation_ev`, applied by
`node_exposure` — *was* to be folded in additively here. **§15.4 measured that
this is not available: `exposure_compensation_ev` has a second consumer,
`printing.cpp:168`, where the enlarger re-times the print for it.** Moving it
into the mapper would stop that compensation and change the picture.

**For V1, Scene Latitude does not carry Film Exposure.** `EV_film = 0`,
`E_placed = E`, `node_exposure` keeps its job, and `E` is measured after
auto-exposure and before Exp. Comp. The additive form below is kept because it
is what a future version would use *if* `printing.cpp` were told about it in the
same change — which is a change to the print model and out of scope here:

$$E_{\text{placed}} = E + EV_{\text{film}}\qquad(EV_{\text{film}} \equiv 0 \text{ in V1})$$

This is not a new degree of freedom. It is the *same* gain, moved from after
the curve to before it, so that "Exposure Comp. +1 EV" means "the scene sits one
stop higher relative to the film's latitude", which is what a photographer
already believes it means. When Scene Latitude is enabled, `node_exposure`
becomes the identity; when it is disabled, nothing moves at all (§12.1).

Then

$$E_{\text{mapped}} = f(E_{\text{placed}}),\qquad
k = 2^{\,E_{\text{mapped}} - E},\qquad
RGB' = k\cdot RGB$$

Note the exponent is `E_mapped − E`, **not** `E_mapped − E_placed`: the gain `k`
must carry the Film Exposure placement as well as the compression, because
`node_exposure` is no longer going to apply it. With the curve disabled
(`f = id`), `k = 2^{EV_film}` exactly — which is precisely today's
`node_exposure`, and is the first half of the bypass proof in §12.1.

### 5.2 Which magnitude — and why the spectral model does not decide it

The brief asks whether `b = X+Y+Z` is the right quantity "given that the
spectral reconstruction already uses it".

**It is not an argument either way, and the reason is worth stating precisely.**
`spk_tc_b` computes `XYZ = M·RGB`, `b = X+Y+Z`, and a chromaticity pair `tc`
from `x = X/b`, `y = Y/b`; `spk_lut2d_cubic` then returns `acc(tc)·b`. Both `b`
and `XYZ` are *linear* in `RGB`, so for any positive scalar `k`:

- `tc(k·RGB) = tc(RGB)` — chromaticity is exactly invariant;
- `b(k·RGB) = k·b(RGB)`;
- therefore `upsample(k·RGB) = k·upsample(RGB)`.

So **whatever scalar we choose, the effect on the spectral stage is a pure gain
on `b` and nothing else.** Choosing `Y` does not make the mapper "fight" the
spectral model; choosing `b` does not make it "agree" with it. The spectral
model is indifferent. (The exact conditions on this identity — the `1e-10`
denominator guard and the `clamp(tx,ty)` — are in §12.2.)

That frees the choice to be made on photometric and product grounds:

| Candidate | Argument for | Argument against |
|---|---|---|
| `Y` (CIE luminance) | **The meter already uses it.** `Pipeline::exposure_sample_y` computes "the Y row of RGB→XYZ, no adaptation", and `kMidgray = 0.184` is defined against it. If the curve's axis uses a different quantity from the one that defines its own origin, then "0 EV" on the histogram and "0 EV" on the curve are different places, and every percentile in §9 is measured in one unit and consumed in another. | A very saturated highlight (a red LED, a blue stage light) has low `Y` for a large channel value, so `Y` under-compresses it and one channel can still exceed the film's latitude. |
| `b = X+Y+Z` | Already computed in `spk_tc_b`, so free if the node is fused (§10.3). | For a fixed `Y`, `b` is larger for low-luminous-efficiency colours (violets, deep blues) than for yellows, so it compresses saturated blues harder than equally bright yellows for no photometric reason. And it is *not* the quantity the meter uses, so `n_ref` must be derived (§5.3) rather than read off. |
| `max(R,G,B)` | Guarantees no channel exceeds the target window. | Not differentiable across channel-crossing loci; produces the strongest desaturation of bright colours; diverges from the meter most of all. |
| Power norm `(R³+G³+B³)/(R²+G²+B²)` | A smooth approximation of `max`; darktable ships it in filmic's "preserve chrominance" list for exactly this trade-off. | Three extra multiplies and a divide; still not the meter's quantity. |

**Recommendation, revised by §15.5: the power norm, not `Y`.** The norm stays a
named parameter (`Y` / `b` / `power_norm` / `max`), but `Y` is no longer the
default, and the reason is the opposite of the one anticipated below. Measured
on a real frame: 0.14 % of pixels have near-zero `R` and `G` with a positive
`B` — RAW noise after the camera matrix — and `Y` under-reports them by a factor
of 10⁴, so the shadow branch hands them the largest gain in the frame and the
result is saturated blue speckle. The power norm and `max(RGB,0)` agree to three
figures there and do not. §15.5.

The "saturated highlight escapes" objection was, at the time of writing, thought
to be the only real one. **It was the wrong end of the curve** (§15.5). The
answer below still stands for highlights and is kept; it simply is not the
governing case. **SpektraFilm has a per-channel shoulder already, and it is
the product.** A channel that lands above the film's latitude after a
ratio-preserving pre-map does not clip — it runs onto that channel's own
measured shoulder, which is the physically correct behaviour of film and is
exactly what the user is paying for. Pre-desaturating the scene to prevent that
(AgX's answer, §2.8) would be replacing film's colour behaviour with a display
transform's. The pre-map's job is to place the *achromatic* scale inside the
medium; the medium's job is everything else.

### 5.3 The reference `n_ref`

`n_ref` must be **derived, never assumed**:

- With `n = Y`: `n_ref = kMidgray = 0.184`, directly, because auto-exposure
  already normalises the metered log-mean `Y` to that value
  (`pipeline.cpp:46`, and `exposure_evs_from`'s `-log2(·/kMidgray)`).
- With `n = b`: `n_ref = 0.184 / y_w`, where `y_w` is the `y` chromaticity of the
  working space's white under the same `M` the kernel uses — i.e. `b/Y` for a
  neutral. It must be computed from `baked_.tc_b_matrix`, not typed in.

Two further references that are **measured, not assumed** (§8):
`reference_ev` — where the medium's own mid-scale actually sits on the film's
log-exposure axis, which is what `midscale_neutral_density` in every profile is
about — and the medium's boundaries.

### 5.4 The curve

With `E ≡ E_placed`, `Δ ≥ 0` the distance past a knee, `H > 0` the room between
that knee and the medium's boundary, and `m ≥ 1` the roll-off order:

$$g_m(\Delta)=\Delta\left(1+\left(\tfrac{\Delta}{H}\right)^{m}\right)^{-1/m},\qquad
g_m'(\Delta)=\left(1+\left(\tfrac{\Delta}{H}\right)^{m}\right)^{-\frac{m+1}{m}},$$

$$g_m''(\Delta)=-\frac{m+1}{H}\left(\tfrac{\Delta}{H}\right)^{m-1}
\left(1+\left(\tfrac{\Delta}{H}\right)^{m}\right)^{-\frac{2m+1}{m}}$$

**Highlight branch** (`E > K_h`): `f(E) = K_h + g_m(E − K_h)`, `H = H_h`.
**Shadow branch** (`E < K_s`): `f(E) = K_s − g_m(K_s − E)`, `H = H_s`.
**Core** (`K_s ≤ E ≤ K_h`): `f(E) = E`, `f'(E) = 1`, `f''(E) = 0`.

This is the **smooth minimum** of `Δ` and `H` — the same algebraic family as the
`softsign`/algebraic-sigmoid, confined to one branch. `g_m(Δ) → H` from below,
monotonically, for every `m ≥ 1`.

Properties, all by construction rather than by fitting:

1. **Monotone.** `g_m' > 0` for all `Δ ≥ 0`, `H > 0`, `m ≥ 1`. There is no
   parameter combination that can make `f` non-monotone. This is the property
   filmic's splines cannot state.
2. **Identity core, exact** — and §5.6 makes it *bit*-exact, not merely exact in
   real arithmetic.
3. **Contact of order `m` at the knee.** `g_m(Δ) = Δ − Δ^{m+1}/(mH^m) + O(Δ^{2m+1})`,
   so value, slope **and (for `m ≥ 2`) curvature** all match the core. At `m=2`
   the first non-zero derivative of the departure is the third.
4. **Curvature is bounded and peaks away from the knee.** `|g_m''|` is maximised
   at `Δ/H = ((m−1)/(m+2))^{1/m}` — for `m=2`, at `Δ = H/2`, with value
   `0.8587/H` against the `m=1` step of `2/H`. **The curvature ramps in and
   ramps out; there is no point at which it jumps.**
5. **Bounded, never clipping.** `f(E) → K_h + H_h` as `E→∞`, approached but
   never reached. `K_h + H_h` is the **ceiling** and `K_s − H_s` the **floor**.
   Nothing in the scene, at any exposure, can be mapped outside
   `(K_s−H_s, K_h+H_h)`. A specular highlight at +30 EV lands below the paper's
   white by construction, not by clamping.
6. **Independent sides.** `(K_s, H_s)` and `(K_h, H_h)` share everything except
   `m`. Asymmetry is free (requirement I).
7. **Polynomial tail.** `g_m' ~ (H/Δ)^{m+1}`, against `tanh`'s exponential
   `sech²`. At the far extreme this is worth about a factor of two (§7.4's
   table: `f'(+16)` is 7.7 × 10⁻³ at `m=2` against `tanh`'s 3.7 × 10⁻³) — real,
   but *not* the deciding argument, and §7.4 records the arithmetic error that
   first made it look decisive.
8. **`m` is a continuous parameter along the whole trade.** This is the actual
   deciding property, and it is a property of the *family*, not of any one
   curve. §7.4.
9. **Stable to ±16 EV and beyond** — see the `±16` rows in §6.

### 5.5 What `m` is, in photographic terms

`m` is a **roll-off order**: *how gradually the compression is allowed to
begin.* Low `m` means "hold the midtones dead straight for as long as possible,
then turn hard"; high `m` means "start bending early and never turn hard".

The table in §1 is the measured consequence at a fixed pull-back, and the
non-obvious half is worth restating: **higher `m` gives both a smoother knee and
more separation in the extremes.** It buys those by spending the width of the
exactly-untouched core. So `m` is not a quality dial with a right answer — it is
the same currency the pull-back sliders spend (§9.3), and the UI should show the
core width as the price tag on both.

`m = 2` is the default because it is the lowest order that removes the curvature
step entirely, and because it has an exact, cheap closed form:
`g_2(Δ) = ΔH/√(H²+Δ²)` — one `fma`, one `rsqrt`, two multiplies, no `pow`.
`m = 1` keeps a fast path (a single divide) and is what a photographer who wants
the widest possible untouched core would choose, accepting the corner.
Non-integer `m` is valid and needs `pow`; expose it only if §14.4 finds it
matters.

### 5.6 The signal never becomes log — and the identity is bit-exact

The brief's hardest constraint. Three separate statements, all structural:

**1. No log encoding of the signal.** What leaves this node is
`RGB' = k·RGB`: scene-linear, in the same working space, in the same units,
with the same white point. `log2` and `exp2` occur only inside the computation
of the *scalar* `k`. Nothing downstream — `spk_tc_b`, the spectral integral, the
film curves — ever sees a log-encoded value, and none of them is told anything
new. The film's own `log10` remains `node_expose_log`'s, in its own place,
unchanged.

**2. No normalised log window.** This is the specific failure mode in AgX and
filmic: they map `[black EV, white EV]` onto `[0,1]` and *then* apply the curve,
which bakes the assumed dynamic range into the curve's shape, so changing the
window changes the rendering of the midtones. Here `E` is an **absolute** axis —
stops relative to the metered mid-grey — and `f`'s parameters are absolute
positions on it. Widening the medium moves the knees and nothing else. There is
no window, no normalisation, and no LUT axis with a baked domain.

**3. The round trip is exactly lossless in the core.** The kernel must compute
the **delta**, not the mapped value:

$$\delta(E) \;=\; f(E) - E \;=\; \begin{cases} -\dfrac{\Delta^{3}}{r\,(H+r)},\ r=\sqrt{H^{2}+\Delta^{2}} & \text{on a branch }(m=2)\\[1ex] 0 & \text{in the core}\end{cases}$$

$$k = 2^{\,\delta(E_{\text{placed}})\;+\;EV_{\text{film}}}$$

In the core, `δ` returns a literal `0.0f`, so the exponent is `EV_film`
**exactly** and `k = exp2(EV_film)` is bit-for-bit the gain
`node_exposure` applies today (`pipeline.cpp:865`, `pow(2.0, exposure_compensation_ev)`,
narrowed to float32). Computing `f(E)` and then `f(E) − E` instead would lose
the last bits to rounding and cancellation, and the "untouched midtones"
guarantee would become a claim rather than a fact. The rationalised form above
also removes the cancellation in `g_2(Δ) − Δ` for small `Δ`, which is precisely
where the core meets the branch.

### 5.7 Borrowing the implementation logic of camera log curves

S-Log3, ARRI LogC3/LogC4, RED Log3G10, Canon Log 2/3 and V-Log are all built the
same way, and that way is a better template for this node than any tone-mapping
operator in §2:

| Camera log practice | What it becomes here |
|---|---|
| **Piecewise: a linear segment and a curved segment, joined at a stated cut point.** | Identity core + branch, joined at the knee `K`. Same shape of object. |
| **Constants are *solved* from photographic anchors** — 18 % grey lands at a stated code value, 90 % white at another, the curve covers N stops — never hand-tuned coefficients. | `K` and `H` are solved from (a) the measured medium boundary and (b) a pull-back stated in stops. Nothing in `SceneLatitudeParams` is a coefficient a human typed. §9.2. |
| **Value and slope match exactly at the cut**, verified in the published equations. | Contact of order `m` at the knee, by construction rather than by verification. |
| **A stated coverage in stops** (LogC3 ≈ 14.8, Log3G10 ≈ 16), published as the curve's headline property. | The descriptor states the medium's coverage and the UI shows "scene 15.0 → medium 8.5". §8. |
| **The log part is an encoding for transport, and the grade happens elsewhere.** | Exactly the inversion the user asked for: the log axis is for *computing a gain*, and the picture stays linear. §5.6. |

**And the one place to go beyond them.** Every camera log curve above is only
**C¹ at its cut** — the curvature steps there, exactly as the first draft's
`m=1` did. They get away with it because the cut sits deep in the toe, typically
6–7 stops below grey, where sensor noise is larger than the artifact and where
almost no picture content lives. **This node's knee does not have that luxury:**
§9 puts it 1–3 stops from the subject, in skin, sky and studio backdrop. That is
the whole argument for `m ≥ 2`, and it is a genuine difference in requirements
rather than a criticism of the camera curves.

### 5.8 The kernel, in full

```
n    = norm(RGB)                          // Y by default
E    = log2(max(n, n_floor) / n_ref)      // n_floor = n_ref * 2^-24
Ep   = clamp(E + EV_film, -24, +24)       // domain guard, §11

hi   = Ep > K_h;   lo = Ep < K_s;         // at most one is true
D    = select(0.0f, select(K_s - Ep, Ep - K_h, hi), hi | lo);   // >= 0
H    = select(H_h,  H_s, lo);
sgn  = select(-1.0f, +1.0f, lo);          // shadows move up, highlights down

r    = sqrt(H*H + D*D);                   // m = 2 fast path
d    = sgn * (D*D*D) / (r * (H + r));     // == 0.0f exactly when D == 0

k    = exp2(d + EV_film);                 // == exp2(EV_film) exactly in the core
RGB' = k * RGB;                           // guarded, §11
```

One `log2`, one `exp2`, one `sqrt` (or `rsqrt`+`fma`), one divide, a handful of
`fma`, three selects. No branch diverges within a SIMD group — the cases are
`select` over values, not control flow. `D == 0` in the core forces `d` to a
literal zero through the multiply, which is what makes §5.6's bit-exactness
hold without a special case.

---

## 6. Example mappings

All at `m = 2`, parameterised the way §9 says the UI will: the photographer
states a **pull-back in stops per side**, and `K`/`H` are solved from it against
the measured medium boundary. `E` and `f(E)` in stops relative to metered
mid-grey. Reproduce with `rfc/probes/rfc023-curve-probe.py`.

### 6.1 15 EV scene → 8.5 EV medium (`kodak_portra_400` + `kodak_portra_endura`, the shipped default pair)

Scene `P0.1 … P99.9 = [−7.0, +8.0]`; medium `[−4.3, +4.2]`.
Pull-back: highlights **4.05 stops**, shadows **2.95 stops**.
Solved: `K_h = +1.231`, `H_h = 2.969` (ceiling **+4.200**);
`K_s = −1.783`, `H_s = 2.517` (floor **−4.300**).
Identity core **[−1.78, +1.23] = 3.01 stops**; peak `|f''| = 0.289` per stop²,
reached **1.48 stops past the knee**, not at it.

| E | f(E) | f'(E) | f''(E) |
|---:|---:|---:|---:|
| −16.0 | −4.261 | 0.0053 | +0.0011 |
| −10.0 | −4.190 | 0.0251 | +0.0084 |
| −7.0 | **−4.050** | 0.0820 | +0.0383 |
| −5.0 | −3.765 | 0.2340 | +0.1354 |
| −4.0 | −3.447 | 0.4226 | +0.2498 |
| −3.0 | −2.879 | 0.7297 | +0.3409 |
| −2.0 | −1.999 | 0.9890 | +0.1008 |
| 0.0 | 0.000 | 1.0000 | 0 |
| +2.0 | +1.975 | 0.9072 | −0.2225 |
| +3.0 | +2.751 | 0.6340 | −0.2817 |
| +4.0 | +3.256 | 0.3911 | −0.1971 |
| +6.0 | +3.752 | 0.1476 | −0.0669 |
| +8.0 | **+3.950** | 0.0648 | −0.0241 |
| +16.0 | +4.142 | 0.0077 | −0.0015 |

Compare the `f''` column against the first draft's (`m = 1`): the peak was
**−1.3961** and it arrived as a step at `E = +3`. Here the largest value
anywhere is **−0.2817**, and the column walks to it and back.

Output span of the robust scene range: **8.00 stops** inside an 8.5-stop medium.
Hard bounds over *all* inputs: **[−4.30, +4.20] = 8.50 stops** — the mapper
cannot exceed the medium at any input.

### 6.2 15 EV → 12 EV (`neutral_wide_060`, from `neutral-wide-paper-profiles`)

Medium `[−6.0, +6.0]`; pull-back 2.25 / 1.25 stops.
`K_h = +3.806, H_h = 2.194`; `K_s = −4.347, H_s = 1.653`.
**Identity core [−4.35, +3.81] = 8.15 stops** — eight of the scene's fifteen
stops pass through untouched, and `f` is still exactly `E` at `±3`.
`f(+8) = +5.750` with `f'(+8) = 0.0996`; `f(−7) = −5.750`.

The model degrading toward the identity as the medium widens is requirement 12,
and it is also the quantitative statement of why Scene Latitude and a wide paper
**compose** rather than compete (§13.4).

### 6.3 12 EV → 8.5 EV (a well-exposed scene, `[−5.5, +6.5]`)

Pull-back 2.55 / 1.45. `K_h = +1.863, H_h = 2.337`; `K_s = −2.528, H_s = 1.772`.
Identity core **4.39 stops** — 1.4 stops wider than §6.1 against the same
medium, because the scene asks for less. `f(+6.5) ≈ +3.95`, `f(−5.5) ≈ −4.05`,
`f'(+8) = 0.0451` for anything beyond the robust top.

### 6.4 Asymmetry, and the budget the two sliders share

The two pull-backs are independent controls, but they are not independent of
each other's consequences: **`K_s < K_h` must hold, and the gap between them is
the identity core.** When the photographer asks for more than the medium has,
the knees cross and the fit is invalid — which is a real constraint to surface
in the UI, not an implementation detail to hide.

15 EV scene, 8.5 EV medium, `m = 2`. The material sets the minimum pull-back per
side (`N_h ≥ 3.80`, `N_s ≥ 2.70`) because nothing may land beyond the boundary:

| `N_h` | `N_s` | `K_h` | `K_s` | core | `f(+8)` | `f(−7)` | `f'(+8)` | `f'(−7)` | |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 3.90 | 2.80 | +2.278 | −2.703 | **4.98** | +4.100 | −4.200 | 0.0323 | 0.0423 | widest core, flattest extremes |
| 4.05 | 2.95 | +1.231 | −1.783 | 3.01 | +3.950 | −4.050 | 0.0648 | 0.0820 | §6.1, balanced |
| 4.50 | 2.95 | −1.011 | −1.783 | 0.77 | +3.500 | −4.050 | **0.1255** | 0.0820 | highlight priority |
| 4.05 | 3.40 | +1.231 | +0.266 | 0.97 | +3.950 | −3.600 | 0.0648 | **0.1506** | shadow priority |
| 4.50 | 3.40 | −1.011 | +0.266 | −1.28 | — | — | — | — | **knees cross — invalid** |

**The counter-intuitive row is the third, and it is worth understanding before
designing the slider.** Pulling highlights *harder* (4.05 → 4.50 stops) nearly
doubles the slope at +8 EV. Dragging the scene's top further from paper white
leaves it room to have gradation; parking it right against the boundary does
not. So "pull back more" is not simply "lose more highlight" — it trades the
*core* for the *extremes*, in the same currency `m` trades in (§5.5). The UI
must therefore read out the core width and the extreme slopes, or the control
will be misread in exactly this case.

**And the honest headline:** at 15 → 8.5 stops the two sides are competing for
one 8.5-stop budget. A wide untouched core *or* graded extremes — not both.
§14.3.

---

## 7. Curve analysis — where artifacts would come from

### 7.1 `f'` — the compression ratio, read photographically

`f'(E)` is literally "how many stops of print for one stop of scene" at `E`. In
§6.1, `f'(+8) = 0.0648`: a full stop of scene difference in the brightest 0.1 %
becomes 1/15 stop on the print. Multiplied by the paper's peak slope of
~0.95 density/stop (§8.2), that is **0.062 density** — roughly 0.2 L\* at
mid-lightness. Thin, but present. **This is a real and unavoidable statement
about what 15 → 8.5 costs, not a defect of this curve**: *any* global monotone
map from 15 stops into 8.5 must spend what the core does not use on nine stops
of scene, and the arithmetic does not care which curve family does it.

### 7.2 `f''` — sign, and why it is right

`f'' < 0` on the highlight branch and `f'' > 0` on the shadow branch, both
approaching 0 from their respective sides as `|E|` grows. In photographic terms
the curve's *shoulder* and *toe* both get gentler the further out you go, which
is the behaviour requirement 3 and 4 ask for and the opposite of a hard clip.

### 7.3 Curvature, and why `m ≥ 2` settles it

**With `m = 1` there is a curvature step**: `f''` jumps from `0` to `−2/H_h` at
the knee, which at the first draft's `H_h = 1.256` was **−1.59 stop⁻²**. With
`m = 2` there is no step at all — `f''(K) = 0` — and the peak is
`0.8587/H = 0.289 stop⁻²`, reached smoothly 1.48 stops further out.

Is either large? The right comparison is the curvature of the thing it composes
with. Computed from the shipped profiles (`density_curves` against
`log_exposure`, converted to per-stop):

| profile | ch | peak slope (D/stop) | max \|d²D/dEV²\| (D/stop²) |
|---|---|---|---|
| `kodak_portra_400` | R | 0.199 | 0.284 |
| | G | 0.178 | 0.199 |
| | B | 0.207 | 0.195 |
| `kodak_ektar_100` | R | 0.208 | 0.242 |
| `kodak_portra_endura` | G | 0.747 | 0.665 |
| `kodak_endura_premier` | R | 1.233 | 1.158 |

The composed density curve is `D(f(E))`, so
`d²D/dE² = D''·(f')² + D'·f''`. The mapper's own contribution at its worst point
is `D'·max|f''|`, for Portra 400's green channel (`D' = 0.178 density/stop`):

| | max \|f''\| | composed contribution | vs. the film's own max (0.199) |
|---|---:|---:|---|
| `m = 1` (first draft) | 1.592, **as a step** | 0.283 D/stop² | **larger than the film's own** |
| `m = 2` (recommended) | 0.289, ramped | **0.051 D/stop²** | **26 % of the film's own** |

**That is the result that settles the question.** At `m = 1` the mapper
introduced a curvature feature stronger than the shoulder of the film it sits in
front of, and it introduced it discontinuously. At `m = 2` its worst curvature
is a quarter of what the film does to every photograph anyway, and it arrives
gradually. The knee is no longer the most curved thing in the chain, or even
close.

Two residual controls remain worth having:

1. **An `H_min` floor.** `max|f''| = 0.8587/H` at `m=2`, so a very hard
   pull-back against a very narrow medium can still sharpen the knee. A floor on
   `H` (equivalently a ceiling on curvature) lets the Fit refuse, and the UI say
   so, rather than silently producing a hard turn.
2. **`m` itself**, per §5.5, which is the direct control on the same quantity.

### 7.4 The other branch families, measured at an equal landing point

Every candidate fitted so that the scene's top lands at exactly `+3.950 EV` with
the ceiling pinned at `+4.200` — so what is being compared is *shape*, not
strength. "ord" is the order of contact with the identity at the knee (1 = a
curvature step; ≥2 = none). `K_h` is the core's edge: **higher is more untouched
midtone.**

| branch | ord | `K_h` | `H_h` | `f'(+6)` | `f'(+8)` | `f'(+16)` | max\|f''\| |
|---|---:|---:|---:|---:|---:|---:|---:|
| `g_m`, `m=1` (hyperbola) | **1** | **+2.944** | 1.256 | 0.0849 | 0.0396 | 0.0077 | **1.592** (a step) |
| `H(1−e^{−Δ/H})` | **1** | +1.468 | 2.732 | 0.1903 | 0.0915 | 0.0049 | 0.366 (a step) |
| **`g_m`, `m=2`** | **2** | **+1.231** | 2.969 | 0.1476 | 0.0648 | 0.0077 | **0.289** |
| `H·tanh(Δ/H)` | **2** | −0.530 | 4.730 | 0.2237 | 0.1029 | 0.0037 | 0.163 |
| `g_m`, `m=3` | **3** | −0.602 | 4.802 | 0.1813 | 0.0784 | 0.0068 | 0.206 |

**Read the table as one trade curve, not five candidates.** Every family buys
extreme slope with core width, at very nearly the same exchange rate. What
actually separates them is two columns:

- **Contact order.** `m=1` and the exponential saturation `H(1−e^{−Δ/H})` both
  leave the identity with a curvature step (`2/H` and `1/H` respectively) and
  are therefore out on the user's first constraint — **including the exponential,
  which otherwise looks like the best row in the table** (the widest core *and*
  a better `f'(+8)` than `m=2`). It is worth recording that it was not rejected
  for being bad; it was rejected for having a corner.
- **Whether the family has a parameter.** `tanh` is a single fixed point on the
  trade curve, sitting a little beyond `m = 3`; it cannot be moved. `g_m` spans
  the whole curve continuously — including the `m=1` end that a photographer
  wanting the maximum untouched core would choose — with one number, and its
  cheapest useful point (`m=2`, one `sqrt`) is also the one with the widest core
  among the no-corner options.

**A correction, recorded because the first draft of this section was wrong.**
It claimed `tanh` "throws away 97 % of the remaining highlight separation".
That number came from evaluating `tanh` at `m=1`'s knee and room rather than at
`tanh`'s own fit, and it is not true: fitted properly, `tanh` has a *better*
`f'(+8)` than `m=2` (0.103 vs 0.065) and pays for it in core width
(−0.53 vs +1.23, i.e. it starts compressing half a stop *below* mid-grey). The
polynomial-vs-exponential tail difference is real but small until about +16 EV.
**The recommendation does not change, but the reason for it does: `g_m` wins on
parameterisation and cost, not on tail retention.**

**The softplus smooth-min** `f(E) = C − (1/s)\log_2(1+2^{s(C−E)})` is rejected
separately and for a harder reason: `f' = σ(s(C−E)) < 1` **everywhere**, so
there is no exact identity core — only an asymptotically close one (3 stops in,
`s = 1.5`: `f' = 0.989`, a 1.1 % midtone contrast loss compounding across both
sides) — and `f(E_mid) ≠ E_mid` needs a recentring constant. It also breaks
§5.6's bit-exact bypass, which is a requirement rather than a nicety.

The lesson worth keeping: the brief asked for curvature at the progressive ends,
and the tempting move was to reach for a C^∞ function. **What was actually
needed is contact order at one point, plus a parameter to move along the trade.
Global analyticity was never the requirement, and treating it as one is what
produced the wrong argument above.**

### 7.5 The other artifact source, which is not the curve

**The shadow branch is a noise amplifier, and it is placed before the grain
model.** In §6.1, `k` at `E = −7` is `2^(−4.050+7) = 7.7×` — a 2.95-stop lift of
the scene's darkest 0.1 %, applied to RAW data that at −7 EV is close to the
sensor's read-noise floor. Photon and read noise are lifted by the same factor;
`node_grain` then adds film grain *on top of a noisier negative*. This is a real,
predictable consequence that the literature on global TMOs documents and that no
choice of curve family avoids. §14.2 makes it an explicit empirical test.

---

## 8. `ProfileLatitudeDescriptor` — how to measure the medium

### 8.1 The method: probe the shipping pipeline, do not reimplement it

The brief proposes a runtime 1-D neutral ramp through film → negative → paper →
scan, cached, yielding `T(E) = Y_out`. **That is the right method, and the
reason is a repo-specific one rather than a general one.**

The alternative — composing the answer analytically from `density_curves`,
`log_sensitivity`, the print gain and the scan integral — means writing a second
implementation of the chain. This repository has two standing notes about
exactly that failure mode: `parity-drivers-go-stale` (three harnesses graded a
days-old engine green because `build.sh dylib` skipped their drivers) and
`guards-that-cannot-fire` (the repeat defect shape here is a check that cannot
fail). A descriptor computed from a parallel implementation is a guard that will
silently drift from the engine it describes.

**Recommendation: the descriptor is produced by rendering a synthetic neutral
ramp through the real `Pipeline`.** Concretely: a 256×1 (or 1024×1) scene-linear
image whose pixels are neutral at `2^E · n_ref` for `E` on a uniform grid over
`[−12, +12]`, run through the *existing* render with `auto_exposure` off,
Scene Latitude off, and the current film/paper/enlarger parameters; take `Y` of
the result. At 256 px this is free — several orders of magnitude below a single
preview tier — and it is *definitionally* correct because it is the same code
path as the picture.

Two practical requirements the codebase imposes:

- The probe must run with `boost` disabled or at its current setting understood,
  because `node_boost` normalises by `device_max` over the frame and a 256-px
  ramp has a different maximum from a photograph (`film_boost`'s comment
  documents exactly this hazard for strips).
- `profile_state_hash` must cover **everything the render reads**, not just the
  two profile names: enlarger CC/filters, `print_exposure`, DIR couplers,
  `scan_film`, `black_white`, and the engine version — the same hazard as
  `cache-keys-and-the-warm-up-race`.

### 8.2 The metric: slope thresholding is defensible, but there is a better-grounded one

The brief asks whether `d(log Y_out)/dE` thresholding is a defensible definition
of "useful latitude".

**It is defensible but arbitrary in exactly the parameter that matters.** Below,
the shipped profiles' own `density_curves`, measured at several thresholds
(density-domain slope, expressed in scene-stop units on each profile's own
log-exposure axis):

| profile | ch | ≥20 % peak | ≥30 % | ≥50 % | ≥70 % | ISO-range style |
|---|---|---|---|---|---|---|
| `kodak_portra_400` | R | 12.95 | 12.49 | 11.03 | 10.12 | **11.18** |
| | G | 13.31 | 12.13 | 11.13 | 9.48 | **11.07** |
| | B | 13.59 | 12.77 | 11.40 | 10.12 | **11.45** |
| `kodak_ektar_100` | R | 12.31 | 11.49 | 9.67 | 8.66 | 10.34 |
| `kodak_portra_endura` | R | 3.92 | 3.10 | 2.19 | 1.46 | **3.90** |
| | G | 4.19 | 3.56 | 2.28 | 1.46 | **4.10** |
| | B | 3.19 | 2.74 | 2.10 | 1.37 | **3.23** |
| `kodak_endura_premier` | R | 2.83 | 2.37 | 1.82 | 1.19 | 2.75 |

The threshold moves the answer by **3–4 stops** on film and by a factor of
**2.7** on paper. A number that varies that much with an unmotivated constant
should not be the thing a Fit depends on.

**Recommendation: use the sensitometric definition, ISO 6846's ISO range
(§2.11), applied to the end-to-end probe rather than to a single profile.** The
boundaries are the exposures at which the *output* reaches a fixed distance from
its own black and white:

- `useful_highlight_ev` = the `E` at which `Y_out` reaches **90 % of the way
  from `Y_black` to `Y_white`** in the scan's own output units;
- `useful_shadow_ev` = the `E` at which `Y_out` rises to the equivalent of
  **Dmin + 0.04** above black.

Two properties make this better than slope thresholding: the criterion is
**absolute** (a fixed density distance from the medium's own limits) rather than
relative to a peak slope that a wide paper deliberately lowers; and it is the
criterion the medium's own manufacturers publish against, so it is comparable
with `neutral-wide-paper-profiles`' measured 8.5 / 12.0 / 13.5 stop figures.

Alongside it the descriptor should carry the slope-based numbers as
*diagnostics*, because slope is what predicts whether texture survives and
because the two disagreeing is informative.

**A cross-check worth recording.** Composing the two profile tables naively —
paper ISO range 3.90 "paper stops" = 1.174 log₁₀ E, divided by Portra 400's
peak film gamma of 0.199 density/stop — predicts ≈ **5.9 scene stops** for
portra_400 + portra_endura. The measured end-to-end figure in
`neutral-wide-paper-profiles` is **8.5**. The 2.6-stop gap is the film's own toe
and shoulder continuing to carry information after the paper's straight portion
has ended, plus the per-channel offsets. **That gap is the argument for §8.1 in
one number: static composition of profile metadata under-predicts the real
latitude by about 30 %.**

### 8.3 The descriptor is a measurement, never a render parameter

The brief's separation is correct and should be enforced structurally, not by
convention:

```
ProfileLatitudeDescriptor {          // measured, cached, derived
    ev_min, ev_max                   // probe domain
    useful_shadow_ev, useful_highlight_ev
    reference_ev                     // where the medium's mid-scale actually sits
    response[N], slope[N]            // diagnostics + the Fit's raw material
    profile_state_hash
}

SceneLatitudeParams {                // the render state; on the wire; in the edit
    enabled
    norm                             // Y | b | power_norm | max
    ev_film                          // Film Exposure placement
    k_shadow, h_shadow               // RESOLVED, in stops
    k_highlight, h_highlight
    m                                // roll-off order, 2.0 default
}
```

**The wire carries the resolved `K`/`H`, not the pull-backs.** This is not a
detail. If the wire carried `N_h`/`N_s` and the engine derived `K`/`H` from the
descriptor at render time, then **changing the paper would silently change every
existing edit** — precisely the failure §8.3 exists to prevent, arriving by the
back door. The sliders of §9.2 are *UI state*; they resolve to `K`/`H` at
parameter-commit time and the resolved values are what is stored, sent and
rendered. The UI can keep the `N` values alongside for display and for
re-solving when the photographer drags, exactly as an inverse-kinematics rig
keeps its handles.

Changing the paper updates the descriptor and may raise a UI warning ("the
current Scene Latitude was fitted for an 8.5-stop paper; this one is 12.0 —
Fit again?"), and it changes the sliders' legal range and readouts. It **must
not** touch `SceneLatitudeParams`. Only pressing **Fit**, or dragging a slider,
writes them. This is the same discipline as
`product-mode-rides-on-preview-long-edge`: a derived quantity must not be
allowed to become an implicit render input.

---

## 9. The Fit algorithm

### 9.1 The scene statistic

Reuse the existing ~1600 px metering path (`exposure_sample_y`), which already
produces the right sample at the right cost and is already the thing that
defines `E = 0`. Add, in the same pass:

```
SceneHistogram {
    bins[128]          // over E in [-16, +16], quarter-stop bins
    p001, p01, p1, p50, p99, p999
    metered_ev
    mass_above_p99     // fraction of the frame in the top percentile
}
```

using the same rank-by-exact-integer-division discipline as
`exposure_evs_from` (the comment there about `q/100*(n-1)` in floating point
landing one rank low applies verbatim).

Percentiles are a **fit policy**, not a render parameter — the renderer receives
only `SceneLatitudeParams`. Agreed and important: it means a future smarter Fit
cannot change existing edits.

### 9.2 The interaction model — two sliders, in stops, after the subject is set

This is the design constraint the user stated, and it determines the
parameterisation rather than being decorated onto it:

> *After the subject's exposure is decided, the photographer independently
> chooses how far to pull back the highlights and how far to pull back the
> shadows.*

So the render state is **not** a knee and a room. It is:

| control | unit | what it is |
|---|---|---|
| (existing) metering + Exp. Comp. | EV | fixes `E = 0` on the subject. **Nothing below moves it.** |
| **highlight pull-back `N_h`** | stops | how far the scene's top (`P99.9`) is dragged down |
| **shadow pull-back `N_s`** | stops | how far the scene's bottom (`P0.1`) is dragged up |
| **roll-off `m`** | order | how gradually compression begins (§5.5), default 2 |

`K` and `H` are *derived*, never typed. Per side, with `a` the scene extreme
(from the histogram), `C` the medium boundary (from the descriptor), and
`t = a − N` the landing point:

$$\text{solve } K \text{ in } \quad K + g_m(a-K)\big|_{H=C-K} \;=\; t,
\qquad H = C-K$$

- **`m = 1` has a closed form**, and it is the one the first draft was built on:
  `K = t − √((a−t)(C−t))` — the knee sits one geometric mean below the landing
  point. (The quadratic is `K² − 2tK − aC + (a+C)t = 0`.)
- **`m ≥ 2` is a 1-D root find**, and that is fine. `f(a)` is strictly
  decreasing in `K` (verified over the whole range: `K = +2.944 → f(a) = 3.950`,
  `K = 0 → 2.754`, `K = −4 → 0.871`, `K = −10 → −2.06`), so the solve is
  bracketed and bisection cannot fail. Seeded from the `m = 1` closed form,
  Newton converges in two or three steps. **It runs once per parameter commit on
  the CPU — never per pixel, never per tile, never on the GPU.** The first draft
  advertised "no solver" as a virtue; it is not one, and trading it for the
  curvature result in §7.3 is not close.

**The validity rules, which belong in the UI and not only in the solver:**

1. **`N ≥ a − C` per side.** Nothing may be asked to land beyond the medium's
   own boundary. At §6.1 that is `N_h ≥ 3.80`, `N_s ≥ 2.70` — the sliders'
   minimum is set by the paper, and moves when the paper does.
2. **`K_s < K_h`.** The two knees must not cross; the gap between them *is* the
   identity core. Asking for more than the medium has makes them cross (the last
   row of §6.4's table), and the correct response is to refuse and say which
   slider to back off, not to clamp silently.
3. **`H ≥ H_min`** (§7.3), a curvature ceiling.

**What the UI must read out**, because §6.4 showed the controls are misreadable
without it: the **identity core width**, where each extreme **lands**, and the
**slope at each extreme**. "Pull back more" trades core for extremes; a slider
with no readout will be understood as "lose more highlight", which is wrong.

### 9.3 Fit is a suggestion, not a mode

**Fit** reads the histogram and the descriptor and *writes the two sliders*.
After that the photographer owns them. Changing the paper updates the descriptor
— which moves the sliders' legal range and the readouts — but must not move the
sliders themselves (§8.3).

A defensible default policy, and it is only a default:

- `N_h = (a_h − C_h) + margin`, `N_s = (a_s − C_s) + margin` with
  `margin = 0.25` stop — i.e. land each robust extreme a quarter stop inside the
  medium. This is §6.1.
- If that makes the knees cross, spend the deficit proportionally to each side's
  overflow and report it.
- If `a ≤ C` on a side, that side is **off**: the branch is the exact identity
  and the slider reads 0. **This is the degenerate case that matters most** —
  it is what a camera JPEG should produce (§14.7).

Two properties of this family make percentile-driven fitting safe here in a way
it is not for range-mapping approaches:

- **The percentile and the asymptote do different jobs.** `P99.9` decides where
  the *bulk* lands; `C` independently guarantees that everything *beyond* it —
  the sun, the hot pixel, the chrome reflection — also cannot exceed the medium.
  A "map `[P0.1, P99.9]` onto `[floor, ceiling]`" scheme has one parameter doing
  both jobs and must choose which to get wrong.
- **Outliers cannot force compression.** Moving `P99.9` moves `N_h`'s suggested
  value only; it cannot move the ceiling, and the photographer can overrule it.

A "protect speculars" variant that fits against `P99` instead of `P99.9` is
therefore strictly safe, and is the right answer when `mass_above_p99` (§9.1)
says the top percentile is sparse.

### 9.4 Is percentile-based fitting enough for professional use?

Partly. Two known gaps, both worth building the hooks for and neither worth
solving in V1:

- **Specular vs. diffuse highlights.** A scene where the top 2 % is a chrome
  bumper wants a different fit from one where the top 2 % is a white wedding
  dress, and no percentile distinguishes them. `mass_above_p99` is the cheapest
  discriminator (speculars are sparse, diffuse whites are not) and belongs in
  the histogram from day one even if the Fit ignores it in V1.
- **Where the subject is.** Mantiuk's objective weights by *visible* contrast
  over the whole image; a photographer weights by the face. The existing
  centre-weighted metering grid (`exposure_evs_from`'s `sigma = 0.2` Gaussian)
  is already in the codebase and is the obvious first approximation if this
  becomes a complaint.

---

## 10. GPU feasibility

### 10.1 Per-pixel cost

| op | count | note |
|---|---|---|
| `fma` (norm) | 3 | `Y = m·RGB`, or 6 if `b = X+Y+Z` |
| `max`, `isfinite` guards | 3 | §11 |
| `log2` | 1 | hardware, 1 result per cycle per ALU on Apple GPUs |
| `add`, `clamp` | 3 | `E_placed`, domain clamp |
| `select` ×3 + `sub` | 4 | branch choice, `Δ`, `H`, sign |
| `sqrt` | 1 | `r = √(H²+Δ²)`; hardware, or `rsqrt`+`fma` |
| `divide` | 1 | the delta's denominator `r(H+r)` |
| `fma`/`mul` | 5 | `Δ³`, `H²+Δ²`, assembly |
| `exp2` | 1 | hardware |
| `mul` | 3 | `k·RGB` |

≈ **24 ALU ops, three hardware transcendentals, no divergence, no texture reads,
no neighbourhood, no reduction.** Comparable to `spk_tc_b` (9 fma + a divide +
clamps) and far below `spk_spectral_epilogue`'s 81-iteration loop. On the 102 MP
path the node will be **entirely bandwidth-bound**: 12 bytes in, 12 bytes out
per pixel. `m = 1` saves the `sqrt`; a general non-integer `m` costs a `pow`
pair and is the only variant worth measuring before exposing.

### 10.2 Memory

One transient output plane, `alloc_like(in)` — 1.2 GB at 102 MP in float32
RGB, released at the next node under RFC-020's class-P disposal. Given
`rfc020-outcome-confirmed`'s 13.7 GB peak at 102 MP, an additional transient of
this class is within the existing envelope but is **not free**, which leads
directly to:

### 10.3 The version that costs nothing

Because `upsample(k·RGB) = k·upsample(RGB)` exactly (§5.2, §12.2), and because
`spk_tc_b` *already computes and writes* `b`, the entire mapper can be folded
into `spk_lut2d_cubic`'s final line:

```metal
float bv = b[i];
// today:   out = acc * bv;
// enabled: out = acc * bv * k;    where k = exp2(f(log2(bv/b_ref) + ev) - log2(bv/b_ref))
```

**Zero extra passes, zero extra planes, ~12 extra ALU ops on a kernel that is
already bandwidth-bound.** The catch is that it changes a kernel inside the
spectral stage, which is precisely the code the parity harnesses in
`engine/tests/` exist to protect, and it makes the norm choice `b`-only (§5.2's
`Y` recommendation would need `Y` passed alongside `b`, i.e. one more float per
pixel written by `spk_tc_b`).

**Recommendation: ship Option A (a separate `node_scene_latitude` before
`node_upsample`) in V1** — it matches the architecture contract literally, keeps
the spectral kernels byte-identical, and is trivially reviewable. **Record
Option B here as the measured optimisation to take once the curve is settled**,
gated on a parity run and on the memory measurement discipline of
`rfc020-measurement-traps`.

### 10.4 The ramp probe's cost

256×1 px through the full pipeline. Dominated by fixed per-render setup, not by
pixels — which in this engine means `Pipeline::build` and the setup caches
(`open-path-direct-render-verified`'s remaining lever). Cache by
`profile_state_hash`; recompute on profile, enlarger or engine-version change.
It must not run on the interactive path uncached.

---

## 11. Numerical safety

The governing rule, and it is stronger than "produce something sensible":

> **The Scene Latitude node must never change what the existing pipeline does
> with a pathological pixel. It either applies a finite positive gain, or it
> applies exactly 1.0.**

That rule makes every edge case answerable without colour-science argument,
because `k = 1` is provably a no-op on a path that already handles the pixel
some way.

| condition | behaviour |
|---|---|
| `n ≤ 0` (includes all-negative RGB) | `k = 1`. The pixel reaches `spk_tc_b` exactly as it does today, and today's `denom > 1e-10` guard and `clamp(tx,ty)` handle it. |
| `0 < n < n_floor` (`n_floor = n_ref·2^-24`, i.e. −24 EV) | **Superseded by §15.5.** Clamping `E` and evaluating the branch hands the noise floor the *largest* gain the curve can produce — measured at 2²¹ on a real frame, and visible as blue speckle. The gain is bounded instead: `d ← g_m(d, L_max)`, `L_max` a parameter in stops (default 4), applied through the same smooth-min so the curve stays C¹ and relaxes to slope 1. `k ≤ 2^{L_max}` by construction. |
| `n = NaN` | `k = 1`. Detect with `n == n` (survives fast-math better than `isnan`, and the codebase already had to reason about exactly this — see the `isnan` note in `spectral.hpp`). |
| `n = +Inf` | `k = 1`. **This case must be special-cased, not left to the maths**: `E = +Inf → f = ceiling → k = 2^(C−Inf) = 0`, and `Inf × 0 = NaN` would inject a NaN into the spectral stage. |
| any RGB component NaN/Inf, `n` finite | `k` is still finite; the bad component stays bad and reaches the same downstream handling as today. Do not "repair" it here. |
| extreme `EV_film` (±30) | `E_placed` is clamped to `[−24,+24]` before `f`. The clamp is on the *placed* value, so a large Film Exposure saturates rather than wrapping. |
| `k` itself | `k = clamp(k, 2^-30, 2^30)` as a final belt-and-braces, so no arithmetic below can see a denormal or an overflow. |

### 11.2 Negative scene-linear RGB — do **not** clamp

The brief asks whether clamping negatives before computing `n` would alter
colour science undesirably. **It would, and worse, it would do so invisibly.**
Negative components after the camera matrix and white balance are real
out-of-gamut information, and `spk_tc_b` currently receives them and resolves
them through the chromaticity clamp. Clamping them in a new upstream node would
change the rendering of every saturated colour in every image, silently, as a
side effect of a tone control.

Two acceptable policies:

1. **Guard only the scalar** (recommended): `n = norm(max(RGB, 0))` for the
   purpose of computing `k`, leave `RGB` itself untouched, and apply `k` to the
   original signed triple. `k` is a positive scalar, so signs and ratios are
   preserved exactly and the downstream behaviour is unchanged in kind.
2. **darktable's desaturation** (`_desaturate_negative_values`, §3): rotate the
   triple toward its own achromatic mean just far enough to make the minimum
   zero, preserving the mean. Mathematically nicer, but it *does* change the
   pixel, so it must be a named, off-by-default option and must be evaluated
   against the spectral upsampler's existing behaviour, not assumed better.

---

## 12. Architecture contract

### 12.1 Can it be an optional pre-film transform with the film model untouched? — **Yes, and provably.**

**Disabled path — unchanged, byte for byte:**

```
decode → geometry → auto_exposure → [crop/pitch] → upsample → exposure → boost → …
```

Nothing is reordered, no kernel is edited, no parameter default changes. The
gate is a single `if (!params.scene_latitude.enabled) { out = in; return true; }`
in the new node, the same shape as `node_edr`, `node_boost` and
`node_dir_couplers` already use. This should be verified the way this repo
verifies such things: **the hash of every un-striped render is byte-identical
across the change**, exactly as `film_prefix`'s seed hoist was.

**Enabled path:**

```
… auto_exposure → scene_latitude (carries EV_film) → upsample → exposure (identity) → …
```

**`node_exposure` is unchanged and still applies Exp. Comp.** — §15.4 measured
why it has to: `printing.cpp:168` reads the same parameter to re-time the
enlarger, so emptying it would stop the print compensating and change the
picture. The mapper is inserted *before* `upsample` and carries no `EV_film`.

### 12.2 The reorder is not a reorder

The brief treats moving Film Exposure across `upsample` as a deliberate
asymmetry to be accepted. It is milder than that. For any positive scalar `k`:

$$\text{upsample}(k\cdot RGB) = k\cdot \text{upsample}(RGB)$$

because `tc` is a function of chromaticity alone and the output is
`acc(tc)·b` with `b` linear in `RGB`. So "apply `2^{EV}` before upsample" and
"apply `2^{EV}` after upsample" are the *same function*, and the enabled path's
placement of Film Exposure is an algebraic identity rather than a change of
model.

**Exact conditions, because this identity is load-bearing and has two holes:**

1. `spk_tc_b` computes `denom = max(b, 1e-10)`. If `b` and `k·b` fall on
   opposite sides of `1e-10`, chromaticity differs. This affects only pixels
   below ~10⁻¹⁰ in `b` — far under `n_floor` — and §11 routes those to `k=1`
   anyway.
2. `tx, ty` are `clamp(·, 0, 1)`. The clamp is on chromaticity, which is
   scale-invariant, so it is unaffected. ✔
3. Float32 rounding: `k·(acc·b)` and `acc·(k·b)` differ in the last ulp. So the
   enabled path is *mathematically* but not *bitwise* identical between
   placements — which matters only if Option B (§10.3) is adopted, and then the
   comparison is against the enabled path, not the shipped one.

### 12.3 There is already a node of exactly this shape in this engine

`spk_edr` (`engine/src/shaders/nodes.metal:344`):

```metal
float y = max(p[0]*r + p[1]*g + p[2]*b, 0.0f);
float toe = p[5], shoulder = p[6];
float mapped = y;
if (y > 0.0f && (y < toe || y > shoulder)) {
    float u = clamp((log2(y) - p[3]) * p[4], 0.0f, 1.0f) * float(count-1u);
    ...
    mapped = exp2(mix(lut[i0], lut[i0+1u], t));
}
float scale = mapped / (y + 1e-10f);
out = rgb * scale;
```

A scalar luminance; **identity between a toe and a shoulder**; a curve in
`log2` applied only outside that window; `RGB` rescaled by
`mapped/y`. That is the model of §5, already shipped, already validated, on the
*other* side of the pipeline.

Three things follow:

- The architecture is not novel for this codebase and carries no new risk class.
- `EdrToneMap`'s profile schema (`domain_log2_y`, `toe_y`, `shoulder_y`,
  `target_log2_y[]`, `version`) is the template for `SceneLatitudeParams` and for
  the descriptor's serialisation, including its validation in
  `profile.cpp:140–160`.
- **A LUT is a legitimate research vehicle and a poor V1.** `spk_edr`'s shape —
  a small `log2`-domain LUT with a lerp, built on the CPU from whatever curve is
  current — gives complete freedom to change the curve without touching a
  kernel, which is worth a great deal while `m` and the norm are still open. But
  it **breaks §5.6's bit-exact identity core**: a lerp between two quantised
  entries does not return a literal `0.0f`, so "the midtones are untouched"
  degrades from a fact to a tolerance, and the disabled-vs-enabled-at-defaults
  comparison stops being a hash check. Use the LUT to explore, ship the closed
  form. §14.1.

### 12.4 EDR stays separate

Scene Latitude (before film, fits scene into medium) and EDR (after scan,
exploits display headroom) must not be merged, must not share parameters, and
must not be co-fitted. They can both be on: Scene Latitude compresses 15 stops
into the paper, the paper renders it, and EDR then re-expands the *print's*
highlights into display headroom. That is a print under a brighter light, which
is a coherent thing; it is not an undo of the compression and must not be
presented as one.

---

## 13. Rejected alternatives

**13.1 Any display-referred sigmoid placed before the film** (Reinhard, Drago,
Hable, ACES, AgX, darktable `sigmoid`). Two shoulders in series, two opinions
about midtone contrast, no expressible identity. §2.

**13.2 Per-channel application, or application in a perceptual space (JMh,
IPT).** ACES 2.0 applies its tone scale to `J`; AgX applies per channel with
primary inset. Both exist to control hue and saturation behaviour *because they
are the last transform before a display*. Here the last word on colour belongs
to three measured density curves and a spectral integral. A ratio-preserving
scalar is the only placement that leaves that word with them. (It has a known
cost — darktable documents it: bright saturated pixels desaturate along
spectral lines — and §5.2 argues that cost is the film's to pay, not ours to
pre-empt.)

**13.3 Local / neighbourhood operators** (Durand & Dorsey, Reinhard's local
half, Mantiuk's full QP). Correct for the hardest part of the problem,
incompatible with the pointwise/no-intermediate constraint, and a much larger
change. §14.3.

**13.4 Widening the paper — RFC-022 and the `neutral_wide_*` morphs.** The
premise is superseded, **the findings are not.** `neutral-wide-paper-profiles`
measured the trade exactly: 8.5 → 12.0 stops costs 24 % of mean C\*ab, and
8.5 → 13.5 costs 33 %, "and the chroma loss is not uniform (skin keeps 51 %,
blue 83 %), so a global saturation slider will not undo it." That is the
quantitative case for attacking the scene instead of the medium, and it is
RFC-022's own data. What survives and stays valuable:

- a wide paper remains a legitimate *material* choice, and the descriptor
  (§8) is what finally makes choosing one an informed decision rather than a
  taste test;
- Scene Latitude and a wide paper **compose**: with a 12-stop medium the
  identity core grows from 6.1 to 10.2 stops (§6.2), so a photographer who
  accepts the chroma cost gets a dramatically gentler curve. These are not
  competing solutions.

**13.5 Baking the compression into film or paper profiles.** Violates
`engine = process / profiles = materials / photographer = decisions`, is
unauditable, and cannot adapt to the scene. Explicitly out, and this RFC exists
partly to make sure it stays out.

**13.6 Fitting a spline through constrained nodes** (filmic's approach). More
expressive, needs monotonicity repair, and has no closed-form fit. Revisit only
if §14 finds the two-branch model genuinely insufficient, and if so, prefer a
monotone Hermite (Fritsch–Carlson) over an unconstrained fit.

**13.7 Normalising the log axis into `[0,1]` over the scene's dynamic range**
(AgX's and filmic's construction). This is the specific thing the user ruled out
as "log-domain input", and it is ruled out for a concrete reason, not a stylistic
one: it makes the curve's *shape* a function of the assumed dynamic range, so
re-estimating the scene's range changes how the midtones render. On an absolute
EV axis, widening the medium or re-metering moves the knees and leaves every
untouched stop untouched. §5.6.

**13.8 `tanh`, exponential saturation, and the softplus smooth-min.** Measured
against `g_m` at an equal landing point in §7.4. `tanh` is *not* rejected on
quality — it is a legitimate curve that happens to sit at one fixed point of the
same trade, a little past `m = 3`, and costs an `exp`; `g_m` is preferred
because `m` spans the whole trade including the wide-core end. Exponential
saturation is the strongest row in that table and is rejected purely for having
a curvature step. Softplus is rejected on the hard grounds: no exact identity
core, and it breaks §5.6's bit-exact bypass. Recorded here because "use a
smoother function" is the obvious response to "the curve must not be mechanical"
and it is the wrong one — what was needed is contact order at one point plus a
parameter, not global analyticity.

**13.9 Placing the mapper after `node_exposure` instead of before `upsample`.**
Algebraically identical (§12.2), so this is a code-organisation question, not a
model question — and Option A wins it because it keeps the spectral kernels
untouched. §10.3.

---

## 14. What must be tested, because literature cannot settle it

**14.1 Closed form vs. LUT.** The closed form is recommended and §5.6 makes the
case structural: in the core the kernel returns a literal `0.0f` delta, so
`k = exp2(EV_film)` is bit-for-bit today's `node_exposure` gain and
"enabled-at-defaults renders identically to disabled" is a **hash check**, not a
tolerance. A LUT cannot give that. Use a LUT while `m` and the norm are open,
then verify the hash against the closed form before shipping.

**14.1b What `m` should default to.** §1's table is arithmetic; which point on
it looks right on skin, sky and a studio backdrop is not. The sweep to run is
`m ∈ {1, 1.5, 2, 3}` at a *fixed landing point*, so what is being judged is the
transition and the core width rather than the overall strength. The prediction
from §7.3 is that `m = 1` will show a visible turn on a smooth gradient and
`m = 2` will not; if `m = 3` is preferred, the finding is that photographers
value tail texture over core width more than this document assumes, and the
default should move.

**14.2 Shadow lift and noise.** §7.5. Render the same RAW at several shadow
knees and measure noise in the lifted region *after* `node_grain`, against the
ungraded reference. The open question is not whether noise rises — it must —
but whether film grain masks it (plausible; grain is a multiplicative-ish
texture at the same spatial scale) or compounds with it. **This is the single
most likely reason V1 would need a shadow-side slope floor.**

**14.3 Whether a global curve is enough at 15 → 8.5.** §6.4 and §6.5 show the
two sides competing for one budget: at that ratio you can have a wide identity
core or graded extremes, not both. The literature's answer to this exact
impasse is local tone mapping (Durand & Dorsey; Reinhard's local half;
Mantiuk's visibility weighting), and the codebase already has an independent
observation pointing the same way — the note that ACR's Highlights/Shadows
"out-pull the app's" because of the "global curve vs. local operator" gap
(`layer2-exposure-clips`). **Expect V1 to be a large improvement and not a
complete answer, and do not respond to the shortfall by over-compressing the
curve.**

**14.4 The knee's visibility.** §7.3 predicts this is now settled — at `m = 2`
the mapper's worst curvature is 26 % of the film's own — but a prediction about
Mach banding is not a measurement of one. Test on smooth gradients (sky, skin,
studio backdrop, an out-of-focus wall) across the `m` sweep of §14.1b and across
`H` down to the `H_min` floor. **The specific thing to look for is a band at the
knee position, not general flatness**; flatness in the extremes is §7.1 and is
expected.

**14.5 The norm.** `Y` vs `b` vs power norm vs `max`, on frames with saturated
highlights — stage lighting, neon, sunset, a red dress in sun. §5.2 argues `Y`
on consistency grounds and argues the failure mode is the film's to handle; that
argument is sound but is not evidence.

**14.6 Where `reference_ev` actually is.** §8 assumes the medium's mid-scale can
be located on the probe. `midscale_neutral_density` exists in every profile and
may make this exact rather than fitted. Worth settling before the Fit's
`margin` semantics are frozen, because everything in §9 is measured from it.

**14.7 The JPEG path.** Once Scene Latitude exists, the JPEG's baked-in camera
curve becomes a *second* compression in series. Measure it: run the same scene
as RAW and as camera JPEG with Fit applied to each, and check whether the JPEG
now needs Scene Latitude off, or whether the descriptor-driven Fit correctly
detects that the JPEG already fits and returns something close to the identity
(§9.2's degenerate case). **If the Fit does return near-identity for JPEGs
unprompted, that is the strongest possible validation of the whole design**, and
it is the direct answer to the observation this RFC started from.

---

## 15. Measured, on a real frame

**Everything above this section was arithmetic and literature. This section is
what happened when the design was run on a photograph, and three of its claims
did not survive.**

### 15.1 Method

`_DSC8683.NEF` — a night flash portrait, 50 MB, the hard case on purpose:
flash-lit subject against a park that falls away into noise.

No engine code was changed to measure this. `spk_open` already takes a
scene-linear float32 `(H, W, 3)`, and §12.2 proves that a per-pixel scalar
applied before `upsample` is the same function as a node would be — so the curve
was applied in numpy and both images were rendered through the **shipping
dylib** via `engine/tests/spk_ctypes.py`.

- `rfc/probes/rfc023-decode-raw.swift` — `CIRAWFilter` configured exactly as
  `ImageDecoder.rawFilter(look: .linear)` does (`boostAmount = 0`,
  `boostShadowAmount = 0`, gamut mapping off, `localToneMapAmount = 0`,
  `extendedDynamicRangeAmount = 0`), rendered to float32 **linear ProPhoto** at
  2048 px long edge. 1366 × 2048.
- `rfc/probes/rfc023-slm-probe.py` — the metering, the curve, the norms, the
  medium probe and the PNG writer.
- Metering reproduces `Pipeline::legacy_exposure_ev(center_weighted)` and was
  **checked against the engine's own auto-exposure render**: max 157 counts of
  65535, which is *smaller than the engine's own render-to-render spread* (1569
  counts between two consecutive renders of identical parameters, grain off).
  Every variant below therefore runs with `auto_exposure: false` and the same
  measured gain, so the only difference between them is the curve.

Metered scene, in stops relative to mid-grey after the meter's +1.506 EV:

| P0.1 | P1 | P5 | P50 | P95 | P99.9 | P100 |
|---:|---:|---:|---:|---:|---:|---:|
| −10.34 | −6.98 | −5.06 | **−2.57** | +1.79 | +2.71 | +5.27 |

3.28 % of pixels have `Y ≤ 0`. Note the median at **−2.57 EV**: this frame's
problem is almost entirely the shadow side, and the highlight side will turn out
to be nearly a no-op — which is itself a test (§15.7).

### 15.2 The medium probe works, and the medium is much narrower than assumed

§8.1's neutral ramp, run through the real pipeline (512 × 16 px, auto-exposure
and grain off), `kodak_portra_400` + `kodak_portra_endura` at shipped defaults:

```
E:   -6      -4      -3      -2      -1       0      +1      +2      +3      +4
Y: .00450  .00553  .00821  .01919  .06320  .18351  .38407  .58735  .67478  .69960
```

`Y(0) = 0.18351` — mid-grey prints as mid-grey, which is the first sanity check
and it passes. White is 0.7051, black 0.00443, a 159:1 print.

| criterion | window | stops |
|---|---|---:|
| ISO 6846 (`Dmin+0.04` … `0.90·Dmax`) | **[−3.18, +2.49]** | **5.66** |
| slope ≥ 30 % of peak | [−6.93, +1.57] | **8.50** |
| slope ≥ 20 % of peak | [−11.06, +2.00] | 13.06 |
| slope ≥ 50 % of peak | [−3.17, +0.82] | 3.99 |

**Two results here, and both were predicted by §8.2 but not their size.**
The slope criterion moves the answer by **9 stops** across the range of
plausible thresholds — and `slope ≥ 30 %` reproduces the **8.50** in
`neutral-wide-paper-profiles` *exactly*, which identifies the criterion that
earlier measurement used and confirms the two are measuring the same engine.
The ISO criterion, which is the one §8.2 recommends because it is absolute, says
**5.66 stops**. That is the number the Fit should use, and it is 2.8 stops
tighter than the figure this project has been working from.

The window is also **asymmetric**: 3.18 stops below mid-grey, 2.49 above. Not
something to guess at — the probe is the only way to know it.

*(Correction: the first pass of this measurement had the ISO criterion
backwards — applying the 0.04 to the shadow end and 90 % to the highlight end —
and produced [−4.86, +2.40]. The boundary that matters, the shadow one, was
1.7 stops too generous.)*

### 15.3 §12.2's identity is confirmed on the shipping engine

The load-bearing claim — that a scalar before `upsample` and the same scalar
after it are the *same function* — is directly testable, because
`exposure_compensation_ev` is applied after `upsample` today. With
`io.scan_film: true` (the negative, no print):

| | Y(−2 EV) | Y(0) | Y(+2 EV) |
|---|---:|---:|---:|
| `exposure_compensation_ev = −2` | 0.26869 | 0.14613 | 0.07980 |
| input pre-multiplied by 2⁻² | 0.26869 | 0.14613 | 0.07980 |
| `exposure_compensation_ev = +2` | 0.07980 | 0.04393 | 0.02385 |
| input pre-multiplied by 2⁺² | 0.07980 | 0.04393 | 0.02385 |

Not "close" — `np.array_equal` over the whole frame. **The reorder is an
algebraic identity, measured, not merely argued.**

### 15.4 But Film Exposure has a second consumer, and §5.1 and §12.1 were wrong

On the **print** path the same test gives the opposite answer:

| | Y(0) via `exposure_compensation_ev` | Y(0) via input gain |
|---|---:|---:|
| −2 EV | 0.17332 | 0.01862 |
| 0 EV | 0.17563 | 0.17563 |
| +2 EV | 0.17309 | 0.58430 |

Exposure compensation does essentially nothing to the print's mid-grey, while
the identical gain on the input moves it by the full amount.

The cause is `engine/src/core/printing.cpp:168`. `print_constants` reads
`params.camera.exposure_compensation_ev` **directly** and computes the
enlarger's gain from a mid-grey shifted by it:

```cpp
density_spectral_for(kMidgray * std::pow(2.0, params.camera.exposure_compensation_ev),
                     out.density_spectral_midgray_comp);
```

With `print_exposure_compensation = true` and `normalize_print_exposure = true`
— both hard-coded defaults in `params.hpp:151-152`, **neither on the wire**, and
both cleared only in `lut_mode` — the enlarger re-times the print for the film
exposure. That is correct darkroom behaviour and it is deliberate: changing film
exposure changes *where the scene sits on the film's curve*, and you re-time the
print. It is not a bug.

**It does make §5.1 and §12.1 wrong as written.** They say `EV_film` folds into
the mapper's `k` and `node_exposure` becomes the identity. Do that and
`printing.cpp:168` sees `exposure_compensation_ev = 0`, the enlarger stops
compensating, and the picture changes — the mapper would silently acquire a
brightness control that Exp. Comp. does not have today.

**The correction:** `exposure_compensation_ev` stays exactly where it is, on the
wire and in `node_exposure`, and **Scene Latitude does not carry it.** `E` is
then measured *after* auto-exposure and *before* Exp. Comp., and the mapper's
knees are positions on that axis. If a future version wants `EV_film` inside the
mapper, `printing.cpp` has to be told about it in the same change — and that is
a change to the print model, which this RFC is not allowed to make. §5.1's
`E_placed = E + EV_film` therefore reduces to `E_placed = E` for V1, and
§5.6's bit-exact bypass becomes simply `δ = 0 → k = 1`.

### 15.5 The shadow gain is unbounded — the design flaw the render found

`f` maps `E → −∞` onto a finite floor, so `k = 2^{f(E)−E} → ∞`. That is inherent
to "compress the shadows into a floor", and §11 made it worse by specifying
"clamp `E` at −24 and evaluate the branch there": **the clamp receives the
maximum possible gain.**

Measured on this frame, shadow pull-back 4.05 stops, `norm = Y`, no limit:

```
k: median 1.41   P99.9 83,260   max 1,880,716      <- 21 stops of gain
```

and it is visible. **Blue speckle through the hair and the skirt**, over a
render that is otherwise fine. The mechanism, measured: 0.14 % of pixels have
`max(RGB)/Y > 8` — near-zero `R` and `G` with a positive `B`, which is what RAW
noise looks like after the camera matrix. `Y` under-reports exactly those
pixels, so they receive the largest gain, and the gain is applied to all three
channels, so what comes out is saturated blue.

**Two fixes, both needed, both measured:**

1. **Bound the lift with the same smooth-min.** `d ← g_m(d, L_max)` where `d` is
   the delta and `L_max` the maximum lift in stops. Because `g_m` is the same
   operator, the curve stays C¹ and simply relaxes to slope 1 once the gain
   reaches the limit — it does not clip, and `f` stays monotone
   (`f' = 1 + g_m'(d)·(f'_unbounded − 1) ∈ [f'_unbounded, 1]`). At
   `L_max = 4` stops: `k` max **1,880,716 → 15.1**.
2. **A norm that does not collapse on a one-channel pixel.** On the speckle set,
   the median gain by norm: `Y` 216,385 · mean-of-clipped 68.99 · **power norm
   24.56** · `max(RGB,0)` 24.47. The power norm and `max` agree to three
   figures and are 10⁴ below `Y`.

The limit alone removes the visible speckle; power norm + limit is cleanest and
is what §15.6 uses. **This is the reverse of §5.2's prediction**: that section
argued for `Y` and said the only real objection was a saturated *highlight*
escaping. The failure is at the *shadow* end, it is worse than predicted, and it
is not the film's to absorb — the film never sees a sensible triple.

`SceneLatitudeParams` therefore gains one field, `max_lift_stops` (default 4),
and §11's floor rule is replaced: **`k` is bounded by construction, not by a
clamp on `E`.**

### 15.6 With those two fixes: yes, it is better

Shadow pull-back, power norm, `L_max = 4`, `m = 2`, highlight side off. Crop
means in L\*, and detail as the standard deviation of log₂ Y in stops:

| variant | `N_s` | `K_s` | face L\* | face sd | jacket L\* | **background L\*** | bg sd | untouched |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| baseline | — | — | 55.54 | 2.756 | 77.05 | **19.28** | 1.110 | 100 % |
| land P5 | 2.13 | −1.05 | 55.69 | 2.500 | 77.09 | **20.52** | 0.896 | 24.0 % |
| land P1 | 4.05 | −0.21 | 55.83 | 2.421 | 77.14 | **22.37** | 0.906 | 22.0 % |
| land P0.1 | 7.41 | +0.94 | 56.25 | 2.339 | 77.28 | **26.15** | 0.981 | 15.2 % |

The subject does not move — face L\* 55.54 → 55.83, jacket 77.05 → 77.14 — while
the background opens by 3.1 L\* and the grass, the bridge rail, the water and
the far trees acquire real texture. No banding, no colour cast, no halo, and the
film grain covers the lifted noise rather than compounding with it, which
resolves §14.2's open question **in the favourable direction for this frame**.
`land P0.1` is visibly too much: at `K_s = +0.94` the knee has climbed above
mid-grey and the picture starts to go flat.

**A control worth having run.** The alternative a photographer has today is to
push exposure. Measured at +1.0 and +1.5 EV of Exp. Comp., the print barely
moves at all (face 55.54 → 55.96 → 55.54, background 19.28 → 19.23 → 18.55) —
for the reason §15.4 found. **Exp. Comp. cannot do this job, by design, and
Scene Latitude is not a re-invention of a control that already works.**

### 15.7 Three things that behaved exactly as specified

- **The highlight side is nearly a no-op, correctly.** `P99.9 = +2.71` against a
  `+2.49` boundary is 0.22 stops of overflow, so Fit asks for `N_h = 0.47` and
  **91.9 % of the frame is left at `k = 1` exactly**. §9.3's degenerate case,
  working.
- **Both validity rules fired on real inputs.** A pull-back below the material
  minimum was refused (`N_s = 2.03` would land at −4.95, past the −3.18
  boundary — §9.2 rule 1), and `m = 3` at the same pull-back crossed the knees
  (`K_s = +1.62 > K_h = +0.91`, core −0.71 — rule 2) and rendered a picture that
  compresses everywhere. Neither rule is theoretical.
- **The `m` sweep changes the picture, but not in the way §7.3 expected.** At
  `m = 1`, 2 and 3 with the same pull-back, **no knee, band or turn is visible
  anywhere** — not on the jacket, not on skin, not on the water gradient. §14.4
  predicted the `m = 1` curvature step might show; on this frame it does not.
  What `m` visibly changes is how far the dark areas open (background L\* 20.10
  / 22.37 / 24.25 for `m` = 1 / 2 / 3), i.e. the core-width trade of §5.5 and
  not smoothness. **`m = 2` remains the recommendation, but the argument for it
  is now the trade, not the artifact.** One frame is not a proof; §14.4's test
  stands, on gradients chosen for the purpose.

### 15.8 "Untouched" is a node guarantee, not a picture guarantee

§5.6 promises the identity core is bit-exact. It is — at the node. **The
rendered picture is not**, because halation and the DIR couplers are spatial:
lifting the shadows moves pixels the node left at exactly `k = 1`.

Difference in output counts (of 65535) over pixels with `k == 1` exactly:

| | median | P90 | P99 | P99.9 | max | > 64 counts |
|---|---:|---:|---:|---:|---:|---:|
| highlight pull-back 0.47 st | **0** | **0** | 11 | 66 | 44003 | 0.10 % |
| shadow pull-back 4.05 st | 4 | 75 | 265 | 931 | 2843 | 11.9 % |

For the highlight case **90 % of core pixels are bit-identical**; the max is a
handful of pixels immediately beside a specular. For a 4-stop shadow lift the
core moves measurably, though by ≤ 0.1 % of full scale for 90 % of it.

The carriers were identified by switching them off one at a time (max count
difference in the core, highlight case): all defaults 44003 → glare off 43985 →
halation off 22113 → couplers off 27283 → **halation + couplers + glare off
6685**.

**This does not weaken the architecture — it names the claim correctly.** The
node is pointwise and its bypass is exact; the *film model* has spatial
coupling, which is the product. The UI must not promise "your midtones will not
move"; it should promise "the curve does not touch them", and the difference is
one halation radius wide.

### 15.9 What the experiment changed in this document

| § | claim | status |
|---|---|---|
| §12.2 | pre- and post-`upsample` scalars are the same function | **confirmed**, bit-identical on the negative (§15.3) |
| §8.1 | probe the shipping pipeline, do not compose metadata | **confirmed**, and the criterion moves the answer 9 stops (§15.2) |
| §8.2 | use ISO 6846's absolute criterion | **confirmed**; the real window is 5.66 stops, not 8.5 (§15.2) |
| §5.1, §12.1 | `EV_film` folds into the mapper; `node_exposure` becomes identity | **wrong.** `printing.cpp:168` is a second consumer (§15.4) |
| §5.2 | `Y` is the right norm; the risk is a saturated highlight | **wrong end.** The failure is a one-channel *shadow* pixel (§15.5) |
| §11 | clamp `E` at −24 and evaluate the branch | **wrong.** That hands the noise floor a 21-stop gain (§15.5) |
| §7.3, §14.4 | the `m = 1` curvature step may be visible | **not observed** on this frame (§15.7) |
| §5.6 | the identity core is bit-exact | **true at the node, not in the picture** (§15.8) |
| §14.2 | shadow lift vs. grain — does noise compound? | **grain covered it**, on this frame (§15.6) |

---

## 16. Colour response — measured, and it is the opposite of RFC-022's trade

The question this section answers: **for a photographer who cares about
latitude, is this a gain or a loss in colour, and where?** RFC-022's answer for
a wide paper was a measured loss. This one is a measured gain, and the reason is
structural rather than lucky.

### 16.1 The film has a colour window, and it is narrower than its tonal window

The same chromaticity, taken from the real frame and placed at different scene
exposures through the shipping pipeline. C\*ab of the rendered print:

| scene EV | −5.0 | −4.0 | −3.0 | −2.0 | −1.0 | **−0.5** | 0.0 | +1.0 | +2.0 | +3.0 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **skin** C\* | 1.6 | 1.1 | 3.9 | 14.1 | 22.3 | **24.5** | 23.7 | 21.2 | 14.2 | 5.3 |
| **foliage** C\* | 1.5 | 0.9 | 1.9 | 12.1 | 29.1 | 38.5 | 47.0 | **56.1** | 51.8 | 35.7 |
| **flower** C\* | 1.6 | 1.1 | 2.3 | 8.6 | 12.8 | **14.6** | 13.6 | 11.8 | 7.4 | 2.4 |
| (L\* for reference) | 4.3 | 5.0 | 7.2 | 15.0 | 28.7 | 37.9 | 47.4 | 66.0 | 79.7 | 85.5 |

**Below about −3.5 EV every colour renders at C\*ab ≈ 1.7 — that is, as a
grey.** Not "desaturated": gone. The toe of a negative has no colour to give,
and neither does the paper below its own toe.

Taking 50 % of each patch's peak as the boundary, the **colour window is roughly
4.2–4.4 stops** against the 5.66-stop tonal window of §15.2. **A film's colour
latitude is narrower than its tonal latitude**, which is a fact about the
medium, not about this RFC, and it is the single most useful thing the probe
measured.

### 16.2 What Scene Latitude does to colour, on the real frame

Shadow pull-back 4.05 stops, power norm, `L_max = 4`, `m = 2`. Patch means in
CIELAB (D50):

| patch | baseline L\*, C\*ab | after L\*, C\*ab | **ΔC\*** | Δhue |
|---|---|---|---:|---:|
| **skin** | 57.15, 22.18 | 57.29, 22.36 | **+0.8 %** | **0.0°** |
| foliage | 11.48, 7.53 | 15.80, 13.38 | **+77.8 %** | −3.6° |
| hair | 29.22, 12.29 | 31.11, 15.39 | +25.3 % | −1.9° |
| flower | 40.37, 10.31 | 41.91, 12.76 | +23.8 % | +2.6° |
| jacket (near-neutral) | 64.54, 6.56 | 65.26, 7.63 | +16.4 % | −3.8° |

**Chroma goes up everywhere it moves, and skin does not move at all** — skin sat
inside the identity core, so it is preserved to +0.14 L\*, +0.8 % C\*, 0.0° of
hue. §16.1 says why the shadows gain: they were sitting at −4 to −6 EV where the
film has no colour, and the curve put them back inside the window.

### 16.3 The control: is this the film's colour, or invented colour?

The obvious objection is that a gain applied in the shadows might be
manufacturing saturation. It is not, and the test is direct: expose the **whole
frame** up until the foliage reaches the same lightness the curve gave it
(+0.48 EV), and compare at matched L\*.

| patch | SLM vs. baseline | **SLM vs. the correctly-exposed control, at matched L\*** |
|---|---|---|
| foliage | +4.32 L\*, +77.8 % C\* | **+0.00 L\*, +1.1 % C\*, −0.2° hue** |
| skin | +0.14 L\*, +0.8 % C\* | −7.41 L\*, +9.0 % C\*, −1.2° |
| hair | +1.89 L\*, +25.3 % C\* | −2.68 L\*, +24.1 % C\* |

**The foliage lands within 1.1 % of chroma and 0.2° of hue of the same region
exposed correctly in camera.** The colour Scene Latitude produces in the shadows
*is* the film's colour at that exposure — it is not a saturation effect applied
afterwards, and there is no separate grade to un-do. That follows from the
architecture: the node only changes *where on its own characteristic curve* a
pixel lands, and everything after it is untouched physics.

The skin row is the same statement read the other way: the control had to lift
the whole frame, so it took skin 7.4 L\* too bright. **Scene Latitude buys the
shadow's colour without spending the subject's exposure.** That is the thing a
global exposure change cannot do, and it is the product argument.

### 16.4 Against RFC-022's wide paper — the same goal, opposite sign

| | tonal latitude | chroma | hue | skin |
|---|---|---|---|---|
| `kodak_portra_endura` (measured paper) | 8.5 st (slope criterion) | 100 % | — | — |
| `neutral_wide_060` | 12.0 st | **−24 %** | — | — |
| `neutral_wide_050` | 13.5 st | **−33 %**, non-uniform | — | **keeps 51 %** |
| solved neutral profiles (RFC-022) | 13.0 st | max C\*ab 1.52 → 0.30 | **red −26°, blue −14.8°** | — |
| **Scene Latitude (this RFC)** | medium unchanged | **+16 % … +78 %** where it acts | **≤ 3.8°** | **+0.8 %, 0.0°** |

The two approaches move in opposite directions on colour because they act in
different places:

- **A wide paper lowers the paper's gamma.** Lower gamma is less chroma, and it
  is less chroma *everywhere* — including in the midtones and on skin, which
  were not the problem. `neutral-wide-paper-profiles` recorded that the loss is
  non-uniform (skin keeps 51 %, blue 83 %) so a global saturation slider cannot
  undo it.
- **Scene Latitude moves the scene, not the medium.** The medium keeps its
  gamma, its Dmax, its colour. What changes is which part of the film's own
  curve a given part of the scene sits on — and the shadows were sitting where
  the film is colourless.

**For a photographer chasing latitude, this is the better trade, and not
marginally.** The wide paper buys 3.5–5 extra stops of tone by spending a
quarter to a third of the colour. Scene Latitude buys the same kind of shadow
opening by spending the *width of the untouched core* (§6.4, §15.6) and gains
chroma in the region it touches.

### 16.5 What it does cost, stated plainly

Nothing here is free, and three costs are real:

1. **The identity core narrows.** On this frame, 22 % of the picture is left at
   `k = 1` exactly at a 4.05-stop pull-back. Everything else has been moved
   along the film's curve — correctly, but moved.
2. **Local contrast in the compressed region falls**, because that is what
   compression is. Measured: background detail spread 1.110 → 0.906 stops. The
   region gains colour and lightness and loses *contrast*; §7.1 is the general
   statement and §14.3 is the honest limit.
3. **Hue drifts by up to ~3.8°** where the curve acts (the near-neutral jacket
   is the worst case, which is expected: a near-neutral has a long hue lever).
   That is an order of magnitude below RFC-022's solved profiles (−26° on red)
   and below most observers' threshold on a non-memory colour, but it is not
   zero and it is not measured on a chart.

**And one thing that is not a cost but will read like one:** past about
−3.5 EV, §16.1 says the film has no colour to recover. Lifting a region from
−6 EV produces a *grey* region that is now lighter. The curve cannot invent what
the emulsion did not record — which is exactly why the Fit should land the
robust percentile inside the **colour** window (≈ ±2.1 stops), not merely inside
the tonal one (±2.8), and §9.3's default margin should be revisited against
§16.1 before this ships.

---

## Sources

- Reinhard, Stark, Shirley & Ferwerda — [*Photographic Tone Reproduction for Digital Images*, SIGGRAPH 2002](https://dl.acm.org/doi/10.1145/566570.566575) ([PDF](https://www.cs.utah.edu/docs/techreports/2002/pdf/UUCS-02-001.pdf))
- Mantiuk, Daly & Kerofsky — [*Display Adaptive Tone Mapping*, SIGGRAPH 2008](https://dl.acm.org/doi/10.1145/1399504.1360667) ([PDF](https://www.cl.cam.ac.uk/~rkm38/pdfs/mantiuk08datm.pdf))
- Giannoulis, Massberg & Reiss — [*Digital Dynamic Range Compressor Design — A Tutorial and Analysis*, JAES 60(6), 2012](https://aes2.org/publications/elibrary-page/?id=16354)
- ACES — [Output Transforms: Tone Mapping](https://docs.acescentral.com/system-components/output-transforms/technical-details/tone-mapping/) and the [Output Transform Tone Scale VWG thread](https://community.acescentral.com/t/output-transform-tone-scale/3498)
- darktable — [`sigmoid` manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/sigmoid/), [`filmic rgb` manual](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/filmic-rgb/), source [`src/iop/sigmoid.c`](https://github.com/darktable-org/darktable/blob/master/src/iop/sigmoid.c)
- AgX — [sobotka/AgX](https://github.com/sobotka/AgX), [Blender parameterised AgX view transform](https://projects.blender.org/blender/blender/pulls/147770)
- ARRI — [*LogC4 Logarithmic Color Space Specification*, 1 May 2022](https://www.arri.com/resource/blob/278790/dc29f7399c1dc9553d329e27f1409a89/2022-05-arri-logc4-specification-data.pdf) (the constants are derived in the document; the best-documented member of the camera-log family, §2.12/§5.7)
- [ISO 6846:1992 — *Photography — Black-and-white continuous-tone papers — Determination of ISO speed and ISO range for printing*](https://www.iso.org/standard/13355.html); conventional density criteria cross-checked against [Ilford Multigrade RC technical information](https://www.ilfordphoto.com/wp/wp-content/uploads/2021/01/MULTIGRADE-IV-RC-Papers-060619.pdf)
- This repository — `engine/src/shaders/nodes.metal` (`spk_tc_b`, `spk_lut2d_cubic`, `spk_edr`), `engine/src/pipeline/pipeline.cpp` (`exposure_evs_from`, `node_upsample`, `node_exposure`, `film_prefix`), `engine/resources/profiles/*.json`

---

## 17. Engine implementation (2026-09-24)

Option A of §10.3, as designed, plus the §15 corrections.

- **Node** `filming.expose.scene_latitude` (`engine/src/pipeline/scene_latitude.cpp`,
  kernel `spk_scene_latitude` in `engine/src/shaders/scene_latitude.metal`): after
  auto-exposure, before `upsample`, in the band-able `film_scale_and_expose`
  stage. Not dispatched when off. Power norm by default, `Y` and `max` on the
  wire; the lift bounded by `max_lift` through the same smooth-min (§15.5);
  §11's pathological-pixel rule (`k = 1`) and the `k` clamp.
- **Host math** `engine/src/core/latitude_fit.{hpp,cpp}`: the double-precision
  curve, the knee solve, the ISO 6846 boundaries, the scene statistic, the Fit
  and the suggestion.
- **Wire** eight shoot-layer fields and one C call, API-SPEC §12.

**Gates**, `rfc/probes/rfc023-engine-check.py` on `_DSC8683.NEF` at 2048 px,
grain and glare off:

| gate | result |
|---|---|
| off vs a build of `main` before this change | **byte-identical** |
| on with both rooms 0 | **byte-identical** |
| striped (97 rows) vs un-striped, curve on | **byte-identical** |
| node vs the §15 numpy reference (`apply_slm2`, power, bounded) | max 1 / 65535 |
| crossed knees, unknown norm, pull-back under the minimum | refused |
| `parity_schema` / `setup` (227) / `render` (27) / `session` (59) / `lut` / `strip_executor` / `gpu_smoke` / math guard | 0 failures |

**Two things the implementation found.**

1. **The Fit must solve for the bounded landing.** §15.6 solved the curve and
   then applied the lift bound, so the landing it reported was not the one the
   render made: on this frame a 3.24-stop shadow pull-back landed 0.72 stop
   short, outside the medium. The Fit now inverts the bound first
   (`d* = N·L/√(L² − N²)`) and solves for `d*`. The cost is honest and large:
   at `max_lift = 4` the §9.3 suggestion for this frame (P0.1 at −7.62 into a
   boundary at −4.63) needs the knee at +7 EV and is refused with
   `knees_cross`; at `max_lift = 8` it is valid with a 0.37-stop core. Fitting
   the shadows to P1 instead (`shadow_percentile: 1`, what §15.6 preferred)
   turns the shadow side off on this frame — P1 already sits inside the medium.
2. **The medium measured today is not §15.2's.** Portra 400 + Portra Endura
   through today's engine: **[−4.63, +2.40] EV = 7.03 stops** (glare off;
   −4.86 with glare on), against §15.2's 5.66. The engine's own probe and the
   Python `probe_medium` agree exactly, so the difference is in the chain
   between 2026-09-21 and now, not in the probe. Not investigated yet.

The probe runs with **glare off** although glare is part of the print: on the
1024 × 8 ramp its stochastic field made the minimum sample the "black" and put
the shadow boundary at −9.45 EV. A descriptor that moves between calls is worse
than one 0.23 stop conservative.

Not done: the UI; §16.5's colour-window margin; Option B's fusion into
`spk_lut2d_cubic`; a gradient test for the knee (§14.4).
