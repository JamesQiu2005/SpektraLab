# STYLE.md: how SpektraLab is written in Japanese

Written 2026-10-22 by the terminology session, for the agent that translates
`Resources/Localizable.xcstrings` and `Resources/InfoPlist.xcstrings` into `ja`.
The words for each term are in `GLOSSARY.md`, worked sentences are in `HARD-STRINGS.md`, and the open choices are in
`DECISIONS-FOR-OWNER.md`. **No native speaker has read any of this.**
The owner reads no Japanese, so every rule below gives its reason in English.

The owner's brief: *"as little 片假名 as possible … English when necessary, especially the control
assets … the use of Kanji is strongly encouraged."* This file turns that into rules a translator can
follow, and sets where those rules stop: the result has to be **natural Japanese that a Japanese film
photographer would accept**. A kanji word nobody uses is worse than a katakana word everybody uses.

---

## 1. Script policy

Decide each word in this order. Stop at the first rule that applies.

| # | Rule | Script | Examples |
|---|---|---|---|
| 1 | **Never translated** (LOCALIZATION.md "Never translated"): product and stock names, file formats, colour spaces, units, film format names, licences, people's names. | English, as written | SpektraLab, Pro, CINE, Kodak Portra 400, RAW, DNG, ProRAW, HEIF, HEIC, JPEG, JPG, PNG, TIFF, sRGB, Display P3, Adobe RGB, ProPhoto, MP, px, EV, ISO, K, mm, GB, MB, 135, 120, 645, 6×6, XPan, CC BY-SA 4.0, Andrea Volpato, spektrafilm |
| 2 | **An Apple system name** (an app, a setting, a button the system also shows, an account): write it exactly as Apple's Japanese interface shows it, **even if it is katakana or English**, because users look for it. | as Apple writes it | 「Finder」, 「設定」, iCloud Drive, Apple Account, App, 共有, 完了, キャンセル, 取り消す, やり直す, コピー, ペースト, 編集内容をコピー, 書き出す, 読み込む, プライバシーポリシー, ストレージ |
| 3 | **An established Japanese photographic or darkroom term in kanji exists and is in real use**: use it. Prefer the word film photographers say over the textbook word when they differ, and say which one you used in the glossary. | 漢字 (with okurigana) | 現像, 焼き付け, 引伸機, 印画紙, 号数, 軟調/硬調, 露光, 露出, 絞り, 測光, 段, 粒状感, 散乱, 周辺減光, 色温度, 色相, 彩度, 輝度, 階調, 明部/暗部, 中間調, 送り穴, 巻き上げ, 日付写し込み, 密着焼き |
| 4 | **A plain Japanese word (wago or common kanji) says it naturally**, even if photo software usually uses a loanword: use it. | 漢字+かな | 明るさ, 色合い, 曲線, 色相環, 傾き補正, 切り取り, 並べ替え, 角丸, 横並び/縦並び |
| 5 | **The only natural word is a loanword** (no kanji word exists, or the kanji word is archaic, Chinese, or would make a Japanese user stop and think): keep the katakana and say why in the glossary. | カタカナ | フィルム, カメラ, レンズ, シャッター, ハレーション, カプラー, スキャン, ライトテーブル, コントラスト, ホワイトバランス, ネガ/ポジ, ピント |
| 6 | **A tight control where even the katakana does not fit, or where Japanese photographers themselves use the Latin letters**: English (see §2). | English | HSL, ISO, WB (only in a chip or tile) |

Hiragana is used for okurigana, particles, auxiliary verbs, and for the few words that are
normally written in kana (かぶり, ばらばら, まだ, すべて, ください). Write すべて, not 全て, as
Apple does in 「すべてを選択」. Write 下さい only as ください, and 出来る only as できる.

### The things kanji preference never justifies

- **No Chinese words in Japanese clothing.** The Chinese catalogue is there to show what a key means,
  not to borrow words from. These look like kanji words but are Chinese, or mean something else in
  Japanese, and must never appear:

  | Chinese (zh-Hans) | Why not | Japanese |
  |---|---|---|
  | 胶片 / 底片 | not Japanese words | フィルム (ネガ for a negative) |
  | 相纸 / 相紙 | not Japanese | 印画紙 |
  | 冲洗 / 沖洗 | Japanese 沖 is "offshore"; 沖洗 is not a word | 現像 |
  | 印放 / 放相 | not Japanese | 焼き付け |
  | 放大机 | 机 is "desk" in Japanese | 引伸機 |
  | 曝光 | Chinese; Japanese 曝 is a rare literary character | 露出 (camera) / 露光 (printing, the engine) |
  | 颗粒 / 顆粒 | 顆粒 in Japanese means granules (medicine, soup stock) | 粒状感 |
  | 光晕 / 光暈 | not used for halation in Japanese | ハレーション |
  | 成色剂 | Chinese | カプラー |
  | 宽容度 | the Japanese form is 寛容度 (shinjitai) | 寛容度 |
  | 片边 / 片條 / 片门 / 齿孔 | Chinese terms | フィルムの縁 / 全幅 / 画枠 / 送り穴 |
  | 档 / 級 (stops) | Chinese | 段 |
  | 号数 | the same word is Japanese too: OK | 号数 |
  | 图库 / 相册 | Chinese | ライブラリ (Apple) |
  | 导出 / 导入 / 输出 | Chinese | 書き出す / 読み込む |
  | 设置 | Chinese | 設定 |
  | 白平衡 | Chinese | ホワイトバランス |
  | 高光 / 阴影 | Chinese | 明部 / 暗部 (or ハイライト / シャドウ, decision 3) |
  | 暗角 | Chinese | 周辺減光 |
  | 位 (bit, "16 位") | Japanese 位 is a rank ("16th place") | 16ビット |
  | 像素 | Chinese | ピクセル / 画素 |
  | 画幅 | Chinese photographic term, rare in Japanese (the web light table uses it: see §8) | 判型 (film format), コマ (the develop tab) |
  | 视图 / 预设 / 配方 | Chinese | 表示 / プリセット / 書き出し設定 |

- **Shinjitai only.** Japan's standard forms: 図 not 圖/图, 写 not 寫, 発 not 發/发, 対 not 對/对,
  変 not 變/变, 読 not 讀/读, 黒 not 黑, 済 not 濟/济, 縁 not 緣/缘, 拡 not 擴/扩, 転 not 轉/转,
  単 not 單/单, 覧 not 覽/览, 検 not 檢/检, 収 not 收, 縦 not 縱/纵, 焼 not 燒/烧, 機 not 机,
  様 not 樣, 帯 not 帶/带, 号 not 號, 録 not 錄/录, 価 not 價/价, 択 not 擇/择, 応 not 應/应, 処 not 處/处.
  A Chinese input method gives the wrong form silently. Type with a Japanese IME, or check each
  character. *Suggestion for whoever extends `tools/localization_check.py`*: a `ja` value that holds a
  Simplified-only telltale (张 图 这 们 设 选 导 胶 纸 边 页 发 对 变 读 时 后 门 开 关 无 让 应 专 为 动 长 种 证)
  or a Traditional-only one (圖 們 邊 發 對 變 讀 寫 會 實 與 從 處 號 續 譯 應 價 擇 數 錄 歷 點 黑 檔) [corrected 2026-10-22: 選 張 導 頁 are standard Japanese (選択, 拡張, 導入, 頁) and 膠 is rare but valid; they are not telltales]
  is almost always a mistake. (設 and 這 are left out: 設 is Japanese, and 這 is a rare Japanese character.) Characters shared by Japanese and one Chinese form (写, 点, 画, 時, 紙, 門, 層, 機)
  must **not** be in that table.
- **Rare or literary kanji are flagged** in the glossary with "literary" in the *why* column
  (陰画/陽画, 橙, 拡大鏡's alternative 天眼鏡, 矩形). Use them only where the glossary says so.
- **A coinage is said to be one.** Where no Japanese term exists for what SpektraLab does (the
  gate shapes, the pair, the Filed view), the glossary says "built from ordinary words, not a
  standard term", with confidence *medium* or *low*.

### Where English is used, exactly

English (half-width Latin letters) appears in the Japanese app only in these classes. Anything
outside the list is translated.

1. **Names** (rule 1): SpektraLab, Pro, CINE, every stock name, every
   people/licence name, Mac, macOS, Finder, iCloud, iCloud Drive, Apple Account,
   AirDrop (Apple JP shows "AirDrop"), App (Apple JP writes "App" for an app: 「Appを開く」).
2. **File formats, colour spaces, units, film format numbers** (rule 1). `ZIP` is written in capitals
   in running Japanese text (動作記録をZIPで書き出す).
3. **Controls whose Japanese photographers use the Latin letters themselves**:
   - `HSL` (the tool tile; Lightroom JP also titles the panel "HSL").
   - `ISO` (also a label on its own, as on every Japanese camera).
   - `EV` after a value.
   - `WB` **only** where ホワイトバランス (7 glyphs) cannot fit: a 70 pt tile. In a row, a sheet title
     or a sentence write ホワイトバランス.
   - `AE` / `AF` are not used: the app does not show them in English either.
4. **Mode names that stay English in every language**: `Pro` (the develop page's Pro fold:
   「Pro操作」 for "Pro controls").
5. Nothing else. In particular: no English for Undo, Reset, Crop, Grain, Halation, Film, Paper,
   Library or Settings. Those all have Japanese words (see the glossary). The owner asked for English
   "when necessary", and for these it is not necessary.

### Where katakana is tolerated

Only in these two classes. The complete list (63 words) is at the end of `GLOSSARY.md`, and each
word's row there gives the reason:

- **Apple's own words** (rule 2), 25 words, e.g. キャンセル, コピー, ペースト, オン, オフ, ストレージ, メモリ,
  プライバシーポリシー, ダウンロード, アクセス, ライブラリ, フォルダ, ファイル, プレビュー, ピクセル, サーバ.
- **Photographic and technical loanwords with no living kanji word** (rule 5), 38 words, e.g. フィルム,
  カメラ, レンズ, シャッター, ホワイトバランス, コントラスト, ハレーション, カプラー, スキャン, ネガ, ポジ, リバーサル,
  ハーフ, コマ (a native word, conventionally written in katakana; 齣 would look archaic), ピント, シーン,
  ライトテーブル, プリセット, データ, エンジン.

Every other katakana word found in a translation is a mistake to fix, or a new entry the glossary
must get first.

### Terminal long vowel (ー)

Follow Apple's Japanese style for **computing words**: no final ー on words of three or more morae:
フォルダ, メモリ, ライブラリ, サーバ, スライダ, ユーザ, コンピュータ, サムネール (Apple's spelling).
Keep the final ー on **photographic objects**, as Japanese photographers and the site write them:
フィルター, シャッター, カプラー, ポスター. (Apple's Photos says フィルタ for its looks; SpektraLab's
tagline is about a photographic filter, and the site writes フィルター.)

---

## 2. Register

| Where | Form | Example | Why |
|---|---|---|---|
| Tab, section, row and tile labels | **Noun** (体言止め). No です・ます. | 現像, 印画紙, 明部と暗部, 日付写し込み | Apple's Japanese labels are nouns. |
| Buttons, menu items | **Sino-Japanese verbal noun alone** where Apple uses one (削除, 共有, 編集, 選択, 保存, 比較, 適用, 回転, 反転, 再接続); **plain dictionary-form verb** for native verbs (開く, 閉じる, 戻る, 取り消す, やり直す, 書き出す, 読み込む, 取り出す, 置く, 外す). Never 〜します on a button. | 「削除」「書き出す」「ロックを解除」 | Apple's practice: 「削除」「共有」 but 「書き出す」「読み込む」「取り消す」. |
| Status lines, captions, badges | Noun or noun+中/済み: 現像中, 書き出し中, 現像済み, 焼き付けなし | | Short and still a sentence fragment, as Apple's "読み込み中…". |
| Sentences: alerts, footers under a row, notes, empty states, onboarding, privacy | **です・ます**. Requests with 〜てください. | 「この写真を取り除きますか？」「原寸の現像は、書き出すときに行います。」 | Apple's Japanese UI writes every message in です・ます. Plain form (だ・である) reads as a manual or a novel. |
| Alert titles that are questions | 〜しますか？ | 「3枚の写真を取り除きますか？」 | Apple. |
| The product's voice lines (tagline, "An empty darkroom") | May be plain/poetic, as the site's 「写真を、焼く。」 | 「フィルターではない。写真を、焼く。」 | Brand line, taken from the site. Only for lines the glossary marks *voice*. |

Politeness: plain です・ます, not keigo. Use ご〜 / お〜 only in fixed polite forms that Apple's
own Japanese copy also uses: お試しください, ご利用中, ご自身, お名前. **Never write あなた / あなたの**. Japanese
leaves the user out ("your library" → 「ライブラリ」, "your frames" → 「写真」). The English
"you" sentences are rewritten without a subject.

---

## 3. Punctuation

| Mark | Japanese | Notes |
|---|---|---|
| Comma, full stop | 、 。 (full-width) | Never , or . in Japanese text. A label has no 。. |
| Question, exclamation | ？ (full-width), no ！ | Apple JP alert titles end in ？. The app never exclaims. |
| Colon | ： (full-width) between a label and its explanation ("Off: originals stay on the disk." → 「オフ：元ファイルはディスクに残ります。」). In running sentences, recast with 。 instead of a colon. | The English uses colons a lot; Japanese uses them less. Do not chain two colons in a sentence. |
| Quotation of an app, setting, button | 「」. Nested: 『』. | 「Finder」, 「設定」›「一般」, 「設定をコピー」を使います. |
| Paths | 「設定」›「一般」›「言語」: each element in its own 「」, joined by the app's **›** with no spaces. | The app already writes › in its paths. Apple's own support pages use ＞; inside the app keep ›, so the three languages match. |
| Parentheses | （ ） full-width around Japanese; ( ) half-width only inside an all-Latin run. | 「中央重点（旧方式）」 |
| Separator dot | Keep the app's ` · ` (half-width space, middle dot, space) exactly where the key has it. Do not replace it with ・. | It is built by code (`Fmt.dot`) and joins values in every language. |
| Listing dot | ・ (full-width katakana middle dot) between Japanese nouns in a sentence or label: 「フィルム・印画紙」, or use と. | |
| Range | 〜 (wave dash) for numeric ranges in sentences: 「380〜780 nm」. | The site writes 380〜780 nm. |
| Ellipsis | … (one character), as the English keys have it: 「名称変更…」「書き出し中…」. | |
| Arrows | Keep → and ↻ as in the key: 「→ 軟調」. | |
| Line breaks | Keep each `\n` where the key has one. A Japanese line may break anywhere; do not add breaks. | |

---

## 4. Spacing between Japanese and Latin or numbers

**No space between Japanese and a Latin word or a number. A half-width space between a number and a
Latin unit, as the key has it. A space between two Latin words.**

- 「このMacに7日間保存」, 「SpektraLabを開いたままに」, 「RAWとDNG」,
  「3枚の写真」, 「7日間」, 「最大%@ MP」, 「%.1f段を保持」, 「16ビット」, 「色温度 %@ K」.
- *Why*: this is Apple's Japanese convention (support.apple.com/ja-jp, checked 2026-10-22:
  「Apple AccountとiCloud」: no spaces). The units keep their space because most of them are formatted by
  code in English (`+0.3 EV`, `12 MP`) and a page must not show both `12 MP` and `12MP`.
- **The site differs**: spektralab.app/jp puts a space around every Latin word (「RAW ファイル」,
  「SpektraLab を支援する」). That is common on Japanese web pages and fine there. The app follows Apple.
  If the site wants to match the app, it drops those spaces. It does not have to.
- **Keys that begin or end with a space.** A trailing space before a value (`"Grain "`, `"Film Exp. "`,
  `"Print · "`) is a separator: **keep it** (`"粒状感 "`, `"露出 "`, `"焼き付け · "`). A leading space
  that joins two English sentences (`" Last sent %@."`)
  is dropped in Japanese, because Japanese puts no space after 。. Check the page in a snapshot,
  since the checker does not test this (LOCALIZATION.md).

---

## 5. Numbers, units, counters

| Thing | Japanese | Notes |
|---|---|---|
| Digits | Half-width Arabic: 3, 12, 0.5. Never full-width ３ or kanji numerals in UI. | Apple. |
| Megapixels | `%@ MP` as the key has it (「最大48 MP」). Not 万画素 in the UI. | MP is on the never-translated list. 4800万画素 is spec-sheet Japanese, too long for a pill. |
| Pixels | `px` after a value; ピクセル in a spoken/accessibility string (`%@ pixels` → `%@ピクセル`). | Apple says ピクセル. 画素 is fine in a sentence about camera resolution but do not mix the two on one page. |
| EV, ISO, K, mm, GB, MB | As written, half-width, space before the unit as the key has it. | |
| Stops | 段: 「1段」「%.1f段」. "stops" alone → 段. | Japanese photographers count stops in 段 (絞り1段). The site: 「7.88 段の保持」. |
| Bit depth | 「8ビット」「16ビット」. TIFF 16-bit → 「TIFF 16ビット」. | Never 位 (see §1). |
| Percent | `%`, or パーセント in an accessibility string. | |
| Millimetre, inch (accessibility) | ミリ, インチ. | |
| ×, ° | Keep: 「×1.5」「90°」. | |
| Time and dates | Leave dates to the code's formatter (`\.locale` is set at the root). 「今日」「昨日」 for Today/Yesterday. | |
| **Counters** | photos in the library: **枚** (3枚); film frames, the pair's halves: **コマ** (2コマ); pairs: **組** (1組); pieces of film on the light table: **枚**; folders: **個** (2個のフォルダ); items selected: 「%@枚を選択中」 (Apple: 「3枚の写真を選択中」 style). | A Japanese noun needs its counter. Never "3写真". |

---

## 6. Names

- **SpektraLab** is always in Latin letters. No katakana reading (スペクトララボ ×) anywhere. A
  particle follows with no space: 「SpektraLabで撮影」.
- **Film and paper names** are the catalogue's in Japanese too: **in Latin letters, exactly as in
  English** ("Kodak Portra 400", short "Portra 400"; `Sources/Mac/RealStockNames.swift`). Never a
  katakana transliteration (コダック・ポートラ ×). spektralab.app/jp prints the same names.
- **Stock kinds** (the words around the names): カラーネガ, リバーサル, 映画用ネガ, 白黒ネガ, カラー印画紙,
  白黒印画紙, 映画用プリントフィルム. See the glossary.
- **RAW, DNG, HEIF, HEIC, JPEG, JPG, PNG, TIFF, ProRAW** stay as written, with no space before a
  particle: 「RAWを撮影」, 「ProRAWとHEIF」. Plural "RAWs" is just RAW (Japanese has no plural):
  "the RAWs you bring in" → 「読み込んだRAW」.
- **Devices**: 「このMac」 (no counter word; Chinese needed 台, Japanese does not).

---

## 7. Length discipline

Japanese text is shorter in characters than English but each glyph is a full em wide. Count a
kanji or kana as **1**, a half-width Latin letter or digit as **0.5**.

| Control | Budget (full-width glyphs) | At most |
|---|---|---|
| Adjust/EngineRouter tile (~70 pt, 12–13 pt type) | **4** | 5 (自然な彩度). 6 only if the snapshot shows it fits (コントラスト, チャンネル: check first). |
| Pill, chip | 5 | 6 |
| Segment of a segmented control | 4 | 5 |
| Ruler row label before a value | 5 | 7 |
| Navigation-bar title | 8 | 10 |
| Button in a sheet | 6 | 8 |
| Settings row label | 12 | 16 (then let it wrap: rows can) |

How to shorten, in this order:
1. **Drop particles and the object the context already gives**: 「フィルムの縁を外す」 → in a menu of
   the Film Edge page, 「外す」.
2. **Use the compact kanji form**: 写し込み for 日付写し込み inside the Date Back page; 引伸機 not 引き伸ばし機;
   露出 for "Film Exp." in a ruler.
3. **Use the noun, not the verb phrase**: 「書き出し」 not 「書き出す」 in a tab.
4. **Abbreviations Japanese photographers write**: WB (only as §1 says), 「7セグ」 is slang, do not use it.
5. Never cut a word in half, never use half-width katakana (ｶﾒﾗ ×), never shrink the type below the
   design's own size. If it still does not fit, list the key for the owner; the layout changes, not the word.

**Keys with one English word for two places** (the same key, so one Japanese word must fit both, or
the code must split the key with `L("…", as:)`):
- `Brightness`: the Adjust tile **and** the enlarger's brightness. 明るさ fits both.
- `Colour`: Edit's Colour tool **and** the enlarger's colour. 色 fits both.
- `Highlights` / `Shadows` / `Midtones`: the Tone page, the colour wheels, the parametric curve. Same word everywhere.
- `Original`, `Format`, `Frame`, `Level`, `Turned`, `Tint`, `Print`, `Scatter`, `Square`, `All` already have split keys (`{…}`); give each its own word from the glossary.

---

## 8. Consistency with spektralab.app/jp

The site (desktop product) was fetched in full on 2026-10-22: `/jp/`, `/jp/lighttable/`,
`/jp/sponsor/`, `/jp/contact/` (the user guide is English and Chinese only). Its Japanese is good and
natural; the app follows it **except where the owner's kanji rule or Apple's names say otherwise**.
The term-by-term comparison is the glossary's *site* column. Summary of where the app differs and how
the site could follow:

| Site | App | Why | Site could change to |
|---|---|---|---|
| プリント (the stage, the verb) | 焼き付け / 焼き付ける | kanji, and it is the darkroom word (DPE = 現像・焼付・引伸). The site's own tagline already says 「写真を、焼く。」 | 焼き付け in body text; プリント can stay in the photo captions ("…にプリント") |
| デートバック | 日付写し込み | the kanji word Japanese camera menus use | 日付写し込み (デートバック) on first mention |
| フィルムエッジ / エッジプリント / パーフォレーション | フィルムの縁 / 縁の印字 / 送り穴 | decision 4; 送り穴 is everyday Japanese | depends on decision 4 |
| ラチチュード | 寛容度 | decision 6 | 寛容度（ラチチュード） |
| ハーフサイズのペア | ハーフ判の2コマ組 | decision 7 | |
| グレア | 迷光 | kanji optics term | 迷光 |
| モノクロ | 白黒 | kanji; both natural | either; not urgent |
| 画幅 (lighttable page: 「画幅の上にドロップ」「画幅を変更…」) | 判型 | 画幅 is the Chinese photographic word; Japanese says 判型 / 〜判 / 画面サイズ | **should change**: 判型, 「判型を変更…」 |
| 引き伸ばし機 and 引伸機 (both used) | 引伸機 | one form; 引伸機 is the trade form and fits a tile | pick one: 引伸機 |
| ルーペ | 拡大鏡 | kanji, ordinary word | either |
| Spaces around Latin words | no spaces | Apple's convention (§4) | optional |

Terms the app takes **from the site unchanged**: 写真を、焼く / フィルターではない, フィルムと印画紙, 印画紙,
現像, 粒状感, ハレーション, カプラー, ライトテーブル, シーン配置, 段, コマ番号, 撮影データ, 実寸, 色空間, 等倍,
ソフトプルーフ (if ever shown), 映画用, リバーサルフィルム, カラーネガフィルム, 各製造元の商標.

---

## 9. Notes for the code side (not terminology, but the translator will meet them)

- *Done 2026-10-22:* `AppLanguage` has its fourth case (`ja`, own name 「日本語」,
  `Sources/Model/Localization.swift`), `knownRegions`/`CFBundleLocalizations` name it, and the first-launch
  rule gives Japanese to a system whose first preferred language among the app's four is `ja`.
- *Done 2026-10-22:* `tools/localization_check.py` holds `ja` as it holds the two Chinese, with a Japanese
  script table of its own (`NOT_JAPANESE_SIMPLIFIED`, `KYUJITAI_ONLY`; see §1), not the zh tables.
- The privacy policy exists in English and Simplified Chinese only. The app in Japanese is sent to
  the English page unless a Japanese policy is published. The in-app privacy sentences
  (`HARD-STRINGS.md` 6–10) must say no more and no less than the published English policy.

## Desktop text pass, 2026-11-08

Use the glossary in short captions as well as in control labels. A shorter caption must keep the reason
for a disabled control, the scope of a preference, and any effect on existing edits or originals.
Remove a redundant caption's view rather than leaving an empty row. Supporter notes remain verbatim.
