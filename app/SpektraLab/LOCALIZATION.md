# LOCALIZATION.md — the app's four languages

English, 简体中文, 繁體中文, 日本語 (Japanese since 2026-10-22: its own section below). Written 2026-10-12, when
most of the app's first testers read Chinese and the app said "Follow the system" and was English only. The owner:
*"kill that option and do the robust English and Chinese (simplified and traditional) language setting."*

The pages were drawn in each language by the snapshot harness and checked by the scripts below. **The words are
a session's, not the owner's**: the table at the end is there to be corrected.

## How it works

- **The setting.** Settings › General › Language is a pop-up of the four, each language in itself
  (`MacSettingsGeneral`). There is no "follow the system". `Language.shared` (`Sources/Model/Localization.swift`)
  is the one source every page reads.
- **The first launch** takes the system's preferred languages once (`AppLanguage.derived`): the first of
  them that is English, Chinese or Japanese decides; `Hans`, or a Chinese with no script outside Taiwan,
  Hong Kong and Macau, is Simplified; `Hant`, `zh-TW`, `zh-HK`, `zh-MO` and Cantonese are Traditional;
  `ja` is Japanese; anything else is English. It is kept (`settings.language`) and is the user's choice from then on. *This rule
  is a session's choice.*
- **The system's own pieces** — a Finder panel, the share sheet, the app's name (`Resources/InfoPlist.xcstrings`)
  — read `AppleLanguages`, which the app writes with its choice. They follow **at the next launch**; the Language
  row's caption says so.
- **The system's per-app language** can be set because the app declares four localizations
  (`CFBundleLocalizations`, `knownRegions`), and it writes the same `AppleLanguages`. At a launch, if that list is
  no longer the one the app wrote, the system's is taken as the later word and kept. *A session's choice, and the
  system's setting was not driven by hand.*
- **A change is every page's at once.** `Language` is `@Observable`; a page that looked a word up while
  it was drawn is drawn again. `\.locale` is set at the root (`LanguageHost`, `AppServices.swift`).

## The lookup

The pages write plain `String`s, so a string catalog alone does nothing. Every sentence goes through:

| | |
|---|---|
| `L("Settings")` | the English is the key and the fallback |
| `L("\(n) frames")` | an interpolation is an argument: the key is `%@ frames` |
| `L("…" + "…")` | a sentence written over two lines is one key |
| `String(format: L("Glare %.1f×"), x)` | where a number is formatted by `String(format:)` |
| `L("Level", as: "a pair")` | one English word with two senses is two keys: `Level {a pair}` |
| `L(shown: text)` | a sentence made in English elsewhere, looked up where it is shown |

The translations are in `Resources/Localizable.xcstrings` (`zh-Hans`, `zh-Hant`, `ja`). Xcode compiles it
into `zh-Hans.lproj`, `zh-Hant.lproj` and `ja.lproj`; `Language` reads the chosen one. **English never reads a table**: it
is the literal, byte for byte.

A translation orders its arguments by position where the order changes (`%2$@ 张中的 %1$@ 张`); it never
mixes `%@` and `%1$@`.

## Adding a sentence

1. Write it `L("…")` in the source.
2. `python3 tools/localization_check.py --list-missing` prints the keys the catalog lacks.
3. Put each in a file as four lines — key, Simplified, Traditional, Japanese — with a blank line between,
   and `python3 tools/localization_add.py FILE` (`--language ja FILE` for two-line blocks of one
   language). Or edit the catalog in Xcode.
4. `python3 tools/localization_check.py`, then draw the page in each: `tools/snapshot.sh --language zh-Hans
   --only ID` (and `zh-Hant`, `ja`), and look at it.

A key that ends in a space (`"Film Exp. "`, a label before its value) needs the space in its translation
too. The check does not hold this; `Print · ` lost its space once and was seen in a snapshot.

## The checks stay English

- **A launch with a `--` argument is a check's**: a snapshot, a tour, a harness. It is English whatever
  the Mac is set to, reads nothing kept and keeps nothing (`Language.start`).
  `--language zh-Hans|zh-Hant|ja` names another.
- **The self-tests** (`tools/selftest.sh`) compile `Localization.swift` on a Mac with no bundle: every
  lookup is English there.
- **The log is English.** Nothing under `Sources/Diagnostics` or `Sources/Scheduler` that is written to a
  record goes through `L`. Where one string is both shown and written — a wait's reason, an export's
  failure, an engine failure, a stock's "scanned", an export size's title — the
  record keeps the English and the page looks it up with `L(shown:)`.
- `tools/snapshot.sh --language zh-Hans` draws the pages in Chinese into `build/snapshots-zh-Hans`;
  `--switch-to zh-Hans` puts each page up in English, changes the language as Settings does and draws
  the page as it then stands. `tools/same_snapshots.sh` over the two folders is the check that a change
  reaches every page at once.

- `tools/logs_check.sh --language zh-Hans` runs the log's check with the app in Chinese. Four of its
  38 lines then fail, and are meant to: they compare Settings' own note with English words. The log's
  own lines hold, and the files hold no Chinese.

`tools/localization_check.py` (run by `tools/selftest.sh`) fails when a key lacks a language; a
translation's arguments or numbers are not its key's; a `zh-Hant` value holds a Simplified-only
character or the reverse (a table of telltale characters, not a dictionary); a literal is handed to
something that shows it without `L(`; a looked-up key is not in the catalog; a key of the catalog is no
literal any more. `--self-test` breaks each rule once. What it excepts is named in the script (`NEVER`,
`NOT_PAGES`) and in `tools/localization_exceptions.json`. `tools/language_selftest.swift` holds the
launch's rules.

## Never translated

- Product and stock names (the catalogue's, `Resources/StockCatalog.json`), SpektraLab, CINE, Pro.
- Formats and colour spaces: HEIF, JPG/JPEG, PNG, TIFF, RAW, ProRAW, DNG, HEIC, sRGB, Adobe RGB,
  Display P3, ProPhoto. Units: MP, px, EV, ISO, GB, MB, mm, K. Film format names: 135, 120, 645, 6×6,
  XPan, APS, Super 35.
- What is printed on a film's edge and the Date Back's stamp: part of the picture.
- Credits' names and licences: Andrea Volpato, spektrafilm, CC BY-SA 4.0.
- The log, its zip and the zip's read-me; harness output; `os.Logger` lines.
- File names: a pair's `Half-Frame Pair 1` is its name in the library, kept on disk, and stays as made.
- The engine, `legal/`, the server, the site.

## Not translated, and should be said

- **The engine's own error sentences** ("the picture could not be decoded") reach an export's row and the
  status line after *Could not develop*: they are the log's.
- **The system's own error descriptions** (`localizedDescription`) come in the system's language.
- **The snapshot pages' own stand-in status lines** ("Developing · Film Exp. +0.3") are a check's
  fixtures: English in the Chinese drawings. A real status line is translated.
- **The privacy policy** is published in English and Simplified Chinese only: the app in Traditional
  Chinese is sent to the Simplified page, the app in Japanese to the English one
  (`AppLanguage.privacyPolicyURL`).

## The words

Chosen for people who shoot and print film; concise as an Apple interface is. Traditional is written
for Taiwan and Hong Kong, not converted. The first rows follow the published privacy policy and the app's first
public texts, which already said 冲洗, 印放, 相纸, 片边, 日期后背, 配方 ("the first texts" below).

| English | 简体 | 繁體 | A judgement? |
|---|---|---|---|
| Develop, Developing | 冲洗、冲洗中 | 沖洗、沖洗中 | **Yes.** 显影 is the darkroom's own word; 冲洗 is what the policy and the first texts already say, and covers the whole act. |
| Print (the stage), Printing | 印放、印放中 | 放相、放相中 | **Yes.** 印放 from the first texts; Taiwan's darkrooms say 放相. |
| Film | 胶片 | 底片 | **Yes.** Taiwan says 底片 for film of any kind; 膠片 there is cine. |
| Negative / Slide | 负片 / 反转片 | 負片 / 正片 | 反转片 from the first texts; 正片 is Taiwan's word. |
| Paper / Enlarger | 相纸 / 放大机 | 相紙 / 放大機 | |
| Frame (a picture in the library) | 照片，量词"张" | 照片，量詞「張」 | **Yes.** The policy says 照片. The film's own word is kept for the pair: 格. |
| Frame (the develop tab) | 画幅 | 畫幅 | **Yes.** The tab holds the film's size, Film Edge, Date Back, Crop. |
| Format (of film, in Film Edge) | 片幅 | 片幅 | |
| Half-Frame Pair | 半格组 | 半格組 | **Yes.** From "一组半格" in the first texts. 半格双联 is the other candidate. |
| Left / Right / Top / Bottom frame | 左格 / 右格 / 上格 / 下格 | same | |
| Level / Turned (a pair) | 横放 / 竖放 | 橫放 / 直放 | **Yes.** |
| Film Edge | 片边 | 片邊 | From the first texts. |
| Date Back | 日期后背 | 日期機背 | Taiwan says 機背. |
| Strip / Filed (Film Edge's views) | 片条 / 锉边 | 片條 / 銼邊 | **Yes, unsure.** 锉边 is the filed-out negative carrier. |
| Gate / Holes / Body / Advance | 片门 / 齿孔 / 机身 / 过片 | 片門 / 齒孔 / 機身 / 過片 | |
| Gate shapes: Square, Rounded, Eared, Kicked, Shouldered | 方角、圆角、带耳、外挑、带肩 | 方角、圓角、帶耳、外挑、帶肩 | **Yes, unsure.** No settled Chinese for these. |
| Edge fog / Spool leaks | 边缘灰雾 / 片轴漏光 | 邊緣灰霧 / 片軸漏光 | |
| Frame no. | 格号 | 格號 | **Yes.** |
| Latitude | 宽容度 | 寬容度 | |
| stops | 档 | 級 | **Yes.** Taiwan says 格 or 級; 格 is taken by the pair's frames. |
| Scene Placement / Placement | 场景安置 / 安置 | 場景安置 / 安置 | **Yes, unsure.** After the zone system's "placement" (置于). |
| Highlight / Shadow | 高光 / 阴影 | 亮部 / 陰影 | Apple's Photos in each. |
| Halation / Grain / Scatter | 光晕 / 颗粒 / 散射 | 光暈 / 顆粒 / 散射 | |
| Glare (the paper's veil) | 眩光 | 眩光 | **Yes.** |
| Couplers | 成色剂 | 成色劑 | |
| Sub-layers | 分层 | 分層 | |
| Pre-flash | 预闪 | 預閃 | **Yes.** 预曝光 is the longer word. |
| Brightness / Colour / Grade (the enlarger's tools) | 亮度 / 色彩 / 号数 | 亮度 / 色彩 / 號數 | 号数 as a paper's grade. |
| Yellow / Magenta | 黄 / 品红 | 黃 / 洋紅 | |
| → softer / → harder | → 更软 / → 更硬 | → 更軟 / → 更硬 | |
| Film Exposure / Meter | 胶片曝光 / 测光 | 底片曝光 / 測光 | |
| As Shot | 原照设置 | 拍攝設定 | Lightroom's words in each. |
| White Balance / Temperature / Tint | 白平衡 / 色温 / 色调 | 白平衡 / 色溫 / 色調 | |
| Lens correction: distortion, vignetting | 镜头校正：畸变、暗角 | 鏡頭校正：變形、暗角 | |
| Process / Original (the develop page's two capsules) | 成片 / 原图 | 成品 / 原圖 | **Yes.** |
| Original (the file) | 原件 | 原始檔 | |
| GUIDE (the tag on a film edge's preview) | 参考 | 參考 | **Yes.** |
| Library | 图库 | 圖庫 | Apple's Photos. The policy says 资料库 once. |
| Export / Import | 导出 / 导入 | 輸出 / 輸入 | **Yes.** Apple's own Traditional. Taiwan also says 匯出 / 匯入, which the brief named; say which. |
| Share | 共享 | 分享 | Apple's. |
| Save / Storage | 存储 / 储存空间 | 儲存 / 儲存空間 | Apple's. |
| Settings | 设置 | 設定 | |
| Recipe | 配方 | 配方 | From the policy. |
| Favourite | 收藏 | 喜好項目 | Apple's Traditional; Simplified's 个人收藏 shortened. |
| Folder / Linked folder | 文件夹 / 关联的文件夹 | 檔案夾 / 連結的檔案夾 | **Yes.** Apple's 檔案夾; Taiwan also says 資料夾. |
| Working copies / Preview copies | 工作副本 / 预览副本 | 工作副本 / 預覽副本 | |
| Copy / Paste settings | 拷贝 / 粘贴 | 拷貝 / 貼上 | Apple's. |
| Diagnostics / Log | 诊断 / 日志 | 診斷 / 日誌 | Apple's Traditional says 記錄; 日誌 reads less like "a record". |
| Privacy Policy | 隐私政策 | 隱私權政策 | |
| Pro-control | 专业控制 | 專業控制 | "Pro" itself is kept. |
| Capture (Date Taken, Recent Captures) | 拍摄 | 拍攝 | |
| Crop / Straighten / Rotate / Flip | 裁剪 / 拉直 / 旋转 / 翻转 | 裁切 / 拉直 / 旋轉 / 翻轉 | |
| "An empty darkroom" | 一间空暗房 | 一間空暗房 | |

**Unsure, listed apart:** 锉边 for *Filed*; the five gate shapes; 场景安置; 半格组 against 半格双联;
級 for *stops* in Traditional; 輸出/輸入 against 匯出/匯入; whether *Develop* should be 显影 after all.

## Japanese (2026-10-22)

The owner: *"we shall begin our Japanese localization for the app, as Japan market is also really
important … I want as little 片假名 as possible in the app, English when necessary, especially the
control assets … the use of Kanji is strongly encouraged."* The owner reads no Japanese: the words are
held by the terminology files in `l10n-ja/` (STYLE.md, GLOSSARY.md) and every departure from them, and
every string shortened for space, is in `l10n-ja/TRANSLATION-NOTES.md`.

**Japanese is not Chinese.** `AppLanguage.isChinese` was `self != .english` until Japanese came; it is
now the two Chinese only, and each place that asked says what Japanese gets:

| Where | What Japanese gets |
|---|---|
| `Fmt`'s dates (`Format.swift`) | year first with 年 月 日, as Chinese, in Japanese's own locale (`writesDatesWithYearFirst`): "2026年9月28日", "日曜日" |
| The privacy policy (`Diagnostics.policyURL` → `AppLanguage.privacyPolicyURL`) | the English page: there is no Japanese policy |
| `\.locale`, the sidebar's month names | `Locale("ja")`, as each language is its own code |
| The first launch (`AppLanguage.derived`) | a system whose first of the app's languages is `ja` is Japanese (before 2026-10-22 it fell through to the next, or to English) |

`tools/localization_check.py` holds `ja` as it holds the two Chinese: every key, every argument, and
its script — a Simplified character Japanese does not write (设 for 設, 图 for 図, 胶, 冲) or an old form
it no longer writes (圖, 黑, 會) is a failure (`NOT_JAPANESE_SIMPLIFIED`, `KYUJITAI_ONLY`).
