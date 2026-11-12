Windows x64 维护测试版，汇总 beta.2 之后合入 Windows_Linux 的更新。

下载 `SpektraLab-1.3.4-beta.3-windows-x64-setup.exe` 安装，或完整解压 `SpektraLab-1.3.4-beta.3-windows-x64-portable.zip` 后运行 `spektralab.exe`。需要 Vulkan 显卡驱动与 Microsoft Edge WebView2 Runtime；程序未代码签名。便携包免安装，配置、缓存和日志仍使用 Windows 用户目录。

### 更新

- Fujifilm X-E5 无压缩 RAF 的相机校准支持（#98）。
- Canon EOS R6 Mark III CR3 的黑位和色彩数据修复，改善已复现的洋红偏色（#99）。
- 可在设置中选择显示磁盘缓存目录，并保留位置和容量设置（#100）。
- 最近打开的文件夹、从工作台移除照片、中文宿主提示，以及导出进度和完成提示（#47、#46、#45、#44）。
- Sony A7 V ARW6 的已测压缩样本支持、新照片默认胶片和相纸设置（#60、#53）。
- GPU 设备丢失后停止后续提交并给出诊断；仍需重启应用，尚未实现自动恢复或防止驱动复位（#64）。
- Windows 独立发布：安装包与便携包来自同一构建，附对应源码、构建信息和 SHA-256 校验值。后续版本不再覆盖本版附件。

### 验证与限制

- 构建记录涵盖前端检查、Linux/Windows 引擎、MSVC、安装包安装和便携包宿主启动。托管 Windows runner 没有真实 Vulkan GPU，不能代替显卡实测。
- 相机支持范围依据已合并 PR 的样本验证：X-E5 为公开 14-bit 无压缩 RAF；R6 Mark III 为公开 Full RAW/C-RAW。报告者原片、其他压缩模式和全部机型未全面验收。Sony ARW6 支持也不等于所有无损模式已通过。
- 缓存选目录只管理显示预览。旧缓存留在原位置，可在切换前清空；引擎临时文件不受此设置控制。
- Nikon HE/HE*、部分机型的 RAW 校准/显示问题及低显存大图稳定性仍有已知限制。PNG XMP 信息修复 #101 未纳入本版。
- 本版不包含 macOS V2 的新图库和完整新界面；旧版 102MP 性能数字不作为本版重新测量的结果。

旧版回退：[Windows beta.2](https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-windows-v1.3.4-beta.2)。

