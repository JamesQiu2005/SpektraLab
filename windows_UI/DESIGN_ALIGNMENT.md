# Windows 前端设计对齐记录

核对日期：2026-10-04。作者提供的 `sample_frontend_v4.pdf` 共一页；多数文字是矢量轮廓，以下内容来自渲染后的逐区辨认。浏览器打印日期、页码及文件地址不是应用界面内容。导出页另参考作者提供的 `export_page(1).ai` 的 PDF 兼容内容。

同时读取上游 main 的 **ab5e2d85e2ccef04266ca8ebb2f50af51a5c721c**，没有把整个 main 合并进 Windows 分支。设计稿展示、上游源码实现和 Windows 可用功能分别记录，避免将画出的控件当成已可运行功能。

## 设计稿文字与模块

| 区域 | 可辨认文字 | 含义与 Windows 本轮处理 |
|---|---|---|
| 左栏标题 | Film and Print | 胶片与相纸 |
| 导航图 | Navigator、Fit | 当前预览导航图、适合窗口 |
| 胶片 | Film、Positive、Negative；Provia 100f、Velvia 50、Ektarchrome 100、C200、Pro 400H、gold 200、Vision 50D | 正负片分组。实际选项使用引擎目录，不把设计稿里的型号/拼写当作新材质 |
| 相纸 | Print；Crystal Archive Type II、Ektacolor Edge、Endura Premier、Portra Endura、Super Endura、Ultra Endura、Vision 2383、Vision Premier 2393 | 实际相纸目录；反转片不经过相纸。Print Effects、Extended Dynamic Range (EDR) 暂未接入 UI |
| 左栏下方 | Crop、Enlarger | 裁切；相纸亮度、黄色/洋红滤镜。完整放大机高级功能未迁移 |
| 顶栏 | 导入/导出/指针/裁切图标，Solve、Original、分屏图标、100%、缩放图标 | 本轮接入多 RAW 导入、导出设置、裁切、适合/100%；Solve、原图及分屏另行迁移 |
| 下方照片条 | 七张照片缩略图及左右箭头 | 多照片列表、当前照片、导出勾选、全选和同步参数 |
| 右栏标题 | Parameters、Pre-Dev、Post-Dev | 本轮提供引擎已有参数，后期调色仍待独立实现 |
| 宽容度 | Latitude、Portra 400 · Supra Endura、−4.10、+2.25；Below 2.9%、Within 67.1%、Above 30.0%；6.35 stops held、full separation −1.96 to +1.79 | 实际分析与 Scene Placement 节点尚未完整接通，暂不显示示意统计 |
| 输入/相机 | Input / Camera、Metering、Custom、Film Exposure、+0.0、As Shot、Temperature、5500、Tint、+0.0、Vignetting、Lens Correction | 本轮加入胶片曝光；相机白平衡、镜头校正需要 LibRaw 解码层改造 |
| 胶片画幅 | Film Format、Size、135、Side、Short、Side Length、24 mm、Grain/Strength、Halation/Strength、Glare/Strength，强度均为 1.0 | 接入真实画幅尺度及三种效果开关/强度；默认保留原引擎 35 mm，不因示意值改变效果 |
| 场景映射 | Scene Placement、Highlight 0、Shadow 0 | Windows 尚缺相关节点，继续保留为后续任务 |
| 色调遮罩 | Tone Mask | 最新上游仍关闭此功能，本轮不添加空控件 |

导出设计页还显示：`2 images`、`Export Formula`、JPEG – Display P3、TIFF – ProPhoto RGB；Location/Folder/Subfolder、Existing File/Keep；Naming/Org. Name/Film/Print/Date；Format and Size/PNG/8 bit/Color Spce/Display P3/Quality 100/Size 6000×4000；Open With/None、Summary。

本轮实现当前图或所选照片导出，TIFF16、PNG8/16、JPEG8，JPEG 质量及长边缩小；只开放已经正确转换和标记的 sRGB。Display P3、ProPhoto、软打样、命名模板、配方持久化、EXIF 复制及导出后打开应用另行迁移。

## 对照原版追加的行为

上游 `Import/Library.swift`、`Model/Session.swift`、`Geometry.swift`、`Export/Exporter.swift` 已有多图、单图独立编辑、后置裁切及批量导出。最新的 `b477b12`、`c165e43` 增加全选和设置同步，本轮接入 Windows 的已支持字段。

- 当前照片与导出勾选集合分开；切换照片恢复各自参数和裁切。
- 参数变化自动更新；切换前尚未完成的调整也保留。
- 批量导出冻结来源、设置、裁切和选择集合，一次处理一张；取消在完整文件之间生效。
- 单图导出捕获当前已显示结果；批量按每张照片的保存参数生成结果。
- 现有目标文件保留；发布前在目标目录内完成编码，避免失败留下半成品目标文件。

2026-10-04 后续补齐：逐图设置自动保存到应用本地数据目录，重新打开同路径照片时恢复；每张照片支持 64 步会话内撤销/重做，一次滑块拖动合并成一步，同步参数可在接收照片上撤销。保存使用完整文件替换，损坏/不兼容记录、源文件变化或另一窗口改写均明确提示并保留原数据。

裁切增加左右 90° 旋转、水平/垂直翻转和 ±45° 拉直，均与导出共用 16 位几何路径。拉直会插值并自动收紧边缘，松开滑块后应用；90° 旋转和翻转不插值。裁切编辑显示未旋转原图，比例预设指最终输出画面。

照片条仍采用已裁切缩略图；原版的完整照片加裁切外遮罩、自动导入缩略图、文件夹导入、移动文件的设置关联及跨重启撤销历史仍待迁移。设置本身会保留，不把撤销历史持久化。

最新上游还加入半格双拼、全景片门、逐格日期/映射/后期调色，这些依赖 Windows 尚未移植的节点，不能只复制 SwiftUI 面板。`FeatureFlags.swift` 中 masks、toneMask、enlarger 仍为 false；设计稿不等于当前发布功能清单。

## 验证范围

新增输出层测试检查真实 PNG/JPEG/TIFF 文件、位深、ICC、裁切、尺寸、覆盖竞态及失败清理；库工作流用完整 Sony ARW 的两份隔离副本，设置不同参数与裁切，验证切换、同步、文件名与像素对应、批量锁定和取消。额外保留四款反转片和自动预览回归。

Windows 无法运行 macOS 界面；当前验证不代表 Mac 像素对照完成。Qt 离屏场景截图也不代替实体屏幕、系统文件对话框及显示器 ICC 验收。Nikon Z8 HE/HE* 压缩 NEF 仍由当前 LibRaw 明确拒绝，失败时保留已有照片。
