# TRANSLATION-NOTES.md: where the Japanese departs from the glossary, and what was shortened

Written 2026-10-22 by the translating session, with `STYLE.md`, `GLOSSARY.md`, `HARD-STRINGS.md` and the
recommended answers of `DECISIONS-FOR-OWNER.md` (D1–D8). **No native speaker has read the result**: it was
drawn by the snapshot harness and read there. Pruned 2026-11-08 to the Mac app's sentences.

The catalog had 1159 keys; every one has `ja` (1158 written, plus `Format {the develop tab}`, below). The
HARD-STRINGS were used word for word except where this file says otherwise. The translations were written as
`index|Japanese` lines and put in with `tools/localization_add.py --language ja`, so the catalog's diff is
additions only.

## Code changes the words needed

| What | Why |
|---|---|
| `L("Format", as: "the develop tab")` in `EditTool`, `SettingsClipboard`, `FrameEdit`; new key `Format {the develop tab}` (zh-Hans/zh-Hant: 格式, as before) | One English word, two things: the develop page's Format tab is the **film's** format (110, APS, 135, 120) → 判型; Export's Format is the **file** format → 形式 (GLOSSARY §6 and §10). |
| Export's offline size switch (`ExportSheet`, the original away) showed `Size.title`, the log's English ("Preview", "Full"), in every language | It shows `shownTitle` now (プレビュー / 12 MP / 原寸). A fix for all languages: the Chinese page now shows 预览 / 全尺寸 too. |
| Develop's Film & Paper: the Crop button beside the two shelf pills (`StockPreviewPanel`) | Japanese フィルム · すべて and 印画紙 · すべて did not fit beside 切り取り at the column's narrowest and were cut to "…". With `ViewThatFits`, where both pills and the word do not fit, Crop shows its glyph alone (its accessibility label stays 切り取り). English and Chinese always fit and take the first; their pages are byte-identical (`same_snapshots.sh`). |
| Select mode's Paste (`SelectMode`) | 3枚にペースト did not fit beside the heart, the bin and the 112 pt Export: cut to "3枚にペ…". The same `ViewThatFits`: the clipboard glyph goes where the words need its room. English and Chinese unchanged. |
| `tools/localization_check.py` | `ja` is a fourth language; its script check (`NOT_JAPANESE_SIMPLIFIED`, `KYUJITAI_ONLY`) is built from the existing Simplified table minus the characters Japanese writes too (写 会 号 数 点 画 黄 辞 踊 …), plus 冲 获 愿 么 后 种 专 and a table of old forms (圖 黑 會 …). **Correction of STYLE.md §1** (the coordinator, 2026-10-22): its "Traditional-only" list named 選 張 導 頁 膠, which are standard Japanese (選択, 拡張, 導入, 頁; 膠 is rare but valid). They are not in the check's table, a self-test trial holds 選択・拡張・導入・頁・膠 passing, and the line in `STYLE.md` is corrected in place. |

## Departures from the glossary (with the reason)

| Key | Glossary | Used | Why |
|---|---|---|---|
| `Not printed` (the Date Back's value, in Develop and in the pair) | 焼き付けなし (print stage) | 写し込みなし | Both uses say the **date** is not imprinted, not that the frame is not printed. |
| `This app` (Credits' section header) | このApp | このアプリ | Section headers are drawn uppercase: このApp became このAPP on the page. |
| `Format` (develop tab) | 形式 | 判型 (split key, above) | — |
| `brightest` / `darkest` | 最も明るい部分 / 最も暗い部分 | 最も明るい / 最も暗い | They only fill "the %@ part" (`…%@部分が収まります`), which already says 部分. |
| `Eared: … 645 SLR's gate` | — | 一眼レフ | No glossary row; 一眼レフ is the only Japanese word for an SLR. |
| `Rounded: … 645 rangefinder's gate` | — | 距離計連動式645カメラ | No glossary row; kept in kanji rather than レンジファインダー. |
| `Kicked: … a 6×6 insert's` | — | インサート | No glossary row and no kanji word for a film-back insert. |
| `Shouldered: … a 6×8 back's` | — | 6×8の裏蓋 | No glossary row; 裏蓋 (camera back) in kanji rather than バック. |
| `The light the film's name, numbers and barcode were printed with.` | — | バーコード | No kanji word. |
| `A picture to share: … the SpektraLab mark …` | — | マーク | No glossary row; ロゴ would be katakana too. |
| `Drop to copy into SpektraLab` | — | ドロップ | A pointer verb, as ドラッグ (GLOSSARY's tolerated pointer verbs). |
| `engine sources ` (Settings › Engine, before a commit hash) | — | エンジンのソース | A developer detail; no kanji word that says "source code" shortly. |
| `The list is the main lens's …` | — | 主レンズ | Kanji rather than メインレンズ. |
| `Disk`, `card`, `error`, `device`, `test build`, `debug build`, `button` in sentences | — | ディスク, カード, エラー, デバイス, テスト版, デバッグ版, ボタン | Apple's own Japanese words for these; not in the glossary's katakana list, and no kanji word in use. Listed so the glossary can take them. |
| Several sheet/page words | — | 画面 | "this sheet", "this page" → この画面 (kanji) rather than シート/ページ. |
| `Export %@` (a count or a size: "Export 3", "Export 12 MP") | %@を書き出す | 書き出す（%@） | 3を書き出す has no counter and reads oddly; the same key takes a size, so no counter can be added. |
| `Remove %@ pairs?` / `Remove this pair?` | — | %@組を解除しますか？ / この組を解除しますか？ | GLOSSARY §7's own note: the frames stay, so 解除, not 削除. |

## Shortened for space (seen cut in a snapshot)

| English | Full Japanese | Short Japanese | Back-translation (full → short) | Where |
|---|---|---|---|---|
| `Cards, disks, iCloud Drive, in place` | カード、ディスク、iCloud Drive（元の場所のまま） | カード、ディスク、iCloud Driveをそのまま | "…(as they are, where they are)" → "…as they are" | Import's Link a Folder row: cut to "（元の場所のま…". |

## Not translated, and should be said

- **The snapshot pages' stand-in status lines** ("Developing · Film Exp. +0.3") stay English, as LOCALIZATION.md says.
- **The Edge Print step's glyph** is Apple's SF Symbol `textformat`, which the system itself draws as あぁ in Japanese.
