"""Follow-ups: baseline frame spread, WB under a filter, overscan PNGs. Same env as probe.py."""
import os, json, numpy as np
from pathlib import Path
from PIL import Image
S = Path(__file__).parent
os.environ["SPEKTRAFILM_ENGINE_RESOURCES"] = str(S/"res")
import importlib.util, sys
src = open(S/"probe.py").read().split("res = {}")[0]
exec(src)
NP = dict(m_filter_neutral=79.6875, y_filter_neutral=98.125)
out = {}
with Engine() as eng:
    o,_ = render(eng, film_stock="bwx_split", **NP)
    out["baseline_frame_max_spread255"] = float(chroma(o).max())
    base_img = img.copy()
    for name, gains in (("neutral",(1,1,1)),("warm_wb",(1.25,1,0.75)),("cool_wb",(0.8,1,1.3))):
        im2 = base_img*np.array(gains,np.float32)
        row = {}
        for stock in ("bwx_split","bwx_split_r"):
            o,_ = render(eng, image=im2, film_stock=stock, **NP)
            row[stock] = {k: round(float(255*v.mean(0)[1]),1) for k,v in patches(o).items() if k in ("grey18","sky","skin","foliage","red")}
        out["wb_"+name] = row
for stock in ("bwx_split","kodak_portra_400"):
    o = np.load(S/f"overscan_{stock}.npy")
    Image.fromarray((255*o).clip(0,255).astype(np.uint8)).save(S/f"overscan_{stock}.png")
    # the perforation row: brightest 0.5 % of pixels = holes (white light); report their mean rgb
    lum = o.mean(-1); thr = np.percentile(lum, 99.5)
    out["overscan_"+stock] = dict(top05pct_mean255=(255*o[lum>=thr].mean(0)).round(1).tolist(),
                                  median255=(255*np.median(o.reshape(-1,3),0)).round(1).tolist())
json.dump(out, open(S/"probe2_results.json","w"), indent=1); print(json.dumps(out))
