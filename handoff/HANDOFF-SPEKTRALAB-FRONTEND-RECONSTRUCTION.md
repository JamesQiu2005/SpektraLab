# Handoff — SpektraLab 前端与数字暗房流程重构

2026-09-16 · 产品与交互结论 · 下一 session 的设计输入

## 1. 一句话结论

SpektraLab 不是另一个 Lightroom、Capture One，也不是一排胶片 LUT。它是一条**可重复、可解释、允许用户干预的数字胶片管线**：左侧负责照片如何进入胶片、形成底片并被呈现，右侧负责用户希望成片最终长什么样。

```text
线性照片
  -> 虚拟胶片曝光
  -> 数字显影 / developed density
  -> Reference、相纸、电影拷贝或扫描呈现
  -> 桌面级后期编辑
  -> 输出
```

当前 frontend 可以完成导入、胶片、印相和编辑，但它的左侧仍按后端参数类别组织：`Film Profile / Print Profile / Camera / Crop`。目标不是给这些卡片换皮，而是把左侧重构为符合用户心智的流程。

本文件只记录产品与交互结论，不授权直接改代码。中性 density、基础正像反演及其原生实验已经拆到 [HANDOFF-NATIVE-NEUTRAL-DENSITY.md](HANDOFF-NATIVE-NEUTRAL-DENSITY.md)，不要在前端任务里顺手重写该算法。

## 2. 产品定位与克制

### SpektraLab 要做什么

- 接受已经解码的场景线性照片，以线性 ProPhoto RGB 作为 engine 的输入基线。
- 用光谱重构、胶片响应、特性曲线和空间效应形成一张虚拟底片。
- 提供固定版本、可复现的 Reference 解释，作为用户调色的基准。
- 让同一张 developed density 可以进入相纸、电影正片/拷贝、扫描解释等不同呈现。
- 保存 recipe，使用户能理解一个调整发生在拍摄、显影、呈现还是后期。

后端理论上可以接受不存在于现实中的响应模型，未来也可能允许自定义 profile；当前产品不必暴露“创造胶片”功能。对用户开放的 stock 应经过筛选和验证。

### SpektraLab 不做什么

- 不建设完整 DAM：不与 Lightroom、Capture One、开源图库工具竞争目录、关键词、云同步、智能集合与海量归档。
- 不重现一比一的传统暗房操作台，也不要求用户懂 CMY、染料密度或化学参数。
- 不把 Reference 宣传成“绝对真实”“唯一物理正像”或已经验证的 Hasselblad Flextight X5 模拟。
- 不替用户决定审美。产品负责基准可信、行为一致、结果可重现；用户负责好不好看。

最小工作集已经足够形成闭环：

```text
从外部开发器或 Finder 导入
  -> 当前任务中的照片切换
  -> recipe / variant
  -> A/B 对比
  -> 导出并返回原工作流
```

单文件应直接进入编辑；文件夹或多选可以进入轻量 Browse/worklist。Browse 服务于这次工作，不逐步长成照片资料库。

## 3. 左右区域的责任边界

### 左侧：照片如何形成

左侧是数字暗房流程。它处理会改变虚拟底片或解释方式的决定：输入校准、胶片曝光、显影、画幅与呈现。

### 右侧：照片最后长什么样

右侧以 Capture One 的桌面级编辑器作为交互参考：直方图、曝光、曲线、色彩平衡、局部调整和后续输出。它编辑当前呈现结果，并把调整保存成独立的 grade recipe。

右侧可以继续使用“后期”或 `Adjustments` 的统一概念。不要把整列叫 `Print`，否则 Reference 和 scanner/cinema 输出没有自然的编辑归属。

### 不能混淆的三种操作

| 操作 | 所在位置 | 含义 |
|---|---|---|
| 胶片曝光 | 左侧 Film | 改变光如何落在特性曲线上，会改变 density、色彩、颗粒和宽容度 |
| 呈现/印相曝光 | 左侧 Render | 改变底片如何被相纸或其他输出介质解释 |
| 后期曝光 | 右侧 Grade | 改变已经解释出的 RGB 成片，不重新曝光或重新显影胶片 |

这三者即使视觉上都“变亮”，也必须有不同名称、不同 recipe 节点和不同重算边界。

## 4. 左侧建议结构

左侧不需要做成阻塞式 wizard。使用可以随时回头的折叠卡片；每张卡只呈现一个主要决定，摘要始终说明当前状态。

### 0. Input Calibration — 紧凑、默认折叠

用户已经拿到一张数码照片。RAW 由 Core Image 解码为场景线性输入；线性 TIFF 也可以直接进入。解码入口已由现有架构处理，本轮不重新设计 RAW developer。

主界面只需要：

- `As Shot` / 输入白平衡状态。
- 必要时的输入冷暖和 tint 校正。
- 输入色彩空间与线性状态的只读确认，放在信息或高级区，不做日常选项。

这里的白平衡校正属于进入胶片之前的场景估计。右侧成片冷暖属于后期，两者必须有清楚的名称和位置。当前 `Camera WB · Decode` 与 `Print White Balance · Print` 的区分是一个可保留的过渡，但最终命名应服从新流程。

### 1. Film — 选择记录介质和曝光方式

用户要回答：“这张照片是用什么虚拟胶片、什么画幅和什么曝光方式记录的？”

默认可见：

- Film stock。
- Film exposure / exposure compensation。
- Format / physical frame。
- 自动曝光 intent 的简短摘要，需要时展开。

stock 选择不应继续占据一个永久展开的长文本列表。可以使用带搜索/分类的选择器，选择后卡片只显示当前 stock 及关键说明。

### 2. Develop — 数字显影

用户要回答：“底片如何形成？”

这不是传统暗房控制面板。建议默认只提供：

- Standard development。
- 简化的 push/pull 或 development intensity，前提是后端语义得到定义和验证。
- Grain。
- Halation。
- 更高级的 chemistry/DIR 参数仅在研究或高级模式中出现，普通产品不暴露层级系数。

CMY 不应作为主显影控制。底层 CMY layer/density 可以存在，工作色彩空间仍为 ProPhoto RGB。若用户需要校正印相颜色，使用熟悉的冷暖、色偏和印相曝光；不能把 CMY 三个滑杆当成“物理所以必须展示”的证据。

### 3. Render — 从底片得到正像

用户要回答：“如何看这张已经形成的底片？”

呈现模式：

1. **Reference**：默认。系统处理反色与去色罩，给出版本固定、可复现的参考正像。暂称 `SpektraLab Reference` 或 `Filmify Reference`，名称最后统一。
2. **Photographic Paper**：选择相纸，通过原始 developed density 进入物理印相分支。
3. **Cinematic Copy**：通过电影拷贝/正片介质解释 density。
4. **Scanner Style**：有明确定义的 scanner observer/response 后再提供；不能把 `scan_film=true` 的橙色负片直接叫 scanner positive。

Reference 是默认出口，解决“选完胶片后首先看到什么”的问题。它不要求用户点击含义不明的 `Solve`，也不要求手动去色罩。

相纸和电影分支必须继续消费原始 density。UI 可以表现为从 Reference 切换到相纸，但计算上不能把物理印相叠到已经反色的 Reference RGB 后面。

### 4. Frame / Crop 的归属

裁切几何发生在 film effects 之前还是之后，会影响物理像素尺度。用户心智上，画幅属于 Film；构图裁切可以继续作为独立工具，但必须明确：

- 拍摄画幅定义物理成像区域和毫米/像素比例。
- 后期裁切保留原来的物理比例，不应让颗粒和 halation 因裁掉一部分照片而变粗。
- 只有“重新映射画幅”才改变物理尺度。

因此 `Crop` 不应只是与 Film/Profile 并列的无语义卡片。下一 session 需要决定它是顶栏工具、Film 内的 framing 子页，还是左侧独立但带有上述规则的卡片。

## 5. 画幅与空间效果的统一模型

用户提出的关键问题是正确的：颗粒、halation 与其他胶片空间效应的尺寸不应该由文件长宽比随意决定。

当前 engine 已经有一条物理尺度：

```text
pixel_size_um = film_format_mm × 1000 / pre_crop_long_edge_pixels
```

grain、halation、DIR diffusion 等把微米量转换为像素。当前 `film_format_mm` 只代表长边，UI 的同一个 `56 mm` 无法区分 645 与 6×6 的实际成像区域；这正是需要重构的地方。

### 建议的数据语义

画幅 preset 保存**宽和高的实际成像区域**，不是一个模糊的单值。候选库包括：

- 110、APS、35mm。
- 120：645、6×6、6×7、6×9、6×17 等。
- 大画幅：4×5、5×7、8×10。
- 电影画幅可按产品需要另组，不必与静态画幅混成一个长菜单。

用户还要决定照片如何落到这个区域：

| 映射 | 含义 |
|---|---|
| Fit inside frame | 默认；保持照片比例，完整放入指定成像区域 |
| Match short edge | 照片短边对应指定物理短边，另一边按比例推导 |
| Match long edge | 照片长边对应指定物理长边，另一边按比例推导 |
| Custom dimensions | 高级；直接指定照片对应的毫米尺寸 |

最终只产生一个统一的 `µm / pixel`，供物理空间节点使用。方向、裁切、旋转与画幅的关系必须有确定规则，不能从输出宽高比临时猜。

### Grain、halation 和 glare 不能放在同一个模糊“质感”模型里

- **Grain**：发生于显影后的 density，粒子面积和 dye cloud 模糊应按底片物理尺度计算。
- **Halation**：发生于胶片曝光/片基层，应按微米换算，stock 的片基与 anti-halation 类型给出默认值；UI 可以放在 Develop 以便理解，但 engine 顺序不能因此挪到显影后。
- **DIR diffusion**：属于化学与空间显影，也使用物理底片尺度。
- **Print/scanner glare**：当前是呈现端的随机 veiling light，按输出 frame 比例缩放，并非底片尺寸。它需要与拍摄镜头的 optical flare 分开。
- **Lens/optical glare**：若以后加入，应位于胶片曝光前，不能与 print/scanner glare 共用一个参数。

当前默认数值来自上游模型和 profile preset，但产品尚不能清楚回答每个“大小”基线如何测得。重构时先把单位、作用阶段、preset 来源和用户控制的相对量写清；不要把历史常数包装成精确测量。

## 6. Reference 的产品角色

Reference 的价值不是“最漂亮”，而是固定版本下的参考解释：

- 同样的输入、stock、开发参数和算法版本得到同样的结果。
- 默认消除负片色罩并完成反色。
- 把颜色解释与 stock tone 尽量分离，使用户可以在右侧继续编辑。
- 允许同一 density 重呈现为相纸或 cinema，而不需要重新显影。

它目前仍是研发中的概念。现有实验的 positive inverse 没有使用 `channel_density/base_density`，高光也有待审查误差；不能在前端先把“绝对准确扫描”写死。前端可以先设计稳定的节点和 recipe，具体 Reference 算法由独立后端任务完成。

产品语言建议使用：

- `Reference interpretation`
- `Calibrated reference`
- `Fixed reference profile`

避免：

- `Absolute truth`
- `True film color`
- `Hasselblad X5 accurate`，除非以后真的取得设备响应和标定验证。

## 7. Print 与右侧后期

现有 print 逻辑大体可以保留，Capture One 是右侧交互的良好参考。要改的是层级和命名：

- 相纸、cinematic medium、scanner interpretation 选择在左侧 Render。
- 该介质特有的 exposure、冷暖、tint 留在 Render 的展开设置里。
- 直方图、RGB/luma curves、color balance、常规 exposure 和局部编辑位于右侧。
- 右侧始终编辑当前呈现的正像，不表现成模拟 enlarger 的第二套暗房。

CMY filters 可以保留为内部参数和高级兼容层。普通模式把它们转换为用户熟悉的印相 exposure、warm/cool、green/magenta。这个转换需要明确数学定义；仅改标签不算完成。

## 8. 编辑性与 recipe 边界

“可重新渲染”和“可逆编辑”不是一回事。前端状态至少要把这些层分开：

```text
Input recipe
  RAW decode / input WB / geometry

Film recipe
  stock / physical format mapping / film exposure

Develop recipe
  development intent / DIR / grain / halation

Render recipe
  Reference or output medium / print exposure / presentation balance

Grade recipe
  right-side RGB edits / local adjustments
```

更改 Input、Film 或 Develop 会重新生成 density。更改 Render 只重新解释已有 density。更改 Grade 不应碰 density。UI 状态、撤销、复制/粘贴和 sidecar 都应沿着这些边界工作。

未来理想数据边界是：

```text
linear input + recipe
developed float density master
pre-tone linear float positive
independent stock/output tone
grade recipe
deliverable output
```

现有公开 engine 输出仍主要是显示用 RGBA16；真正的量化前浮点 positive tap 属于后端交接，不由前端假装补齐。

## 9. 现有界面与目标的差距

| 当前 | 问题 | 目标 |
|---|---|---|
| Film Profile 和 Print Profile 两个永久长列表 | 资源清单代替了用户决策流程，主次不清 | Film 和 Render 各一个当前选择，详情按需展开 |
| Camera 混合 tone、format、vignette、film exposure、decode WB | 拍摄、几何、胶片曝光和客户端效果混在一起 | Input Calibration 与 Film 分离；frame mapping 有明确物理语义 |
| CMY/Print WB 具有历史暗房术语 | 用户需要理解内部模型才能校色 | exposure + warm/cool + tint；CMY 留给高级或内部层 |
| Grain/halation/glare 看起来都是视觉效果 | 实际发生阶段和尺度不同 | 根据 exposure/develop/render 分组，并显示单位或相对强度来源 |
| `Solve / Original` 含义不清 | 不知道 solve 了什么，Original 是 decode 还是绕过模拟 | Reference 自动成为默认；对比明确标为 Input decode / developed / rendered |
| 左右两侧都是参数 inspector | 无法理解哪边在形成照片、哪边在做后期 | 左侧流程，右侧 grade |
| Format 是单一 long-edge mm | 645/6×6 等无法正确表达 | 实际宽×高 + fit/short/long/custom 映射 |

## 10. 建议的第一版布局

```text
┌ Left: Digital Darkroom ┐  ┌──────── Canvas ────────┐  ┌ Right: Adjustments ┐
│ Input Calibration      │  │                         │  │ Histogram           │
│ Film                   │  │      rendered image     │  │ Exposure            │
│   Stock                │  │                         │  │ Curve               │
│   Exposure             │  │                         │  │ Color Balance       │
│   Physical Frame       │  │                         │  │ Local Adjustments   │
│ Develop                │  │                         │  │ ...                 │
│   Standard / Push-Pull │  │                         │  │                     │
│   Grain / Halation     │  │                         │  │                     │
│ Render                 │  │                         │  │                     │
│   Reference / Paper /  │  │                         │  │                     │
│   Cinema / Scanner     │  │                         │  │                     │
└────────────────────────┘  └─────────────────────────┘  └─────────────────────┘
```

交互原则：

- 默认只展开当前需要做决定的卡片；已完成卡片折叠后仍显示摘要。
- 不用 “Next” 强迫用户线性走完流程。
- 每个控件的名称表达照片语义，不显示 backend 字段名。
- 高级项解释其阶段、单位和影响；没有可靠物理依据的参数不贴“精确”标签。
- 当前呈现路径在 canvas 附近可见，例如 `Portra 400 · Standard · Reference` 或 `Portra 400 · Standard · Portra Endura`。
- 比较模式明确显示比较对象：Input decode、Reference、当前 Render 或另一个 variant。

## 11. 下一 session 的建议工作顺序

1. 先画信息架构和静态 wireframe，不立刻重写 Swift view。
2. 将现有 frontend 参数逐一映射到 `Input / Film / Develop / Render / Grade`，标出没有合适语义或后端不支持的项。
3. 定义 physical frame 数据结构、照片映射规则、裁切规则与 recipe 持久化；这是 grain/halation 尺度正确的前提。
4. 定义 Render 模式的状态机：Reference、paper、cinema、scanner 如何切换，哪些参数共享，哪些各自保存。
5. 定义右侧 grade 的输入点和重算边界，避免后期曝光被路由成 film render。
6. 设计渐进展开、stock picker、路径摘要和对比标签。
7. 在 backend Reference ABI 尚未落地时，用明确的 capability/placeholder 设计，不把 RGBA16 转 float 当成完成。
8. wireframe 得到确认后，再列 Swift 文件、state migration、sidecar schema 和最小验证范围。

## 12. 尚未决定的问题

- 产品显示名最终统一为 `SpektraLab Reference` 还是其他名称。
- Develop 对普通用户到底开放 Standard + push/pull，还是再提供 contrast / development intensity。
- physical frame 默认使用 fit、短边还是长边；建议 fit，但需要用横幅、竖幅、全景照片做交互验证。
- 6×17 等极端比例超出输入画面时，是 letterbox、裁切还是允许自定义虚拟面积。
- crop 位于左侧流程、顶部工具还是右侧几何；其物理比例规则不能因此变化。
- print CMY 到 warm/tint/exposure 的映射是否能在现有模型中稳定、单调地定义。
- glare 是否对用户拆成 optical flare 与 output/scanner glare；在模型未分开前不应给一个含糊的统一滑杆。
- Reference 的最终算法、浮点 positive ABI 与高光问题由后端研究决定。
- 最小 Browse/worklist 保留到什么程度；边界是不建设持久图库数据库。

## 13. 完成定义

前端重构完成的标志，不是左侧换了几张卡片，而是：

- 用户能说清自己正在调整输入、胶片曝光、显影、呈现还是后期。
- 画幅变化能以确定的物理比例改变 grain/halation 等效果，裁切不会意外改变它们。
- Reference 是可重复的默认起点，相纸与 cinema 从 density 正确分叉。
- 同名曝光和白平衡不再指代多个阶段。
- SpektraLab 可以顺畅接入外部照片管理/RAW 工作流，而没有长成另一个 DAM。
- sidecar/recipe 能保存上述阶段并按正确代价重算。

这些成立后，左侧才真正是一套“易用但不假装硬核”的数字暗房流程，右侧则是一套成熟的桌面级后期工作区。

---

## 14. 状态 · 2026-09-17：外观已换，结构未动

`PRD/Frontend_Rework_2026-09-17.md` 那一轮已经落地（`2cfcb12`…`1023ad3`）。
用用户自己的话说：**那一轮只抓住了外观，没有抓住本质。**

本节不改动上面任何一条产品结论，只记录哪些已经兑现、哪些仍然是空的，作为下
一 session 的输入。§11 的工作顺序仍然有效，并且仍然停在第 1 步之前——静态
wireframe 与信息架构还没有画。

### §9 差距表的当前状态

| §9 的“当前” | 2026-09-17 之后 |
|---|---|
| Film Profile 和 Print Profile 两个永久长列表 | **未关闭**。仍是两个常驻列表，只是各自收进一个 well，选中项从白框变成浅色条。数量没变，主次没变 |
| Camera 混合 tone、format、vignette、film exposure、decode WB | **部分**。format 已经整体搬进 Film，并且变成有物理语义的 Film Type / Side / Side Length；其余四项仍然同居一张卡 |
| CMY/Print WB 具有历史暗房术语 | **未关闭**。Enlarger 的 Yellow / Magenta 原样保留，只是默认折叠到最后 |
| Grain/halation/glare 看起来都是视觉效果 | **部分**。三者现在紧挨着决定它们尺度的画幅行，位置说明了归属；但仍是三个一模一样的勾选框，没有单位、没有强度、没有阶段标注 |
| `Solve / Original` 含义不清 | **仅改名**。`Solve` → `Process`，行为一字未动。§9 的抱怨原样成立 |
| 左右两侧都是参数 inspector | **未关闭**。左侧仍是参数分组，不是流程 |
| Format 是单一 long-edge mm | **已关闭**。画幅保存为“哪一边 + 该边长度”，engine 需要的长边由照片自身比例推导，因此一个 `120` 条目就能正确覆盖 645 / 6×6 / 6×7 / 6×9。裁切是否重算效应是设置项，默认关闭，即“裁切不改变底片物理尺度” |

### §13 完成定义的当前状态

- ❌ 用户能说清自己正在调整输入、胶片曝光、显影、呈现还是后期 —— 左侧仍是
  `Camera / Film / Print / Crop`，没有 `Input / Develop / Render` 这三级语义。
- ✅ 画幅变化能以确定的物理比例改变 grain/halation，裁切不会意外改变它们 ——
  这是本轮唯一真正落到“本质”上的一条。
- ❌ Reference 是可重复的默认起点，相纸与 cinema 从 density 正确分叉 ——
  产品里还没有 Reference 这个概念，默认出口仍是相纸。
- ◐ 同名曝光和白平衡不再指代多个阶段 —— 三个“变亮”现在叫
  `Film Exposure`（左·胶片曝光）、`Brightness`（左·印相）、`Exposure`
  （右·后期），名字已经分开；白平衡仍是两处都叫 Temperature / Tint，只靠所在
  分区区分。
- ➖ 不长成 DAM —— 本轮未触及。
- ❌ sidecar/recipe 能保存上述阶段并按正确代价重算 —— sidecar 仍是一个扁平
  的 `FilmParams`，没有 Input / Film / Develop / Render / Grade 五段边界。

### 本轮新增、下一轮要接手的东西

这些是这次为了兑现 PRD 而加进去的，重构时应当被继承而不是重写：

- `AEMethod`（`Model/Params.swift`）。四个 metering intent 加一个 `Custom`，
  `Custom` 就是 engine 一直声明却从没被发送过的 `camera.auto_exposure = false`
  ——“线性化基线”在前端已经是一个可表达的状态了。
- `FilmFrame` / `FilmSide` / `Session.filmFormatMM(side:sideLengthMM:aspect:)`。
  §5 想要的“保存宽和高的实际成像区域”已经有了一半：保存的是**一条边 + 是哪
  条边**，另一条由照片比例推出。§5 的四种映射里，`Match short edge` 和
  `Match long edge` 已实现，`Fit inside frame` 和 `Custom dimensions` 还没有。
- `Session.recalculateEffectsAfterCrop`。§4“只有重新映射画幅才改变物理尺度”
  的开关，默认关闭。
- `DecodeSettings.lensCorrection`。§4.0 的 Input Calibration 里第一个真正落地
  的条目，而且它不经过 engine。
- `View.rowEnabled(_:)`。“不可选就整行变灰”的唯一实现，重构后每一个条件性控
  件都应该走它。

### 一句话给下一 session

左侧现在长得对了，说的还是 backend 的话。要动的是 §4 的分卡、§8 的 recipe
边界和 §6 的 Reference 出口——那三件事都不是 `Theme.swift` 能解决的，而且都
需要先有 §11 第 1 步的 wireframe。
