# Develop

[English](README.md) · **简体中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Português (Brasil)](README.pt-BR.md)

> *"我同时用无反相机和胶片拍摄，可以坦白地说，Develop 的成片看起来就是真正的胶片。它不是用曲线和 LUT 给照片套上胶片风格，
> 而是让场景的光照到胶片的染料层上，冲洗，再把底片印放到相纸上，就像暗房一样。得到的不是对胶片的模仿，
> 而是那卷胶片面对同样的光会拍出的样子。"*
> **jegly**，摄影师，Develop 作者

Develop 是一款 Linux 上的胶片模拟暗房软件。打开 RAW 或 JPEG，选择胶片与相纸，即可得到基于物理模型的照片：
光线穿过胶片与相纸的染料层，带有颗粒、光晕、DIR 耦合剂和放大机滤镜，通过 Vulkan 在 GPU 上渲染。

**Develop 是 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的非官方 Linux 分支**，其引擎源自
Andrea Volpato 的 [spektrafilm](https://github.com/andreavolpato/spektrafilm)。本项目与二者均无隶属或背书关系。
胶片模型、实测配置文件以及印放与扫描模型属于它们；Develop 是 Linux 移植以及基于其构建的应用。

**使用 Mac、iPhone 或 iPad？请使用 [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)。** Develop 面向 Linux 和
Android；SpektraLab 是原版应用，为苹果设备而做。

![Develop 在 Ubuntu 上：街头照片，Ilford Delta 100 胶片，印放于 Ilford Multigrade IV RC 相纸](screenshots/develop.png)

## 功能

- **130 种胶片与相纸**：彩色负片、反转片、电影胶片和黑白胶片，可印放在彩色相纸或 Multigrade 相纸上，也可直接扫描。按品牌排序。
- **整个引擎运行在 Vulkan 上**：Mac 版的每一种效果都能在 Linux 上渲染，包括片边与日期背、镜头像差与柔焦滤镜、漏光、
  数字中间片（Digital Intermediate）、局部场景图层以及 HDR 反转片扫描。
- **所见即导出**：屏幕上的画面就是你得到的文件。
- 半格双拼、多重曝光、HSL、通道混合器、自然饱和度、水印、漏光、镜头特性和片边，与 SpektraLab 的 Mac 版一致。
- 导出 JPEG、PNG 和 16 位 TIFF，色彩空间可选 sRGB、Display P3、Adobe RGB 或 ProPhoto。

## Develop 与 SpektraLab 的区别

SpektraLab 是基于 Metal 的 Mac 应用。它的仓库里也有 Windows 查看器和一个可在 Linux 上构建的引擎，
但在 Linux 和 Windows 上，那个引擎拒绝了 Mac 的许多效果。Develop 是基于该引擎的完整 Linux 编辑器。

**Develop 新增的内容**

| | Develop | SpektraLab |
|---|---|---|
| Linux 桌面编辑器 | 有，提供 `.deb` 和 snap | 只有引擎和宿主程序 |
| Vulkan 上的引擎效果（Linux、Windows） | 全部：片边与日期背、数字中间片、场景宽容度、反差蒙版、镜头像差与柔焦滤镜、漏光、场景图层、HDR 反转片扫描 | 大多被拒绝 |
| Vulkan 上的色彩 | 已修复：自 2.4.0 起每次 Vulkan 渲染都偏红（Vulkan 内核缺少一种模糊模式） | 偏红 |
| 胶片与相纸 | 130 种，包括根据厂商公开数据表制作的 93 种新胶片配置文件 | 38 种 |
| 网络 | 无：由 seccomp 过滤器阻止，不检查更新 | 会检查更新 |
| 镜头校正 | lensfun 数据库，以及为它不认识的手动镜头准备的"我的镜头" | 仅 Mac |
| 局部图层 | 渐变、径向和全幅的曝光与色温蒙版，基于引擎的场景图层 | （引擎功能） |
| 多图排版 | 双联、三联、网格和电影剧照，可设间隙和边框 | 无 |
| 边框 | 任意灰度的相纸白边 | 无 |
| 高级面板 | 显影反差、镜头与扫描仪柔化、高光余量、扫描仪白点与黑点 | 未开放 |

**SpektraLab 有而 Develop 没有的**

- 照片库、Capture One 目录读取和 Light Table。
- HDR：在 HDR 屏幕上显示图片和导出 HDR（增益图）文件。引擎的 HDR 反转片扫描已移植，但 Linux 的网页视图无法显示 HDR。
- 检查更新。有意不做：Develop 不联网。
- iPhone 和 iPad 应用，以及 Mac 和 Windows 版本。

## 新胶片是如何制作的

SpektraLab 附带 spektrafilm 的 28 个实测配置文件和少量自有配置文件。Develop 新增了 93 个胶片配置文件，其中大多是早已停产的胶片，
根据厂商公开的数据表反推而来：富士胶片的《Professional Data Guide》（2005），柯达关于 VISION 电影负片、
EKTACHROME、ELITE Chrome 和 KODACHROME 反转片及其照相负片的技术出版物，以及 Ilford/HARMAN 和富士的黑白胶片数据表。

1. **从数据表中读取曲线。** 每种胶片都要读取：光谱感光度（每一层对每个波长的响应）、特性曲线（密度与曝光量的关系）
   和光谱染料密度（每种染料吸收的颜色）。大多数数据表是以矢量路径保存图表的 PDF，因此 `engine/tools/fujifilm_data_guide/`
   中的数字化工具直接从这些路径读取曲线。每条坐标轴都通过图表自身的网格线和标签拟合，只留下出版方自己的绘图误差。
   只有图片形式的图表则以 600 dpi 描绘。
2. **把曲线做成配置文件。** 曲线经过 spektrafilm 自己的配置文件工厂，再按照 spektrafilm 已发布配置文件的同样规则处理。
   每一项依赖引擎的拟合（相纸的滤镜组、灰阶、颗粒）都用引擎本身来运行。数据表缺少的内容（部分 VISION 数据表没有中性曲线
   或 D-min 曲线）由胶片自身的数据推导，并在配置文件的 `metadata` 中注明。
3. **在可对比的胶片上检验方法。** 同一流程也在 spektrafilm 已有胶片的原始数据上运行过。Pro 400H、Velvia 100、Vision3 500T、
   Kodachrome 64 和 Ektachrome 100 与 spektrafilm 的实测配置文件相差 ΔE2000 1.0 到 2.1（ColorChecker 上的平均值）。
   数字化工具还能从柯达的数据表复现 spektrafilm 的 Kodachrome 64 原始曲线，误差在 0.009 以内。

每个配置文件都在其 `metadata` 中记录来源出版物和拟合误差，`engine/resources_product/NOTICE.md` 列出了全部。
这些是根据公开数据的重建，而不是对真实胶片的测量。它们在厂商数据表允许的范围内尽可能接近每种胶片。

## 设计上就不联网

Develop 无法访问互联网。在其他任何东西启动之前安装的 seccomp 过滤器只允许本地套接字；如果无法安装过滤器，应用会拒绝运行。
它适用于窗口、其网页视图和引擎。没有更新检查、遥测、远程字体或账户。你的照片永远不会离开你的电脑。

## 分支

| 分支 | 内容 |
|---|---|
| `main` | Linux 版 Develop，以及所有应用都基于的引擎 |
| `camera` | Develop Camera：Android 上的胶片相机，位于 `camera/` |
| `android` | Android 上的 Develop 编辑器（开发中） |

每个应用分支都从 `main` 开始，因此引擎修复会到达所有分支。

## Develop Camera（Android）

一款 Android 17 上的胶片相机，通过 Develop 的胶片模型拍摄。从 Develop 的 121 种胶片中选一种，即可在取景器中实时看到效果。
每张照片随后由同一个引擎在手机的 GPU 上冲洗：胶片、相纸、颗粒、光晕等等，与桌面应用一样。

- 从传感器的 RAW 数据冲洗，并使用相机为每一帧提供的校正。
- 颗粒、光晕、柔焦滤镜、镜头特性、黑白滤镜、增感与减感、漏光、片边和日期背。
- 35 毫米、半格双拼、XPan、三联和多重曝光，以及从 6×4.5 到 6×17 的 120 画幅。
- 自动模式带曝光锁定，或手动快门与 ISO。
- 只申请相机权限，不联网。照片保存在 `DCIM/Develop Camera`。

已在 Pixel 11 Pro Fold 上测试。它的 GPU 跳过了引擎的三个镜头内核，导致每次柔焦渲染都是黑的；这些内核已在 `main` 上修复。
构建步骤见 `camera/BUILD.md`。

## Android 上的 Develop 编辑器

Linux 编辑器到 Android 的移植，位于 `android` 分支。它保留桌面布局，并针对触控做了修正。目前还不能使用。

## 安装

目前还没有发布版本。请从源码构建（见下文）；构建会生成 `.deb` 和 snap。

Develop 需要带 Vulkan 驱动的 GPU。它在 Ubuntu 26.04 和 Intel 显卡（Mesa）上开发。`.deb` 会拉取 `libvulkan1`、`liblensfun1`、
`liblensfun-data-v1`、`fonts-urw-base35`、`fonts-liberation-sans-narrow` 和 `fonts-dejavu-core`。snap 自带这些的副本。

## 构建

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

构建需要 C++20 编译器、CMake、Ninja、Vulkan 头文件和 `glslangValidator`，带 npm 的 Node 22，Rust（stable），
Tauri 要求的 WebKitGTK 4.1 开发包，以及用于镜头校正的 `liblensfun-dev`（没有它也能构建，只是少了这一功能）。

## 测试

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

上游自己的引擎检查（`engine/tests/*_checks.py`）同样针对 Linux 引擎运行。

## 致谢与许可

**Develop 基于 SpektraLab，其引擎源自 Andrea Volpato 的 spektrafilm（GPL-3.0-or-later）。** spektrafilm 的 28 个实测
胶片与相纸配置文件和印放 LUT 未经修改直接使用。其他配置文件根据厂商公开的数据表制作（`engine/resources_product/NOTICE.md`）。
胶片和相纸名称是其所有者的商标；它们表明配置文件依据的是哪份公开数据。

| | |
|---|---|
| 应用和引擎 | GPL-3.0-or-later（`license/LICENSE`） |
| spektrafilm 的胶片与相纸配置文件、印放 LUT | CC BY-SA 4.0（`license/SPEKTRAFILM_LICENSE.txt`） |
| lensfun（链接使用，及其镜头数据库） | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | 公有领域 / MIT |

SpektraLab™ 及其图标归其所有者。Develop 使用自己的名称和图标，正如 SpektraLab 的许可条款对公开分支的要求。
