# HARD-STRINGS.md: worked sentences

Written 2026-10-22. These are worked examples of register, length and term use, made with `STYLE.md` and `GLOSSARY.md`
and following their recommended answers to D1–D8. If the owner decides otherwise, swap the term and keep the sentence.
Each entry gives the key, the Japanese, a literal English back-translation, and a note where a choice was made.
`%@` and `%.1f` are placeholders; where two placeholders change order, the positional form is used (`%1$@`).
Renumbered 2026-11-08: the sentences are the Mac app's, and those of features the Mac does not have are gone.

---

## First run, empty states, voice

**1.** `Not a filter. A print.`
> フィルターではない。写真を、焼く。

*Back:* "Not a filter. Burning (printing) the photograph." This is the site's own tagline, so the
app and the site say the same line. *Voice* register: plain form, on purpose.

**2.** `An empty darkroom`
> 空っぽの暗室

*Back:* "An empty darkroom."


**3.** `Frames develop at preview size as they arrive.\nFull size is made when you zoom in, and when you export.`
> 写真は届いた順にプレビューサイズで現像されます。\n原寸の現像は、拡大したときと書き出すときに行います。

*Back:* "Photos are developed at preview size in the order they arrive. The full-size development is
done when you zoom in and when you export." 原寸, never フルサイズ (GLOSSARY §8).

**4.** `JPEG and HEIC come in developed by their camera,\nso the film starts from that picture, not from RAW.`
> JPEGとHEICは、カメラで処理された状態で読み込まれます。\nそのため、フィルムはRAWではなく、その画像から始まります。

*Back:* "JPEG and HEIC are imported already processed by the camera. So the film starts from that
image, not from RAW." 処理された avoids a second use of 現像 for the camera's own processing.

**5.** `SpektraLab changes at once. What macOS shows of its own, such as a Finder panel, follows the next time the app is opened.`
> SpektraLabの表示はすぐに切り替わります。Finderのパネルなど、macOSが表示する部分は、次にAppを開いたときから切り替わります。

*Back:* "SpektraLab's display changes right away. The parts macOS shows, such as Finder's panel, change from the
next time you open the app." "App" in Latin letters, as Apple JP writes it.

## Diagnostics and privacy

These must say no more and no less than the published privacy policy (English). "Log" is 動作記録 throughout.


**6.** `With sharing on, the log goes to %@ over an encrypted connection, when the app is opened and when you leave it, under a random number made for this installation. The server notes the country a log arrived from, keeps no address, and deletes a log 90 days after it last arrived.`
> 共有がオンのとき、動作記録はAppを開いたときと離れたときに、暗号化された接続で%@へ送信されます。送信には、このインストール用に無作為に作られた番号を使います。サーバは記録がどの国や地域から届いたかを記録しますが、IPアドレスは保存せず、最後に届いてから90日後に記録を削除します。

*Back:* "When sharing is on, the operation record is sent to %@ over an encrypted connection when you
open the app and when you leave it. It is sent under a number made at random for this installation.
The server records which country or region a record came from, but does not keep the IP address, and
deletes a record 90 days after it last arrived." **Flag:** the English "keeps no address" is read
here as the IP address, which is what the privacy policy means (zh-Hans says 不保存地址). A bare アドレス would read as an e-mail
address in Japanese. Confirm with the policy before shipping.

**7.** `Turning sharing on sends what this Mac has kept, up to 7 days of it. Turn it off and nothing more is sent; what was already sent is not deleted by that. Turning it on again starts a new number.`
> 共有をオンにすると、このMacに保存されている動作記録（最大で直近7日分）が送信されます。オフにすると以後は何も送信されませんが、送信済みの記録がそれで削除されるわけではありません。もう一度オンにすると、新しい番号になります。

*Back:* "When you turn sharing on, the records kept on this Mac (at most the last 7 days) are sent.
When you turn it off nothing more is sent, but that does not delete records already sent. Turning it on again gives a new number."

**8.** `To have what was sent deleted sooner, write to the address in the privacy policy (Settings) with the number below. It stays here after sharing is turned off.`
> 送信済みの記録を早めに削除してほしい場合は、下の番号を添えて、プライバシーポリシー（「設定」内）に記載の連絡先までご連絡ください。番号は、共有をオフにしたあともここに表示されます。

*Back:* "If you want records already sent deleted sooner, please contact the address given in the privacy
policy (in Settings), adding the number below. The number stays shown here after sharing is turned off."
"Address" → 連絡先 (contact address), since here it is the e-mail address.


**9.** `The log stays on this Mac for 7 days and leaves it only when you export it: Export Log Zip hands you the files to send yourself.`
> 動作記録はこのMacに7日間保存され、書き出したときだけ外に出ます。「動作記録をZIPで書き出す」で、ご自身で送るためのファイルを受け取れます。

*Back:* "The record is kept on this Mac for 7 days and leaves it only when you export it. With
'Export the record as ZIP', you receive the files to send yourself."

**10.** `SpektraLab's server could not be reached from here (%@). Export Log Zip, and send it by hand.`
> ここからSpektraLabのサーバに接続できませんでした（%@）。「動作記録をZIPで書き出す」で書き出して、手動で送ってください。

*Back:* "Could not connect to SpektraLab's server from here (%@). Export it with 'Export the record as ZIP' and send it by hand."

## Credits and licences

**11.** `Film and paper profiles from spektrafilm by Andrea\nVolpato; black and white SpektraLab's own. CC BY-SA 4.0`
> フィルムと印画紙の特性データは、Andrea Volpatoによる\nspektrafilmに由来します。白黒はSpektraLab独自のものです。CC BY-SA 4.0

*Back:* "The characteristic data of the films and papers comes from spektrafilm by Andrea Volpato. Black
and white is SpektraLab's own. CC BY-SA 4.0." "Profile" → 特性データ ("characteristic data"), kanji
and exact; the site says プロファイル. The line break moves so that a name is not split.

**12.** `The colour film and paper profiles are from spektrafilm by Andrea Volpato, under CC BY-SA 4.0.`
> カラーフィルムと印画紙の特性データは、Andrea Volpatoによるspektrafilmに由来し、CC BY-SA 4.0で提供されています。

*Back:* "The colour film and paper characteristic data comes from spektrafilm by Andrea Volpato and is
provided under CC BY-SA 4.0."

**13.** `The black-and-white films and their paper are SpektraLab's own profiles, built from their makers' published data sheets, under CC BY-SA 4.0 as well.`
> 白黒フィルムとその印画紙は、各製造元が公開している技術資料をもとに作成したSpektraLab独自の特性データで、同じくCC BY-SA 4.0で提供しています。

*Back:* "The black-and-white films and their paper are SpektraLab's own characteristic data, made from
the technical documents each manufacturer publishes, also provided under CC BY-SA 4.0."


## Develop and the darkroom

**14.** `%@ is a slide: it is scanned, not printed. The paper waits for a negative.`
> %@はリバーサルフィルムです。焼き付けずにスキャンします。印画紙はネガを選ぶと使えます。

*Back:* "%@ is a reversal film. It is scanned without printing. The paper can be used when you choose a negative."

**15.** `%@ is a black-and-white film: it prints on a black-and-white paper. The colour papers wait for a colour film.`
> %@は白黒フィルムなので、白黒印画紙に焼き付けます。カラー印画紙はカラーフィルムを選ぶと使えます。

*Back:* "%@ is a black-and-white film, so it is printed on black-and-white paper. The colour papers can be used when you choose a colour film."

**16.** `Highlight and Shadow would cross: pull back less on one side.`
> 明部と暗部が交差してしまいます。どちらか一方の引き込みを弱めてください。

*Back:* "The bright part and the dark part would cross. Please weaken the pulling-in on one of the two."
引き込む ("pull in") is the site's verb for Scene Placement (シーン配置がエンジン自身のフィットで引き込みます).


## Errors and alerts

**17.** `Keep SpektraLab open while it works.` and `There is not enough memory for this size just now. Try a smaller one.`
> 処理中はSpektraLabを開いたままにしてください。
> 現在、このサイズに必要なメモリが足りません。小さいサイズをお試しください。

*Back:* "Please keep SpektraLab open while it is processing." / "At the moment there is not enough memory for
this size. Please try a smaller size."

---

### What these examples set

- Every message is です・ます. Requests use 〜てください, and suggestions use お試しください.
- No あなた. "Your …" disappears or becomes お名前.
- 「」 around Settings, Finder's own names and every button named in a sentence. Paths are 「設定」›「…」.
- No space between Japanese and Latin. A space before a unit stays (12 MP).
- Each term is the glossary's, including the decided-pending ones: 焼き付け (D1), ライブラリ (D2),
  明部/暗部 (D3), フィルムの縁 (D4), ネガ/ポジ/リバーサル (D5), 寛容度 (D6), 2コマ組 (D7), 元ファイル/元画像 (D8).
- Length: the Japanese is about 45–60 % of the English's character count. Screen width is about the
  same as the English, because each glyph is wider.
