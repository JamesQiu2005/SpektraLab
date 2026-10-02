#!/usr/bin/env python3
"""Build Resources/StockCatalog.json and Resources/FilmCovers/ from the engine's
profile library, so the app never parses the 5.6 MB of sensitometric JSON.

    Tools/gen-catalog.py
"""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]

# Read from the engine's own baked resources, not from the Python reference
# tree under `src/`. This is the difference the standalone repo makes: `src/`
# is not here, and `engine/resources/` is — the same 28 profiles the engine
# opens at run time, plus `print_luts.json`, which is the metadata index over
# the 8 print-preview LUTs (`paired_film`, `lut_size`, and so on) that the bake
# wrote. Deriving the catalog from the engine's inputs means the catalog cannot
# disagree with what the engine will actually load.
PROFILES = REPO / "engine/resources/profiles"
PRINT_LUTS = REPO / "engine/resources/print_luts.json"
COVERS_SRC = REPO / "modern_UI/film_covers"
OUT = HERE / "Spektrafilm/Resources"

# stock id -> substring of the cover filename
COVERS = {
    "kodak_portra_400": "Kodak_Portra_400",
    "kodak_portra_160": "Kodak_Portra_160",
    "kodak_portra_800": "Kodak_Portra_800",
    "kodak_portra_800_push1": "Kodak_Portra_800",
    "kodak_portra_800_push2": "Kodak_Portra_800",
    "kodak_gold_200": "Kodak_Gold_200",
    "kodak_ektachrome_100": "Kodak_Ektachrome_100",
    "kodak_ultramax_400": "Kodak_UltraMax_400",
    "fujifilm_provia_100f": "Fujifilm_Provia_100F",
    "fujifilm_velvia_100": "Fujifilm_Velvia_100",
    "fujifilm_xtra_400": "Fujifilm_Color_400",
}


# Film stock -> the film gauges its manufacturer made it in, ever (current or
# discontinued; third-party respooling does not count). From
# SpektraLab_mobile/research/overscan/availability.md (2026-10-01), where every
# cell is sourced; that table is the reference, this is its "yes" and
# "discontinued" cells. Gauges: "135", "120", "16mm", "super8", "35mm_motion".
# Format availability is not profile data (RFC-032 §22), so it lives here and
# not in the CC BY-SA profiles. A stock missing from this table gets no
# `formats` key, which the app reads as "not known: offer every format".
FORMATS = {
    "fujifilm_c200": ["135"],
    "fujifilm_pro_400h": ["135", "120"],
    "fujifilm_provia_100f": ["135", "120"],
    "fujifilm_velvia_100": ["135", "120"],
    "fujifilm_xtra_400": ["135", "120"],
    "kodak_ektachrome_100": ["135", "120", "16mm", "super8"],
    "kodak_ektar_100": ["135", "120"],
    "kodak_gold_200": ["135", "120"],
    "kodak_kodachrome_64": ["135", "120"],
    "kodak_portra_160": ["135", "120"],
    "kodak_portra_400": ["135", "120"],
    "kodak_portra_800": ["135", "120"],
    "kodak_portra_800_push1": ["135", "120"],
    "kodak_portra_800_push2": ["135", "120"],
    "kodak_ultramax_400": ["135"],
    "kodak_verita_200d": ["16mm", "35mm_motion"],
    "kodak_vision3_200t": ["16mm", "super8", "35mm_motion"],
    "kodak_vision3_250d": ["16mm", "35mm_motion"],
    "kodak_vision3_500t": ["16mm", "super8", "35mm_motion"],
    "kodak_vision3_50d": ["16mm", "super8", "35mm_motion"],
}


def main() -> None:
    (OUT / "FilmCovers").mkdir(parents=True, exist_ok=True)
    luts = json.loads(PRINT_LUTS.read_text())
    stocks = []
    for path in sorted(PROFILES.glob("*.json")):
        info = json.loads(path.read_text())["info"]
        sid = path.stem
        cover = None
        if sid in COVERS:
            src = next(COVERS_SRC.glob(f"*{COVERS[sid]}*"), None)
            if src:
                cover = f"{sid}.jpg"
                dst = OUT / "FilmCovers" / cover
                if not dst.exists():
                    subprocess.run(["sips", "-Z", "160", str(src), "--out", str(dst)],
                                   check=True, capture_output=True)
        entry = {
            "id": sid,
            "name": info.get("name", sid),
            "stage": info.get("stage"),            # filming | printing
            "use": info.get("use", "still"),       # still | cine
            "type": info.get("type"),
            "targetPrint": info.get("target_print"),
            "hasPreviewLUT": sid in luts,
            "pairedFilm": luts[sid]["paired_film"] if sid in luts else None,
            "cover": cover,
        }
        if sid in FORMATS:
            entry["formats"] = FORMATS[sid]
        stocks.append(entry)
    (OUT / "StockCatalog.json").write_text(json.dumps({"stocks": stocks}, indent=1))
    print(f"wrote {len(stocks)} stocks")


if __name__ == "__main__":
    main()
