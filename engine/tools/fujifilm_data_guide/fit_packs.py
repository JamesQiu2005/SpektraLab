#!/usr/bin/env python3
"""Fit the neutral print pack of each Fujifilm Data Guide film on every colour paper, through the engine,
into engine/resources_product/neutral_print_filters_colour.json.

    python3 engine/tools/fujifilm_data_guide/fit_packs.py --library build/linux/engine/spektralab_engine.so \
        --resources RESOURCES [--check] film [film ...]

RESOURCES is a staged engine resources directory that holds the films' profiles (build-linux.sh stages
engine/resources_product over engine/resources, so build/host-linux-x64/engine does once they are
committed). The fit is spektrafilm's `fit_print_filters`, run through the SpektraLab engine as the
rows already in the file were: C held at 0, M, Y and print exposure free, an sRGB 18 % grey printed
back at 18 % under TH-KG3 (`packfit.py`). The same fit reproduces rows already in both tables to 0.002.
`--check` refits and compares instead of writing.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "engine/tests"))
sys.path.insert(0, str(HERE))
import spk_ctypes as spk  # noqa: E402
import packfit  # noqa: E402

TABLE = REPO / "engine/resources_product/neutral_print_filters_colour.json"
PAPERS = ["kodak_portra_endura", "kodak_supra_endura", "kodak_ultra_endura", "kodak_endura_premier",
          "kodak_ektacolor_edge", "fujifilm_crystal_archive_typeii", "kodak_2383", "kodak_2393"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", required=True)
    ap.add_argument("--resources", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("films", nargs="+")
    a = ap.parse_args()
    table = json.loads(TABLE.read_text())
    # The engine prints with a film's row when the table has one, whatever pack is sent; fit through a
    # copy of the resources whose colour table does not name these films.
    tmp = Path(tempfile.mkdtemp(prefix="fuji-packs-"))
    src = Path(a.resources).resolve()
    for f in src.iterdir():
        if f.name != "neutral_print_filters_colour.json":
            os.symlink(f, tmp / f.name)
    staged = json.loads((src / "neutral_print_filters_colour.json").read_text())
    for paper in staged.values():
        for rows in paper.values():
            for film in a.films:
                rows.pop(film, None)
    (tmp / "neutral_print_filters_colour.json").write_text(json.dumps(staged))
    e = spk.Engine(library=a.library, resources=tmp)
    worst = 0.0
    for film in a.films:
        for paper in PAPERS:
            pack, pe, res = packfit.fit_pack(e, film, paper)
            pack = [round(v, 4) for v in pack]
            if a.check:
                want = table[paper]["TH-KG3"][film]
                d = max(abs(x - y) for x, y in zip(pack, want))
                worst = max(worst, d)
                print(f"{film} -> {paper}: {pack} (row {want}, |d| {d:.4f})")
            else:
                table.setdefault(paper, {}).setdefault("TH-KG3", {})[film] = pack
                print(f"{film} -> {paper}: {pack}  print exposure {pe:.4f}  grey residual {res:.1e}", flush=True)
    if a.check:
        print(f"largest difference {worst:.4f}")
        return int(worst > 0.01)
    TABLE.write_text(json.dumps(table, indent=1) + "\n")
    print(f"wrote {TABLE.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
