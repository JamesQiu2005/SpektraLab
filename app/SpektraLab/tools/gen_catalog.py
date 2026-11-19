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
    at which the engine renders the granularity its maker publishes (`OWN_GRAIN`,
    `COLOUR_GRAIN`; a colour film with no comparable figure, its speed's).
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
    "kodak_portra_160nc": ("Kodak Portra 160NC", "Portra 160NC", "colour negative"),
    "kodak_portra_160vc": ("Kodak Portra 160VC", "Portra 160VC", "colour negative"),
    "kodak_portra_400nc": ("Kodak Portra 400NC", "Portra 400NC", "colour negative"),
    "kodak_portra_400vc": ("Kodak Portra 400VC", "Portra 400VC", "colour negative"),
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
    # the product's black-and-white films from makers' data sheets (2026-11-19)
    "ilford_pan_f_plus_50": ("Ilford Pan F Plus 50", "Pan F Plus 50", "b&w negative"),
    "ilford_fp4_plus_125": ("Ilford FP4 Plus 125", "FP4 Plus 125", "b&w negative"),
    "ilford_delta_100": ("Ilford Delta 100", "Delta 100", "b&w negative"),
    "ilford_delta_400": ("Ilford Delta 400", "Delta 400", "b&w negative"),
    "ilford_delta_3200": ("Ilford Delta 3200", "Delta 3200", "b&w negative"),
    "ilford_sfx_200": ("Ilford SFX 200", "SFX 200", "b&w negative"),
    "ilford_xp2_super_400": ("Ilford XP2 Super 400", "XP2 Super 400", "b&w negative"),
    "ilford_ortho_plus_80": ("Ilford Ortho Plus 80", "Ortho Plus 80", "b&w negative"),
    "kodak_tmax_400": ("Kodak T-Max 400", "T-Max 400", "b&w negative"),
    "kodak_tmax_p3200": ("Kodak T-Max P3200", "T-Max P3200", "b&w negative"),
    "kodak_plus_x_125": ("Kodak Plus-X 125", "Plus-X 125", "b&w negative"),
    "kodak_double_x_5222": ("Kodak Double-X 5222", "Double-X 250", "b&w negative"),
    "fujifilm_neopan_400": ("Fujifilm Neopan 400", "Neopan 400", "b&w negative"),
    "fujifilm_neopan_1600": ("Fujifilm Neopan 1600", "Neopan 1600", "b&w negative"),
    "kodak_portra_endura": ("Kodak Professional Portra Endura", "Portra Endura", "colour paper"),
    "kodak_supra_endura": ("Kodak Professional Supra Endura", "Supra Endura", "colour paper"),
    "kodak_ultra_endura": ("Kodak Professional Ultra Endura", "Ultra Endura", "colour paper"),
    "fujifilm_crystal_archive_typeii": ("Fujifilm Crystal Archive Type II", "Crystal Archive II", "colour paper"),
    "kodak_2383": ("Kodak Vision 2383", "Vision 2383", "cine print film"),
    "kodak_endura_premier": ("Kodak Professional Endura Premier", "Endura Premier", "colour paper"),
    "kodak_ektacolor_edge": ("Kodak Ektacolor Edge", "Ektacolor Edge", "colour paper"),
    "kodak_2393": ("Kodak Vision Premier 2393", "Vision Premier 2393", "cine print film"),
    "ilford_multigrade_iv_rc": ("Ilford Multigrade IV RC", "Multigrade IV RC", "b&w paper"),
    # the product's own, from FUJIFILM's Professional Data Guide AF3-207U (2005; NOTICE.md)
    "fujifilm_pro_160s": ("Fujifilm Pro 160S", "Pro 160S", "colour negative"),
    "fujifilm_pro_160c": ("Fujifilm Pro 160C", "Pro 160C", "colour negative"),
    "fujifilm_npl_160": ("Fujifilm NPL 160", "NPL 160", "colour negative"),
    "fujifilm_pro_800z": ("Fujifilm Pro 800Z", "Pro 800Z", "colour negative"),
    "fujifilm_superia_reala": ("Fujifilm Superia Reala", "Reala 100", "colour negative"),
    "fujifilm_superia_100": ("Fujifilm Superia 100", "Superia 100", "colour negative"),
    "fujifilm_superia_200": ("Fujifilm Superia 200", "Superia 200", "colour negative"),
    "fujifilm_true_definition_400": ("Fujifilm True Definition 400", "True Def. 400", "colour negative"),
    "fujifilm_superia_xtra_800": ("Fujifilm Superia X-TRA 800", "X-TRA 800", "colour negative"),
    "fujifilm_superia_1600": ("Fujifilm Superia 1600", "Superia 1600", "colour negative"),
    "fujifilm_nexia_a200": ("Fujifilm Nexia A200", "Nexia A200", "colour negative"),
    "fujifilm_nexia_400": ("Fujifilm Nexia 400", "Nexia 400", "colour negative"),
    "fujifilm_nexia_800": ("Fujifilm Nexia 800", "Nexia 800", "colour negative"),
    "fujifilm_velvia_50": ("Fujifilm Velvia 50", "Velvia 50", "slide (positive)"),
    "fujifilm_velvia_100f": ("Fujifilm Velvia 100F", "Velvia 100F", "slide (positive)"),
    "fujifilm_astia_100f": ("Fujifilm Astia 100F", "Astia 100F", "slide (positive)"),
    "fujifilm_provia_400f": ("Fujifilm Provia 400F", "Provia 400F", "slide (positive)"),
    "fujifilm_64t_type_ii": ("Fujifilm 64T Type II", "64T Type II", "slide (positive)"),
    "fujifilm_sensia_100": ("Fujifilm Sensia 100", "Sensia 100", "slide (positive)"),
    "fujifilm_sensia_200": ("Fujifilm Sensia 200", "Sensia 200", "slide (positive)"),
    "fujifilm_sensia_400": ("Fujifilm Sensia 400", "Sensia 400", "slide (positive)"),
    # the product's own motion-picture negatives, from the makers' data sheets (NOTICE.md)
    "fujifilm_eterna_250": ("Fujifilm Eterna 250", "Eterna 250", "cine negative"),
    "fujifilm_eterna_250d": ("Fujifilm Eterna 250D", "Eterna 250D", "cine negative"),
    "fujifilm_f_64d": ("Fujifilm F-64D", "F-64D", "cine negative"),
    "kodak_vision2_50d": ("Kodak Vision2 50D", "Vision2 50D", "cine negative"),
    "kodak_vision2_250d": ("Kodak Vision2 250D", "Vision2 250D", "cine negative"),
    "kodak_vision_500t_5263": ("Kodak Vision 500T (5263)", "Vision 500T 5263", "cine negative"),
    "kodak_vision_500t": ("Kodak Vision 500T", "Vision 500T", "cine negative"),
    "kodak_vision_320t": ("Kodak Vision 320T", "Vision 320T", "cine negative"),
    "kodak_vision_250d": ("Kodak Vision 250D", "Vision 250D", "cine negative"),
    "kodak_vision2_100t": ("Kodak Vision2 100T", "Vision2 100T", "cine negative"),
    "kodak_vision2_200t": ("Kodak Vision2 200T", "Vision2 200T", "cine negative"),
    "kodak_vision2_500t": ("Kodak Vision2 500T", "Vision2 500T", "cine negative"),
    "kodak_vision2_expression_500t": ("Kodak Vision2 Expression 500T", "Vision2 Expr. 500T", "cine negative"),
    "kodak_vision_500t_5263": ("Kodak Vision 500T (5263)", "Vision 500T 5263", "cine negative"),
    "kodak_vision_200t": ("Kodak Vision 200T", "Vision 200T", "cine negative"),
    "kodak_vision_800t": ("Kodak Vision 800T", "Vision 800T", "cine negative"),
    "fujifilm_reala_500d": ("Fujifilm Reala 500D", "Reala 500D", "cine negative"),
    # the product's own Kodak still negatives (NOTICE.md)
    "kodak_ultra_color_100uc": ("Kodak Ultra Color 100UC", "Ultra Color 100UC", "colour negative"),
    "kodak_ultra_color_400uc": ("Kodak Ultra Color 400UC", "Ultra Color 400UC", "colour negative"),
    "kodak_ektapress_pj100": ("Kodak Ektapress PJ100", "Ektapress PJ100", "colour negative"),
    "kodak_ektapress_pj800": ("Kodak Ektapress PJ800", "Ektapress PJ800", "colour negative"),
    "kodak_pro_100": ("Kodak Pro 100", "Pro 100", "colour negative"),
    "kodak_pro_400mc": ("Kodak Pro 400 MC", "Pro 400 MC", "colour negative"),
    # batch 4 (2026-11-19): current colour films and more cine stocks, from the makers' sheets
    "kodak_pro_image_100": ("Kodak Pro Image 100", "Pro Image 100", "colour negative"),
    "fujifilm_200": ("Fujifilm 200", "Fujifilm 200", "colour negative"),
    "fujifilm_400": ("Fujifilm 400", "Fujifilm 400", "colour negative"),
    "kodak_ektachrome_e100_2": ("Kodak Ektachrome 100 #2", "Ektachrome 100 #2", "slide (positive)"),
    "kodak_ektachrome_100d_7294": ("Kodak Ektachrome 100D 7294", "Ektachrome 100D", "slide (positive)"),
    "fujifilm_eterna_vivid_160": ("Fujifilm Eterna Vivid 160", "Eterna Vivid 160", "cine negative"),
    "fujifilm_eterna_400": ("Fujifilm Eterna 400", "Eterna 400", "cine negative"),
    "fujifilm_eterna_500": ("Fujifilm Eterna 500", "Eterna 500", "cine negative"),
    "kodak_supra_200": ("Kodak Supra 200", "Supra 200", "colour negative"),
    "kodak_supra_400": ("Kodak Supra 400", "Supra 400", "colour negative"),
    "kodak_royal_supra_200": ("Kodak Royal Supra 200", "Royal Supra 200", "colour negative"),
    "kodak_royal_supra_400": ("Kodak Royal Supra 400", "Royal Supra 400", "colour negative"),
    "kodak_royal_gold_100": ("Kodak Royal Gold 100", "Royal Gold 100", "colour negative"),
    "kodak_royal_gold_200": ("Kodak Royal Gold 200", "Royal Gold 200", "colour negative"),
    "kodak_royal_gold_400": ("Kodak Royal Gold 400", "Royal Gold 400", "colour negative"),
    "kodak_portra_100t": ("Kodak Portra 100T", "Portra 100T", "colour negative"),
    "kodak_profoto_100": ("Kodak Profoto 100", "Profoto 100", "colour negative"),
    "kodak_vericolor_iii": ("Kodak Vericolor III", "Vericolor III 160", "colour negative"),
    "kodak_high_definition_200": ("Kodak High Definition 200", "HD 200", "colour negative"),
    "kodak_high_definition_400": ("Kodak High Definition 400", "HD 400", "colour negative"),
    # the product's own Kodak slides, from Kodak's E- publications (NOTICE.md)
    "kodak_ektachrome_64": ("Kodak Ektachrome 64", "Ektachrome 64", "slide (positive)"),
    "kodak_ektachrome_64t": ("Kodak Ektachrome 64T", "Ektachrome 64T", "slide (positive)"),
    "kodak_ektachrome_100_plus": ("Kodak Ektachrome 100 Plus", "Ektachrome 100 Plus", "slide (positive)"),
    "kodak_ektachrome_e100vs": ("Kodak Ektachrome E100VS", "E100VS", "slide (positive)"),
    "kodak_ektachrome_e100g": ("Kodak Ektachrome E100G", "E100G", "slide (positive)"),
    "kodak_ektachrome_e200": ("Kodak Ektachrome E200", "E200", "slide (positive)"),
    "kodak_ektachrome_160t": ("Kodak Ektachrome 160T", "Ektachrome 160T", "slide (positive)"),
    "kodak_ektachrome_320t": ("Kodak Ektachrome 320T", "Ektachrome 320T", "slide (positive)"),
    "kodak_ektachrome_400x": ("Kodak Ektachrome 400X", "Ektachrome 400X", "slide (positive)"),
    "kodak_ektachrome_p1600": ("Kodak Ektachrome P1600", "Ektachrome P1600", "slide (positive)"),
    "kodak_elite_chrome_extra_color_100": ("Kodak Elite Chrome Extra Color 100", "Elite Chrome EC 100", "slide (positive)"),
    "kodak_elite_chrome_200": ("Kodak Elite Chrome 200", "Elite Chrome 200", "slide (positive)"),
    "kodak_elite_chrome_400": ("Kodak Elite Chrome 400", "Elite Chrome 400", "slide (positive)"),
    "kodak_kodachrome_25": ("Kodak Kodachrome 25", "Kodachrome 25", "slide (positive)"),
    "kodak_kodachrome_200": ("Kodak Kodachrome 200", "Kodachrome 200", "slide (positive)"),
}
# What a profile's `info` does not say. CineStill 800T is Vision3 500T's emulsion with its
# remjet off, declared a still colour negative printed on 2383 (the desktop's catalogue).
# Motion-picture negatives whose profiles say "still" (the engine reads a profile's `use`, so the profiles
# are left as they are): the picker shows them as cine, beside Vision3 (2026-11-19).
CINE_IN_CATALOGUE = {
    "fujifilm_eterna_500",
    "fujifilm_eterna_400",
    "fujifilm_eterna_vivid_160",
    "kodak_ektachrome_100d_7294",
    "kodak_vision2_50d",
    "kodak_vision2_100t",
    "kodak_vision2_200t",
    "kodak_vision2_250d",
    "kodak_vision2_500t",
    "kodak_vision2_expression_500t",
    "kodak_vision_200t",
    "kodak_vision_250d",
    "kodak_vision_320t",
    "kodak_vision_500t",
    "kodak_vision_500t_5263",
    "kodak_vision_800t",
    "fujifilm_eterna_250",
    "fujifilm_eterna_250d",
    "fujifilm_f_64d",
    "fujifilm_reala_500d",
}

INFO = {
    "cinestill_800t": {"stage": "filming", "type": "negative", "target_print": "kodak_2383"},
    # Kodak's ELITE Chrome consumer editions: aliases of the professional films whose curves they publish
    "kodak_elite_chrome_extra_color_100": {"stage": "filming", "type": "positive", "target_print": None},
    "kodak_elite_chrome_200": {"stage": "filming", "type": "positive", "target_print": None},
    # ROYAL SUPRA 200 and High Definition 200: aliases of SUPRA 200 (identical published curves)
    "kodak_royal_supra_200": {"stage": "filming", "type": "negative", "target_print": "kodak_portra_endura"},
    "kodak_high_definition_200": {"stage": "filming", "type": "negative", "target_print": "kodak_portra_endura"},
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
    # the 2006-2011 line: NC softer, VC deeper, beside their successors' hues
    "kodak_portra_160nc": "#e8c8ad", "kodak_portra_160vc": "#e0a47f",
    "kodak_portra_400nc": "#ddb390", "kodak_portra_400vc": "#d08c63",
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
    # the product's own colour films (E-190), with their family
    "kodak_portra_160nc", "kodak_portra_160vc", "kodak_portra_400nc", "kodak_portra_400vc",
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
# The product's black-and-white films from makers' data sheets (2026-11-19): after HP5 Plus.
BW_SHEETS = ['ilford_pan_f_plus_50', 'ilford_fp4_plus_125', 'ilford_delta_100', 'ilford_delta_400', 'ilford_delta_3200', 'ilford_sfx_200', 'ilford_xp2_super_400', 'ilford_ortho_plus_80', 'kodak_tmax_400', 'kodak_tmax_p3200', 'kodak_plus_x_125', 'kodak_double_x_5222', 'fujifilm_neopan_400', 'fujifilm_neopan_1600']
ORDER[ORDER.index("ilford_hp5_plus_400") + 1:ORDER.index("ilford_hp5_plus_400") + 1] = BW_SHEETS
# The product's Fujifilm films (AF3-207U): the negatives after X-Tra 400, the slides after Velvia 100,
# so no card that was there has moved relative to the others.
FUJI_NEGATIVES = ["fujifilm_pro_160s", "fujifilm_pro_160c", "fujifilm_npl_160", "fujifilm_pro_800z",
                  "fujifilm_superia_reala", "fujifilm_superia_100", "fujifilm_superia_200",
                  "fujifilm_true_definition_400", "fujifilm_superia_xtra_800", "fujifilm_superia_1600",
                  "fujifilm_nexia_a200", "fujifilm_nexia_400", "fujifilm_nexia_800"]
FUJI_SLIDES = ["fujifilm_velvia_50", "fujifilm_velvia_100f", "fujifilm_astia_100f", "fujifilm_provia_400f",
               "fujifilm_64t_type_ii", "fujifilm_sensia_100", "fujifilm_sensia_200", "fujifilm_sensia_400"]
ORDER[ORDER.index("fujifilm_xtra_400") + 1:ORDER.index("fujifilm_xtra_400") + 1] = FUJI_NEGATIVES
ORDER[ORDER.index("fujifilm_velvia_100") + 1:ORDER.index("fujifilm_velvia_100") + 1] = FUJI_SLIDES
# The product's Kodak still negatives after Ultramax 400.
KODAK_NEGS = ['kodak_ultra_color_100uc', 'kodak_ultra_color_400uc', 'kodak_ektapress_pj100', 'kodak_ektapress_pj800', 'kodak_pro_100', 'kodak_pro_400mc', 'kodak_supra_200', 'kodak_supra_400', 'kodak_royal_supra_200', 'kodak_royal_supra_400', 'kodak_royal_gold_100', 'kodak_royal_gold_200', 'kodak_royal_gold_400', 'kodak_portra_100t', 'kodak_profoto_100', 'kodak_vericolor_iii', 'kodak_high_definition_200', 'kodak_high_definition_400']
ORDER[ORDER.index("kodak_ultramax_400") + 1:ORDER.index("kodak_ultramax_400") + 1] = KODAK_NEGS
CHOSEN.update({"kodak_ultra_color_100uc": "#d9783f", "kodak_ultra_color_400uc": "#cf6a35", "kodak_ektapress_pj100": "#c7925c", "kodak_ektapress_pj800": "#b07a47", "kodak_pro_100": "#d6a983", "kodak_pro_400mc": "#c99470", "kodak_supra_200": "#dba06b", "kodak_supra_400": "#cf915c", "kodak_royal_supra_200": "#e0a56e", "kodak_royal_supra_400": "#d4965f", "kodak_royal_gold_100": "#e3be54", "kodak_royal_gold_200": "#dcb44a", "kodak_royal_gold_400": "#d3a940", "kodak_portra_100t": "#c4a490", "kodak_profoto_100": "#cfa87f", "kodak_vericolor_iii": "#b8977b", "kodak_high_definition_200": "#e2b06a", "kodak_high_definition_400": "#d6a15c"})
# The product's Kodak slides after Kodachrome 64.
KODAK_SLIDES = ['kodak_ektachrome_64', 'kodak_ektachrome_64t', 'kodak_ektachrome_100_plus', 'kodak_ektachrome_e100vs', 'kodak_ektachrome_e100g', 'kodak_ektachrome_e200', 'kodak_ektachrome_160t', 'kodak_ektachrome_320t', 'kodak_ektachrome_400x', 'kodak_ektachrome_p1600', 'kodak_elite_chrome_extra_color_100', 'kodak_elite_chrome_200', 'kodak_elite_chrome_400', 'kodak_kodachrome_25', 'kodak_kodachrome_200']
ORDER[ORDER.index("kodak_kodachrome_64") + 1:ORDER.index("kodak_kodachrome_64") + 1] = KODAK_SLIDES
CHOSEN.update({"kodak_ektachrome_64": "#5a86c4", "kodak_ektachrome_64t": "#4a6fb2", "kodak_ektachrome_100_plus": "#5f8dcc", "kodak_ektachrome_e100vs": "#3f74c8", "kodak_ektachrome_e100g": "#6a95cf", "kodak_ektachrome_e200": "#5582c0", "kodak_ektachrome_160t": "#4867a6", "kodak_ektachrome_320t": "#42609c", "kodak_ektachrome_400x": "#4d79b8", "kodak_ektachrome_p1600": "#3d5f98", "kodak_elite_chrome_extra_color_100": "#7aa0d6", "kodak_elite_chrome_200": "#7096cc", "kodak_elite_chrome_400": "#668cc2", "kodak_kodachrome_25": "#d1ad4a", "kodak_kodachrome_200": "#bf9530"})
# The product's cine negatives after Verita 200D: Kodak's older generations, then Fujifilm's.
CINE = ["kodak_vision2_50d", "kodak_vision2_100t", "kodak_vision2_200t", "kodak_vision2_250d", "kodak_vision2_500t",
        "kodak_vision2_expression_500t", "kodak_vision_200t", "kodak_vision_250d", "kodak_vision_320t", "kodak_vision_500t",
        "kodak_vision_500t_5263", "kodak_vision_800t", "fujifilm_eterna_250", "fujifilm_eterna_250d", "fujifilm_f_64d",
        "fujifilm_reala_500d"]
ORDER[ORDER.index("kodak_verita_200d") + 1:ORDER.index("kodak_verita_200d") + 1] = CINE
# batch 4 (2026-11-19): after their families; no card that was there moves relative to the others
ORDER[ORDER.index("kodak_high_definition_400") + 1:ORDER.index("kodak_high_definition_400") + 1] = ["kodak_pro_image_100"]
ORDER[ORDER.index("fujifilm_nexia_800") + 1:ORDER.index("fujifilm_nexia_800") + 1] = ["fujifilm_200", "fujifilm_400"]
ORDER[ORDER.index("kodak_kodachrome_200") + 1:ORDER.index("kodak_kodachrome_200") + 1] = ["kodak_ektachrome_e100_2", "kodak_ektachrome_100d_7294"]
ORDER[ORDER.index("fujifilm_reala_500d") + 1:ORDER.index("fujifilm_reala_500d") + 1] = ["fujifilm_eterna_vivid_160", "fujifilm_eterna_400", "fujifilm_eterna_500"]
CHOSEN.update({"kodak_pro_image_100": "#d9a26e", "fujifilm_200": "#5fae7a", "fujifilm_400": "#4f9e6c",
               "kodak_ektachrome_e100_2": "#4f86c9", "kodak_ektachrome_100d_7294": "#5a7fb8",
               "fujifilm_eterna_vivid_160": "#5f9488", "fujifilm_eterna_400": "#56877d", "fujifilm_eterna_500": "#4d7a72"})
CHOSEN.update({
    "kodak_vision2_50d": "#7a99ab", "kodak_vision2_250d": "#6a929a", "kodak_vision_500t_5263": "#56718b",
    "kodak_vision_500t": "#4f6a85", "kodak_vision_320t": "#5c7c96", "kodak_vision_250d": "#68959b",
    "fujifilm_eterna_250": "#5e8c88", "fujifilm_eterna_250d": "#6a9a8e", "fujifilm_f_64d": "#7aa59a",
    "kodak_vision2_100t": "#6f8fa6", "kodak_vision2_200t": "#63849d", "kodak_vision2_500t": "#527290",
    "kodak_vision2_expression_500t": "#5d6f8a", "kodak_vision_200t": "#5f809a", "kodak_vision_800t": "#47607c",
    "fujifilm_reala_500d": "#74a08a",
})
# Fujifilm's negatives in the greens of C200 / X-Tra / Pro 400H; its slides beside Provia's blue and Velvia's magenta.
CHOSEN.update({
    "fujifilm_pro_160s": "#8fb39a", "fujifilm_pro_160c": "#6f9f86", "fujifilm_npl_160": "#5f8f8a",
    "fujifilm_pro_800z": "#6c9480", "fujifilm_superia_reala": "#82b07e", "fujifilm_superia_100": "#78ad70",
    "fujifilm_superia_200": "#69a463", "fujifilm_true_definition_400": "#5e8f6e",
    "fujifilm_superia_xtra_800": "#4f8a5c", "fujifilm_superia_1600": "#477a52",
    "fujifilm_nexia_a200": "#9cbf7a", "fujifilm_nexia_400": "#8ab36a", "fujifilm_nexia_800": "#7aa35e",
    "fujifilm_velvia_50": "#a8467c", "fujifilm_velvia_100f": "#c06a98", "fujifilm_astia_100f": "#d1a0b8",
    "fujifilm_provia_400f": "#4a7cc4", "fujifilm_64t_type_ii": "#4b5fa8", "fujifilm_sensia_100": "#7aa5e0",
    "fujifilm_sensia_200": "#6a98d6", "fujifilm_sensia_400": "#5a8acb",
})
# One family, so one hue: none. Four greys apart enough to tell on a card and
# as a library dot; the paper's base a neutral white beside the colour papers' creams.
CHOSEN.update({
    "kodak_tri_x_400": "#8c8a87", "kodak_tmax_100": "#a9a8a6", "fujifilm_neopan_acros_100_ii": "#c1c3c5",
    "ilford_hp5_plus_400": "#73716e", "ilford_multigrade_iv_rc": "#f1f1ef",
})
# The black-and-white films from makers' data sheets: greys again, light for slow films, dark for fast ones.
CHOSEN.update({
    "ilford_pan_f_plus_50": "#cfcecb", "ilford_fp4_plus_125": "#b3b1ae", "ilford_delta_100": "#bab9b7",
    "ilford_delta_400": "#7f7d7a", "ilford_delta_3200": "#4f4e4c", "ilford_sfx_200": "#8f8580",
    "ilford_xp2_super_400": "#867a76", "ilford_ortho_plus_80": "#b9b3a5", "kodak_tmax_400": "#7b7c7e",
    "kodak_tmax_p3200": "#5a5b5d", "kodak_plus_x_125": "#a3a19c", "kodak_double_x_5222": "#696866",
    "fujifilm_neopan_400": "#858789", "fujifilm_neopan_1600": "#5f6163",
})
# What the Grain strength's 1 is on a black-and-white film: the desktop app's
# `FilmParams.ownGrain` (its 0bca29da), measured there on engine renders with
# the grain as one layer against each maker's published RMS granularity. The
# wire stops at 2, so Tri-X's ruler is at its end from 1.18 and HP5's from 1.34.
OWN_GRAIN = {"kodak_tri_x_400": 1.70, "ilford_hp5_plus_400": 1.49, "kodak_tmax_100": 0.74,
             "fujifilm_neopan_acros_100_ii": 0.64}
# The black-and-white films from makers' data sheets (2026-11-19). The engine's visual RMS at grain 1 measured with
# engine/tools/fujifilm_data_guide/grain_probe.py (scanned, the grain as one layer, 6 um pixels, net D 1.0, 8x8 px
# for the 48 um circle); that probe reads the four rows above at 0.96 x their makers' RMS (Tri-X 17, T-Max 100 8,
# Acros II 7; HP5 Plus's row implies 16), so each figure is 0.96 x target / measured, capped at the wire's 2.
# SHEET: the maker's diffuse RMS granularity (T-Max 400 10, P3200 18, Plus-X 10, Double-X 14).
# RULE: no figure published (HARMAN publishes none; FUJIFILM's guide none for Neopan): the RMS a film of that speed
# has in its family, fitted on the published ones: conventional (Plus-X, Double-X, Tri-X) 10 x (ISO/125)^0.458,
# tabular (T-Max 100/400, P3200, Acros II) 10.0 x (ISO/250)^0.352 (Delta at ISO 1000 for Delta 3200; XP2 Super's dye
# image on the tabular rule). About +-20 %.
OWN_GRAIN.update({
    # SHEET
    "kodak_tmax_400": 0.93, "kodak_tmax_p3200": 1.89, "kodak_plus_x_125": 0.98, "kodak_double_x_5222": 1.30,
    # RULE
    "ilford_fp4_plus_125": 1.41, "ilford_pan_f_plus_50": 0.58, "ilford_sfx_200": 1.31, "ilford_ortho_plus_80": 0.71,
    "fujifilm_neopan_400": 1.91, "fujifilm_neopan_1600": 2.0, "ilford_delta_100": 0.64, "ilford_delta_400": 1.24,
    "ilford_delta_3200": 2.0, "ilford_xp2_super_400": 1.63,
})
# What the Grain strength's 1 is on a colour film (2026-11-11, the owner: "each colour film, negative and
# positive, has its own default grain"): the `grain_amount` at which the engine renders the film's granularity,
# with the sub-layers on (the app's default), at 6 µm pixels. Two sources, never mixed in one row:
# - SHEET: the maker's diffuse RMS granularity (48 µm, D 1.0) over what the engine renders at 1, measured
#   2026-10-07 (research/colour-film-granularity.md §4, commit ccbfadde). Slides on the visual figure;
#   Vision3 and Verita on the green record of their H-1 sheets' curves.
# - ISO: no comparable figure is published. Kodak's still negatives carry only Print Grain Index, which Kodak
#   says cannot be compared with RMS (E-58); Fujifilm's negative "4" is footnoted as not comparable with its
#   reversal scale. Searched again 2026-11-11 (Kodak and Fujifilm sheets, JP editions, pre-1996 predecessors):
#   nothing. So the target is the green record a Vision3 stock of that speed has, fitted on the four Vision3
#   sheets, G = 4.498 × (ISO/50)^0.212, over what the engine renders in green at 1.
# The pushed Portra 800 profiles take Portra 800's: the push is already in their profiles, which render grainier.
COLOUR_GRAIN = {
    # SHEET
    "kodak_kodachrome_64": 1.15, "fujifilm_provia_100f": 0.96, "fujifilm_velvia_100": 0.99,
    "kodak_ektachrome_100": 0.88, "kodak_vision3_500t": 1.01, "kodak_vision3_200t": 1.01,
    "kodak_vision3_250d": 0.83, "kodak_vision3_50d": 0.69, "kodak_verita_200d": 1.06,
    # CineStill 800T is Vision3 500T's emulsion (its profile is an alias of 500T's data) and publishes no sheet.
    "cinestill_800t": 1.01,
    # ISO
    "kodak_portra_160": 0.92, "kodak_portra_400": 1.06, "kodak_portra_800": 1.23,
    "kodak_portra_800_push1": 1.23, "kodak_portra_800_push2": 1.23,
    "kodak_ektar_100": 0.79, "kodak_gold_200": 0.97, "kodak_ultramax_400": 1.09,
    "fujifilm_c200": 0.70, "fujifilm_xtra_400": 0.74, "fujifilm_pro_400h": 1.20,
    # ISO, the product's own profiles (2026-11-15; the same probe re-measured Portra 160 / 400 at 0.915 / 1.062):
    # green 7.29 / 8.34 / 7.46 / 8.61 at 1. VC's steeper curves render grainier, so it takes less to reach its speed's.
    "kodak_portra_160nc": 0.79, "kodak_portra_160vc": 0.69, "kodak_portra_400nc": 0.94, "kodak_portra_400vc": 0.81,
    # The product's Fujifilm films (2026-11-18, AF3-207U). Measured on the Linux engine with a probe rebuilt for
    # it (engine/tools/fujifilm_data_guide/grain_probe.py: scanned, sub-layers on, 6 um pixels, net D 1.0,
    # an 8x8 px aperture for the 48 um circle) and scaled by what that probe reads on this table's own rows,
    # per family: slides x1.023 (Provia 100F, Velvia 100), negatives x0.987 (Pro 400H, C200, Portra 400).
    # The probe reproduces those rows to within 10 %, so each figure below carries about that.
    # SHEET: Fujifilm's diffuse RMS granularity (48 um, D 1.0), the slides'.
    "fujifilm_velvia_50": 0.92, "fujifilm_velvia_100f": 0.79, "fujifilm_astia_100f": 0.56,
    "fujifilm_provia_400f": 1.47, "fujifilm_64t_type_ii": 0.78, "fujifilm_sensia_100": 0.68,
    "fujifilm_sensia_200": 1.3, "fujifilm_sensia_400": 1.05,
    # ISO: the guide footnotes its negatives' RMS (3-7) as not comparable with its reversal scale, so the rule above.
    "fujifilm_pro_160s": 1.11, "fujifilm_pro_160c": 0.98, "fujifilm_npl_160": 0.86, "fujifilm_pro_800z": 0.96,
    "fujifilm_superia_reala": 0.47, "fujifilm_superia_100": 0.32, "fujifilm_superia_200": 0.55,
    "fujifilm_true_definition_400": 0.90, "fujifilm_superia_xtra_800": 0.93, "fujifilm_superia_1600": 1.21,
    "fujifilm_nexia_a200": 0.83, "fujifilm_nexia_400": 0.87, "fujifilm_nexia_800": 1.18,
    # The product's cine negatives (2026-11-19): ISO rule, the same probe and family factor (x0.987). The makers'
    # granularity curves (as the Vision3 rows above use) are not digitised for these yet.
    "fujifilm_eterna_250": 1.34,
    "fujifilm_eterna_250d": 1.15,
    "fujifilm_f_64d": 0.79,
    "kodak_vision2_50d": 1.09,
    "kodak_vision2_250d": 1.15,
    "kodak_vision_250d": 1.0,
    "kodak_vision_320t": 0.84,
    "kodak_vision_500t": 0.99,
    # The product's Kodak still negatives (2026-11-19): ISO rule, the same probe and factor (x0.987); the two aliases
    # take SUPRA 200's.
    "kodak_ultra_color_100uc": 0.75,
    "kodak_ultra_color_400uc": 1.16,
    "kodak_ektapress_pj100": 0.83,
    "kodak_ektapress_pj800": 0.98,
    "kodak_pro_100": 0.72,
    "kodak_pro_400mc": 1.2,
    "kodak_supra_200": 0.86,
    "kodak_supra_400": 1.07,
    "kodak_royal_supra_400": 1.2,
    "kodak_royal_gold_100": 0.88,
    "kodak_royal_gold_200": 0.97,
    "kodak_royal_gold_400": 0.92,
    "kodak_portra_100t": 0.73,
    "kodak_profoto_100": 0.79,
    "kodak_vericolor_iii": 0.53,
    "kodak_high_definition_400": 1.19,
    "kodak_royal_supra_200": 0.86,
    "kodak_high_definition_200": 0.86,
    # The product's Kodak slides (2026-11-19): SHEET, Kodak's diffuse rms granularity (E-163 etc.; P1600's 34 is at EI 1600),
    # the same probe and slide factor (x1.023). The two ELITE Chrome aliases take their professional twin's figure.
    "kodak_ektachrome_64": 1.18,
    "kodak_ektachrome_64t": 1.14,
    "kodak_ektachrome_100_plus": 1.31,
    "kodak_ektachrome_e100vs": 0.8,
    "kodak_ektachrome_e100g": 0.8,
    "kodak_ektachrome_e200": 1.18,
    # batch 4 (2026-11-19), the same probe and family factors. ISO rule (x0.987): Pro Image 100, Fujifilm 200 / 400 (the
    # sheets give Print Grain Index or nothing comparable), Eterna Vivid 160 / 400 / 500. SHEET (x1.023): E100 (E-4000,
    # RMS 8); Ektachrome 100D publishes a granularity curve, not a figure: E100's 8 is taken (its still twin).
    "kodak_pro_image_100": 0.79, "fujifilm_200": 1.04, "fujifilm_400": 1.02, "kodak_ektachrome_e100_2": 0.80,
    "kodak_ektachrome_100d_7294": 1.13, "fujifilm_eterna_vivid_160": 1.02, "fujifilm_eterna_400": 0.97,
    "fujifilm_eterna_500": 1.20,
    "kodak_ektachrome_160t": 1.24,
    "kodak_ektachrome_320t": 1.57,
    "kodak_ektachrome_400x": 1.98,
    "kodak_ektachrome_p1600": 2.0,
    "kodak_elite_chrome_400": 1.95,
    "kodak_kodachrome_25": 0.61,
    "kodak_kodachrome_200": 1.92,
    "kodak_elite_chrome_extra_color_100": 0.8,
    "kodak_elite_chrome_200": 1.18,
    "kodak_vision2_100t": 0.91,
    "kodak_vision2_200t": 1.05,
    "kodak_vision2_500t": 2.0,
    "kodak_vision2_expression_500t": 1.57,
    "kodak_vision_500t_5263": 1.24,
    "kodak_vision_200t": 1.07,
    "kodak_vision_800t": 0.93,
    "fujifilm_reala_500d": 1.65,
}
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
            "use": "cine" if sid in CINE_IN_CATALOGUE else info.get("use", "still"),       # still | cine
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
        if film and info.get("channel_model") != "bw":
            if sid not in COLOUR_GRAIN:
                raise SystemExit(f"no grain amount of its own for the colour film {sid}")
            stock["grain"] = COLOUR_GRAIN[sid]
        stocks.append(stock)
    OUT.write_text(json.dumps({"stocks": stocks}, indent=1, ensure_ascii=False) + "\n")
    mono = [s["shortName"] for s in stocks if s.get("monochrome")]
    print(f"wrote {len(stocks)} stocks -> {OUT.relative_to(REPO)} ({len(mono)} black and white: {', '.join(mono)})")


if __name__ == "__main__":
    main()
