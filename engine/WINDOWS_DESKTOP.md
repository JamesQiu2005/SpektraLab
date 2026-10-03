# Windows 桌面预览（2026-10-03）

这是 Windows 原生 Win32 界面的第一版：打开 RAW、选择胶片和相纸、调整相纸亮度、查看完整分辨率结果，并导出当前画面的 16 位 TIFF。解码和渲染在本机完成，运行时不需要 Python。

## 启动

直接双击：

[SpektraLab.exe](D:/SpektraLab-win/build-windows-desktop/engine/SpektraLab.exe)

也可以启动时指定图片：

```powershell
& 'D:/SpektraLab-win/build-windows-desktop/engine/SpektraLab.exe' --open 'D:/SpektraLab-win/test-raw.ARW'
```

程序默认读取可执行文件旁的 `resources` 目录，不依赖启动时的当前目录。移动程序时，保留整个 `build-windows-desktop/engine` 文件夹，包括相邻运行库 DLL、完整 `resources` 和许可证通知；不能只复制 EXE。Vulkan 由显卡驱动提供。

资源目录的**完整路径目前必须只含 ASCII 字符**，因此建议先保留现有安装位置。RAW 图片及 TIFF 导出路径支持中文等 Unicode 字符。需要指定另一份资源时，使用：

```powershell
& 'D:/SpektraLab-win/build-windows-desktop/engine/SpektraLab.exe' --resources 'D:/SpektraLab-win/build-windows-desktop/engine/resources' --open 'D:/照片/测试.ARW'
```

## 使用流程

1. 点击“打开 RAW…”选择图片，或在程序就绪时拖入**一张** RAW。首次打开会完成解码、上传、完整渲染和预览转换。
2. 用左侧下拉框选择“胶片”和“相纸”。目录来自随程序提供的真实配置，不是固定的示例列表。
3. 拖动“相纸亮度”，范围为 **−2.0 到 +2.0 EV**，步进 0.1 EV。正值增加最终画面亮度；内部对应降低放大机曝光量，换算为 `print_exposure = 2^(-EV)`，不修改拍摄曝光或胶片材料曲线。
4. 点击“应用效果”更新画面。修改相纸或相纸亮度时会请求复用负片缓存；修改胶片需要更新负片。“重置选择与亮度”只恢复控件选择，仍需点击“应用效果”。
5. 点击“适合窗口”查看整张图片，或点击“100%”查看一个图片像素对应一个画布像素的细节。在 100% 模式下，按住鼠标左键拖动画面可平移。
6. 点击“导出 16 位 TIFF…”，选择一个尚不存在的文件名。

解码、渲染和导出由一个后台工作线程串行执行。操作期间会暂时禁用相关修改按钮；已有画面仍可用于查看。操作中关闭窗口，会等待本次操作完成后退出，目前没有中途取消解码或 GPU 渲染的按钮。

打开失败时会显示原因，并保留先前成功显示的画面和对应参数，不会用失败图片替换它。

## 解码模式与导出内容

默认仍为**兼容模式**，沿用已验证的 RAW 解码规则；颗粒、眩光、自动曝光等未提供控件的效果保持引擎默认值。

“高光扩展（实验）”是主动选择项。更改解码模式后点击“应用效果”，会重新解码当前 RAW，再完整渲染。它可以保留 RGB 转换阶段的部分负值和超过 1 的信号，但去马赛克仍经过整数流程，也不能恢复传感器已经饱和的信号。支持范围及限制见 [原生 RAW 说明](WINDOWS_NATIVE_RAW.md)。

**导出保存的是当前已经显示的那一帧。** 如果只移动滑块或更换选项、尚未点击“应用效果”，导出的仍是原先画面。保存时不进行第二次随机颗粒渲染，也不从 8 位预览反推像素。

TIFF 使用完整分辨率、原始 RGB16 通道值和内嵌 sRGB ICC 配置；引擎结果中的不透明 alpha 被去除。程序保留独立的 RGBA16 结果，预览降到 8 位不会影响导出精度。**现有文件一律拒绝覆盖**，即使另一个程序在导出过程中抢先创建同名目标，也不会替换它。输入 RAW 不会被修改。

当前输出为 SDR、编码 sRGB；HDR、Display P3 / ProPhoto TIFF、EXIF 复制、DI 导出尚未接入这版界面。

## 显示与验证边界

预览是全分辨率 **8 位 SDR sRGB**，适合窗口时才缩放显示。绘制使用标记为 sRGB 的位图，并向 GDI 请求 `ICM_ON` 色彩管理；这不等于已经验证校准显示器上的实际颜色。多显示器 ICC 切换、HDR 桌面和真实可见窗口的手动交互验收仍待完成。

当前自动测试覆盖了共享桌面 host 的 RAW 打开、参数更新、缓存重印、高光扩展、失败后保留旧画面，以及逐个 RGB16 样本核对的 TIFF 导出。另有 Win32 离屏窗口测试，检查控件选择、适合窗口 / 100% 绘制、导出和 HE* 拒绝后保留画面：

- [host 集成报告](D:/SpektraLab-win/validation/windows-ui-phase5/host-integration/report.json)
- [窗口离屏测试报告](D:/SpektraLab-win/validation/windows-ui-phase5/ui-validation/report.json)

报告中的窗口图像由**离屏窗口和内存 DC 绘制**产生，不是实际显示器截图。它能核对布局与像素绘制，不能证明屏幕色彩、真实拖放、对话框操作或人工使用体验。测试总耗时还包括比较和文件输出，不能作为正式渲染基准。

## 尼康 HE / HE* 状态

当前正式依赖仍为 LibRaw 0.22.2。用户提供的 `test-raw.NEF` 是 Nikon Z8 的 HE* 文件，仍会明确拒绝；界面不会把内嵌 JPEG 当作 RAW 结果展示。

已经找到公开的 HE / HE* 解码 fork，但候选中存在已确认的边界问题和待验证的像素误差，尚未编译接入本程序，也没有用它完成这张 NEF 的测试。后续实验计划及固定版本链接见 [GitHub 调查报告](D:/SpektraLab-win/validation/windows-ui-phase5/NIKON_HE_RESEARCH.md)。现阶段可以用支持的 RAW 继续验证界面；尼康正向流程需要受支持的无损压缩 NEF，或经核对的 RAW DNG。

## 构建选项

当前构建入口默认同时启用原生 RAW 和桌面界面，输出到 `D:/SpektraLab-win/build-windows-desktop`：

```powershell
& 'D:/SpektraLab-win/SpektraLab-main/engine/build-windows.ps1' -Compiler 'E:/mingw/mingw64/bin/g++.exe'
```

其余工具路径和构建前提见 [Windows 构建说明](WINDOWS.md)。只构建命令行 RAW host 和后端时可传 `-Desktop:$false`；传 `-NativeRaw:$false` 会同时禁用依赖 RAW host 的桌面目标。不要把这些构建选项作为运行 EXE 的参数。

本轮只增加桌面 host 和显示层，继续使用现有 C API、GPU 后端、胶片/相纸资源及 RAW / TIFF 读写实现。
