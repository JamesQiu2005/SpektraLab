import sys; sys.argv=[""]
exec(open("render_pair.py").read().split("# A 3:4 slot")[0])
ff = 24 * 2400 / 2133
run(src("snow"), {"film_format_mm": ff, "print_exposure": 2 ** -1.0}, OUT / "half_snow_p10.png")
gap = np.full((2133, 96, 3), 1e-6, np.float32)
run(gap, {"film_format_mm": 24.0, "auto_exposure": False, "print_exposure": 2 ** -1.0}, OUT / "gap_p10.png")
