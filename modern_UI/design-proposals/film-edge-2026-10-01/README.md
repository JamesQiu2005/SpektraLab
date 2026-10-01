# Film Edge and Date Back on desktop (proposal, 2026-10-01)

The full spec, the mobile flow, every format's mask and the engine handoff live in
`SpektraLab_mobile/design/overscan/` (README there, commit `371ad16`). This folder carries the desktop half.

| file | what |
|---|---|
| `overscan_desktop_1_framing_v1.svg` | framing in the gate, with the Format menu open |
| `overscan_desktop_2_film_edge_v1.svg` | Film Edge developed |
| `overscan_desktop_3_date_back_v1.svg` | Date Back with a film edge |
| `overscan_desktop_4_date_only_v1.svg` | Date Back alone, on the photo's own crop |
| `overscan_flow_v1.svg` | the concept graph: the order of decisions and the pixel math |
| `preview_desktop_v1.png` | the four desktop states side by side |

**Where it lives.** It goes in two left-rail sections of *Film and Print*, under Film: **Film Edge**
and **Date Back**.
- **They belong to the film**, and depend on neither the print stock nor the DI.
- **Date Back is separate** because it works without a film edge.
- **No top-bar tool.** Framing borrows the crop tool, as the Crop section already does.
- **No wizard.** The rows' order carries the dependencies (format → view → turn → framing → gate →
  light), and every control develops on release.
- **While Film Edge is on:** Crop reads *Held by Film Edge*, and Film Format reads *Set by Film Edge*.

The pictures are engine renders with display names. Desktop may print real marks (RFC-032 §26);
the drawings don't.
