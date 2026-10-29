<!-- Historical milestone record; the 2026-10-29 PR23 integration supersedes pending CineStill and DI bypass descriptions. See desktop/docs/PR23-INTEGRATION-20261029.md. -->
# Windows 前端对齐 macOS 清单

基准日期：2026-10-28  
macOS：本地参考 `main / fd891c6`  
Windows：个人仓库 `evanfan005-bit/SpektraLab-Windows`，`Windows_Linux / aed5fd9` + 本轮未提交改动  
原清单：旧目录 `SpektraLab-Windows-Linux-20261006/desktop/MACOS-MAIN-ALIGNMENT-CHECKLIST-20261028.md`，保留原稿。

本版已按新仓库重新审查。原稿的 Windows 基线 `751ca6b` 已过时；例如 Esc 修复 `7e1403c` 已在当前分支历史中，本轮应复验，不重复移植。Windows 的片边、日期、半格、场景置位、Cineon、镜头矫正和预览色域已有实现，不能继续按早期“stub／skipped”描述。

本轮完成参数保存、数值输入、画幅控件等首组修复、软打样刷新，以及 `noFilm` 的前端、Agent 和原生渲染链路；新开发程序已完成下述限定范围的 Windows 实机操作、PNG 导出和退出重开验证。**不代表 Windows 迁移或与 macOS 的视觉对齐已经完成**。noFilm 尚缺部分实机场景、其他 GPU 与双端视觉验收，CineStill 800T 仍待实现。依赖和验收门槛见 [新版胶片功能迁移计划](docs/WINDOWS-FILM-MIGRATION-PLAN-20261028.md)。

**状态与证据规则**

- **实现**：当前源码已有相应行为；本轮实现提交统一暂记“未提交工作区”。
- **自动测试**：类型检查、静态检查、单元测试、浏览器测试、原生测试分别记录，不互相替代。
- **实机**：真实 Windows 应用中的操作与显示；构建成功或浏览器模拟测试不能代替。
- **双端视觉**：相同照片、参数、窗口及显示条件下，与固定 macOS 基线比较。Windows 单端截图不能代替。
- 下方复选框表示**整项验收完成**。代码和自动测试已通过、但实机或双端要求尚未完成的功能仍不勾选，并明确标注已取得的进展。

**当前验证记录**

| 层级 | 当前记录 | 最终记录／证据位置 |
| --- | --- | --- |
| 源码审查 | 已审查 `aed5fd9` 与 `main/fd891c6`，建立下方对应表 | 本清单、`PARITY.md`、新版胶片功能迁移计划 |
| 类型检查 | 最新 noFilm 工作区的 Node、Web、Agent 三套 TypeScript 检查通过 | [完整 check 日志](build/check-nofilm-20261028.log) |
| 静态检查 | 最新 `npm run check` 中 ESLint 通过；本轮文档及源码 `git diff --check` 通过 | [完整 check 日志](build/check-nofilm-20261028.log)，本轮 diff 检查输出 |
| 单元测试 | **387 项通过，1 项 realhost 默认跳过**；包括 noFilm 保存／撤销／缓存、导出冻结、旧 host 拒绝及 Agent 链路，不将跳过项计为真实引擎通过 | [完整 check 日志](build/check-nofilm-20261028.log)；取代首组修复的 356 项记录 |
| 浏览器测试 | **50 项通过**；Chromium + 页面内 mock host，新增 noFilm 编辑／重开／proof、旧 host 恢复和半格限制；保留负号、Esc、画幅锁及中英文缩放回归 | [noFilm E2E 日志](build/e2e-nofilm-20261028.log)。首组 47 项日志及六张布局截图仍在 `build/e2e-alignment-20261028*`；这些均是浏览器交互证据，不是原生引擎或双端视觉验收 |
| 首组 Windows 隔离开发构建（旧后端） | Vite 前端与 Tauri 壳构建成功；复用 2026-10-22 的 host 和资源，**未包含 noFilm 原生实现**，不含 CLI，不是发布包 | [首组构建日志](../build/windows-dev-20261028/tauri-build.log)、[首组构建清单](../build/windows-dev-20261028/development-build.json)；EXE SHA-256 `082c70b31e2cb74bc40a5ae6f6fc8aed9d9d9e012757d46b81f1394c5946bec2` 已实查 |
| noFilm Windows 隔离开发构建 | Vite/Tauri 构建成功，`build/windows-nofilm-20261028` 含本轮新编 host；前端与原生源均为 `aed5fd9` + 本轮工作区。已核对 EXE、host 及清单中的 152 项引擎资源哈希，0 项不匹配；无 CLI，不是发布包 | [新构建日志](../build/windows-nofilm-20261028/tauri-build.log)、[新构建清单](../build/windows-nofilm-20261028/development-build.json)；EXE SHA-256 `84ccf738a2fddf5b947dba49145ead52c57a7e8ef43cf1e0f49f140c4047ee96`；host 身份见下一行。构建／文件核验不代表打包后功能验收 |
| noFilm Windows 原生测试 | **新增 2/2、相关回归 8/8 通过**；另以 ARW 验证两种解码模式、自定义白平衡、精确恢复、冻结的私有导出／proof 与编辑器隔离。测试使用本轮新编 host；不代表全原生套件或 GUI 通过 | [新增测试](../../build-personal-nofilm-20261028/test-nofilm.log)、[相关回归](../../build-personal-nofilm-20261028/test-regression.log)、[ARW 测试](../../build-personal-nofilm-20261028/test-nofilm-arw.log)。host SHA-256 `f8c492c9083311a971e16f3cd25e447127cdfd29b272de06d4a834bc1284c98a` 已实查；具体覆盖与限制见迁移计划。Z8 HE／HE* NEF 在现有 LibRaw 打开阶段被拒绝，未算通过 |
| 既有胶片输出回归 | 旧 host 与新 host 的 7 个受控 film／grade／geometry／P3 export／proof／edge-date／Cineon 载荷逐字节相同，proof 统计一致 | [比较结果](../../build-personal-nofilm-20261028/film-baseline-outputs/result.json)。旧 host 来自原仓库 `751ca6b`（原生测试负责人确认引擎源码与当前基线相同，构建脚本有差异）；仅覆盖这组固定输入，不是全胶片／双端一致性结论 |
| 首组真实 Windows 应用（旧后端） | 用户确认可接管后，使用隔离应用和 RAW 副本完成负数提交／失焦、片边锁定／恢复 42 mm、后期文案及 JPEG→TIFF 软打样更新检查；RTX 5070 Ti 上实际运行旧 bundled host。已关闭测试窗口并交还桌面 | [首组原生验收记录](../build/windows-dev-20261028/native-ui-evidence.json)、[首组原生运行日志](../build/windows-dev-20261028/native-ui.log)。未实际写出导出文件、未做应用重开或双端视觉验收；**不是 noFilm 验收** |
| noFilm 真实 Windows 应用 | RTX 5070 Ti、新隔离包与 4688×7028 RAW 副本：菜单启用旁路，主图／导航／胶片条随之改变；后期输入 Unicode `−1.25` 提交并变暗；选当前 Portra 400 恢复胶片，Ctrl+Z 恢复旁路，均保留曝光；旋转 90°、拖裁剪后 JPEG/P3 与 PNG/sRGB proof 显示相同裁剪旋转。完全退出再打开同副本，旁路勾选、曝光和几何恢复。两次测试窗口均已关闭，桌面已交还 | [实机记录](../build/windows-nofilm-20261028/native-ui-evidence.json)、[首次运行日志](../build/windows-nofilm-20261028/native-ui-first-run.log)、[重开日志](../build/windows-nofilm-20261028/native-ui-reopen.log)、[保存的 sidecar](../build/windows-nofilm-20261028/native-ui-sidecar.json)：`noFilm=true`、`exposure=-1.25`、`quarterTurns=1`。GUI 未测试 redo、半格、片边、日期、DI；这些只有相应自动测试证据 |
| noFilm 实机文件导出 | PNG/sRGB 实际导出成功 1/1，5903×4047，29,302,987 bytes；尺寸与裁剪旋转后的结果相符 | SHA-256 `854fc9f0086fe77014bb49ecd211adbd9655713c959162c4bb533083aeda31b0`，路径和结果见上述实机记录。此次不代表所有格式、色域或显示器的色彩准确性验收 |
| 双端视觉／显示链 | 未验收 | 待固定 macOS 环境及双端截图基准 |
| 实现提交 | 本轮改动尚未提交 | 提交后补 SHA；不把基线 SHA 当作本轮实现提交 |

**P1：参数与操作正确性，优先完成**

- [ ] **保留新版参数**：修复保存时丢失 `effects.highlightHeadroom` 等未知嵌套字段的问题。验收：参数经过两端往返读写后不丢失。  
  实现：已改为保留未知嵌套参数，并让当前已知值覆盖旧值；自动测试覆盖编辑、重置、重复 JSON 保存，以及 false／null／数组替换。实机和实际 macOS 往返待验收；保留 `highlightHeadroom` 不等于 Windows 已实现其渲染效果。
- [x] **修复负数输入**：统一 `−` 与 `-` 的解析。验收：负数输入、回车、失焦均不改变符号。  
  单测与浏览器回归已通过：滑条数值、单位字段、逗号小数、回车和失焦；控件禁用后不提交遗留草稿。原生窗口输入 `−2`、回车、重新聚焦后 Tab 均保持 `−2.0`；关闭应用后 sidecar 的 `exposureCompensationEV` 为 `-2`。
- [ ] **修复 Esc 取消**：核对并接入上游 `7e1403c` 的取消输入修复。验收：Esc 不提交草稿、不增加编辑记录。  
  审查结论：该提交已在 `aed5fd9` 历史中，本轮保留取消机制并纳入回归；单测与浏览器回归通过，真实应用的 Esc 与编辑记录检查未重复执行。
- [ ] **支持“不应用胶片模拟”**：接入 `noFilm` 的界面、保存、显示、缩略图和导出行为；保留后期调整与裁剪，遵守半格限制。  
  本轮已实现：逐张保存、菜单切换、选胶片恢复、撤销／重做、缓存与迟到响应隔离、全照片缩略图、普通导出及软打样、Agent 读取和编辑；原生从已解码源图进入正常后期／几何／输出转换，片边和日期参数保留但不绘制。导出同时冻结普通和 DI 几何，Cineon 保留负片语义；旧 host 对已保存旁路明确拒绝，半格不能启用。新包实机已验证旁路、后期曝光、选胶片／撤销、旋转裁剪、两种 proof、PNG 写出及退出重开；redo／半格／片边／日期／DI 实机、其他 GPU、双端视觉与完整发布验证仍未完成，整项不勾选。
- [ ] **对齐 CineStill 800T**：同步胶片资源、引擎接口和前端；加入高光余量，默认 4 EV、范围 0–8 EV，正确显示固定关闭的防光晕层。  
  待实现。涉及资源别名、C++ 参数及光晕模型、Vulkan 路径和界面，详见迁移计划里程碑 B。
- [x] **对齐画幅控件状态**：片边接管画幅时锁定相关控件并说明原因；非 Custom 画幅禁用边长输入；关闭片边后恢复原设置。  
  单测与浏览器回归通过：显示有效片边的名称和尺寸；锁定 Size／Side／边长／单位；状态层拒绝无效修改；片边期间重置效果保留用户原画幅。原生窗口已检查 135 禁用边长、Custom 42 mm、片边锁定及解锁恢复；片边实际呈现在画布、导航与胶片条。像素级多表面及双端比较另行验收。

**P2：布局与编辑体验**

- [ ] **统一基础布局**：右栏最小宽度由 268 对齐到 280，核对行高、间距、字号及控件尺寸。  
  已实现右栏下限 280，并测试旧宽度载入后的约束；侧栏拖宽和持久化原已存在。浏览器生成中英文 100/115/130% 共六张截图，检查画幅菜单在栏内；其余尺寸及完整双语缩放／双端视觉核对待做。
- [ ] **统一初始展开状态**：按 macOS 设置剪贴板、片边、日期、裁剪及后期分区的默认折叠状态。  
  待实现。macOS 还默认折叠 Enlarger；对应键为 `clipboard/filmEdge/dateBack/crop/enlarger/wb2/exposure2/colorbalance`，曲线仍展开。Windows 当前首次启动全部展开。
- [ ] **补充分区高度调整**：支持拖动横向分隔线、双击恢复、保存高度及分区内部滚动。  
  待实现。已有侧栏宽度调整不能代替分区高度调整。
- [ ] **完善宽容度图**：对齐固定 EV 横轴、平方根高度、层次分离带、边界、超范围提示和读数。  
  待实现上述图形交互；当前已有场景测量、置位拟合和可用范围，图表仍使用动态横轴及线性柱高。
- [ ] **完善色彩平衡**：补齐 3-Way 三向色轮，以及饱和度、亮度弧形滑条。  
  待实现。当前为单区域色相／饱和度圆盘和直线滑条。
- [ ] **统一曲线交互**：双击重置通道、右键删除点；对齐拖出删除规则，补充图像取点和悬停辅助线。  
  待实现。当前双击删除近点、拖出删除只检查纵向边界，已有文本读数。
- [ ] **统一裁剪呈现**：对齐照片旋转、水平裁剪框、手柄及视口变化；保留已有拖线拉直功能。  
  待对齐和视觉验收。拖线拉直已有源码实现，不能按旧 PARITY 描述为缺失。
- [ ] **整理顶部工具栏**：对齐高度和分组，安排拼接、预览色域入口，明确窄窗口行为。  
  拼接和预览色域入口、分组和换行已存在；仍需核对高度、窄窗口和不同界面缩放下的呈现。
- [ ] **补齐胶片条右键菜单**：定位文件、重置单张、创建／删除半格拼接；操作对象必须是所点照片。  
  待实现。当前胶片条只有点击选择，不能用当前已打开照片替代右键点击对象。
- [ ] **对齐胶片与相纸菜单**：核对重置范围、推荐相纸、处理入口；评估并接入 Fast flip 所需能力。  
  推荐相纸入口已有；其余菜单和 Fast flip 待实现／评估。
- [ ] **核对控件规格与文案**：逐项检查范围、步长、默认值、重置及禁用说明；后期白平衡使用“色温偏移／色调偏移”，后期曝光步长对齐为 1/4 EV。  
  已完成上述白平衡文案和曝光步长，并有目标单测；原生窗口已看到两项偏移文案。其余控件逐项核对、原生曝光步进及双端视觉验收待做。

**P2：导出体验**

- [ ] **补齐导出页浏览**：Grid/Viewer 切换、网格大小、照片选择与浏览。  
  待实现；当前为软打样画布与导出照片条。
- [ ] **对齐导出页布局**：使用导出页专用尺寸规范，核对方案、命名、格式、尺寸及摘要区域。  
  各区域已有，专用尺寸及实机视觉比较待做。
- [x] **优化软打样刷新**：修改名称、目录不重新渲染；更新图像时保留旧预览并显示更新状态。  
  单测通过：只跟随影响图像的方案字段刷新；同照片更新时保留旧图，换照片立即隐藏旧图，迟到结果不能覆盖新状态；保留原软打样计算与输出分辨率语义。原生 JPEG 方案改名后保留预览；切换 TIFF 16-bit／ProPhoto 时观察到旧图和“正在更新导出软打样”，随后完成新预览。目录修改的请求次数由单测验证；实际导出文件与色彩准确性不在本项证据范围。
- [ ] **评估 Open With**：在核心导出体验对齐后，补充导出完成后的外部应用打开功能。  
  待评估／实现；当前“在文件夹中显示”不能替代 Open With。

**验收与维护**

- [ ] **建立对应表**：记录 macOS 来源提交、Windows 对应模块、差异状态、实现提交和验收证据。  
  下方已建立源码对应表，并补入本轮自动测试与原生操作结果；本轮实现未提交，其余实机／双端视觉证据待补。
- [x] **更新 PARITY 清单**：纠正已实现功能仍被标为缺失的记录。  
  [PARITY.md](PARITY.md) 已按当前源码刷新，并明确区分源码覆盖与平台／视觉验收；后续功能落地时继续维护。
- [ ] **建立截图基准**：固定照片、参数、窗口尺寸和显示条件，覆盖中英文及 100/115/130% 界面缩放。
- [ ] **检查画面一致性**：覆盖裁剪、旋转、片边、日期、半格，检查画布、导航图、缩略图及导出。
- [ ] **复测日期后背裁剪**：仅开日期后背、关闭片边，从未裁剪状态首次切换比例，确认画面不跳变。
- [ ] **验证显示链**：检查广色域、跨显示器、预览精度及导出色彩转换。
- [ ] **验证连续操作**：快速切图、拖动参数、撤销／重做、重新打开及批量导出，不出现旧结果覆盖新状态。
- [ ] **完成真实应用验收**：分别记录源码检查、自动测试、实机行为和视觉比较结果，不以某一项代替全部验收。

**源码对应表**

除单独列出的提交外，macOS 来源均指 `main/fd891c6` 的最终文件状态；不是声称每项都由该提交首次引入。Windows 模块路径相对本文件所在的 `desktop/`。本轮新增实现均尚未提交；未实现项没有实现提交。

| 事项 | macOS 来源／基线 | Windows 对应模块 | 差异状态及当前证据 |
| --- | --- | --- | --- |
| 参数兼容 | `Model/Sidecar.swift`、`Model/Params.swift` | `src/shared/sidecar.ts`、`params.ts` | 本轮实现；`sidecar.test.ts` 覆盖嵌套未知值和重复保存；真实双端往返待验收 |
| 负号与 Esc | `Controls/ScrubSlider.swift`；Windows 取消修复 `7e1403c` | `src/controls/controls.tsx`、`tests/e2e/editor.spec.ts`、`tests/e2e/alignment.spec.ts` | 负号本轮修复；Esc 已合入并复验；单测及 E2E 通过，原生负数提交／失焦及保存值通过；原生 Esc 未重复执行 |
| noFilm | 上游 `fd891c6`，`Model/Session.swift`、`Export/Exporter.swift` | `src/state/session.ts`、`shared/sidecar.ts`、`shared/filmEdge.ts`、`canvas/Canvas.tsx`、`export/*`、`agent/workspace.ts`、`../engine/host/main.cpp`、`../engine/src/pipeline/engine.cpp` | 本轮前后端实现；387 单测／50 E2E 总门禁通过，新包 RTX 5070 Ti 上完成菜单／曝光／撤销／裁剪旋转／proof／PNG／重开限定验收；原生及未测边界见上表，双端视觉待验收；[迁移计划里程碑 A](docs/WINDOWS-FILM-MIGRATION-PLAN-20261028.md) |
| CineStill 800T | `089e335/389ecc0/94e064d/bdef67d/342c974/7473478` 的最终合成状态 | `../engine/src/core`、`../engine/src/pipeline`、资源、`src/shared/params.ts`、`panels/RightRail.tsx` | 待实现；[迁移计划里程碑 B](docs/WINDOWS-FILM-MIGRATION-PLAN-20261028.md)；参数保留测试不构成渲染验收 |
| 画幅锁定与恢复 | `Panels/Sections/ParameterSections.swift` | `src/panels/RightRail.tsx`、`state/session.ts` | 本轮实现；`RightRail.format.test.tsx`、`session-film-edge.test.ts`、E2E 通过；原生片边锁定与 Custom 42 mm 恢复通过 |
| 侧栏、默认折叠、分区高度 | `Theme/Theme.swift`、`Controls/SectionHeader.swift`、`SectionLayout.swift` | `src/state/settings.ts`、`controls/PanelResize.tsx`、`controls.tsx`、`styles/theme.css` | 下限 280 本轮实现且测试通过；默认折叠、分区高度及视觉尺寸待对齐 |
| 宽容度、色轮、曲线 | `Panels/Sections/LatitudeSection.swift`、`RightSections.swift`、曲线控件 | `src/panels/RightRail.tsx`、`CurveEditor.tsx` | 现有功能部分覆盖，图形与交互差异待做；WB 文案及曝光 1/4 EV 本轮实现并测试 |
| 裁剪与顶栏 | `Canvas/CropOverlay.swift`、`Windows/TopBar.swift` | `src/canvas/Canvas.tsx`、`windows/TopBar.tsx` | 拖线拉直、拼接、色域入口已存在；旋转／裁剪框呈现和窄窗布局待验收 |
| 胶片条及胶片／相纸菜单 | `Panels/Filmstrip.swift`、`Sections/FilmSection.swift`、`PrintProfileSection.swift` | `src/windows/Filmstrip.tsx`、`panels/LeftRail.tsx` | 推荐相纸已有；右键菜单、重置／处理范围和 Fast flip 待做 |
| 导出浏览、布局、Open With | `Export/ExportPage.swift`、`ExportRecipe.swift` | `src/export/ExportPage.tsx`、`recipes.ts` | 方案及导出已存在；Grid/Viewer、专用尺寸、Open With 待对齐 |
| 软打样刷新 | `Export/ExportPage.swift`、`SoftProof.swift` | `src/export/ExportPage.tsx`、`exporter.ts` | 本轮实现；`ExportPage.test.tsx` 覆盖无关修改、保留旧图、切片与迟到结果；原生改名和 JPEG→TIFF 更新过程通过 |
| 画面／显示／连续操作 | `ARCHITECTURE.md` §7.7、§7.8，`SurfaceAgreementTests` | `src/canvas`、`shared/surfaces.ts`、`state/session.ts`、`export` | 需另做实际照片、真实 host、多表面及双端验证；不能由单一绿色测试推定完成 |

**范围约定**

保留 Windows 原生窗口、Ctrl 快捷键和文件对话框；内存与缓存控制按 Windows 实际架构设计；不复现 macOS 已知缺陷；本轮不纳入 `v2-ui` 图库。

**执行顺序**

参数兼容与输入 → 新版胶片功能 → 基础布局与控件 → 编辑工具 → 导出页 → 两端实机验收。

本轮在首组正确性修复后，完成右栏下限、后期文案／步长和软打样刷新，再贯通 noFilm 前后端及上述限定实机验收。后续补齐未测场景，按依赖推进 CineStill 与其余布局／交互，并保留双端视觉和完整发布门槛。
