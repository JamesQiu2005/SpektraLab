# screenshots/

The product as it renders, on real photographs. These are captures of the
**running app**, taken 2026-09-17 and 2026-09-19, and they are what `README.md` shows a
reader who has not built it.

They are not the same thing as `modern_UI/design/snapshots/`. Those come from
the snapshot harness (`--snapshot WxH out.png`), which draws the canvas
offscreen at a stated size so a layout can be *measured* against the drawing in
`modern_UI/reference_layout/Main/`. These are what a person sees.

| file | what it is | size |
|---|---|---|
| `spektralab-main_new.png` | the editor in a window: `_DSC0897.NEF` (Nikon Z7 II, 8256×5504), Lower Manhattan at dusk, on **Kodak Portra 400**, printed on **Kodak Professional Portra Endura**; 135 film; grain, halation, glare and EDR on; straightened −0.6°; `28 %` with the `full` badge up. Taken before the Print section's buttons became Solve / Original | 2048 px wide, from 3824 |
| `natural_halation.png` | the before/after split on a San Francisco frame — left of the line is Apple's decode of the RAW, right is the same pixels through film and paper | 1386 px wide, from 1798 |
| `physically_accurate_grain.png` | the canvas at 1:1 on the Yosemite frame: the engine's grain at the render's own pixels | **native, 1226 px, unresampled** |
| `app-icon.png` | the app icon as macOS draws it, read back out of the built bundle | 1024 px, from a 2048 px rendition |

**The 1:1 capture must not be resized.** At and above 100 % the canvas samples
nearest (`canvasFragment` in `Canvas/Shaders.metal`), so the pixels in that
file are the grain the engine drew — a particle count per sub-layer and
channel, scaled by the frame's pixel pitch in µm. Resampling the file to save
a megabyte resamples the evidence, and so does a JPEG.

`app-icon.png` is the odd one out: it is not a capture but a render, and it is
made rather than taken — build the app, then

```bash
swiftc -O Tools/render-icon.swift -o /tmp/render-icon
/tmp/render-icon "$PWD/build/DerivedData/Build/Products/Debug/SpektraLab.app" \
                 ../../screenshots/app-icon.png 1024
```

from `modern_UI/Spektrafilm`. It reads the icon the way the Finder does, so it
is also the check that `Spektrafilm/SpektraLab.icon` reached the bundle — an
app icon that failed to compile is a build that succeeds.

## Re-taking them

A screenshot is a claim about the interface on the day it was taken, and this
interface moves. Re-take them when it does, and say in the commit what moved.

1. Launch the app and open a frame with something to show — grain wants a
   large negative, halation wants a bright edge against a dark one.
2. Fullscreen (⌃⌘F) — macOS hides the window buttons there, which is why
   these captures have none. In a window they sit on the top bar's
   centreline (`Windows/TrafficLights.swift`), not in the corner.
3. For the split: `⌥\`, then drag the line on the canvas. It is anchored to the
   picture, not to the window, so it stays on the same building when you pan.
4. For the 1:1 crop: zoom to 100 % or beyond and capture a region (⇧⌘4).
5. Keep the file names. `README.md` and `ARCHITECTURE.md` §7 link to them.
