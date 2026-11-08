# Notice: what SpektraLab is derived from, and what it changed

**The SpektraLab engine is a C++/Metal implementation derived from spektrafilm by Andrea Volpato
(GPL-3.0-or-later).** spektrafilm is at https://github.com/andreavolpato/spektrafilm; its film
simulation, its measured film and paper profiles and its print and scan model are what SpektraLab
renders. SpektraLab is not affiliated with or endorsed by the spektrafilm project.

This file is the notice GPL-3.0 §5(a) asks of a modified version. The licence texts themselves are
beside it and are not edited: `LICENSE` (GPL-3.0) and `SPEKTRAFILM_LICENSE.txt` (CC BY-SA 4.0 for the
spektrafilm profiles, the LUTs and their direct derivatives, with Andrea Volpato's preamble).

## What was modified

| | |
|---|---|
| the engine (`engine/`) | spektrafilm's Python pipeline, written again in C++20 with Metal kernels behind a C ABI (`spk_*`), from 2026-09-10 (RFC-014). It is held to the Python reference by the parity harnesses in `engine/tests/`, which import the upstream `spektrafilm` package as their oracle. Nodes and wire fields the reference does not have are SpektraLab's additions (`API-SPEC-callable-render-service.md` §11 on) |
| the profiles (`engine/resources/profiles/`) | spektrafilm's 28 profiles, baked from the upstream data and unmodified |
| the print LUTs and the minilab tables (inside `engine/resources/spektralab_constants.bin`, indexed by `print_luts.json`; `engine/resources/minilab/`) | derivatives of those profiles (the print LUTs baked by `engine/tools/bake_resources.py` from the upstream reference); CC BY-SA 4.0 like the profiles they encode |
| SpektraLab's own data (`engine/resources_product/`) | profiles SpektraLab built from manufacturers' published data sheets, and one alias over an unmodified spektrafilm profile; `engine/resources_product/NOTICE.md` says what each is built from |
| the application | SpektraLab's own, GPL-3.0-or-later |

## Other components

- **metal-cpp** (`engine/third_party/metal-cpp`), Apple's C++ bindings for Metal, Apache-2.0.
- **spklib** (`vendor/spklib/macos/spklib-host`), the helper that reads SpektraLab libraries and
  Capture One catalogs, MIT, shipped as a prebuilt binary and run as a separate process
  (`API-SPEC-library-helper.md`).
