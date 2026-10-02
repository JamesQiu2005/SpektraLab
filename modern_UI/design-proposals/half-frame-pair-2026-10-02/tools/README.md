# Design tools for the half-frame pair proposal (design only)

These are the scripts that produced this folder's drawings and renders. **They are not part of the
product:** nothing builds them, nothing runs them, and nothing ships them (CLAUDE.md: no Python at build
or run time). Keeping them here is answer sheet question A7.

| file | what |
|---|---|
| `render_pair.py`, `render_more.py` | the halves and the gap, through **filmify's** engine dylib (`engine/tests/spk_ctypes.py`) |
| `render_strip.py` | the Film Edge strip, frames 6 and 6A, through the **scratch** engine (below) |
| `render_scope.py` | Frame vs + Overscan on the strip: two prints of one negative, cut along the engine's gate coverage. The coverage comes from a flat input rendered ×1 and ×2 and differenced |
| `gen_pair_v2.py` | the SVG screens and concept sheets. It imports the desktop chrome read-only from `SpektraLab_mobile/design/src` (`gen.py`, `gen_overscan.py`) |
| `snap.swift` | SVG to PNG through WKWebView (`swiftc -O snap.swift -o snap`). It uses `loadFileURL`, because `loadHTMLString` cannot read local files |

**To reproduce, with this layout in any working directory:**

```
work/
  snap                     # swiftc -O tools/snap.swift -o work/snap
  meng/engine/             # git -C SpektraLab_mobile archive 371ad16 engine | tar -x -C work/meng
                           # cd work/meng/engine && patch -p1 < ../../../pair_scratch.patch && bash build.sh dylib
  v2/                      # these scripts, plus v2/img/ (created by them) and v2/out/
```

- **The inputs** are the owner's frames, decoded to `.f32` in
  `SpektraLab_mobile/research/overscan/engine_proto/in/` (street, snow, cathedral, bund, nyc).
- **`imgio`** in that folder encodes the PNGs.
- **Run order:**
  1. `render_pair.py` and `render_more.py`;
  2. `sips` crops to the 3:4 slot (see the generator's file names);
  3. `render_strip.py` and `render_scope.py`;
  4. `gen_pair_v2.py out`.
- **The build needs the Metal toolchain** (`xcodebuild -downloadComponent MetalToolchain`) and the
  sandbox disabled to reach it.
- **Never build inside `SpektraLab_mobile`'s own tree;** another machine works there.
