from common import *
import json
e = spk.Engine()
img = np.full((64, 96, 3), 0.18, np.float32)
s = e.open(img, dict(BASE, film_stock="standin_bw_silver"))
gp = s.get_params(); print(json.dumps(gp)[:3000])
r,_ = s.render("full"); print(r.shape, r[32,48])
s.close()
for st in ("kodak_portra_400","standin_bw_dyes","standin_bw_silver"):
    for sf in (True, False):
        o = render(e, img, dict(film_stock=st, scan_film=sf)); print(st, sf, o.shape, o[32,48])
