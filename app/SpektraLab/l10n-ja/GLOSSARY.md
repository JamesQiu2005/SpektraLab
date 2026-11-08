# GLOSSARY.md: SpektraLab's Japanese terms

Written 2026-10-22, read with `STYLE.md`. One row per recurring term and per control label in
`Localizable.xcstrings` (1158 keys when it was written) and `InfoPlist.xcstrings`. Not yet checked by a native speaker.
Pruned 2026-11-08 to the Mac app's words.

**Columns.** *script*: 漢字, 漢字+かな, かな, カナ (katakana kept), 漢字+カナ (a compound with a
katakana part), EN (English kept). **Every カナ and EN row says in *why* why no kanji word works.**
*site*: what spektralab.app/jp uses (fetched 2026-10-22), "—" if it does not use the term.
*conf*: high / medium / low. *back*: a literal English back-translation of the Japanese.
A row whose choice is put to the owner says **D1…D8** (`DECISIONS-FOR-OWNER.md`); the glossary
carries the recommended word, so the translator can work before the owner answers.

Sources named in *why*: **Apple** = Apple's Japanese interface and support.apple.com/ja-jp (the Photos
editing guide and the iCloud Photos page `108782` were read on 2026-10-22; other Apple words are from
knowledge of Apple's Japanese interface and are marked *Apple (not re-checked)* where I could not open a
page); **LR** = Adobe Lightroom's Japanese UI; **darkroom** = Japanese darkroom usage.

---

## 1. The process: film, develop, print

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Film | フィルム | ふぃるむ | カナ | The only Japanese word. 感材 (light-sensitive material) is trade jargon; 胶片 is Chinese. | フィルム | high | film |
| Films (sidebar section) | フィルム | ふぃるむ | カナ | No plural in Japanese. | フィルム | high | film |
| + Film | ＋ フィルム | | カナ | As the key. | — | high | + film |
| Paper / Print {the paper} | 印画紙 | いんがし | 漢字 | The darkroom word for photographic paper. | 印画紙 | high | printing paper |
| Film & Paper / Film and paper | フィルムと印画紙 | ふぃるむといんがし | 漢字+カナ | | フィルムと印画紙 | high | film and printing paper |
| Develop (the stage, the page, the verb) | 現像 / 現像する | げんぞう | 漢字 | The word for developing film, and for the whole act. | 現像 | high | develop(ment) |
| Developing | 現像中 | げんぞうちゅう | 漢字 | Status line. | — | high | developing |
| Developed | 現像済み | げんぞうずみ | 漢字+かな | | — | high | developed |
| Not developed / not developed yet | 未現像 / まだ現像していません | みげんぞう | 漢字 | 未現像 for a badge; the sentence for a row. | — | high | undeveloped |
| Waiting to develop | 現像待ち | げんぞうまち | 漢字+かな | | — | high | waiting for development |
| Develop Again | 再現像 | さいげんぞう | 漢字 | | — | high | redevelop |
| Could not develop | 現像できませんでした | | 漢字+かな | です・ます: an error sentence. | — | high | could not develop |
| Print (the stage, the verb) | 焼き付け / 焼き付ける | やきつけ | 漢字+かな | **D1.** The darkroom's own word (DPE = 現像・焼付・引伸). Matches the site's tagline 写真を、焼く. | プリント | medium | printing (burning onto paper) |
| Printing | 焼き付け中 | やきつけちゅう | 漢字+かな | | — | medium | printing |
| Printed | 焼き付け済み | やきつけずみ | 漢字+かな | | — | medium | printed |
| Not printed / no print | 焼き付けなし | やきつけなし | 漢字+かな | | — | medium | no printing |
| print (lowercase, the mode word) | 焼き付け | やきつけ | 漢字+かな | | — | medium | printing |
| Print · (label before a value) | 焼き付け ·  | | 漢字+かな | Keep the trailing space and dot. | — | medium | printing · |
| Print Effects | 印画の効果 | いんがのこうか | 漢字+かな | 印画 = the photographic print (as in 印画紙). 焼き付け効果 reads clumsily. | プリント効果 | medium | effects of the print |
| Film Effects | フィルムの効果 | ふぃるむのこうか | 漢字+カナ | | フィルム効果 | high | the film's effects |
| Scan / Scanned / scanned | スキャン / スキャン済み / スキャン | すきゃん | カナ | No natural kanji (走査 is engineering jargon). | スキャン | high | scan(ned) |
| Scanned, not printed. | スキャンのみ。焼き付けはしません。 | | 漢字+カナ | | — | high | scan only; not printed |
| Enlarger | 引伸機 | ひきのばしき | 漢字 | The darkroom's trade form; fits a tile. The site writes both 引伸機 and 引き伸ばし機; pick one. | 引き伸ばし機 / 引伸機 | high | enlarger |
| EngineRouter | 暗室 | あんしつ | 漢字 | | 暗室 | high | darkroom |
| An empty darkroom | 空っぽの暗室 | からっぽのあんしつ | 漢字+かな | *voice* line. | — | high | an empty darkroom |
| Negative | ネガ | ねが | カナ | The everyday word. The kanji 陰画 is *literary*/old: textbooks only. **D5.** | ネガ | high | negative |
| Positive | ポジ | ぽじ | カナ | 陽画 is literary. **D5.** | — | high | positive |
| SLIDE (tag) / slide (positive) | ポジ / リバーサル（ポジ） | ぽじ / りばーさる | カナ | Japanese say リバーサル or ポジ for slide film; スライド is the mounted slide. **D5.** | リバーサルフィルム | high | positive / reversal (positive) |
| %@ is a slide. | %@はリバーサルフィルムです。 | | | | リバーサルフィルム | high | %@ is a reversal film |
| colour negative | カラーネガ | からーねが | カナ | Standard. No kanji for "colour film" (彩色 is wrong). | カラーネガフィルム | high | colour negative |
| colour paper | カラー印画紙 | からーいんがし | 漢字+カナ | | — | high | colour printing paper |
| b&w negative / B&W | 白黒ネガ / 白黒 | しろくろ | 漢字(+カナ) | 白黒 and モノクロ are both everyday; the owner prefers kanji. | モノクロフィルム | medium | black-and-white negative |
| b&w paper | 白黒印画紙 | しろくろいんがし | 漢字 | | — (印画紙 モノクロ) | medium | black-and-white printing paper |
| cine negative | 映画用ネガ | えいがようねが | 漢字+カナ | | 映画用カラーネガフィルム | high | negative for motion pictures |
| cine print film | 映画用プリントフィルム | えいがようぷりんとふぃるむ | 漢字+カナ | The industry term for release print stock; no kanji alternative. | 映画用 | medium | print film for motion pictures |
| Cine (pill) | 映画用 | えいがよう | 漢字 | The site's word. | 映画用 | high | for motion pictures |
| Standard (pill) | 標準 | ひょうじゅん | 漢字 | | — | high | standard |
| Couplers | カプラー | かぷらー | カナ | The Japanese term. 発色剤 exists but in everyday Japanese means a food colour fixative. | カプラー / DIRカプラー | high | couplers |
| How hard the film's layers hold each other back: | フィルムの各層が互いの発色を抑える強さ： | | | Describes the interimage effect (重層効果). | — | medium | the strength with which the film's layers suppress each other's colour |
| Grain | 粒状感 | りゅうじょうかん | 漢字 | The site's word; film reviewers also say 粒状性 (technical) and 粒子 (LR's slider). 顆粒 is wrong. | 粒状感 | high | graininess |
| Grain sub-layers / Sub-layers | 粒状の層 / 層 | りゅうじょうのそう / そう | 漢字 | | — | medium | layers of grain |
| Grain in one layer / one layer | 粒状は1層 / 1層 | いっそう | 漢字 | | — | medium | grain in one layer |
| Grain in three layers / three, as the film has | 粒状は3層 / 3層（フィルムと同じ） | さんそう | 漢字 | | — | medium | grain in three layers |
| Halation | ハレーション | はれーしょん | カナ | The only Japanese term; no kanji word exists (光暈 is Chinese). Anti-halation layer = ハレーション防止層, the standard term. | ハレーション | high | halation |
| Remove anti-halation layer | ハレーション防止層を除く | はれーしょんぼうしそうをのぞく | 漢字+カナ | | — | high | remove the anti-halation layer |
| Light that passes through the film and comes back: | フィルムを透過して戻ってくる光： | | | | — | high | light that passes through the film and returns |
| Scatter | 散乱 | さんらん | 漢字 | Physics' word for light scatter. | — | high | scattering |
| Glare (the paper's veil) | 迷光 | めいこう | 漢字 | Optics' word for stray light. A kanji word in real use; グレア is the site's. | グレア | medium | stray light |
| inside the emulsion | 乳剤の中で | にゅうざいのなかで | 漢字+かな | 乳剤 = emulsion, standard. | — | high | inside the emulsion |
| Film Exposure / Film Exp. | フィルムの露出 / 露出 | ろしゅつ | 漢字(+カナ) | Photographers say 露出 for how much a frame was exposed (露出オーバー). 露光 is kept for the enlarger and the engine's sensitometry. | 露出 | medium | exposure of the film |
| Exposure (Adjust) / exposure | 露出 | ろしゅつ | 漢字 | Apple Photos and LR use 露出 / 露光量. | 露出 | high | exposure |
| Exposure compensation | 露出補正 | ろしゅつほせい | 漢字 | Camera term. | — | high | exposure compensation |
| Source exposure / Source (that mode) | 元の露出 / 元の露出 | もとのろしゅつ | 漢字+かな | "Keep the photographer's exposure". | — | medium | the original exposure |
| balanced | バランス | ばらんす | カナ | No natural kanji (均衡 sounds like economics). | — | low | balance |
| Latitude | 寛容度 | かんようど | 漢字 | **D6.** Textbook term (露光寛容度); everyday speech says ラチチュード. Never 宽容度 (Chinese form). | ラチチュード | medium | latitude (tolerance) |
| Latitude: %@ | 寛容度：%@ | | | | — | medium | |
| stops / %.1f stops held | 段 / %.1f段を保持 | だん / だんをほじ | 漢字 | Japanese count stops in 段. | 段 / 7.88 段の保持 | high | stops / holds %.1f stops |
| Scene | シーン | しーん | カナ | 撮影シーン is everyday; 場面 is a scene in a story, not a photograph. | シーン | high | scene |
| Scene Placement | シーン配置 | しーんはいち | 漢字+カナ | The site's word; 配置 is the zone system's "placement". | シーン配置 | high | scene placement |
| Placement | 配置 | はいち | 漢字 | | 配置 | high | placement |
| Highlight placement / Shadow placement | 明部の配置 / 暗部の配置 | めいぶ / あんぶ | 漢字 | Follows D3. | — | medium | placement of the bright/dark part |
| GUIDE (tag) | 目安 | めやす | 漢字 | "A rough guide", everyday. | — | medium | rough guide |
| The finished picture / Process (capsule) | 仕上がり | しあがり | 漢字+かな | Natural word for the finished result. | — | high | the finish |
| The developed film / picture | 現像したフィルム / 現像した写真 | | | | — | high | |
| Engine / SpektraLab engine | エンジン / SpektraLabエンジン | えんじん | カナ | The site's word; 処理系 is computer-science jargon. | エンジン | high | engine |
| Unavailable materials | 使えない感材 | つかえないかんざい | 漢字+かな | 感材 here is right: it covers film and paper together. Only in this diagnostic row. | — | low | unusable sensitive materials |

## 2. The enlarger and the paper (EngineRouter)

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Brightness (Adjust tile **and** enlarger; one key) | 明るさ | あかるさ | 漢字+かな | Apple Photos' word; also right for the print's brightness. | — | high | brightness |
| Brightness (label before a value) | 明るさ  | | | Keep the trailing space. | — | high | |
| The enlarger's exposure. It prints again from the same negative. | 引伸機の露光です。同じネガから焼き付け直します。 | | | | — | high | |
| Colour (enlarger **and** Edit's Colour tool; one key) | 色 | いろ | 漢字 | One character fits every place. | — | high | colour |
| Yellow / Magenta (enlarger filters, HSL) | 黄 / 赤紫 | き / あかむらさき | 漢字 | Kanji colour words are natural. Japanese colour printers say イエロー / マゼンタ or write Y / M; 赤紫 is the Japanese colour name nearest magenta. | — | medium | yellow / red-purple |
| → blue / → green | → 青寄り / → 緑寄り | あおより / みどりより | 漢字+かな | 〜寄り = "leaning toward". | — | high | toward blue / green |
| Grade | 号数 | ごうすう | 漢字 | A paper's grade (2号, 3号) and a multigrade filter number. | フィルター 2 | high | grade number |
| → softer / → harder | → 軟調 / → 硬調 | なんちょう / こうちょう | 漢字 | The darkroom's words for soft and hard grades. | — | high | soft tone / hard tone |
| Pre-flash | 予備露光 | よびろこう | 漢字 | EngineRouter word for flashing paper (also プレフラッシュ, 前露光). | — | medium | preliminary exposure |
| A flash of plain light on the paper first: softer highlights. | 先に印画紙へ均一な光を当て、明部をやわらかくします。 | | | | — | medium | |
| Paper and the enlarger wait for a negative. | 印画紙と引伸機はネガを選ぶと使えます。 | | | | — | high | paper and enlarger can be used when you choose a negative |
| the film's own paper | このフィルムに合う印画紙 | | | "The paper that suits this film". | 対応する印画紙 | high | |

## 3. Decode (RAW) and white balance

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Decode | RAW処理 | ろーしょり | EN+漢字 | The RAW-decoding stage. 復号 means decryption; デコード is jargon. | RAW デコード | medium | RAW processing |
| These reach a RAW file's decode only. | この2つはRAWファイルの処理にだけ効きます。 | | | | — | medium | |
| White Balance / White balance | ホワイトバランス | ほわいとばらんす | カナ | Universal in Japanese; 白平衡 is Chinese. In a chip or a tile where 7 glyphs cannot fit: `WB`. | ホワイトバランス | high | white balance |
| As Shot | 撮影時の設定 | さつえいじのせってい | 漢字+かな | LR's words. | — | high | settings at capture |
| Custom | カスタム | かすたむ | カナ | One key for a hand-set white balance **and** a custom film size, so one word must fit both. 手動 fits only the first and 任意 only the second; カスタム is Apple's own word for both. If the code splits the key, use 手動 for white balance. | — | medium | custom |
| Temperature | 色温度 | しきおんど | 漢字 | | — | high | colour temperature |
| Temperature %@ K | 色温度 %@ K | | | | — | high | |
| Tint / Tint {the colour shift} | 色合い | いろあい | 漢字+かな | Apple Photos' word for Tint. Both keys can take it. | — | high | hue / tint |
| Daylight / Cloudy / Shade / Tungsten / Fluorescent | 太陽光 / 曇天 / 日陰 / 白熱電球 / 蛍光灯 | たいようこう / どんてん / ひかげ / はくねつでんきゅう / けいこうとう | 漢字 | The white-balance presets on Japanese cameras. | — | high | sunlight / overcast / shade / incandescent / fluorescent |
| Auto / Auto · %@ / Auto, on / off | 自動 / 自動 · %@ / 自動、オン / 自動、オフ | じどう | 漢字 | Apple writes 自動 (flash, HDR). | — | high | automatic |
| This negative is read as the negative it is. | このネガは、ネガのまま読み取ります。 | | | | — | high | |
| JPEG and HEIC come in developed by their camera … | (see HARD-STRINGS 4) | | | | | | |

## 4. Adjust (Edit)

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Edit | 編集 | へんしゅう | 漢字 | Apple. | — | high | edit |
| Adjust | 調整 | ちょうせい | 漢字 | Apple Photos' tab. | — | high | adjust |
| Light (Edit's group) | 光 | ひかり | 漢字 | | — | high | light |
| Brightness | 明るさ | あかるさ | 漢字+かな | Apple. | — | high | brightness |
| Contrast | コントラスト | こんとらすと | カナ | Every Japanese editor says コントラスト. 明暗差 is a natural kanji word but not a tool name; **use 明暗差 only if コントラスト does not fit its tile** (STYLE §7). | — | high | contrast |
| Tone (tile) | 階調 | かいちょう | 漢字 | The tile holds Highlights & Shadows, Whites & Blacks. | — | high | tonal gradation |
| Highlights / Highlight | 明部 | めいぶ | 漢字 | **D3.** Photographic word for the bright part (明部・中間部・暗部). Apple and LR say ハイライト. | — | medium | bright part |
| Shadows / Shadow | 暗部 | あんぶ | 漢字 | **D3.** Same. | — | medium | dark part |
| Highlights & Shadows | 明部と暗部 | | 漢字 | | — | medium | |
| Midtones | 中間調 | ちゅうかんちょう | 漢字 | | — | high | middle tones |
| Midtones {the colour pad} | 中間 | ちゅうかん | 漢字 | The pad's centre. | — | medium | middle |
| Blacks / Whites | 黒レベル / 白レベル | くろれべる / しろれべる | 漢字+カナ | LR's words; 黒点 is a "black spot". | — | high | black level / white level |
| Whites & Blacks | 白レベルと黒レベル | | 漢字+カナ | In a segmented band: 「白・黒レベル」. | — | high | |
| HSL | HSL | — | EN | LR JP titles the panel HSL; a Japanese translation of the letters (色相・彩度・輝度) is too long for a tile. | — | high | HSL |
| Hue | 色相 | しきそう | 漢字 | | — | high | hue |
| Saturation | 彩度 | さいど | 漢字 | Apple, LR. | — | high | saturation |
| Luminance / Luma | 輝度 | きど | 漢字 | LR's HSL word. Both keys take it (different pages). | — | high | luminance |
| Vibrance | 自然な彩度 | しぜんなさいど | 漢字+かな | Apple and LR. 5 glyphs: fits a tile at most. | — | high | natural saturation |
| Channels | チャンネル | ちゃんねる | カナ | The channel mixer. No kanji word. 5 glyphs: check the tile. | — | high | channel |
| Colour Wheels | 色相環 | しきそうかん | 漢字 | The standard Japanese word for the colour wheel. (Video software says カラーホイール.) | — | medium | hue circle |
| Master (the wheels) | 全体 | ぜんたい | 漢字 | | — | high | the whole |
| Curve | 曲線 | きょくせん | 漢字 | A plain word; the usual tool name is トーンカーブ (Photoshop, LR). Clear in context and kanji. | — | medium | curve |
| Point / Parametric (curve modes) | 点 / 領域 | てん / りょういき | 漢字 | LR says ポイント / パラメトリック; these say what each mode moves. | — | medium | points / regions |
| Lights / Darks (parametric regions) | 明るめ / 暗め | あかるめ / くらめ | 漢字+かな | Natural adjectives between 明部 and 暗部. | — | medium | brighter / darker |
| Split | 境界 | きょうかい | 漢字 | The boundary between regions. | — | medium | boundary |
| Input / Output | 入力 / 出力 | にゅうりょく / しゅつりょく | 漢字 | | — | high | |
| Add point | 点を追加 | てんをついか | 漢字+かな | | — | high | |
| Shows / Folds the plot | 曲線を表示 / 曲線をしまう | | | | — | high | |
| Vignette | 周辺減光 | しゅうへんげんこう | 漢字 | The optical term; LR says 周辺光量補正. | — | high | peripheral light falloff |
| Midpoint | 中心点 | ちゅうしんてん | 漢字 | LR's vignette "Midpoint". | — | high | centre point |
| Temperature (tile) | 色温度 | しきおんど | 漢字 | | — | high | |
| Colours: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta | 赤、橙、黄、緑、水色、青、紫、赤紫 | あか、だいだい、き、みどり、みずいろ、あお、むらさき、あかむらさき | 漢字 | Plain colour words. LR writes them all in katakana. 橙 is slightly *literary*; オレンジ is everyday, but 橙 is understood by everyone. | — | medium | |
| Black / White | 黒 / 白 | くろ / しろ | 漢字 | | — | high | |
| Black: a black backing … / White: the scan's light … | 黒：黒い台紙、または暗室で焼いたストリップ。 / 白：スキャン時に送り穴を抜ける光。 | | | | — | medium | |
| Changed / Edited / edited | 調整済み / 編集済み | | 漢字+かな | | — | high | |
| Nothing yet | まだ調整はありません | | | | — | high | no adjustments yet |
| Presets / Save Preset / No presets yet | プリセット / プリセットを保存 / プリセットはまだありません | ぷりせっと | カナ | LR's word; no kanji word (登録設定 is unusual). | — | high | preset |
| A preset with this name already exists | 同じ名前のプリセットがすでにあります | | | | — | high | |

## 5. Crop and geometry

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Crop | 切り取り | きりとり | 漢字+かな | Apple Photos JP (「切り取り/回転/反転/傾き補正」). | — | high | cut out |
| Straighten | 傾き補正 | かたむきほせい | 漢字+かな | Apple. | — | high | tilt correction |
| Rotate / Turn / Turn 90° / Turn Left / Turn Right | 回転 / 回転 / 90°回転 / 左に回転 / 右に回転 | かいてん | 漢字 | Apple; the site: 右へ回転. | 右へ回転 | high | |
| Flip | 反転 | はんてん | 漢字 | Apple. | — | high | |
| Aspect ratio | 縦横比 | じゅうおうひ | 漢字 | Apple (not re-checked). | — | high | |
| Freeform / Free | 自由形式 / 自由 | じゆうけいしき | 漢字 | Apple's 自由形式. | — | high | |
| Original ratio | 元の比率 | もとのひりつ | 漢字+かな | Apple shows オリジナル here; kanji is just as clear. | — | medium | |
| Square {a ratio} | 正方形 | せいほうけい | 漢字 | Apple says スクエア; 正方形 is the plain word. | — | medium | square |
| Landscape / Portrait | 横長 / 縦長 | よこなが / たてなが | 漢字+かな | | — | high | |
| Ratio locked / Unlock the ratio | 比率を固定中 / 比率の固定を解除 | | | | — | high | |
| Horizontal / Vertical {perspective} | 水平方向 / 垂直方向 | すいへいほうこう / すいちょくほうこう | 漢字 | Apple's perspective sliders. | — | high | |
| Guides | 補助線 | ほじょせん | 漢字 | | — | high | auxiliary lines |
| Horizontals / Verticals {guides} | 水平線 / 垂直線 | | 漢字 | | — | high | |
| Rectangle {guides} | 長方形 | ちょうほうけい | 漢字 | 矩形 is *literary*/technical. | — | high | |
| Apply / Apply {the guides} | 適用 | てきよう | 漢字 | | — | high | |
| Fit / Fit picture / Fitted | 全体表示 / 画像を全体表示 / 全体表示中 | ぜんたいひょうじ | 漢字 | 画面に合わせる is longer. | ウィンドウに合わせて表示 | high | whole view |
| Zoom in / Zoomed %@ percent of fit | 拡大 / 全体表示の%@% | かくだい | 漢字 | | 拡大 | high | |
| Crop held by Film Edge | 切り取りはフィルムの縁が決めます | | | | — | medium | |
| Frame {placing the picture} | 構図 | こうず | 漢字 | "Composition": what the user sets when placing the picture. | — | high | composition |
| Picture | 画像 | がぞう | 漢字 | | — | high | image |

## 6. Film Edge, Date Back, formats

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Film Edge / Film edge | フィルムの縁 | ふぃるむのふち | 漢字+カナ | **D4.** Plain words for the rebate. 縁 reads ふち here (in context it does not read えん). | フィルムエッジ | medium | the film's border |
| Edge (step name) | 縁 | ふち | 漢字 | | — | medium | border |
| Film edge on / off / %@ | フィルムの縁 オン / オフ / %@ | | | | — | medium | |
| Remove film edge / Take the Film Edge Off | フィルムの縁を外す | | | | — | medium | |
| Film Edge & Date Back | 縁と日付 | ふちとひづけ | 漢字 | Compact form for the tab title. | フィルムエッジ · デートバック | medium | border and date |
| Edge Print | 縁の印字 | ふちのいんじ | 漢字 | **D4.** エッジプリント is the usual term (and the site's). | エッジプリント | medium | printing on the border |
| Holes | 送り穴 | おくりあな | 漢字+かな | Everyday Japanese for sprocket holes (also パーフォレーション). | パーフォレーション | high | feed holes |
| 120 film has no perforations. | 120フィルムには送り穴がありません。 | | | | — | high | |
| Gate | 画枠 | がわく | 漢字 | The frame's outline. Used by Japanese videographers; アパーチャー is the camera part. | — | medium | picture frame outline |
| Gate shapes: Square / Rounded / Eared / Kicked / Shouldered | 角形 / 角丸 / 耳付き / 張り出し / 肩付き | かくがた / かどまる / みみつき / はりだし / かたつき | 漢字(+かな) | Built from ordinary words, **not standard terms** (no Japanese terms exist; the Chinese ones are coinages too). 角丸 is everyday ("rounded corners"). | — | low | square / rounded corners / with ears / protruding / with shoulders |
| Body / Another camera body / Body No. %@ | 本体 / 別の本体 / 本体 %@号 | ほんたい | 漢字 | カメラ本体 is the everyday Japanese for the body (ボディ is also common). | — | medium | main body |
| Advance / the camera's advance | 巻き上げ / カメラの巻き上げ間隔（フィルムの縁があるとき） | まきあげ | 漢字+かな | The Japanese word for film advance. | — | high | wind-on |
| Frame no. / Frame no. %@ / auto | コマ番号 / コマ番号 %@ / コマ番号 自動 | こまばんごう | 漢字+カナ | The site's word. | コマ番号 | high | frame number |
| Edge fog / Edge fog %.1f | 縁かぶり / 縁かぶり %.1f | ふちかぶり | 漢字+かな | かぶり is the photographic word for fog (in kana). | — | medium | border fog |
| Spool leaks | 光漏れ | ひかりもれ | 漢字+かな | The everyday word for light leaks. "Spool" is understood from the page. | — | medium | light leak |
| Light (the edge print's light) | 印字の光 | いんじのひかり | 漢字+かな | | — | medium | light of the printing |
| Strip (view) | 全幅 | ぜんぷく | 漢字 | "The whole width": what the view shows. ストリップ is the site's. | ストリップ | medium | full width |
| Filed (view) | 細縁 | ほそぶち | 漢字 | A thin border, as a filed-out carrier gives (黒フチ in darkroom slang). Built from ordinary words. | — | low | thin border |
| Data / Data needs Film Edge | 撮影データ / 撮影データにはフィルムの縁が必要です | さつえいでーた | 漢字+カナ | データ: no kanji word. | 撮影データ | high | shooting data |
| Format {of film} / Film size %@ | 判型 / フィルムのサイズ %@ | はんけい | 漢字 | Format of film: 判型 (35ミリ判, 6×7判). Not 画幅 (Chinese). | 画幅 (lighttable) | medium | format type |
| Half (format) | ハーフ | はーふ | カナ | ハーフサイズ is the Japanese name for half-frame. | ハーフ | high | half |
| name below / on the left / on the right / on top | 銘柄は下 / 左 / 右 / 上 | めいがら | 漢字 | 銘柄 = a film's product name. | — | medium | brand name below… |
| This film's edge prints no frame numbers. | このフィルムの縁にはコマ番号が入りません。 | | | | — | medium | |
| Date Back | 日付写し込み | ひづけうつしこみ | 漢字+かな | Japanese camera menus' own word (デートバック is the accessory's name). | デートバック | medium | date imprinting |
| Date / Dates / No date | 日付 / 日付 / 日付なし | ひづけ | 漢字 | | 日付 | high | |
| Print Each Frame's Date | 各コマに日付を写し込む | | 漢字+カナ | | — | medium | |
| Remove the Date(s) | 日付を消す | | | | — | high | |
| Turn on Date Back first. | 先に日付写し込みをオンにしてください。 | | | | — | medium | |
| face (a date's typeface) | 書体 | しょたい | 漢字 | | — | high | typeface |
| Dots | ドット | どっと | カナ | No kanji word (点描 is a painting style). | — | medium | dots |
| seven segments | 7セグメント | せぶんせぐめんと | カナ | Engineering word; known from digital clocks. | — | medium | |
| Corner / top left … | 隅 / 左上・右上・左下・右下 | すみ | 漢字 | | — | high | |
| center (meter) / center-weighted (legacy) | 中央 / 中央重点（旧方式） | ちゅうおう / ちゅうおうじゅうてん | 漢字 | Camera terms. | — | high | |

## 7. The half-frame pair

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Half-Frame Pair / half-frame pair | ハーフ判の2コマ組 | はーふばんのにこまぐみ | 漢字+カナ | **D7.** Built from ordinary words, after 2枚組 ("a set of two"); not a standard term. | ハーフサイズのペア | medium | a two-frame set in half format |
| Pair (button, tab) | 2コマ組 | にこまぐみ | 漢字+カナ | **D7.** | ペア | medium | two-frame set |
| a pair (counter) / %@ pairs | 組 / %@組 | くみ | 漢字 | | — | high | set |
| Pair With | 組にする | くみにする | 漢字+かな | | — | medium | make a set |
| In this pair | この組に入っています | | | | — | medium | |
| New half-frame pair | 新しい2コマ組 | | | | — | medium | |
| Remove this pair? | この組を解除しますか？ | | | The frames stay in the library, so 解除 ("undo the set"), not 削除. | — | medium | |
| Frame {one of a pair} | このコマ | このこま | カナ | コマ: a native Japanese word, written in katakana by convention. | コマ | high | this frame |
| Left / Right / Top / Bottom frame | 左のコマ / 右のコマ / 上のコマ / 下のコマ | | カナ+漢字 | | — | high | |
| The first frame / The second frame | 1コマ目 / 2コマ目 | いちこまめ | | | — | high | |
| 1 of 2 frames | 2コマ中1コマ | | | | — | high | |
| Level {a pair} / Turned {a pair} | 横並び / 縦並び | よこならび / たてならび | 漢字+かな | | 左右 / 上下 | high | side by side / stacked |
| Spacing / %.1f mm apart | 間隔 / %.1f mm間隔 | かんかく | 漢字 | | — | high | |
| Centred / Placed | 中央 / 配置済み | | 漢字 | | — | high | |
| Swap the Two Frames | 2コマを入れ替える | | | | — | high | |
| Put the Pair on Its Strip | 2コマ組をフィルムに戻す | | | | — | medium | |
| An empty hole is unexposed film. | 空いたコマは未露光のフィルムです。 | | | | — | high | |

## 8. Library and gallery

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Library | ライブラリ | らいぶらり | カナ | **D2.** Apple Photos' tab name; users know it. | — | medium | library |
| All {the gallery} / All | すべて | | かな | Apple writes すべて. | — | high | all |
| Photos (gallery view) / Photo | 写真 | しゃしん | 漢字 | | — | high | |
| Imported | 読み込み済み | よみこみずみ | 漢字+かな | Apple's 読み込む. | — | high | imported |
| Import / Import %@ / Importing %@… | 読み込む / %@枚を読み込む / %@枚を読み込み中… | よみこむ | 漢字+かな | Apple. | — | high | |
| Copy into SpektraLab / Copied into SpektraLab / Copy files in / Copied in | SpektraLabに取り込む / 取り込み済み / ファイルを取り込む / 取り込み済み | とりこむ | 漢字+かな | 取り込む ("take in") is kept apart from 読み込む (import, which may read in place) and from コピー (the clipboard). | — | medium | take into SpektraLab |
| Frame (a picture in the library) | 写真（枚） | しゃしん | 漢字 | Counter 枚. | — | high | |
| Collections | 分類 | ぶんるい | 漢字 | Apple's Photos says コレクション; the app's are sidebar groups, which 分類 describes. | — | medium | classification |
| Favourite / Favourites / Unfavourite / No favourites yet. | お気に入り / お気に入り / お気に入りから外す / お気に入りはまだありません。 | おきにいり | 漢字+かな | Apple. | — | high | |
| Select / Select All / Deselect All / %@ Selected | 選択 / すべてを選択 / すべての選択を解除 / %@枚を選択中 | せんたく | 漢字 | Apple. | — | high | |
| Sort / Newest First / Oldest First | 並べ替え / 新しい順 / 古い順 | ならべかえ | 漢字+かな | Apple. | — | high | |
| View / as Icons / as List / Larger Icons / Smaller Icons | 表示 / アイコン表示 / リスト表示 / アイコンを大きく / アイコンを小さく | ひょうじ | 漢字+カナ | Apple's Finder words. | — | high | |
| Sidebar | サイドバー | さいどばー | カナ | Apple. | — | high | |
| Info / Where / Kept here | 情報 / 場所 / 保存場所 | じょうほう / ばしょ / ほぞんばしょ | 漢字 | | — | high | |
| Source (library column) / Sources (Settings) | 取得元 / 読み込み元 | しゅとくもと / よみこみもと | 漢字+かな | | — | medium | where it came from |
| Original {the file} | 元ファイル | もとふぁいる | 漢字+カナ | **D8.** Apple says オリジナル. | — | medium | the original file |
| Original {the picture} / Original (capsule) | 元画像 | もとがぞう | 漢字 | **D8.** | — | medium | the original image |
| Original missing / The original is missing | 元ファイルが見つかりません | | | | — | medium | |
| Keep Originals in SpektraLab | 元ファイルをSpektraLabに保持 | | | Mirrors Apple's iCloud setting 「ダウンロードしてオリジナルを保持」; with D8 the noun is 元ファイル. | — | medium | |
| Working copies / Preview copies | 作業用ファイル / プレビュー画像 | さぎょうよう / ぷれびゅー | 漢字+カナ | コピー is avoided for files; these say what each is. | — | medium | working files / preview images |
| preview size / Preview size | プレビューサイズ | ぷれびゅーさいず | カナ | Apple says プレビュー; サイズ: no natural kanji for image size (大きさ is fine in a sentence). | プレビューサイズ | high | |
| Full / Full size / full size | 原寸 | げんすん | 漢字 | **Never フルサイズ**: in Japanese that means a 35 mm full-frame sensor. Apple writes フル解像度; 原寸 is shorter and kanji. | フル解像度 | medium | original size |
| Actual Size (light table) | 実寸 | じっすん | 漢字 | Physical 1:1 size. The site's word. | 実寸 | high | actual dimensions |
| Thumbnails and cache | 縮小画像とキャッシュ | しゅくしょうがぞう | 漢字+カナ | Apple writes サムネール; 縮小画像 is the plain kanji word. キャッシュ: no kanji. | — | medium | |
| Linked folders / Link a Folder / Unlink / Reconnect | 連携フォルダ / フォルダを連携 / 連携を解除 / 再接続 | れんけい / さいせつぞく | 漢字+カナ | 連携 is the Japanese UI word for linking a service or a folder. フォルダ is Apple's. | — | medium | |
| iCloud Drive | iCloud Drive | | EN | Apple JP keeps it in English. | — | high | |
| Remove / Remove from Library / Remove this frame? | 取り除く / ライブラリから取り除く / この写真を取り除きますか？ | とりのぞく | 漢字+かな | Apple's 「アルバムから取り除く」. Delete = 削除. | — | high | |
| Delete / Undo Delete | 削除 / 削除を取り消す | さくじょ | 漢字 | Apple. | — | high | |
| Rename / Rename… | 名称変更 / 名称変更… | めいしょうへんこう | 漢字 | Apple. | — | high | |

## 9. Camera and lens (what a picture was taken with)

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Capture / Date Taken / Recent Captures | 撮影 / 撮影日 / 最近の撮影 | さつえい | 漢字 | | — | high | shooting |
| Camera / Cameras (Filters, Info) | カメラ | かめら | カナ | Apple. | — | high | |
| Lens / Lens Correction | レンズ / レンズ補正 | れんず / れんずほせい | カナ(+漢字) | No kanji word for lens (鏡玉 is archaic). LR: レンズ補正. | — | high | |
| distortion / vignetting (lens) | 歪曲 / 周辺減光 | わいきょく / しゅうへんげんこう | 漢字 | 歪曲収差 in full. | — | high | |
| ISO | ISO | | EN | As on every Japanese camera. | — | high | |
| Meter / meter / Meter off | 測光 / 測光 / 測光オフ | そっこう | 漢字 | | 測光 | high | metering |
| Measuring / No light in the frame to measure / Not measured | 測光中 / 測光できる光がありません / 未測光 | | 漢字 | | — | high | |
| brightest / darkest | 最も明るい部分 / 最も暗い部分 | | | | — | high | |
| protect highlights / shadows | 明部を保護 / 暗部を保護 | | 漢字 | Follows D3. | — | medium | |
| Grid | グリッド | ぐりっど | カナ | Apple's word. | — | high | |
| Shows more / fewer controls | 操作項目を増やす / 減らす | | | | — | medium | |

## 10. Export and recipes

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Export / Exporting / Export %@ | 書き出す / 書き出し中 / %@を書き出す | かきだす | 漢字+かな | Apple. | 書き出し | high | |
| Recipe / Recipes / New Recipe / Rename / Delete Recipe | 書き出し設定 / 書き出し設定 / 新規書き出し設定 / 書き出し設定の名称変更 / 書き出し設定を削除 | かきだしせってい | 漢字+かな | "Export setting". レシピ (the site's word) in Japan means a Fujifilm-style **look** recipe, which would mislead. | 書き出しレシピ | medium | export setting |
| Recipe name | 設定の名前 | | | | — | high | |
| What Export opens with | 書き出し時に使う設定 | | | | — | high | |
| Format (export) / Format, %@ | 形式 / 形式、%@ | けいしき | 漢字 | Apple's ファイル形式. | ファイル形式 | high | |
| Colour space | 色空間 | しきくうかん | 漢字 | | 色空間 | high | |
| Quality | 画質 | がしつ | 漢字 | | — | high | |
| Size | サイズ | さいず | カナ | No natural kanji for an image's size; 寸法 is for objects. | 画像サイズ | high | |
| Long edge / Short edge / %@ px long edge | 長辺 / 短辺 / 長辺%@ px | ちょうへん / たんぺん | 漢字 | | — | high | |
| %@-bit, lossless / TIFF 16-bit | %@ビット、可逆圧縮 / TIFF 16ビット | びっと / かぎゃくあっしゅく | カナ+漢字 | ビット: no kanji (位 is wrong). | 16bit | high | |
| wide colour | 広色域 | こうしきいき | 漢字 | | — | high | |
| Save / Save to / Save to Files / Saved to Files | 保存 / 保存先 / 「ファイル」に保存 / 「ファイル」に保存しました | ほぞん | 漢字 | Apple. | 保存先 | high | |
| Share / Shared / Don't Share | 共有 / 共有しました / 共有しない | きょうゆう | 漢字 | Apple. | 共有 | high | |
| Show in Files | 「ファイル」で表示 | | | | — | high | |
| Finish in the background | バックグラウンドで完了 | | カナ+漢字 | Apple's word. | — | high | |

## 11. Light Table

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Light Table | ライトテーブル | らいとてーぶる | カナ | The site's word; no kanji word (透写台 is a tracing table). | ライトテーブル | high | |
| Add to Light Table / Lay Down %@ | ライトテーブルに置く / %@枚を置く | おく | | | テーブルに並べる | high | |
| Take Off / Take All Off / Taken off | 取り出す / すべて取り出す / 取り出しました | とりだす | 漢字+かな | | テーブルから取り出す | high | |
| On the table / Put back | テーブルの上 / 戻しました | | | | — | high | |
| Bring to Top | 最前面へ | さいぜんめんへ | 漢字 | Apple (Keynote, Pages). | — | high | |
| Scatter {the films} / Scattered / Random / Laid at random | 散らす / 散らしました / ばらばら / ばらばらに置きました | ちらす | 漢字+かな | ランダム avoided: ばらばら is natural Japanese. | — | medium | |
| Tidy Up / Tidied up | 整列 / 整列しました | せいれつ | 漢字 | | 並べる | high | |
| Loupe / Look Closer / Zoom to Film | 拡大鏡 / 近くで見る / フィルムまで拡大 | かくだいきょう | 漢字 | Film shooters say ルーペ (the site's); 拡大鏡 is the plain kanji word. | ルーペ | medium | magnifier |
| Table Size / Table Orientation | テーブルの大きさ / テーブルの向き | | | | — | high | |
| Contact Sheet / Share Contact Sheet | 密着焼き / 密着焼きを共有 | みっちゃくやき | 漢字+かな | The darkroom word; ベタ焼き is the slang. | — | medium | contact print |
| Poster | ポスター | ぽすたー | カナ | No kanji word. | — | high | |
| Style / With Light Table / Layout Only | 体裁 / テーブルごと / 配置のみ | ていさい / てーぶるごと / はいちのみ | 漢字 | 体裁 = how it is laid out (スタイル avoided). | — | low | form / with the table / layout only |
| 1 film / %@ films (on the table) | 1枚 / %@枚 | まい | 漢字 | Pieces of film. | — | high | |
| Scan to visit | スキャンして開く | | | | — | high | |

## 12. Settings and the build

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Privacy Policy | プライバシーポリシー | | カナ | Apple and the site. 個人情報保護方針 is corporate-legal. | — | high | |
| Apple Account | Apple Account | | EN | Apple JP keeps it in English. | — | high | |

## 13. Settings, storage, diagnostics

| English | 日本語 | reading | script | why | site | conf | back |
|---|---|---|---|---|---|---|---|
| Settings / Open Settings | 設定 / 設定を開く | せってい | 漢字 | Apple. | 設定 | high | |
| Language | 言語 | げんご | 漢字 | Row of the language itself: 日本語. | — | high | |
| About | 情報 | じょうほう | 漢字 | Apple. | — | high | |
| Feedback | ご意見 | ごいけん | 漢字+かな | Plain Japanese. フィードバック is also common (the site's). | フィードバック | medium | opinions |
| Storage | ストレージ | すとれーじ | カナ | Apple's word. | — | high | |
| Limits / Memory budget / app allowance | 上限 / メモリ上限 / Appの上限 | じょうげん | 漢字(+カナ) | メモリ: Apple. | — | high | |
| Mac headroom / is hot, slower | 余裕 / 高温のため低速 | よゆう / こうおん | 漢字 | | — | medium | |
| Experiments / Experimental simulation | 実験的機能 / 実験的なシミュレーション | じっけんてききのう | 漢字 | シミュレーション: no kanji (模擬 is stiff). | シミュレーター | high | |
| Apply Film Emulation / Film emulation on/off | フィルムを再現 / フィルム再現 オン/オフ | さいげん | 漢字+カナ | 再現 ("reproduce") is the natural word. エミュレーション avoided. | — | medium | reproduce film |
| Licences / Licences and credits | 使用許諾 / 使用許諾と謝辞 | しようきょだく / しゃじ | 漢字 | | 謝辞 | high | |
| Diagnostics | 診断 | しんだん | 漢字 | | — | high | |
| Log (noun) / What the log holds / Never in it / Where it goes | 動作記録 / 記録する内容 / 記録しないもの / 送信先 | どうさきろく | 漢字 | ログ avoided: 動作記録 ("record of how it runs") is plain and kanji. | — | medium | operation record |
| Export Log Zip | 動作記録をZIPで書き出す | | 漢字+EN | | — | medium | |
| Share the log with SpektraLab(?) | SpektraLabと動作記録を共有（しますか？） | | | | — | medium | |
| This installation's number / The number before it | このインストールの番号 / 以前の番号 | | | インストール: Apple's word. | — | high | |
| Show First Run | 初回起動画面を表示 | しょかいきどう | 漢字 | | — | high | |
| Restore the Demo Library | サンプルのライブラリを復元 | | | | — | high | |
| a release build / a debug build / This build | リリース版 / デバッグ版 / このバージョン | ばん | 漢字(+カナ) | 版 = edition. | — | high | |

## 14. Common actions and states (Apple's words)

| English | 日本語 | script | why | conf |
|---|---|---|---|---|
| OK / Done / Cancel / Close / Back / Next / Continue / Go / Open | OK / 完了 / キャンセル / 閉じる / 戻る / 次へ / 続ける / 移動 / 開く | mixed | Apple. キャンセル and OK are Apple's own. | high |
| Not Now | 今はしない | かな+漢字 | Apple. | high |
| Retry / Try Again / Check Again | 再試行 / もう一度試す / 再確認 | 漢字 | | high |
| Undo / Redo | 取り消す / やり直す | 漢字+かな | Apple. | high |
| Reset / Reset %@? / Reset Channel | 元に戻す / %@を元に戻しますか？ / チャンネルを元に戻す | 漢字+かな | Apple's 「元に戻す」 (Revert). リセット avoided; 初期化 means formatting. | medium |
| Copy / Paste | コピー / ペースト | カナ | Apple. | high |
| Copy Settings / Paste Settings / Paste to %@ | 設定をコピー / 設定をペースト / %@枚にペースト | 漢字+カナ | Apple's 「編集内容をコピー」 pattern. | high |
| Clipboard / Nothing is copied yet | クリップボード / まだ何もコピーしていません | カナ | Apple. | high |
| Compare / Before / After | 比較 / 現像前 / 現像後 | 漢字 | The site's 比較. | high |
| On / Off | オン / オフ | カナ | Apple. | high |
| None / Unknown / Empty / Missing | なし / 不明 / 空 / 見つかりません | | | high |
| Today / Yesterday | 今日 / 昨日 | 漢字 | | high |
| Download | ダウンロード | カナ | Apple. | high |

---

## Katakana kept (and why no kanji works)

Apple's own (users look for them, rule 2): キャンセル, コピー, ペースト, オン, オフ, ストレージ, メモリ,
プライバシーポリシー, ダウンロード, アクセス, ズーム, グリッド, ライブラリ (D2),
フォルダ, ファイル, サイドバー, アイコン, リスト, プレビュー, ピクセル, サーバ, バージョン, インストール,
バックグラウンド, クリップボード, plus the pointer verbs クリック/ドラッグ in help sentences. **(25 words + 2 pointer verbs)**

Photographic and technical loanwords with no living kanji word (rule 5): フィルム, カメラ, レンズ,
シャッター, ホワイトバランス, コントラスト, ハレーション, カプラー, スキャン, ネガ, ポジ, リバーサル, カラー,
ハーフ, コマ, ピント, シーン, ライトテーブル, プリセット, カスタム, チャンネル, データ, エンジン, ドット, 7セグメント,
ポスター, サイズ, プリントフィルム (cine), キャッシュ, ビット, レベル (黒/白レベル),
バランス, シミュレーション, プロファイル (lens profile only), インチ, ミリ, パーセント, フィルター (tagline only). **(38 entries)**

Katakana the site uses that the app **replaces** with kanji: プリント → 焼き付け, デートバック → 日付写し込み,
フィルムエッジ → フィルムの縁 (D4), エッジプリント → 縁の印字 (D4), パーフォレーション → 送り穴, ストリップ → 全幅,
ラチチュード → 寛容度 (D6), グレア → 迷光, ルーペ → 拡大鏡, ペア → 2コマ組 (D7), レシピ → 書き出し設定,
モノクロ → 白黒, フィードバック → ご意見, ランダム → ばらばら, フルサイズ/フル解像度 → 原寸,
ハイライト/シャドウ (Apple, LR) → 明部/暗部 (D3), オリジナル (Apple) → 元画像/元ファイル (D8),
サムネール (Apple) → 縮小画像, コレクション (Apple) → 分類, リセット → 元に戻す, ログ → 動作記録, スタイル → 体裁.

## English kept

Never translated (names, formats, units, numbers): SpektraLab, Pro, CINE,
stock names, Mac, macOS, Finder, iCloud, iCloud Drive, Apple Account, App,
AirDrop, RAW, DNG, ProRAW, HEIF, HEIC, JPEG, JPG, PNG, TIFF, ZIP, sRGB, Display P3, Adobe RGB,
ProPhoto, MP, px, EV, ISO, K, mm, GB, MB, UTC, 135, 120, 645, 6×6, XPan, CC BY-SA 4.0, Andrea Volpato, spektrafilm.

Controls designed to stay English: **HSL** (tile), **ISO** (label), **EV** (after a value), **WB**
(only a tile where ホワイトバランス cannot fit), **Pro** (in Pro操作), **OK** (Apple's button). **(6 control uses)**

## Desktop text pass, 2026-11-08

- Drag: ドラッグ. Fit remains 全体表示 in compact controls; a percentage may name the window.
- Print keeps 焼き付け; Crop keeps 切り取り; Film Edge keeps フィルムの縁, including explanatory sentences.
- Shorter messages retain every format argument, data-loss warning, permission restriction and side effect.
- The Supporters introduction must make sense even when the shipped list is empty.
