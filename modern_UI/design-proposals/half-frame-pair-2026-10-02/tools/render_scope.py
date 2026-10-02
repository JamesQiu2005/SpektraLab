# Exposure scope on the strip: the right hole's print +1 stop, frame only vs + overscan.
# A print-only change leaves the negative identical, so two prints of one canvas composite exactly.
exec(open("render_strip.py").read().split('print("input"')[0])
def rgba_of(delta, src=None):
    base = {"film_stock": "kodak_gold_200", "print_stock": "kodak_supra_endura",
            "input_color_space": "ProPhoto RGB", "input_cctf_decoding": True,
            "output_color_space": "sRGB", "output_cctf_encoding": True,
            "overscan_active": True, "overscan_format": "135_half", "overscan_mode": "strip",
            "overscan_pair": True, "overscan_camera_seed": 19, "overscan_frame_seed": 5,
            "overscan_edge_text": "KODA GOLD 200"}
    with spk.Engine(dylib=ENG / "build/libspektrafilm_engine.dylib") as e:
        s = e.open(comp if src is None else src, {**base, **delta}); rgba, res = s.render("preview"); s.close()
    return rgba.astype(np.float64)

def save(a, png):
    raw = OUT / (Path(png).stem + ".u16")
    np.ascontiguousarray(np.clip(a, 0, 65535).astype("<u2")).tofile(raw)
    subprocess.run([str(PROTO / "imgio"), "encode", str(raw), str(a.shape[1]), str(a.shape[0]), str(png)], check=True, capture_output=True)
    raw.unlink()

# The gates, from the engine: one stop more scene light changes only what the gates let through.
quiet = {"auto_exposure": False, "overscan_fog": 0.0, "overscan_leaks": 0.0}
flat = np.full_like(comp, 0.35)   # same size, same seeds: the same layout, with nothing in the pictures
d = np.abs(rgba_of(quiet, flat * 2.0)[..., :3] - rgba_of(quiet, flat)[..., :3]).mean(-1)
gate = np.clip(d / np.median(d[d > 0.5 * d.max()]), 0, 1)
h, w = gate.shape
cols = np.arange(w)[None, :]
mid = w // 2 + 0  # the gap is in the middle of the canvas along the film
right = gate * (cols >= mid)
left = gate * (cols < mid)
print("gate coverage L/R px:", int(left.sum()), int(right.sum()))

base = rgba_of({})
up = rgba_of({"print_exposure": 2 ** -1.0})
R, Lm = right[..., None], left[..., None]
frame_only = base.copy(); frame_only[..., :3] = base[..., :3] * (1 - R) + up[..., :3] * R
with_over = up.copy();    with_over[..., :3] = up[..., :3] * (1 - Lm) + base[..., :3] * Lm
save(frame_only, OUT / "strip_scope_frame.png")
save(with_over, OUT / "strip_scope_overscan.png")
save(np.dstack([gate * 65535] * 3 + [np.full_like(gate, 65535)]), OUT / "strip_gate_mask.png")
print("done")
