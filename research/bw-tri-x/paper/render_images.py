"""Test prints on the five local images. Engine defaults (grain, halation, glare on), auto exposure on,
dir_couplers_amount 0.4 on Tri-X (research/black-and-white-tri-x.md section 6). Grade settings from grade_table.json.
-> out/print_g2_<image>.png, out/sheet_compare.png, out/sheet_grades_<image>.png, csv/image_stats.csv"""
import numpy as np, common as c
from PIL import Image, ImageDraw
IM = ['smoke', 'R0030139', '_DSC2439', '_DSC2704', '_DSC2715']
IO = dict(input_color_space='ProPhoto RGB', input_cctf_decoding=False, auto_exposure=True, film_format_mm=35.0)
TX = dict(film_stock=c.FILM, dir_couplers_amount=0.4)
def stats(rgba):
    lin = c.srgb_decode(c.to_float(rgba)); L = c.lab(lin); l = L[..., 0]
    return dict(L_mean=l.mean(), L_median=np.median(l), L_p02=np.percentile(l, 2), L_p98=np.percentile(l, 98),
                frac_black=(l < 12).mean(), frac_white=(l > 86).mean(), C_max=np.hypot(L[..., 1], L[..., 2]).max(), C_mean=np.hypot(L[..., 1], L[..., 2]).mean())
def tile(rgba, label, size=560):
    t = Image.fromarray((rgba[..., :3] >> 8).astype(np.uint8)); t.thumbnail((size, size))
    canvas = Image.new('RGB', (size, size + 22), (40, 40, 40)); canvas.paste(t, ((size - t.width) // 2, 22 + (size - t.height) // 2))
    ImageDraw.Draw(canvas).text((6, 5), label, fill=(255, 255, 255)); return canvas
def sheet(rows, path):
    W = max(sum(t.width for t in r) for r in rows); Hh = sum(r[0].height for r in rows)
    s = Image.new('RGB', (W, Hh), (40, 40, 40)); y = 0
    for r in rows:
        x = 0
        for t in r: s.paste(t, (x, y)); x += t.width
        y += r[0].height
    s.save(path)
rowsA = []; lines = ['image,variant,' + ','.join(['L_mean', 'L_median', 'L_p02', 'L_p98', 'frac_black', 'frac_white', 'C_max', 'C_mean'])]
def rec(n, v, rgba):
    s = stats(rgba); lines.append('%s,%s,' % (n, v) + ','.join('%.3f' % s[k] for k in ['L_mean', 'L_median', 'L_p02', 'L_p98', 'frac_black', 'frac_white', 'C_max', 'C_mean']))
    print('%-10s %-26s L* mean %5.1f median %5.1f p2 %5.1f p98 %5.1f  black %.3f white %.3f  C*max %.2f' % (n, v, s['L_mean'], s['L_median'], s['L_p02'], s['L_p98'], s['frac_black'], s['frac_white'], s['C_max']))
with c.engine() as eng:
    for n in IM:
        img = c.load_image(n); row = []
        col, _ = c.render(eng, img, dict(IO, film_stock='kodak_portra_400'), base={}); rec(n, 'portra400_colour_print', col); row.append(tile(col, 'Portra 400 -> Endura (colour print, defaults)'))
        di, _ = c.render(eng, img, dict(IO, **TX, digital_intermediate=True), base={}); rec(n, 'trix_DI', di); row.append(tile(di, 'Tri-X, Digital Intermediate (no paper)'))
        g2, p = c.render(eng, img, dict(IO, **TX, print_stock=c.PAPER, **c.grade_delta('2')), base={}); rec(n, 'trix_mgiv_filter2', g2); row.append(tile(g2, 'Tri-X -> MULTIGRADE IV RC, filter 2 (Y68, exp 1.0)'))
        c.save_png(g2, c.OUT / f'print_g2_{n}.png')
        fb, _ = c.render(eng, img, dict(IO, **TX, print_stock=c.PAPER), base={}); rec(n, 'trix_mgiv_no_row_fallback', fb); row.append(tile(fb, 'same, NO pack / no database row (silent M65 Y55)'))
        na, _ = c.render(eng, img, dict(IO, **TX, print_stock=c.PAPER, **c.grade_delta('2'), auto_exposure=False), base={}); rec(n, 'trix_mgiv_filter2_no_auto_exposure', na)
        rowsA.append(row)
        if n in ('smoke', '_DSC2704'):
            gr = []
            for g in ('00', '1', '2', '3', '4', '5'):
                d = c.grade_delta(g); r, _ = c.render(eng, img, dict(IO, **TX, print_stock=c.PAPER, **d), base={}); rec(n, 'trix_mgiv_filter' + g, r)
                gr.append(tile(r, 'filter %s  (M%.0f Y%.0f, exp %.2f)' % (g, d['m_filter_neutral'], d['y_filter_neutral'], d['print_exposure']), size=440))
            sheet([gr[:3], gr[3:]], c.OUT / f'sheet_grades_{n}.png')
sheet(rowsA, c.OUT / 'sheet_compare.png')
open(c.HERE / 'csv/image_stats.csv', 'w').write('\n'.join(lines) + '\n')
