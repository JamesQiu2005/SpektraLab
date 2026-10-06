"""What breaks silently / loudly around an unknown paper: print LUTs, DI export, target_print. -> out/lut_di_checks.json"""
import json, numpy as np, common as c
out = {}
def attempt(tag, fn):
    try: v = fn(); out[tag] = v; print('OK   ', tag, '->', v)
    except Exception as ex: out[tag] = 'ERROR: ' + str(ex); print('ERROR', tag, '->', ex)
stops = np.arange(-6, 6.01, 0.5); img = c.ramp(stops)
def stat(rgba):
    lin = c.srgb_decode(c.patches(rgba, len(stops))); L = c.lab(lin)
    return dict(L_mid=round(float(L[len(stops) // 2, 0]), 2), L_min=round(float(L[:, 0].min()), 2), L_max=round(float(L[:, 0].max()), 2), max_C=round(float(np.hypot(L[:, 1], L[:, 2]).max()), 3))
with c.engine() as eng:
    attempt('print_lut_catalog keys', lambda: sorted(eng.print_lut_catalog().keys()))
    attempt('warm_up(tri-x, mgiv)', lambda: eng.warm_up(c.FILM, c.PAPER))
    base = dict(c.CLEAN, film_stock=c.FILM, print_stock=c.PAPER, **c.grade_delta('2'))
    with eng.open(img, base) as s:
        attempt('preview_stock_lut(mgiv)', lambda: s.preview_stock_lut(c.PAPER)[1])
        attempt('preview_stock_lut(kodak_portra_endura) from a Tri-X/MGIV session', lambda: (lambda r: dict(info=r[1], **stat(r[0])))(s.preview_stock_lut('kodak_portra_endura')))
        attempt('export_di(mgiv)', lambda: s.export_di(c.PAPER)[1])
        attempt('export_di(None)', lambda: (lambda r: dict(info=r[1], **stat(r[0])))(s.export_di(None)))
        attempt('render_digital_intermediate (film target_print = endura)', lambda: (lambda r: dict(info=r[1], **stat(r[0])))(s.render_digital_intermediate()))
    for film in (c.FILM, 'kodak_tri_x_400_mgiv'):
        d = dict(c.CLEAN, film_stock=film, digital_intermediate=True)
        def go():
            with eng.open(img, d) as s:
                rgba, _ = s.render('full'); return dict(print_stock=s.get_params().get('print_stock'), **stat(rgba))
        attempt('live DI, film %s' % film, go)
        def go2():
            with eng.open(img, dict(c.CLEAN, film_stock=film, print_stock=c.PAPER, **c.grade_delta('2'))) as s:
                r = s.render_digital_intermediate(); return dict(info=r[1], **stat(r[0]))
        attempt('render_digital_intermediate, film %s on MGIV session' % film, go2)
    attempt('film copy with target_print=mgiv, straight print', lambda: stat(c.render(eng, img, dict(film_stock='kodak_tri_x_400_mgiv', print_stock=c.PAPER, **c.grade_delta('2')))[0]))
    attempt('original film, straight print', lambda: stat(c.render(eng, img, dict(film_stock=c.FILM, print_stock=c.PAPER, **c.grade_delta('2')))[0]))
json.dump(out, open(c.OUT / 'lut_di_checks.json', 'w'), indent=1, default=str)
