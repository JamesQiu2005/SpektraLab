# Minilab coverage ledger

Generated 2026-10-25T14:56:09+0800 by `engine/tools/minilab_bake/report.py`.

| | count |
|---|---:|
| Colour pairs qualified | **97 / 136** |
| Production tables qualified | **194 / 272** |
| Production tables staged into `engine/resources/minilab/` | 194 |
| Full qualified coverage | **no** |

A pair counts as qualified only when *both* calibration spaces reached
`visual_pass`; "the files exist" is not the criterion.

## Special routes (never counted as colour minilab)

| route | rows | disposition | evidence |
|---|---:|---|---|
| silver_path | 4 | accounted, own runtime path preserved | `engine/tests/bw_checks.py` |
| positive_bypass | 36 | accounted, own runtime path preserved | `engine/src/pipeline/pipeline.cpp (positive print bypass)` |
| incompatible_channel_models | 49 | accounted, own runtime path preserved | `engine/src/core/profile.cpp pairing rule + minilab_inventory.py` |

## Colour pairs

| film | paper | default | sRGB | ProPhoto | qualified |
|---|---|:-:|---|---|:-:|
| cinestill_800t | fujifilm_crystal_archive_typeii |  | staged | staged | **yes** |
| cinestill_800t | kodak_2383 | yes | staged | staged | **yes** |
| cinestill_800t | kodak_2393 |  | staged | staged | **yes** |
| cinestill_800t | kodak_ektacolor_edge |  | staged | staged | **yes** |
| cinestill_800t | kodak_endura_premier |  | gate_failed | gate_failed | no |
| cinestill_800t | kodak_portra_endura |  | staged | staged | **yes** |
| cinestill_800t | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| cinestill_800t | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| fujifilm_c200 | fujifilm_crystal_archive_typeii | yes | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_c200 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | fujifilm_crystal_archive_typeii | yes | integrated_verified | integrated_verified | **yes** |
| fujifilm_pro_400h | kodak_2383 |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | kodak_2393 |  | numeric_pass | gate_failed | no |
| fujifilm_pro_400h | kodak_ektacolor_edge |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | kodak_endura_premier |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | kodak_portra_endura |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | kodak_supra_endura |  | gate_failed | gate_failed | no |
| fujifilm_pro_400h | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| fujifilm_xtra_400 | fujifilm_crystal_archive_typeii | yes | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| fujifilm_xtra_400 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_ektar_100 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_ektar_100 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_gold_200 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_gold_200 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_gold_200 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_160 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_portra_160 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_160 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_400 | fujifilm_crystal_archive_typeii |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_2383 |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_2393 |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_ektacolor_edge |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_portra_endura | yes | visual_pass | visual_pass | **yes** |
| kodak_portra_400 | kodak_supra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_400 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_800 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_800_push1 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push1 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_portra_800_push2 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push2 | kodak_2383 |  | gate_failed | gate_failed | no |
| kodak_portra_800_push2 | kodak_2393 |  | gate_failed | gate_failed | no |
| kodak_portra_800_push2 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push2 | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_portra_800_push2 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push2 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_portra_800_push2 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_ultramax_400 | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_2383 |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_portra_endura | yes | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_ultramax_400 | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_verita_200d | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_2383 | yes | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_endura_premier |  | numeric_pass | gate_failed | no |
| kodak_verita_200d | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_verita_200d | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_vision3_200t | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_200t | kodak_2383 | yes | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_200t | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_200t | kodak_ektacolor_edge |  | numeric_pass | gate_failed | no |
| kodak_vision3_200t | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_vision3_200t | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_200t | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_200t | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_vision3_250d | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_2383 | yes | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_250d | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_vision3_500t | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_2383 | yes | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_endura_premier |  | gate_failed | gate_failed | no |
| kodak_vision3_500t | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_500t | kodak_ultra_endura |  | gate_failed | gate_failed | no |
| kodak_vision3_50d | fujifilm_crystal_archive_typeii |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_2383 | yes | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_2393 |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_ektacolor_edge |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_endura_premier |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_portra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_supra_endura |  | integrated_verified | integrated_verified | **yes** |
| kodak_vision3_50d | kodak_ultra_endura |  | gate_failed | gate_failed | no |

## Blocked / failed rows

| film | paper | space | state | chart mean | photograph mean | photograph p99 | error |
|---|---|---|---|---:|---:|---:|---|
| cinestill_800t | kodak_endura_premier | sRGB | gate_failed | 0.050 | 0.204 | 0.696 | one or more numeric gates failed |
| cinestill_800t | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.057 | 0.203 | 0.673 | one or more numeric gates failed |
| cinestill_800t | kodak_ultra_endura | sRGB | gate_failed | 0.061 | 0.288 | 0.973 | one or more numeric gates failed |
| cinestill_800t | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.072 | 0.294 | 0.929 | one or more numeric gates failed |
| fujifilm_c200 | kodak_ultra_endura | sRGB | gate_failed | 0.056 | 0.091 | 0.356 | one or more numeric gates failed |
| fujifilm_c200 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.073 | 0.148 | 0.503 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_2383 | sRGB | gate_failed | 0.034 | 0.430 | 2.125 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_2383 | ProPhoto RGB | gate_failed | 0.037 | 0.508 | 2.396 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_2393 | ProPhoto RGB | gate_failed | 0.121 | 0.185 | 0.657 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_ektacolor_edge | sRGB | gate_failed | 0.107 | 0.923 | 4.613 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_ektacolor_edge | ProPhoto RGB | gate_failed | 0.127 | 1.123 | 5.297 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_endura_premier | sRGB | gate_failed | 0.141 | 1.160 | 8.414 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.137 | 1.547 | 10.595 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_portra_endura | sRGB | gate_failed | 0.139 | 1.027 | 6.253 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_portra_endura | ProPhoto RGB | gate_failed | 0.171 | 1.240 | 6.350 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_supra_endura | sRGB | gate_failed | 0.155 | 0.994 | 5.219 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_supra_endura | ProPhoto RGB | gate_failed | 0.174 | 1.206 | 5.950 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_ultra_endura | sRGB | gate_failed | 0.126 | 1.038 | 5.249 | one or more numeric gates failed |
| fujifilm_pro_400h | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.133 | 1.196 | 5.564 | one or more numeric gates failed |
| fujifilm_xtra_400 | kodak_ultra_endura | sRGB | gate_failed | 0.036 | 0.079 | 0.302 | one or more numeric gates failed |
| fujifilm_xtra_400 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.092 | 0.137 | 0.509 | one or more numeric gates failed |
| kodak_ektar_100 | kodak_ultra_endura | sRGB | gate_failed | 0.056 | 0.109 | 0.318 | one or more numeric gates failed |
| kodak_ektar_100 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.058 | 0.126 | 0.390 | one or more numeric gates failed |
| kodak_gold_200 | kodak_endura_premier | sRGB | gate_failed | 0.067 | 0.102 | 0.317 | one or more numeric gates failed |
| kodak_gold_200 | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.059 | 0.108 | 0.414 | one or more numeric gates failed |
| kodak_gold_200 | kodak_ultra_endura | sRGB | gate_failed | 0.066 | 0.124 | 0.368 | one or more numeric gates failed |
| kodak_gold_200 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.071 | 0.137 | 0.401 | one or more numeric gates failed |
| kodak_portra_160 | kodak_endura_premier | sRGB | gate_failed | 0.082 | 0.113 | 0.452 | one or more numeric gates failed |
| kodak_portra_160 | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.087 | 0.138 | 0.541 | one or more numeric gates failed |
| kodak_portra_160 | kodak_ultra_endura | sRGB | gate_failed | 0.083 | 0.146 | 0.508 | one or more numeric gates failed |
| kodak_portra_160 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.091 | 0.176 | 0.610 | one or more numeric gates failed |
| kodak_portra_400 | fujifilm_crystal_archive_typeii | sRGB | gate_failed | 0.292 | 0.666 | 2.722 | one or more numeric gates failed |
| kodak_portra_400 | fujifilm_crystal_archive_typeii | ProPhoto RGB | gate_failed | 0.311 | 0.719 | 2.884 | one or more numeric gates failed |
| kodak_portra_400 | kodak_2383 | sRGB | gate_failed | 0.210 | 0.388 | 1.506 | one or more numeric gates failed |
| kodak_portra_400 | kodak_2383 | ProPhoto RGB | gate_failed | 0.226 | 0.434 | 1.649 | one or more numeric gates failed |
| kodak_portra_400 | kodak_2393 | sRGB | gate_failed | 0.264 | 0.530 | 2.444 | one or more numeric gates failed |
| kodak_portra_400 | kodak_2393 | ProPhoto RGB | gate_failed | 0.290 | 0.585 | 2.496 | one or more numeric gates failed |
| kodak_portra_400 | kodak_ektacolor_edge | sRGB | gate_failed | 0.084 | 0.191 | 0.524 | one or more numeric gates failed |
| kodak_portra_400 | kodak_ektacolor_edge | ProPhoto RGB | gate_failed | 0.089 | 0.214 | 0.614 | one or more numeric gates failed |
| kodak_portra_400 | kodak_endura_premier | sRGB | gate_failed | 0.100 | 0.291 | 1.136 | one or more numeric gates failed |
| kodak_portra_400 | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.104 | 0.332 | 1.257 | one or more numeric gates failed |
| kodak_portra_400 | kodak_supra_endura | sRGB | gate_failed | 0.140 | 0.313 | 0.902 | one or more numeric gates failed |
| kodak_portra_400 | kodak_supra_endura | ProPhoto RGB | gate_failed | 0.154 | 0.344 | 1.019 | one or more numeric gates failed |
| kodak_portra_400 | kodak_ultra_endura | sRGB | gate_failed | 0.123 | 0.154 | 0.436 | one or more numeric gates failed |
| kodak_portra_400 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.140 | 0.168 | 0.484 | one or more numeric gates failed |
| kodak_portra_800 | kodak_ultra_endura | sRGB | gate_failed | 0.098 | 0.129 | 0.410 | one or more numeric gates failed |
| kodak_portra_800 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.092 | 0.146 | 0.449 | one or more numeric gates failed |
| kodak_portra_800_push1 | kodak_ultra_endura | sRGB | gate_failed | 0.066 | 0.101 | 0.315 | one or more numeric gates failed |
| kodak_portra_800_push1 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.073 | 0.140 | 0.443 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_2383 | sRGB | gate_failed | 0.171 | 0.191 | 0.636 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_2383 | ProPhoto RGB | gate_failed | 0.175 | 0.187 | 0.627 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_2393 | sRGB | gate_failed | 0.249 | 0.189 | 0.655 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_2393 | ProPhoto RGB | gate_failed | 0.273 | 0.182 | 0.648 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_endura_premier | sRGB | gate_failed | 0.293 | 0.207 | 0.901 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.323 | 0.229 | 1.013 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_ultra_endura | sRGB | gate_failed | 0.228 | 0.174 | 0.730 | one or more numeric gates failed |
| kodak_portra_800_push2 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.247 | 0.178 | 0.785 | one or more numeric gates failed |
| kodak_ultramax_400 | kodak_ultra_endura | sRGB | gate_failed | 0.080 | 0.118 | 0.365 | one or more numeric gates failed |
| kodak_ultramax_400 | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.090 | 0.136 | 0.425 | one or more numeric gates failed |
| kodak_verita_200d | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.068 | 0.091 | 0.310 | one or more numeric gates failed |
| kodak_verita_200d | kodak_ultra_endura | sRGB | gate_failed | 0.061 | 0.109 | 0.336 | one or more numeric gates failed |
| kodak_verita_200d | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.066 | 0.119 | 0.372 | one or more numeric gates failed |
| kodak_vision3_200t | kodak_ektacolor_edge | ProPhoto RGB | gate_failed | 0.029 | 0.182 | 0.576 | one or more numeric gates failed |
| kodak_vision3_200t | kodak_endura_premier | sRGB | gate_failed | 0.032 | 0.189 | 0.545 | one or more numeric gates failed |
| kodak_vision3_200t | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.029 | 0.196 | 0.575 | one or more numeric gates failed |
| kodak_vision3_200t | kodak_ultra_endura | sRGB | gate_failed | 0.047 | 0.155 | 0.540 | one or more numeric gates failed |
| kodak_vision3_200t | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.049 | 0.157 | 0.536 | one or more numeric gates failed |
| kodak_vision3_250d | kodak_ultra_endura | sRGB | gate_failed | 0.080 | 0.125 | 0.400 | one or more numeric gates failed |
| kodak_vision3_250d | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.077 | 0.146 | 0.441 | one or more numeric gates failed |
| kodak_vision3_500t | kodak_endura_premier | sRGB | gate_failed | 0.034 | 0.189 | 0.498 | one or more numeric gates failed |
| kodak_vision3_500t | kodak_endura_premier | ProPhoto RGB | gate_failed | 0.041 | 0.193 | 0.503 | one or more numeric gates failed |
| kodak_vision3_500t | kodak_ultra_endura | sRGB | gate_failed | 0.043 | 0.161 | 0.532 | one or more numeric gates failed |
| kodak_vision3_500t | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.056 | 0.163 | 0.536 | one or more numeric gates failed |
| kodak_vision3_50d | kodak_ultra_endura | sRGB | gate_failed | 0.071 | 0.113 | 0.353 | one or more numeric gates failed |
| kodak_vision3_50d | kodak_ultra_endura | ProPhoto RGB | gate_failed | 0.067 | 0.132 | 0.408 | one or more numeric gates failed |
