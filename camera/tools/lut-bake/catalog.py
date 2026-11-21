#!/usr/bin/env python3
"""Develop Camera: the film list and how each film is developed, from Develop's own catalogue.

Reads Develop's StockCatalog.json (the 121 "filming" stocks) and paper_grades.json, and writes:
  jobs.tsv   one line per film for bake (C++): id, print stock, scan 0|1, then the B&W enlarger pack or "-"
  films.json the app's film list: id, name, short name, brand, kind, ISO, swatch, print, grain

Each film is developed as Develop develops it by default (desktop/src/shared/params.ts `heldToItsFilm`, `wire`;
the same rules as sonyalpha-film tools/develop/bake.py): a negative printed on its catalogue paper (black and
white on Ilford Multigrade at grade 2, the enlarger pack Develop sends), a slide scanned directly.

    python3 -I catalog.py <develop checkout> <out dir>
"""
import json
import pathlib
import sys

BRANDS = ("Kodak", "Fujifilm", "Ilford", "CineStill")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    develop, out = pathlib.Path(sys.argv[1]).expanduser(), pathlib.Path(sys.argv[2])
    stocks = json.loads((develop / "app/SpektraLab/Resources/StockCatalog.json").read_text())["stocks"]
    grade2 = json.loads((develop / "engine/resources_product/paper_grades.json").read_text())["grades"]["2"]
    films = [s for s in stocks if s["stage"] == "filming"]
    out.mkdir(parents=True, exist_ok=True)
    jobs, listing = [], []
    for s in films:
        scan = s["type"] == "positive"
        bw = s["kind"].startswith("b&w")
        paper = "-" if scan else s["targetPrint"]
        pack = ("%g %g %g" % (grade2["m_filter_neutral"], grade2["y_filter_neutral"], grade2["print_exposure"])
                if bw and not scan else "-")
        jobs.append("\t".join([s["id"], paper, "1" if scan else "0", pack]))
        brand = next((b for b in BRANDS if s["name"].startswith(b)), s["name"].split()[0])
        listing.append({
            "id": s["id"], "name": s["name"], "short": s.get("shortName", s["name"]), "brand": brand,
            "kind": s["kind"], "iso": s.get("iso"), "swatch": s.get("swatch"), "print": None if scan else paper,
            "grain": s.get("grain"), "lut": s["id"] + ".lut",
            # Black and white on Multigrade: the enlarger pack Develop sends (grade 2), for the engine.
            "pack": ([grade2["m_filter_neutral"], grade2["y_filter_neutral"], grade2["print_exposure"]]
                     if bw and not scan else None),
        })
    (out / "jobs.tsv").write_text("\n".join(jobs) + "\n")
    (out / "films.json").write_text(json.dumps({"films": listing}, indent=1) + "\n")
    print("%d films -> %s" % (len(films), out))


if __name__ == "__main__":
    main()
