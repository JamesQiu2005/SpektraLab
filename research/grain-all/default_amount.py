"""Per-film default grain_amount from published RMS granularity.

    default_amount = R_published / R_engine(grain_amount = 1)

because the engine's RMS is exactly linear in grain_amount (linearity.py). One value per grain path.

    python default_amount.py published.csv [--pitch 6] [--out default_amounts.csv]
    python default_amount.py --stock kodak_tri_x_400 --rms 17 [--basis visual_net]

published.csv / .json: columns (or keys)  stock, rms [, basis]   -- other columns are ignored.
  basis = visual_net   net visual density 1.0 on the neutral patch (default; "1.0 above minimum density")
          visual_gross gross visual density 1.0 (measured for the positives only; Kodak reversal sheets)
          R | G | B    one dye record at net density 1.0 in that record
A stock may appear on several rows (e.g. one per basis). Rows whose rms is blank are skipped.
The wire range of grain_amount is 0..2; a value outside it is flagged OUT_OF_RANGE and cannot be sent.
"""
import argparse, csv, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LO, HI = 0.0, 2.0
BASIS = {"visual_net": ("visual", "net_1.0"), "visual_gross": ("visual", "gross_1.0"),
         "R": ("channels", "R"), "G": ("channels", "G"), "B": ("channels", "B")}


def engine_rms(table, stock, basis, mode, pitch):
    try:
        node = table[stock][BASIS[basis][0]][BASIS[basis][1]][f"{mode}_{pitch:g}um"]
        return node["rms48"]
    except KeyError:
        return None


def rows_from(path):
    p = Path(path)
    if p.suffix == ".json":
        data = json.load(open(p))
        if isinstance(data, dict):
            data = [dict(stock=k, **(v if isinstance(v, dict) else {"rms": v})) for k, v in data.items()]
        return data
    with open(p, newline="") as fh:
        return list(csv.DictReader(fh))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("published", nargs="?")
    ap.add_argument("--stock"); ap.add_argument("--rms", type=float); ap.add_argument("--basis", default="visual_net")
    ap.add_argument("--pitch", type=float, default=6.0, choices=[4.0, 6.0, 12.0])
    ap.add_argument("--engine", default=str(HERE / "engine_rms.json"))
    ap.add_argument("--out")
    a = ap.parse_args()
    table = json.load(open(a.engine))
    rows = rows_from(a.published) if a.published else [dict(stock=a.stock, rms=a.rms, basis=a.basis)]
    out = []
    for r in rows:
        stock, rms = r.get("stock"), r.get("rms")
        if rms in (None, ""):
            continue
        rms = float(rms)
        basis = (r.get("basis") or a.basis).strip()
        if stock not in table or basis not in BASIS:
            out.append([stock, basis, rms, a.pitch, "", "", "", "", "", "", "UNKNOWN_STOCK_OR_BASIS"]); continue
        line, flags = [stock, basis, rms, a.pitch], []
        for mode, label in (("sub", "sublayers_on"), ("single", "sublayers_off")):
            e = engine_rms(table, stock, basis, mode, a.pitch)
            if e is None:
                line += ["", "", ""]; flags.append(f"{label}:NOT_MEASURED"); continue
            k = rms / e
            ok = LO <= k <= HI
            line += [round(e, 3), round(k, 3), "ok" if ok else "OUT_OF_RANGE"]
            if not ok:
                flags.append(f"{label}:OUT_OF_RANGE")
        out.append(line + [";".join(flags)])
    head = ["stock", "basis", "published_rms", "pitch_um",
            "engine_rms_sublayers_on", "amount_sublayers_on", "range_sublayers_on",
            "engine_rms_sublayers_off", "amount_sublayers_off", "range_sublayers_off", "flags"]
    w = csv.writer(open(a.out, "w", newline="") if a.out else sys.stdout)
    w.writerow(head); w.writerows(out)


if __name__ == "__main__":
    main()
