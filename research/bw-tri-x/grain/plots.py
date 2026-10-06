"""Figures from out_t2_bw.json / out_t4.json / out_t5_trix.json."""
import json, numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
from PIL import Image
t2 = json.load(open("out_t2_bw.json")); t4 = json.load(open("out_t4.json")); t5 = json.load(open("out_t5_trix.json"))
C = ["#2a78d6", "#d6602a", "#2a9d5c", "#8a4fd6", "#555555", "#c22f6b"]

fig, ax = plt.subplots(figsize=(7.2, 4.4), dpi=150)
pick = [("single px12", "12 um/px (36 mm at 3000 px)"), ("single px6", "6 um/px (36 mm at 6000 px)"), ("single px2", "2 um/px"),
        ("single px2 blur0", "2 um/px, grain blur 0 (white)"), ("sublayers px2 (dye clouds 1.0 um, default)", "2 um/px, sub-layers + dye clouds 1 um"),
        ("sublayers px2 dye3", "2 um/px, sub-layers + dye clouds 3 um")]
for (k, lab), c in zip(pick, C):
    s = t4["4_nps"][k]; ax.plot(s["f"], s["W"], color=c, lw=1.8, label=lab)
ax.axhline(0.017 ** 2 * np.pi * 24 ** 2, color="k", ls=":", lw=1); ax.text(3, 0.535, "sheet: RMS 17 -> 0.523 um^2 at f -> 0", fontsize=8)
ax.set_xscale("log"); ax.set_xlim(2, 250); ax.set_ylim(0, 0.8)
ax.set_xlabel("spatial frequency on film, cycles/mm"); ax.set_ylabel("noise power W(f), D^2 um^2")
ax.set_title("Engine grain: noise power spectrum at net D 1.0 (stand-in, Dmax 3.0, measured)", fontsize=9)
ax.grid(alpha=0.25); ax.legend(fontsize=7.5, frameon=False); fig.tight_layout(); fig.savefig("fig_nps.png"); plt.close(fig)

fig, ax = plt.subplots(figsize=(7.2, 4.4), dpi=150)
r = t2["C_density"]; d = [x["target"] for x in r]
ax.plot(d, [x["rms48_single"] for x in r], "o", color=C[0], label="stand-in Dmax 3.0, one channel, single layer: measured")
ax.plot(d, [x["model_single"] for x in r], "-", color=C[0], lw=1.2, label="  model d(1 - u d/Dmax), with the 0.65 px blur")
ax.plot(d, [x["rms48_sub"] for x in r], "s", color=C[1], label="stand-in, three equal sub-layers: measured")
ax.plot(d, [x["model_sub"] for x in r], "-", color=C[1], lw=1.2)
r5 = t5["density"]; d5 = [x["target"] for x in r5]
ax.plot(d5, [x["single"] for x in r5], "o", mfc="none", color=C[2], label="kodak_tri_x_400.json as built (1/3 sum), single layer: measured")
ax.plot(d5, [x["sub"] for x in r5], "s", mfc="none", color=C[3], label="kodak_tri_x_400.json as built, sub-layers (product default): measured")
dd = np.linspace(0.05, 2.9, 100); ax.plot(dd, 17 * np.sqrt(dd), "--", color="#555555", lw=1, label="Nutting/Siedentopf sqrt(D) through the sheet point")
ax.plot([1.0], [17], "*", color="k", ms=12, label="F-4017: 17 at net D 1.0")
ax.set_xlabel("net density of the negative"); ax.set_ylabel("RMS granularity x1000, 48 um aperture, 6 um pixels")
ax.set_ylim(0, 30); ax.grid(alpha=0.25); ax.legend(fontsize=6.8, frameon=False, loc="upper left"); fig.tight_layout(); fig.savefig("fig_density_dependence.png"); plt.close(fig)

names = ["crop_rgbnoise_independent.png", "crop_rgbnoise_equal.png", "crop_rgbnoise_equal_eqparams.png", "crop_single_px2_blur0.png", "crop_single_px2.png", "crop_sublayers_px2.png", "crop_sublayers_px2_dye3.png"]
ims = [Image.open(n).convert("RGB") for n in names]
w, h = ims[0].size; sheet = Image.new("RGB", (len(ims) * (w + 8) - 8, h), "white")
for i, im in enumerate(ims): sheet.paste(im, (i * (w + 8), 0))
sheet.save("fig_crops.png")
