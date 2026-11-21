# Develop

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語** · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Português (Brasil)](README.pt-BR.md)

> *「私はミラーレスとフィルムの両方で撮影していますが、Develop の仕上がりは本物のフィルムに見えると正直に言えます。
> 曲線や LUT で写真にフィルム風の見た目を塗り重ねるのではありません。シーンの光でフィルムの色素層を露光し、現像し、
> ネガを印画紙にプリントします。暗室と同じやり方です。出てくるのはフィルムの模倣ではなく、同じ光をそのフィルムが写したらこうなる、という結果です。」*
> **jegly**、写真家、Develop の作者

Develop は Linux 向けのフィルムエミュレーション暗室です。RAW か JPEG を開き、フィルムと印画紙を選ぶと、物理モデルに基づいたプリントが得られます。
光はフィルムと印画紙の色素層を通して追跡され、粒状性、ハレーション、DIR カプラー、引き伸ばし機のフィルターパックが加わり、
Vulkan を通じて GPU 上でレンダリングされます。

**Develop は [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) の非公式 Linux フォークです。** そのエンジンは
Andrea Volpato による [spektrafilm](https://github.com/andreavolpato/spektrafilm) から派生しています。どちらのプロジェクトとも提携関係はなく、
承認も受けていません。フィルムモデル、実測プロファイル、プリントとスキャンのモデルは彼らのものです。Develop はその Linux 移植と、その上に作られたアプリです。

**Mac、iPhone、iPad をお使いですか？[SpektraLab](https://github.com/JamesQiu2005/SpektraLab) をお使いください。** Develop は Linux と
Android 向けです。SpektraLab はオリジナルのアプリで、Apple のデバイス向けに作られています。

![Ubuntu 上の Develop：Ilford Delta 100 で撮ったストリート写真を Ilford Multigrade IV RC にプリント](screenshots/develop.png)

## できること

- **130 種のフィルムと印画紙**：カラーネガ、リバーサル、映画用、白黒フィルムを、カラー印画紙か Multigrade 印画紙にプリント、またはスキャン。ブランド順に並びます。
- **エンジン全体が Vulkan 上で動作**：Mac 版のすべての効果が Linux でレンダリングされます。フィルムエッジとデートバック、
  レンズ収差とディフュージョンフィルター、光漏れ、Digital Intermediate、ローカルなシーンレイヤー、HDR リバーサルスキャンも含みます。
- **エディターの表示がそのまま書き出される**：画面の画像が、得られるファイルです。
- ハーフフレームのペア、二重露光、HSL、チャンネルミキサー、自然な彩度、透かし、光漏れ、レンズキャラクター、フィルムエッジ。SpektraLab の Mac 版と同じです。
- JPEG、PNG、16 ビット TIFF で書き出し。色空間は sRGB、Display P3、Adobe RGB、ProPhoto。

## Develop と SpektraLab の違い

SpektraLab は Metal 上で動く Mac アプリです。そのリポジトリには Windows ビューアーと Linux でビルドできるエンジンもありますが、
Linux と Windows ではそのエンジンが Mac の効果の多くを拒否していました。Develop はそのエンジンの上に作られた完全な Linux エディターです。

**Develop が加えたもの**

| | Develop | SpektraLab |
|---|---|---|
| Linux デスクトップエディター | あり、`.deb` と snap | エンジンとホストのみ |
| Vulkan 上のエンジン効果（Linux、Windows） | すべて：フィルムエッジとデートバック、Digital Intermediate、シーンラチチュード、コントラストマスク、レンズ収差とディフュージョンフィルター、光漏れ、シーンレイヤー、HDR リバーサルスキャン | ほとんどが拒否される |
| Vulkan 上の色 | 修正済み：2.4.0 以降、すべての Vulkan レンダリングが赤かぶり（Vulkan カーネルにブラーモードが欠けていた） | 赤かぶり |
| フィルムと印画紙 | 130 種。メーカー公開のデータシートから作った 93 種の新しいフィルムプロファイルを含む | 38 種 |
| ネットワーク | なし：seccomp フィルターで遮断、更新確認もなし | 更新を確認する |
| レンズ補正 | lensfun のデータベースと、それが知らないマニュアルレンズ用の「マイレンズ」 | Mac のみ |
| ローカルレイヤー | 段階、円形、全面のマスクで露出と色温度を調整、エンジンのシーンレイヤー上で | （エンジン機能） |
| 複数写真のレイアウト | 二枚組、三枚組、グリッド、シネマスチル。間隔と枠つき | なし |
| 枠 | 任意のグレーのプリント枠 | なし |
| 詳細パネル | 現像コントラスト、レンズとスキャナーの柔らかさ、ハイライトの余裕、スキャナーの白点と黒点 | 非公開 |

**SpektraLab にあって Develop にないもの**

- フォトライブラリ、Capture One カタログの読み込み、Light Table。
- HDR：HDR 画面での表示と HDR（ゲインマップ）ファイルの書き出し。エンジンの HDR リバーサルスキャンは移植済みですが、Linux の Web ビューは HDR を表示できません。
- 更新の確認。意図的に省いています：Develop はネットワークにアクセスしません。
- iPhone と iPad のアプリ、Mac と Windows 向けのビルド。

## 新しいフィルムの作り方

SpektraLab には spektrafilm の 28 の実測プロファイルと、少数の独自プロファイルが付属します。Develop は 93 のフィルムプロファイルを加えました。
その多くはずっと前に製造終了したフィルムで、メーカーが公開したデータシートから逆算しています：富士フイルムの *Professional Data Guide*（2005 年）、
VISION 映画用ネガ、EKTACHROME、ELITE Chrome、KODACHROME リバーサルとスチル用ネガについての Kodak の技術資料、
そして Ilford/HARMAN と富士フイルムの白黒フィルムのデータシートです。

1. **データシートから曲線を読み取る。** フィルムごとに：分光感度（各層が各波長にどう反応するか）、特性曲線（露光量に対する濃度）、
   分光色素濃度（各色素が吸収する色）。ほとんどのデータシートはグラフをベクターパスで保存した PDF なので、`engine/tools/fujifilm_data_guide/`
   のデジタイザーがそのパスから直接曲線を読み取ります。各軸はグラフ自身のグリッド線とラベルに合わせて当てはめるので、残るのは発行元自身の作図誤差だけです。
   画像だけのグラフは 600 dpi でトレースします。
2. **プロファイルにする。** 曲線は spektrafilm 自身のプロファイル生成工程を通り、spektrafilm が公開しているプロファイルと同じ規則で処理されます。
   エンジンに依存するフィッティング（印画紙のフィルターパック、グレーランプ、粒状性）はすべてエンジン自身で実行します。
   データシートに欠けているもの（一部の VISION のデータシートにはニュートラル曲線や D-min 曲線がない）は、そのフィルム自身のデータから導き、
   プロファイルの `metadata` にその旨を記します。
3. **比較できるフィルムで手法を検証する。** 同じ工程を、spektrafilm がすでに持つフィルムの生データでも実行しました。Pro 400H、Velvia 100、Vision3 500T、
   Kodachrome 64、Ektachrome 100 は、spektrafilm の実測プロファイルとの差が ΔE2000 で 1.0〜2.1（ColorChecker 上の平均）に収まります。
   デジタイザーは Kodak のデータシートから spektrafilm の Kodachrome 64 の生の曲線を 0.009 以内で再現します。

各プロファイルは出典の資料とフィッティング誤差を `metadata` に記録し、`engine/resources_product/NOTICE.md` がそのすべてを一覧にしています。
これらは公開データからの再構成であり、実際のフィルムの測定ではありません。メーカーのデータシートが許す限り、各フィルムに近づけています。

## 設計上、ネットワークなし

Develop はインターネットに接続できません。他の何よりも先に組み込まれる seccomp フィルターがローカルソケットだけを許可し、
フィルターを設定できなければアプリは起動を拒否します。これはウィンドウ、その Web ビュー、エンジンに適用されます。
更新確認、テレメトリー、リモートフォント、アカウントはありません。写真があなたのマシンから出ることはありません。

## ブランチ

| ブランチ | 内容 |
|---|---|
| `main` | Linux 版 Develop と、すべてのアプリが土台にするエンジン |
| `camera` | Develop Camera：Android 用のフィルムカメラ、`camera/` 内 |
| `android` | Android 版の Develop エディター（開発中） |

各アプリのブランチは `main` から始まるので、エンジンの修正はすべてに届きます。

## Develop Camera（Android）

Develop のフィルムモデルを通して撮影する、Android 17 用のフィルムカメラです。Develop の 121 種のフィルムから一つを選ぶと、
ファインダーでライブに確認できます。撮った写真は同じエンジンでスマートフォンの GPU 上で現像されます：フィルム、印画紙、粒状性、ハレーションなど、デスクトップアプリと同じです。

- センサーの RAW データから、フレームごとのカメラ自身の補正を使って現像。
- 粒状性、ハレーション、ディフュージョンフィルター、レンズキャラクター、白黒フィルター、増感と減感、光漏れ、フィルムエッジとデートバック。
- 35 mm、ハーフフレームのペア、XPan、三枚組、多重露光、そして 6×4.5 から 6×17 までの 120。
- 露出ロックつきのオート、またはマニュアルのシャッターと ISO。
- 求める権限はカメラだけで、ネットワークにアクセスしません。写真は `DCIM/Develop Camera` に保存されます。

Pixel 11 Pro Fold でテスト済みです。その GPU がエンジンのレンズカーネルのうち三つを飛ばしていたため、ディフュージョンのレンダリングがすべて真っ黒になっていました。
これらのカーネルは `main` で修正済みです。ビルド手順は `camera/BUILD.md` にあります。

## Android 版の Develop エディター

Linux エディターの Android への移植で、`android` ブランチにあります。デスクトップのレイアウトを保ち、タッチ向けの修正を加えています。まだ使える状態ではありません。

## インストール

公開リリースはまだありません。ソースからビルドしてください（下記）。ビルドで `.deb` と snap ができます。

Develop には Vulkan ドライバーのある GPU が必要です。Ubuntu 26.04 と Intel グラフィックス（Mesa）で開発されています。`.deb` は `libvulkan1`、`liblensfun1`、
`liblensfun-data-v1`、`fonts-urw-base35`、`fonts-liberation-sans-narrow`、`fonts-dejavu-core` を導入します。snap はそれ自身のコピーを持っています。

## ビルド

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

ビルドには C++20 コンパイラー、CMake、Ninja、Vulkan ヘッダー、`glslangValidator`、npm つきの Node 22、Rust（stable）、
Tauri が求める WebKitGTK 4.1 の開発パッケージ、そしてレンズ補正用の `liblensfun-dev`（なくてもビルドできますが、その機能はなくなります）が必要です。

## テスト

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

上流のエンジンチェック（`engine/tests/*_checks.py`）も Linux エンジンに対して実行されます。

## クレジットとライセンス

**Develop は SpektraLab に基づいており、そのエンジンは Andrea Volpato による spektrafilm（GPL-3.0-or-later）から派生しています。**
spektrafilm の 28 の実測フィルム・印画紙プロファイルとプリント LUT は変更せずに使っています。その他のプロファイルはメーカー公開のデータシートから作られています
（`engine/resources_product/NOTICE.md`）。フィルムと印画紙の名前はその所有者の商標で、プロファイルがどの公開データから作られたかを示しています。

| | |
|---|---|
| アプリとエンジン | GPL-3.0-or-later（`license/LICENSE`） |
| spektrafilm のフィルム・印画紙プロファイル、プリント LUT | CC BY-SA 4.0（`license/SPEKTRAFILM_LICENSE.txt`） |
| lensfun（リンク、およびそのレンズデータベース） | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | パブリックドメイン / MIT |

SpektraLab™ とそのアイコンはその所有者に帰属します。SpektraLab のライセンス条項が公開フォークに求めるとおり、Develop は独自の名前とアイコンを使っています。
