# 主编辑器 v3 · 简体中文文案

语言标识：`zh-Hans`。供下一次 Claude Code 实现使用；本文件不接入运行时。
范围仅含主编辑器必要文案、术语和图标辅助标签，不包含营销文案或营销视觉。
布局、尺寸与图标来源沿用 `TOKENS-main-v3-2026-09-18.md`。

## 保留英文的范围

- **SpektraLab**：产品名称不翻译。
- **全部胶片与相纸配置名称**：直接使用 catalog 的英文显示名，不翻译、不音译、
  不按示意图重命名。例如 `Kodak Portra 400`；配置 ID 同样保持原值。
- **CINE、RAW、RGB、ISO、EV、LUT、EDR**：保留通用缩写。说明文字使用中文；
  不因缩写保留而让整行保持英文。EDR 此处是印相参数，不是显示器 HDR 开关。
- **110、APS、135、120** 等格式名称，以及 `mm`、`cm`、`in`、`K`、`%`、
  宽高比、快捷键字母和符号保持原样。
- **sRGB、Display P3、ProPhoto RGB、TIFF、JPEG** 等标准名称在需要出现时保持原样；
  不为本次主页面翻译新增这些控件。
- 文件名、用户自定义名称、相机型号和镜头型号不翻译。

其余界面使用中文，不默认中英双语并排。SF Symbols 名称、参数名、持久化键和
日志字段是实现标识，不是界面文案，不能随本地化改名。

## 主页面文案

以下按语义区分同名字符串；实现时使用稳定的语义键，不做全局英文替换。

| 位置 / English | 简体中文 |
|---|---|
| 左栏标题 · Develop | 显影 |
| 右栏标题 · Edit | 调整 |
| Input / Camera | 输入 / 相机 |
| Film | 胶片 |
| Print（相纸阶段） | 印相 |
| Crop | 裁剪 |
| Histogram | 直方图 |
| White Balance | 白平衡 |
| Exposure | 曝光 |
| Curve | 曲线 |
| Color Balance | 色彩平衡 |
| Metering / AE Method | 测光方式 |
| Custom | 自定义 |
| Balanced | 均衡 |
| Center | 中央主体 |
| Protect highlights | 保护高光 |
| Protect shadows | 保护阴影 |
| center-weighted (legacy) | 中央重点（旧版） |
| Film Exposure | 胶片曝光 |
| As Shot | 拍摄时设置 |
| Temperature / Temp. | 色温 |
| Tint | 色调 |
| Vignetting | 暗角 |
| Lens Correction | 镜头校正 |
| Positive（胶片分类） | 正片 |
| Negative（胶片分类） | 负片 |
| Still（相纸列表分组） | 静态摄影 |
| Cine（相纸列表分组） | 电影 |
| Film Format / Film Type | 胶片画幅 |
| Side | 基准边 |
| Short | 短边 |
| Long | 长边 |
| Side Length | 边长 |
| Grain | 颗粒 |
| Halation | 光晕 |
| Glare | 耀光 |
| No Print Profile | 不使用相纸配置 |
| Extended Dynamic Range (EDR) | 扩展动态范围（EDR） |
| Developed（显示状态） | 显影效果 |
| Original（原图显示） | 原图 |
| Process / Process this frame（现有求解动作） | 自动测光与配光 |
| Contrast | 对比度 |
| Brightness | 亮度 |
| Saturation | 饱和度 |
| Highlights | 高光 |
| Shadows | 阴影 |
| Black Point | 黑场 |
| White Point | 白场 |
| Midtones | 中间调 |
| Luma（曲线通道） | 明度 |
| Red / Green / Blue（曲线通道） | 红 / 绿 / 蓝 |
| Input / Output（曲线数值） | 输入 / 输出 |
| Aspect | 宽高比 |
| Free（裁剪比例） | 自由 |
| Original（裁剪比例） | 原始比例 |
| Straighten | 拉直 |
| degrees | 度 |
| Rotate | 旋转 |

“显影效果”是显示状态，不等于执行“自动测光与配光”。v3 行为决定仍见主 handoff
§8，翻译不能替代该决定。“光晕”与“耀光”必须保持区分，不合并成一个效果名称。
“中央主体”与旧版“中央重点”也必须区分，不能让不同测光模式显示同一个名字。

## 图标辅助标签与必要反馈

图标本身不随语言变化；以下用于工具提示、菜单和辅助功能标签。快捷键由现有
快捷键配置附加，不写成中文键名，也不在翻译中重新定义。

| English / 语义 | 简体中文 |
|---|---|
| Open a folder or image | 打开文件夹或图像 |
| Export | 导出 |
| Select | 选择 |
| Pan | 平移 |
| Before / after split | 原图 / 效果对比 |
| Zoom in / Zoom out | 放大 / 缩小 |
| Fit | 适合窗口 |
| Full screen / Leave full screen | 进入全屏 / 退出全屏 |
| Hide / Show the darkroom rail | 隐藏显影栏 / 显示显影栏 |
| Hide / Show the adjustments rail | 隐藏调整栏 / 显示调整栏 |
| Pick a neutral point on the image | 在图像中选取中性色 |
| White balance preset | 白平衡预设 |
| Reset | 重置 |
| Reset film exposure | 重置胶片曝光 |
| Reset all channels | 重置所有通道 |
| Reset crop | 重置裁剪 |
| Straighten to 0° | 拉直到 0° |
| Crop to whole frame | 恢复完整画面 |
| Reveal in Finder | 在 Finder 中显示 |
| Reset to defaults | 恢复默认设置 |
| Use the film's declared paper | 使用胶片预设的相纸 |
| All effects on / All effects off | 开启所有效果 / 关闭所有效果 |
| full / full…（分辨率状态） | 全分辨率 / 全分辨率处理中… |
| Restart（渲染服务） | 重新启动 |
| Empty filmstrip | 将文件夹或图像拖到此处，或按 ⌘O。 |
| Decode WB disabled | 仅 RAW 图像支持调整解码白平衡。 |
| Non-custom side length | 选择“自定义”画幅后可修改边长。 |
| Positive film disables paper | 正片无需相纸印相。选择负片后可使用相纸配置。 |
| EDR disabled in scan-film mode | 扩展动态范围仅适用于相纸印相。 |
| EDR scope | 影响渲染结果：画布、软打样和导出文件同步变化。 |
| Right-rail WB scope | 对印相扫描结果进行调整。 |
| Fast flip menu | 快速切换（使用预烘焙 LUT，不含耀光，忽略印相调整） |

重置按钮的辅助标签必须说明实际作用范围；Camera / Film 的新重置图标尚未确定
范围时，不用“重置全部”补齐文案。禁用原因必须保留，不能只让控件变灰。

## 字体与接入约束

- **所有文字保持 Bold。** 拉丁字母、数字和英文配置名使用 SF Pro Bold；中文
  使用系统提供的中文字体回退，并保持粗体语义。不要强制用 SF Pro 字形渲染汉字，
  不要为了塞入窄控件改成 Regular。字号角色继续遵循 v3 token。
- 中文标签按实际字宽检查布局。尤其检查“拍摄时设置”“扩展动态范围（EDR）”、
  英文长配置名以及 1100 × 700 最小窗口。优先调整标签空间，不缩放整行文字。
- 独立保留显示文案与 catalog ID、枚举 rawValue、sidecar 和 Session 状态。
  “不使用相纸配置”仍是现有 scan-film 选择，不得创建一个中文相纸 ID。
- 动态数值、文件名、计数和快捷键使用占位符／系统格式化；不要拼接中文句子碎片。
- 本文件是主编辑器文案规格，不是完整应用语言包；设置、导出页、系统错误的完整
  本地化留到相应页面工作。此处不生成 `.xcstrings`，不改 Swift 或项目配置。
- 产品营销视觉由用户后续自行制作，不从本文件派生海报、宣传图或品牌资产。
