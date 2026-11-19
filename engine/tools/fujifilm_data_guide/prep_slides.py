#!/usr/bin/env python3
"""Turn digitise_cine.py's Kodak slide sheets into build_profiles.py inputs (positive chain, Status A, scanned)."""
import json, re, shutil, sys
from pathlib import Path
import pymupdf


def density_level(pdf, pages, default=1.0):
    d = pymupdf.open(pdf)
    t = "".join(d[p - 1].get_text() for p in (pages or range(1, len(d) + 1)))
    m = re.search(r"Densit(?:y|ometry)\s*:\s*([0-9.]+)\s*(?:above|\n|$)", t)
    return float(m.group(1)) if m else default


raw, specs, out = Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), Path(sys.argv[3])
by = {s["stock"]: s for s in specs}
for stock in sys.argv[4:]:
    spec = by[stock]
    dst = out / stock
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(raw / stock, dst)
    (dst / "dye_density_visual_neutral.csv").unlink(missing_ok=True)
    sheet = json.loads((dst / "sheet.json").read_text())
    sheet.update({"positive": True, "cine": True, "tungsten": spec["tungsten"], "trust": "1.0",
                  "process": spec.get("process", "E-6"),
                  # Kodak's slide sensitivity charts are all drawn at density 1.0 (stated on each chart); the text
                  # layer is too broken to parse it reliably (it gave 0, 2 and 200), and the engine only labels it
                  "sensitivity_density_over_min": 1.0})
    (dst / "sheet.json").write_text(json.dumps(sheet, indent=1, default=float))
    print(stock, "D", sheet["sensitivity_density_over_min"], sheet["process"], "tungsten" if spec["tungsten"] else "daylight")
