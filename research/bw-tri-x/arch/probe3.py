"""Side entry points on a bw stand-in: solve, scene_latitude, preview_stock_lut, warm_up, capabilities stats."""
import os, json, numpy as np
from pathlib import Path
S = Path(__file__).parent
os.environ["SPEKTRAFILM_ENGINE_RESOURCES"] = str(S/"res")
exec(open(S/"probe.py").read().split("res = {}")[0])
out = {}
with Engine() as eng:
    d = dict(BASE, film_stock="bwx_split", m_filter_neutral=79.6875, y_filter_neutral=98.125, auto_exposure=True)
    with eng.open(img, d) as s:
        for name, fn in (("solve", lambda: s.solve("both")), ("scene_latitude", lambda: s.scene_latitude()),
                         ("preview_stock_lut", lambda: (lambda a,m: dict(meta=m, max_spread255=float((255*(a[...,:3].max(-1).astype(float)-a[...,:3].min(-1))/65535).max())))(*s.preview_stock_lut("kodak_supra_endura")))):
            try:
                r = fn(); out[name] = r if not isinstance(r, np.ndarray) else list(r.shape)
            except Exception as ex:
                out[name] = dict(error=str(ex)[:300])
        # switch colour -> bw inside one session: do the colour stock's database filters carry over?
    with eng.open(img, dict(BASE, film_stock="kodak_portra_400")) as s:
        a = s.get_params(); s.set_params({"film_stock": "bwx_split"}); b = s.get_params()
        out["stock_switch_pack"] = dict(portra=[a["c_filter_neutral"],a["m_filter_neutral"],a["y_filter_neutral"]],
                                        then_bw=[b["c_filter_neutral"],b["m_filter_neutral"],b["y_filter_neutral"]])
print(json.dumps(out, default=str)[:3000]); json.dump(out, open(S/"probe3_results.json","w"), indent=1, default=str)
