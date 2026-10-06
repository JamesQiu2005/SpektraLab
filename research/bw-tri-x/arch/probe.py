"""Architecture probes on the BUILT engine with a scratch resources dir. MEASURED numbers only.
Run: SPEKTRAFILM_ENGINE_RESOURCES=<arch>/res PYTHONPATH=<repo>/engine/tests python probe.py"""
import os, sys, json, numpy as np
from pathlib import Path
S = Path(__file__).parent
os.environ["SPEKTRAFILM_ENGINE_RESOURCES"] = str(S/"res")
from spk_ctypes import Engine, EngineError

# linear-sRGB patch chart, 8 colours x 96 px wide + a grey ramp, ~0.3 MP
cols = {"grey18":(.18,.18,.18),"red":(.45,.04,.03),"orange":(.6,.25,.04),"yellow":(.7,.6,.05),
        "foliage":(.07,.2,.04),"green":(.05,.45,.08),"sky":(.15,.3,.7),"blue":(.03,.05,.5),"skin":(.5,.3,.2),"white":(.9,.9,.9)}
ramp = [0.18*2**e for e in np.linspace(-6,4,16)]
H=384; W=96*len(cols)
img = np.zeros((H*2,W,3),np.float32)
for i,(k,v) in enumerate(cols.items()): img[:H,i*96:(i+1)*96]=v
rw = W//len(ramp)
for i,v in enumerate(ramp): img[H:,i*rw:(i+1)*rw]=v
BASE = dict(input_color_space="sRGB", input_cctf_decoding=False, output_color_space="sRGB",
            auto_exposure=False, grain_active=False, halation_active=False, dir_couplers_active=False,
            glare_active=False, print_stock="kodak_portra_endura")
def render(eng, image=None, **kw):
    d = dict(BASE); d.update(kw)
    with eng.open(img if image is None else image, d) as s:
        out,_ = s.render("full")
        return out[...,:3].astype(np.float64)/65535.0, s.get_params()
def patches(o):
    return {k:o[40:H-40,i*96+20:(i+1)*96-20].reshape(-1,3) for i,k in enumerate(cols)}
def ramp_vals(o):
    return np.array([o[H+40:-40,i*rw+10:(i+1)*rw-10].reshape(-1,3).mean(0) for i in range(len(ramp))])
def chroma(rgb):  # max channel spread in 8-bit counts
    return 255*(rgb.max(-1)-rgb.min(-1))
res = {}
with Engine() as eng:
    # 1. does a channel_model=bw profile load and render at all?
    o,p = render(eng, film_stock="bwx_split")
    res["1_loads"] = dict(film=p["film_stock"], cmy_neutral=[p["c_filter_neutral"],p["m_filter_neutral"],p["y_filter_neutral"]])
    rv = ramp_vals(o)
    res["2_colour_paper_default_pack"] = dict(ramp_rgb255=(255*rv).round(1).tolist(), max_spread255=float(chroma(rv).max()))
    # 2b. null mid-grey with the wire's own neutral-pack fields (coordinate search)
    m,y = p["m_filter_neutral"], p["y_filter_neutral"]
    def grey_err(m,y):
        o,_ = render(eng, film_stock="bwx_split", m_filter_neutral=m, y_filter_neutral=y)
        g = patches(o)["grey18"].mean(0); return g, np.array([g[0]-g[1], g[2]-g[1]])
    step=16.0
    g,e = grey_err(m,y)
    for it in range(40):
        best=(np.abs(e).sum(),m,y,g,e)
        for dm,dy in ((step,0),(-step,0),(0,step),(0,-step)):
            mm,yy=min(max(m+dm,0),200),min(max(y+dy,0),200)
            g2,e2=grey_err(mm,yy)
            if np.abs(e2).sum()<best[0]: best=(np.abs(e2).sum(),mm,yy,g2,e2)
        if (best[1],best[2])==(m,y): step/=2
        m,y,g,e=best[1:]
        if step<0.05: break
    o,_ = render(eng, film_stock="bwx_split", m_filter_neutral=m, y_filter_neutral=y)
    rv = ramp_vals(o)
    res["2b_colour_paper_nulled_pack"] = dict(m=m,y=y,grey255=(255*g).round(2).tolist(),
        ramp_rgb255=(255*rv).round(1).tolist(), max_spread255_over_ramp=float(chroma(rv).max()))
    NP = dict(m_filter_neutral=m, y_filter_neutral=y)
    # 3. grain: independent per-channel streams on identical channels -> chroma noise
    for name,kw in (("grain_off",{}),("grain_on",dict(grain_active=True))):
        o,_ = render(eng, film_stock="bwx_split", **NP, **kw)
        g = patches(o)["grey18"]
        res["3_"+name] = dict(sd_G255=float(255*g[:,1].std()), sd_RminusG255=float(255*(g[:,0]-g[:,1]).std()),
                              sd_BminusG255=float(255*(g[:,2]-g[:,1]).std()))
    # 3b. one-column profile: are the other channels' grain/halation invisible?
    for name,kw in (("grain_on",dict(grain_active=True)),("halation_on",dict(halation_active=True))):
        for stock in ("bwx_split","bwx_onecol"):
            o,p2 = render(eng, film_stock=stock, **NP, **kw)
            g = patches(o)["grey18"]
            res[f"3b_{stock}_{name}"] = dict(mean255=(255*g.mean(0)).round(2).tolist(), sd_RminusG255=float(255*(g[:,0]-g[:,1]).std()),
                                             frame_max_spread255=float(chroma(o).max()))
    # 4. design (a): a filter baked into the sensitivity. Tonal shifts, in 8-bit luminance of the print.
    tab = {}
    for stock in ("bwx_split","bwx_split_y","bwx_split_r","bwx_split_g","bwx_split_b"):
        o,_ = render(eng, film_stock=stock, **NP)
        tab[stock] = {k: round(float(255*v.mean(0)[1]),1) for k,v in patches(o).items()}
    res["4_filter_variants_G255"] = tab
    # 4b. the same idea on a colour stock: is a WB change visible in tone under a filter?
    # 5. other paths
    for name,kw in (("scan_film",dict(scan_film=True)),("digital_intermediate",dict(digital_intermediate=True)),
                    ("couplers_on",dict(dir_couplers_active=True)),("halation_on",dict(halation_active=True)),
                    ("overscan",dict(overscan_active=True)),("auto_exposure",dict(auto_exposure=True))):
        try:
            o,_ = render(eng, film_stock="bwx_split", **NP, **kw)
            pt = patches(o) if o.shape[:2]==img.shape[:2] else None
            res["5_"+name] = dict(shape=list(o.shape), finite=bool(np.isfinite(o).all()),
                grey255=(255*pt["grey18"].mean(0)).round(2).tolist() if pt else None,
                white255=(255*pt["white"].mean(0)).round(2).tolist() if pt else None,
                frame_max_spread255=float(chroma(o).max()), frame_p99_spread255=float(np.percentile(chroma(o),99)))
        except EngineError as ex:
            res["5_"+name] = dict(error=str(ex))
    # 6. overscan: a flat grey frame of the 135 gate's shape; what do the holes and the edge print look like?
    g135 = np.full((768,1146,3),0.18,np.float32)
    for stock in ("bwx_split","kodak_portra_400"):
        kw = NP if stock.startswith("bwx") else {}
        try:
            o,_ = render(eng, image=g135, film_stock=stock, overscan_active=True, overscan_edge_text="TEST 400", **kw)
            np.save(S/f"overscan_{stock}.npy", o.astype(np.float32))
            sp = chroma(o)
            res["6_overscan_"+stock] = dict(shape=list(o.shape), max255=(255*o.reshape(-1,3).max(0)).round(1).tolist(),
                min255=(255*o.reshape(-1,3).min(0)).round(1).tolist(), frame_max_spread255=float(sp.max()),
                frac_px_spread_gt8=float((sp>8).mean()))
        except EngineError as ex:
            res["6_overscan_"+stock] = dict(error=str(ex))
json.dump(res, open(S/"probe_results.json","w"), indent=1)
print(json.dumps(res, indent=1))
