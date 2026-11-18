import numpy as np, scipy.optimize
QUIET = {"grain_active": False, "glare_active": False, "halation_active": False, "auto_exposure": False,
         "input_cctf_decoding": False, "input_color_space": "sRGB", "output_color_space": "sRGB",
         "output_cctf_encoding": False}
GREY = np.full((8, 8, 3), 0.184, np.float32)

def mean_rgb(s):
    rgba, _ = s.render("full")
    return rgba[2:-2, 2:-2, :3].astype(np.float64).mean((0, 1)) / 65535.0

def fit_pack(e, film, paper, x0=(50.0, 40.0, 1.0)):
    """spektrafilm's fit_print_filters through the engine: C 0, M, Y and print exposure free,
    18 % grey printed back at 18 % (no database row, no print exposure compensation)."""
    # a film with no database row prints with the pack sent; print_exposure_compensation only acts on
    # a camera EV, which is 0 here
    s = e.open(GREY, dict(QUIET, film_stock=film, print_stock=paper, c_filter_neutral=0.0))
    try:
        def res(x):
            s.set_params({"m_filter_neutral": float(x[0]), "y_filter_neutral": float(x[1]), "print_exposure": float(x[2])})
            return mean_rgb(s) - 0.184
        best = None
        for start in (x0, (30.0, 30.0, 1.0), (70.0, 60.0, 1.0)):
            f = scipy.optimize.least_squares(res, start, bounds=([0, 0, 0.05], [200, 200, 20]), diff_step=1e-3,
                                             x_scale=[10, 10, 0.1], xtol=1e-10, ftol=1e-12, gtol=1e-12)
            if best is None or f.cost < best.cost:
                best = f
            if np.abs(f.fun).max() < 1e-4:
                break
        return [0.0, float(best.x[0]), float(best.x[1])], float(best.x[2]), float(np.abs(best.fun).max())
    finally:
        s.close()
