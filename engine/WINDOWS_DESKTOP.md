# Windows 桌面预览：最小 Win32 界面

这版界面支持打开 RAW、选择胶片和相纸、调整相纸亮度、查看完整分辨率结果，并导出当前画面的 16 位 TIFF。解码和渲染在本机完成，运行时不需要 Python。这里描述的是已验证的最小 Win32 前端，不代表完整 macOS 界面已经迁移；后续尚未移植的上游功能仍不支持。

## 构建和启动

先按 [Windows 构建说明](WINDOWS.md) 配置工具链。以下命令从仓库根目录运行，示例 RAW 路径需替换为自己提供的文件：

```powershell
& .\engine\build-windows.ps1
& .\build\windows\engine\SpektraLab.exe --open '..\samples\sample.ARW'
```

也可以直接打开 `build/windows/engine/SpektraLab.exe`，再通过文件对话框选择 RAW。程序默认读取可执行文件旁的 `resources` 目录，不依赖启动时的工作目录。需要显式指定资源时：

```powershell
& .\build\windows\engine\SpektraLab.exe `
    --resources .\build\windows\engine\resources `
    --open '..\samples\照片.ARW'
```

资源目录的**完整路径目前必须只含 ASCII 字符**。RAW 输入及 TIFF 导出路径支持中文等 Unicode 字符。移动程序时保留完整的 `engine` 输出文件夹，包括相邻 MinGW 运行库 DLL、`resources`、项目许可证和 LibRaw 通知；不能只复制 EXE。Vulkan 由显卡驱动提供。

构建时传 `-Desktop:$false` 可以只保留命令行 RAW host 和后端；`-NativeRaw:$false` 会同时禁用依赖 RAW 的桌面目标。构建选项不能作为运行 EXE 的参数。

## 使用流程

1. 点击“打开 RAW…”选择图片，或在程序就绪时拖入一张 RAW。首次打开包括解码、上传、完整渲染和预览转换。
2. 从下拉框选择胶片和相纸；列表来自随程序提供的真实配置。
3. 调整“相纸亮度”：范围 −2.0 至 +2.0 EV，步进 0.1 EV。正值增加最终画面亮度；内部对应 `print_exposure = 2^(-EV)`，不会改写胶片材料曲线。
4. 点击“应用效果”更新画面。修改相纸或相纸亮度会请求复用负片缓存；修改胶片需要更新负片。“重置选择与亮度”只重置控件，仍需应用。
5. 点击“适合窗口”查看整张图片，或点击“100%”使一个图像像素对应一个物理画布像素。100% 模式下可按住左键拖动画面。
6. 点击“导出 16 位 TIFF…”，选择一个尚不存在的目标文件。

解码、渲染和导出由后台工作线程串行执行。操作期间相关修改按钮暂时禁用，已有画面仍可查看。关闭窗口会等待当前操作完成；目前没有中途取消解码或 GPU 渲染的按钮。

打开失败会显示原因，并保留先前成功显示的画面和相应参数。失败文件不会替换当前结果。

## 解码与导出

默认使用已验证的 `compatible16` 解码。颗粒、眩光、自动曝光等没有暴露控件的效果保持引擎默认值。

“高光扩展（实验）”需要主动选择。改变模式后应用效果会重新解码当前 RAW。它能保留 RGB 转换阶段产生的负值和超过 1 的信号，但去马赛克仍经过整数流程，不能恢复传感器已经饱和的数据。详细范围见 [原生 RAW 说明](WINDOWS_NATIVE_RAW.md)。

**导出保存当前已经显示的那一帧。** 尚未应用的控件更改不会进入导出。保存时不会重新生成随机颗粒，也不会从 8 位预览反推像素。

TIFF 保留完整分辨率 RGB16，并嵌入固定 sRGB ICC；不透明 alpha 被去除。独立保存的 RGBA16 结果不受预览降至 8 位影响。现有文件拒绝覆盖，输入 RAW 不会修改。当前导出为 SDR、编码 sRGB；HDR、Display P3/ProPhoto TIFF、EXIF 复制和 DI 文件导出未接入这版界面。

## 显示与测试边界

预览是全分辨率 8 位 SDR sRGB，适合窗口时才缩放。Win32 绘制使用标记为 sRGB 的位图，并向 GDI 请求 `ICM_ON`。请求成功不等于已验证真实显示器的 ICC 转换；校准显示器、多显示器切换和 HDR 桌面仍需验收。

自动测试覆盖共享 host 的完整 RAW 打开、参数更新、缓存重印、headroom、打开失败后保留旧会话、旧结果寿命，以及与同一显示帧逐个 RGB16 样本一致的 TIFF 导出。默认 CTest 还检查 BGRA 通道顺序、行间填充、全部 65,536 个量化输入、透明度约束和 viewport 边界。

Win32 离屏测试检查真实窗口处理函数、控件选择、适合窗口和 100% 绘制、导出及失败打开后的状态。可使用自己提供的支持 RAW 和预期被拒绝的 Nikon HE/HE* 样本重跑：

```powershell
python engine/tools/windows_preview_smoke.py `
    --build build/windows `
    --input '../samples/supported.ARW' `
    --reject '../samples/unsupported-he.NEF' `
    --output build/validation/window-smoke
```

输出目录必须不存在。此工具记录可执行文件和输入哈希、执行结果及输出文件。其图像由离屏窗口和内存 DC 绘制，**不是实际显示器截图**，也不能证明真实拖放、文件对话框、用户手势响应或屏幕色彩正确。测试总耗时包括比较与文件输出，不是正式渲染基准。

当前 LibRaw 0.22.2 明确拒绝 Nikon HE/HE*；不会提取内嵌 JPEG 冒充 RAW 结果。支持 Nikon 正向测试需要受支持的无损压缩 NEF、经验证的 RAW DNG，或将来另行验收的解码器。HE/HE* 的完整解码尚未接入。
