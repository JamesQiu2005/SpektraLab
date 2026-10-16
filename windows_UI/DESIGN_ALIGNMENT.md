# Windows 前端设计对齐记录

首次核对日期：2026-10-04；状态更新：2026-10-16（MSVC 2022 构建，RTX 3070）。作者提供的 `sample_frontend_v4.pdf` 共一页；多数文字是矢量轮廓，以下内容来自渲染后的逐区辨认。浏览器打印日期、页码及文件地址不是应用界面内容。导出页另参考作者提供的 `export_page(1).ai` 的 PDF 兼容内容。

首次核对时读取上游 main 的 **ab5e2d85e2ccef04266ca8ebb2f50af51a5c721c**；此后各项界面按 macOS 源码（`modern_UI/Spektrafilm/`，界面截图 `screenshots/Screenshot_English.png`）逐项移植，引用的 Swift 文件见 [README.md](README.md)。设计稿展示、上游源码实现和 Windows 可用功能分别记录，避免将画出的控件当成已可运行功能。界面文字现为英文（`i18n/en.json`，与 Mac 的 `Strings.swift` 用词一致），不再是首次核对时的中文。

## 设计稿文字与模块

“Windows 现状”一栏为 2026-10-16 的状态。

| 区域 | 可辨认文字 | Windows 现状 |
|---|---|---|
| 左栏标题 | Film and Print | 已实现，布局与 Mac 编辑器一致，可折叠、可调宽 |
| 导航图 | Navigator、Fit | 已实现：1024 px 导航图、视口框、Fit 与缩放比例 |
| 胶片 | Film、Positive、Negative；Provia 100f、Velvia 50、Ektarchrome 100、C200、Pro 400H、gold 200、Vision 50D | 已实现：按 Mac 目录分为 Positive / Negative / Black & White 三组（含四款黑白胶片）。实际选项使用引擎目录，不把设计稿里的型号/拼写当作新材质 |
| 相纸 | Print；Crystal Archive Type II、Ektacolor Edge、Endura Premier、Portra Endura、Super Endura、Ultra Endura、Vision 2383、Vision Premier 2393 | 已实现：Mac 的相纸目录与规则（反转片不经过相纸；黑白胶片配 Multigrade IV RC），Print Effects 已接入。仍缺：Extended Dynamic Range (EDR)，因 Windows 尚无 HDR 输出，灰显并说明；Digital 组（画布上的 Cineon 视图）灰显，DI 导出可用 |
| 左栏下方 | Crop、Enlarger | 已实现：裁切（自由/比例、旋转、翻转、拉直、裁切手柄）；放大机曝光 −3..3 档、黄/洋红滤镜、预闪光。另有 Settings Clipboard、Film Edge、Date Back |
| 顶栏 | 导入/导出/指针/裁切图标，Solve、Original、分屏图标、100%、缩放图标 | 已实现：导入、导出页、裁切、Process（即 Solve：自动曝光与滤镜组）、Original（Space 按住显示）、前后对比分屏、缩放阶梯与 Fit/100%、Soft Proof 与色域警告、应用菜单 |
| 下方照片条 | 七张照片缩略图及左右箭头 | 已实现：整张照片加裁切外遮罩的缩略图、文件夹导入（Finder 顺序）、拖动排序并按文件夹保存、Ctrl+点击多选、全选、同步与复制/粘贴设置、半格双拼条目 |
| 右栏标题 | Parameters、Pre-Dev、Post-Dev | 已实现：Pre-Dev 与 Post-Dev（Layer 2：白平衡、曝光、曲线、色彩平衡、暗角），按 Mac 的顺序与算法 |
| 宽容度 | Latitude、Portra 400 · Supra Endura、−4.10、+2.25；Below 2.9%、Within 67.1%、Above 30.0%；6.35 stops held、full separation −1.96 to +1.79 | 已实现：由引擎的宽容度读数绘制，与 Mac 的 `LatitudePlot` 相同；数字为实际测量值，不是设计稿示意值 |
| 输入/相机 | Input / Camera、Metering、Custom、Film Exposure、+0.0、As Shot、Temperature、5500、Tint、+0.0、Vignetting、Lens Correction | 已实现：测光（含 Custom）、胶片曝光及 As Shot、解码白平衡（色温、色调、As Shot、预设、取中性点），暗角（Post-Dev 的镜头暗角，与 Mac 相同）。仍缺：Lens Correction，LibRaw 无镜头配置，灰显并说明 |
| 胶片画幅 | Film Format、Size、135、Side、Short、Side Length、24 mm、Grain/Strength、Halation/Strength、Glare/Strength，强度均为 1.0 | 已实现：真实画幅尺度及全部效果开关/强度（颗粒、晕光与防晕层、散射、高光提升、DIR 耦合、眩光）；默认 35 mm，不因示意值改变效果 |
| 场景映射 | Scene Placement、Highlight 0、Shadow 0 | 已实现：引擎的场景宽容度映射已移植，按 Mac 的 Fit 规则提交 |
| 色调遮罩 | Tone Mask | 已实现：引擎的反差遮罩（RFC-024）已移植。Mac 用功能开关隐藏此区；Windows 显示并默认折叠 |

导出设计页还显示：`2 images`、`Export Formula`、JPEG – Display P3、TIFF – ProPhoto RGB；Location/Folder/Subfolder、Existing File/Keep；Naming/Org. Name/Film/Print/Date；Format and Size/PNG/8 bit/Color Spce/Display P3/Quality 100/Size 6000×4000；Open With/None、Summary。

现状：已实现 Mac 的导出页——导出配方（读写 Mac 的 JSON）、位置与子文件夹、已有文件策略、命名规则（四个标记）、TIFF16、PNG8/16、JPEG 及质量、长边尺寸、色彩空间（经引擎输出变换一次转换，嵌入对应 ICC）、EXIF、TIFF 预览页、数字中间片（Cineon）、导出后打开（Open With：默认应用、文件资源管理器或自选应用）、Summary 及中间的打样预览。软打样在画布上实时显示（S / Shift+S）。

## 对照原版追加的行为

上游 `Import/Library.swift`、`Model/Session.swift`、`Geometry.swift`、`Export/Exporter.swift` 已有多图、单图独立编辑、后置裁切及批量导出，Windows 均已接入：

- 当前照片与选择集合分开；切换照片恢复各自参数和裁切。
- 参数变化自动更新；切换前尚未完成的调整也保留。
- 批量导出冻结来源、设置、裁切和选择集合，一次处理一张；停止在完整文件之间生效。
- 单图导出捕获当前已显示结果；批量按每张照片的保存参数生成结果。
- 现有目标文件按配方策略处理；发布前在目标目录内完成编码，避免失败留下半成品目标文件。

逐图设置自动保存到应用本地数据目录（记录格式第 2 版，第 1 版仍可读取），重新打开同路径照片时恢复；每张照片支持 64 步会话内撤销/重做，一次滑块拖动合并成一步，同步参数可在接收照片上撤销。保存使用完整文件替换，损坏/不兼容记录、源文件变化或另一窗口改写均明确提示并保留原数据。

2026-10-04 之后补齐的 Mac 功能：完整照片加裁切遮罩的缩略图、文件夹导入与按文件夹保存的顺序、TIFF/JPEG/PNG 输入、Settings Clipboard 七组、Film Edge 与 Date Back（含各画幅片边、帧号、日期与拍摄数据）、半格双拼（每格独立的曝光、白平衡、场景映射、放大机与 Post-Dev）、Post-Dev、画布工具、ProPhoto RGB 工作空间、按显示器 ICC 的显示色彩管理、Settings 与 About 窗口。

## 与 Mac 相比仍缺

- Lens Correction（LibRaw 无镜头配置）；EDR 打印与 HDR 输出；画布上的 Cineon（Digital）视图。
- Settings 中无 Windows 后端的项目灰显并说明：预览分辨率、快速相纸预览、DI 蓝色补偿、裁切改变胶片物理尺度、效果解耦、内存与磁盘缓存、日志与诊断包、更新检查、`spektralab` 命令行与 MCP 代理接口。
- 移动或改名的源文件不会自动关联原有设置（Mac 用指纹识别）；撤销历史不跨重启保存。
- 有意的差异：Mac 的照片条显示不含 Layer 2 的打印，Windows 的照片条显示调色后的画面（AGENTS.md trap 33）；软打样 Mac 只在导出页，Windows 在画布上。

## 验证范围

Qt 编辑器有 22 项 CTest（全部 47 项于 2026-10-16 通过），另有需真实 RAW 的自检、图库、编辑、导出与半格双拼工作流，详见 [README.md](README.md#validation)。

Windows 无法运行 macOS 界面；当前验证不代表 Mac 像素对照完成，引擎也尚无整图 Metal 对照。Qt 离屏场景截图不代替实体屏幕、系统文件对话框及仪器测量的显示器色彩验收。Nikon Z8 HE/HE* 压缩 NEF 仍由当前 LibRaw 明确拒绝，失败时保留已有照片。
