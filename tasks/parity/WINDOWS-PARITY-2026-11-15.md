# Windows Vulkan — public Python reference comparison

Date: 2026-11-15

## Result

The deterministic core pipeline matches the public Python reference over a
whole 240×180 frame:

| Gate | Result |
|---|---|
| Backend | Windows Vulkan, NVIDIA RTX 3060 Laptop GPU, driver 617.42 |
| Vulkan repeatability | two full renders and a cached reprint bit-exact |
| Reference | public `spektrafilm` 0.3.4, commit `3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`, Python 3.13.13 / numba |
| Compared RGB values | 129,600 |
| Max absolute difference | `8.629775545831997e-06` |
| Max uint16 count difference | 1 |
| Count outliers > 1 | 0 |
| Outlier fraction | 0 |
| Gate (`3e-5`, 1 count, `1e-5` fraction) | passed |

This is the public upstream Python reference, not the private fork that
produced the macOS Metal oracle. Public history has no
`spektrafilm.model.colour_baked` or `spektrafilm.service.schema`, so the exact
Metal/Python oracle remains unavailable.

## Compared configuration

- Deterministic synthetic frame from `parity_render.load_frame(seed=7)`,
  240×180, little-endian float32 RGB.
- Kodak Portra 400, Kodak Portra Endura.
- ProPhoto RGB linear input, ProPhoto RGB encoded output.
- Grain, glare and automatic exposure off.
- Halation, DIR couplers, diffusion filter and lens aberrations off to isolate
  the common deterministic core. This is the fixture tool's `core` profile.

The `core` profile is not the material model. It removes effects whose public
upstream implementation differs from the engine so the shared stage arithmetic
can be measured without that difference hiding it.

## Measured limits

With the stock spatial effects enabled (the `default` profile), the same input
does **not** match public upstream:

| Gate | Result |
|---|---|
| Max absolute difference | `0.8277110063785368` |
| Max uint16 count difference | 54,244 |
| Count outliers > 1 | 129,600 / 129,600 |
| Status | failed |

Turning only halation off, or only DIR couplers off, still fails. Both
deterministic effect families differ between the engine and public upstream.
This is not evidence of a Metal defect or a Vulkan defect: the private fork and
the public package are not the same implementation.

The individual Vulkan pointwise probe also passed 193 analytic/float64 cases
with max absolute error `3.53745407e-05`, max relative error `3.53403816e-07`,
and all guards intact on the same GPU.

## Reproduction

The evidence was produced with the fixture driver from the Qt Debug build.
Equivalent Windows engine builds use the same tool.

```powershell
$root = 'build/parity-acceptance-20261115'
python engine/tools/windows_fixture.py generate `
    --output-dir "$root/fixture" --size 180 --profile core
python engine/tools/windows_fixture.py run `
    --driver build/qt-debug/engine/spk_render_fixture.exe `
    --resources build/qt-debug/engine/resources `
    --fixture-dir "$root/fixture" `
    --output-dir "$root/vulkan"
```

Run the Python side in a Linux/WSL checkout with the public package installed:

```bash
ROOT=/path/to/SPEKTRAlab/build/parity-acceptance-20261115
/path/to/public/spektrafilm/.venv/bin/python engine/tools/windows_python_reference.py \
    --fixture-dir "$ROOT/fixture" \
    --resources /path/to/SPEKTRAlab/engine/resources \
    --reference-dir /path/to/public/spektrafilm \
    --output "$ROOT/reference.npy" \
    --metadata "$ROOT/reference-metadata.json"
```

Then compare:

```powershell
python engine/tools/windows_fixture.py compare `
    --fixture-dir "$root/fixture" `
    --got "$root/vulkan/output.rgba16" `
    --reference "$root/reference.npy" `
    --reference-metadata "$root/reference-metadata.json" `
    --report "$root/parity-report.json"
```

## Evidence artifacts

- `build/parity-acceptance-20261115/parity-report.json`
  (`sha256 cb228ff5fb327b69e757f364125467e82ba7616738fa41f0a7f691f9a63644a2`)
- `build/parity-acceptance-20261115/vulkan/output.rgba16`
  (`sha256 075b796a6d6573ecc5a8f189c481402b71e669f0ef96f982385c44fe589eeeda`)
- `build/parity-acceptance-20261115/reference.npy`
  (`sha256 953b826b7360a6d7b2ceff93b01459d698046458625bac435a5ee9aeccc40e77`)
- `build/parity-default-20261115/parity-report.json`
  (`sha256 2b42de8a3762d147d34925ba3d64ff6325aa6797def5485ad33a857f4754f578`)
