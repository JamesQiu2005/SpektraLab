#!/usr/bin/env python3
"""gen_catalog.py -- write Resources/StockCatalog.json from the engine's profiles.

    app/SpektraLab/tools/gen_catalog.py

The desktop's `Tools/gen-catalog.py`, with two differences:

  * **The names are this script's** (`NAMES`): each stock's name, the desktop's (the
    profiles' `info.name`), and a short name for the cards, the maker dropped. A
    profile with no row fails this script instead of shipping without a name.
  * **A swatch per stock**, for the film cards, the paper cards and the library's
    stock dot. The five films and five papers drawn in `design/` keep the
    drawing's colours; the rest are this script's, chosen in the same key.

The order is the picker's: the drawing's first, then by family.

**The product's own profiles** (`engine/resources_product/profiles`, black and
white; `tools/build_engine_mac.sh` lays them into the app's engine resources beside
spektrafilm's) are listed with the rest since 2026-10-09, under the same rule: a
profile with no row in `NAMES` fails this script. What they carry that
the others do not, each absent on a colour stock so that no row of the 28 moved:

  * `monochrome`: the profile's `channel_model` is `bw`, a film with one silver
    emulsion or a silver paper. A silver film prints on a silver paper and a
    colour film on a colour one (`Model/Stock.swift`).
  * `grain`, a film's: what the Grain strength's 1 is on it, the `grain_amount`
    at which the engine renders the granularity its maker publishes (`OWN_GRAIN`).
  * `neutralPack`, a paper's: the enlarger's C, M, Y for it, which the host has
    to send because the engine's own table has no row for a silver paper. Read
    from the paper's grade table, Multigrade filter 2.
"""
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
PROFILES = REPO / "engine/resources/profiles"
PRODUCT_PROFILES = REPO / "engine/resources_product/profiles"
OUT = HERE / "Resources/StockCatalog.json"

# id -> (name, short name, kind). The name is the desktop's; the short name drops the maker.
NAMES = {
    "kodak_portra_400": ("Kodak Portra 400", "Portra 400", "colour negative"),
    "kodak_gold_200": ("Kodak Gold 200", "Gold 200", "colour negative"),
    "kodak_ektar_100": ("Kodak Ektar 100", "Ektar 100", "colour negative"),
    "kodak_vision3_500t": ("Kodak Vision3 500T", "Vision3 500T", "cine negative"),
    "cinestill_800t": ("CineStill 800T", "800T", "colour negative"),
    "fujifilm_pro_400h": ("Fujifilm Pro 400H", "Pro 400H", "colour negative"),
    "kodak_portra_160": ("Kodak Portra 160", "Portra 160", "colour negative"),
    "kodak_portra_800": ("Kodak Portra 800", "Portra 800", "colour negative"),
    "kodak_portra_800_push1": ("Kodak Portra 800 (Push 1)", "Portra 800 +1", "colour negative"),
    "kodak_portra_800_push2": ("Kodak Portra 800 (Push 2)", "Portra 800 +2", "colour negative"),
    "kodak_ultramax_400": ("Kodak Ultramax 400", "Ultramax 400", "colour negative"),
    "fujifilm_c200": ("Fujifilm C200", "C200", "colour negative"),
    "fujifilm_xtra_400": ("Fujifilm X-Tra 400", "X-Tra 400", "colour negative"),
    "kodak_ektachrome_100": ("Kodak Ektachrome 100", "Ektachrome 100", "slide (positive)"),
    "kodak_kodachrome_64": ("Kodak Kodachrome 64", "Kodachrome 64", "slide (positive)"),
    "fujifilm_provia_100f": ("Fujifilm Provia 100F", "Provia 100F", "slide (positive)"),
    "fujifilm_velvia_100": ("Fujifilm Velvia 100", "Velvia 100", "slide (positive)"),
    "kodak_vision3_50d": ("Kodak Vision3 50D", "Vision3 50D", "cine negative"),
    "kodak_vision3_200t": ("Kodak Vision3 200T", "Vision3 200T", "cine negative"),
    "kodak_vision3_250d": ("Kodak Vision3 250D", "Vision3 250D", "cine negative"),
    "kodak_verita_200d": ("Kodak Verita 200D", "Verita 200D", "cine negative"),
    "kodak_tri_x_400": ("Kodak Tri-X 400", "Tri-X 400", "b&w negative"),
    "kodak_tmax_100": ("Kodak T-Max 100", "T-Max 100", "b&w negative"),
    "fujifilm_neopan_acros_100_ii": ("Fujifilm Neopan 100 Acros II", "Acros 100 II", "b&w negative"),
    "ilford_hp5_plus_400": ("Ilford HP5 Plus 400", "HP5 Plus 400", "b&w negative"),
    "kodak_portra_endura": ("Kodak Professional Portra Endura", "Portra Endura", "colour paper"),
    "kodak_supra_endura": ("Kodak Professional Supra Endura", "Supra Endura", "colour paper"),
    "kodak_ultra_endura": ("Kodak Professional Ultra Endura", "Ultra Endura", "colour paper"),
    "fujifilm_crystal_archive_typeii": ("Fujifilm Crystal Archive Type II", "Crystal Archive II", "colour paper"),
    "kodak_2383": ("Kodak Vision 2383", "Vision 2383", "cine print film"),
    "kodak_endura_premier": ("Kodak Professional Endura Premier", "Endura Premier", "colour paper"),
    "kodak_ektacolor_edge": ("Kodak Ektacolor Edge", "Ektacolor Edge", "colour paper"),
    "kodak_2393": ("Kodak Vision Premier 2393", "Vision Premier 2393", "cine print film"),
    "ilford_multigrade_iv_rc": ("Ilford Multigrade IV RC", "Multigrade IV RC", "b&w paper"),
}
# What a profile's `info` does not say. CineStill 800T is Vision3 500T's emulsion with its
# remjet off, declared a still colour negative printed on 2383 (the desktop's catalogue).
INFO = {
    "cinestill_800t": {"stage": "filming", "type": "negative", "target_print": "kodak_2383"},
}

# design/src/gen.py (film cards, STOCK_DOT) and gen_flow.py (PAPERS) name these.
DRAWN = {
    "kodak_portra_400": "#d8a27a", "kodak_gold_200": "#e0b54a", "kodak_ektar_100": "#c4503f",
    "kodak_vision3_500t": "#46637f", "fujifilm_pro_400h": "#7fa38c",
    "fujifilm_provia_100f": "#5d8fd8", "kodak_kodachrome_64": "#c9a13c",
    "kodak_portra_endura": "#f3ede3", "kodak_supra_endura": "#f1ece4", "kodak_ultra_endura": "#f4efe6",
    "fujifilm_crystal_archive_typeii": "#eef0ee", "kodak_2383": "#151312",
}
# Not drawn: chosen beside the drawn ones, one hue per family.
CHOSEN = {
    "kodak_portra_160": "#e3b997", "kodak_portra_800": "#c98c62",
    "kodak_portra_800_push1": "#b97a52", "kodak_portra_800_push2": "#a66944",
    "kodak_ultramax_400": "#d98a3d", "kodak_ektachrome_100": "#4f7fc0",
    "kodak_vision3_50d": "#6d8fa3", "kodak_vision3_200t": "#57799a", "kodak_vision3_250d": "#5f8a92",
    "kodak_verita_200d": "#7a6c9c", "cinestill_800t": "#5b5f86",
    "fujifilm_c200": "#6fae7a", "fujifilm_xtra_400": "#5c9a69", "fujifilm_velvia_100": "#b4558a",
    "kodak_endura_premier": "#f2ede5", "kodak_ektacolor_edge": "#f0ece6", "kodak_2393": "#181513",
}
ORDER = [
    # camera films: the drawing's five, then the families
    "kodak_portra_400", "kodak_gold_200", "kodak_ektar_100", "kodak_vision3_500t", "cinestill_800t", "fujifilm_pro_400h",
    "kodak_portra_160", "kodak_portra_800", "kodak_portra_800_push1", "kodak_portra_800_push2",
    "kodak_ultramax_400", "fujifilm_c200", "fujifilm_xtra_400",
    "kodak_ektachrome_100", "kodak_kodachrome_64", "fujifilm_provia_100f", "fujifilm_velvia_100",
    "kodak_vision3_50d", "kodak_vision3_200t", "kodak_vision3_250d", "kodak_verita_200d",
    # print stocks: the drawing's five, then the rest
    "kodak_portra_endura", "kodak_supra_endura", "kodak_ultra_endura", "fujifilm_crystal_archive_typeii",
    "kodak_2383", "kodak_endura_premier", "kodak_ektacolor_edge", "kodak_2393",
]
# The product's own stocks: the black-and-white films after every colour film,
# their paper after every colour one, so no card that was there has moved.
ORDER[ORDER.index("kodak_portra_endura"):ORDER.index("kodak_portra_endura")] = [
    "kodak_tri_x_400", "kodak_tmax_100", "fujifilm_neopan_acros_100_ii", "ilford_hp5_plus_400"]
ORDER.append("ilford_multigrade_iv_rc")
# One family, so one hue: none. Four greys apart enough to tell on a card and
# as a library dot; the paper's base a neutral white beside the colour papers' creams.
CHOSEN.update({
    "kodak_tri_x_400": "#8c8a87", "kodak_tmax_100": "#a9a8a6", "fujifilm_neopan_acros_100_ii": "#c1c3c5",
    "ilford_hp5_plus_400": "#73716e", "ilford_multigrade_iv_rc": "#f1f1ef",
})
# What the Grain strength's 1 is on a black-and-white film: the desktop app's
# `FilmParams.ownGrain` (its 0bca29da), measured there on engine renders with
# the grain as one layer against each maker's published RMS granularity. The
# wire stops at 2, so Tri-X's ruler is at its end from 1.18 and HP5's from 1.34.
OWN_GRAIN = {"kodak_tri_x_400": 1.70, "ilford_hp5_plus_400": 1.49, "kodak_tmax_100": 0.74,
             "fujifilm_neopan_acros_100_ii": 0.64}
# A silver paper's grades as packs (`engine/resources_product/paper_grades.json`),
# and the filter new prints are made through.
PAPER_GRADES = REPO / "engine/resources_product/paper_grades.json"
GRADE = "2"


def iso_of(short: str):
    m = re.search(r"(\d{2,4})", short)
    return int(m.group(1)) if m else None


def main() -> None:
    paths = {p.stem: p for d in (PROFILES, PRODUCT_PROFILES) for p in sorted(d.glob("*.json"))}
    ids = sorted(paths)
    missing = [i for i in ids if i not in NAMES]
    if missing:
        raise SystemExit(f"no name in NAMES for: {', '.join(missing)}")
    unordered = [i for i in ids if i not in ORDER]
    if unordered:
        raise SystemExit(f"no place in the picker's order for: {', '.join(unordered)}")
    grades = json.loads(PAPER_GRADES.read_text()) if PAPER_GRADES.exists() else {}
    stocks = []
    for sid in [i for i in ORDER if i in ids]:
        info = {**json.loads(paths[sid].read_text())["info"], **INFO.get(sid, {})}
        name, short, kind = NAMES[sid]
        film = info.get("stage") == "filming"
        stock = {
            "id": sid,
            "name": name,
            "shortName": short,
            "kind": kind,
            "stage": info.get("stage"),            # filming | printing
            "use": info.get("use", "still"),       # still | cine
            "type": info.get("type"),              # negative | positive
            "targetPrint": info.get("target_print"),
            "iso": iso_of(short) if film else None,
            "swatch": DRAWN.get(sid) or CHOSEN[sid],
        }
        if info.get("channel_model") == "bw":
            stock["monochrome"] = True
            if film:
                if sid not in OWN_GRAIN:
                    raise SystemExit(f"no grain amount of its own for the black-and-white film {sid}")
                stock["grain"] = OWN_GRAIN[sid]
            else:
                if grades.get("paper") != sid or GRADE not in grades.get("grades", {}):
                    raise SystemExit(f"no filter {GRADE} pack for the silver paper {sid} in {PAPER_GRADES.name}")
                g = grades["grades"][GRADE]
                stock["neutralPack"] = [0.0, g["m_filter_neutral"], g["y_filter_neutral"]]
        stocks.append(stock)
    OUT.write_text(json.dumps({"stocks": stocks}, indent=1, ensure_ascii=False) + "\n")
    mono = [s["shortName"] for s in stocks if s.get("monochrome")]
    print(f"wrote {len(stocks)} stocks -> {OUT.relative_to(REPO)} ({len(mono)} black and white: {', '.join(mono)})")


if __name__ == "__main__":
    main()
