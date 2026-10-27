# SpektraLab Windows 社区版

这是 [JamesQiu2005/SpektraLab](https://github.com/JamesQiu2005/SpektraLab) 的社区 Windows 移植，
由 [LUOJW5566](https://github.com/LUOJW5566) 整理发布。原 macOS 应用作者为邱瀚泽（Hanze Qiu）。
光谱胶片过程模型、原28份实测配置和印相LUT来自
[Andrea Volpato 的 spektrafilm](https://github.com/andreavolpato/spektrafilm)。
本版不是原作者发布或认可的官方 Windows 版；合并前的维护与安装问题请在本 fork 反馈。

## 下载与安装

**[打开 Windows 下载页](https://github.com/LUOJW5566/SpektraLab/releases/latest)**

1. 下载以 **`Setup.exe`** 结尾的文件，不要下载 GitHub 自动生成的 Source code。
2. 双击安装包，阅读许可证并点击 **安装**。默认安装到当前用户的 Programs 目录，不要求管理员权限。
3. 从桌面或开始菜单的 **SpektraLab Windows Community** 打开软件，导入自己的 RAW、JPG、PNG 或 TIFF。

安装包会检查 Microsoft WebView2；缺失时使用微软签名的官方引导程序补齐，需要联网。
如果微软运行时安装失败，会停止并提示重试，不假装安装成功。
保留已有编辑记录和原始照片；卸载移除已安装文件与快捷方式，保留编辑记录及其他自行放入的文件。

不想安装可下载 **Portable.zip**，完整解压后运行文件夹里的 `SpektraLab.exe`，保留同目录全部文件。
便携版需要已安装 WebView2。两种版本采用相同的独立社区配置标识；已打开窗口时再次启动会交给现有窗口。

## 系统与硬件

- Windows x64。实际验收环境为 Windows 11、NVIDIA RTX 3070 Ti Laptop、Vulkan；其他显卡和 Windows 10 尚未逐机验证。
- 需要支持本引擎 Vulkan 计算的显卡驱动；没有 CPU 渲染回退。显卡驱动应从显卡厂商获取。
- 不需要 Python、Node.js、Visual Studio 或自己编译。
- 安装包和应用目前没有商业代码签名，Windows 或浏览器可能显示未知发布者/下载警告。
  请核对本仓库 Release 与 SHA256；本项目不要求关闭杀毒软件或系统安全功能。

## 能做什么

使用原 C++/Vulkan 引擎和 Tauri 编辑器：中文三栏布局、胶片与相纸、RAW 白平衡/曝光、
曲线与分区色彩平衡、裁切/旋转/对比、Film Edge 片基/齿孔/片名/帧号/真实 DX、
日期背印、半格双图与独立取景/印放/调色、撤销重做及编辑记录。

**JPG、PNG、TIFF 都能导出**，含 JPEG Display P3、PNG sRGB 和 TIFF16 ProPhoto。
导出可以保留调色、裁切和胶片片边。没有真实 DX 数据的胶片不会生成随机条码。

快捷键：`Ctrl+O` 打开、`Ctrl+E` 导出、`C` 取景/裁切、`Esc` 结束或取消、
`Ctrl+Z` 撤销、`Ctrl+Shift+Z` / `Ctrl+Y` 重做。半格取景可拖动并以指针为锚点滚轮缩放。

## 验证与差异

真实 Sony A7 IV RAW、50MP 级 JPG/PNG/TIFF16 原生窗口点击导出、双孔完整 PNG、
最终便携 ZIP 解压后独立启动/4086×3769 JPEG 写入、尺寸/位深/ICC 独立读取均已通过。
107项常规单测与21项浏览器回归通过；默认4项可选 realhost 跳过，真实 RAW 另行实跑。
浏览器合成输入与 mock 测试不作为原生 GPU 交互证据。

仍有显示器 ICC/宽色域显示管理、镜头配置校正、吸管、拉线拉直、胶片条排序和部分 Mac 色轮手势差异。
Mac CLI/MCP/Agents 页面没有作为本版已实现功能发布；没有声称整图 Metal/Vulkan 逐像素一致。
详见 [Windows 验收](distribution/windows/VALIDATION.md) 与 [逐项功能对照](desktop/PARITY.md)。

## 许可与源码

应用/引擎及本次移植代码按 **GPL-3.0-or-later**；原胶片/相纸配置与 LUT 按 **CC BY-SA 4.0**。
保留全部原作者署名及各依赖/字体各自许可证。Fork 并不代替履行这些许可。
Kodak、Fujifilm、Ilford等名称为各权利人的商标，本版不代表其认可。

安装版与便携版均附 `source/`，含实际编译版本对应源码、锁定依赖源码、许可证及重建脚本。
仓库额外提供本次安装脚本与修改说明；`source/LICENSE-REVIEW-GAPS.json` 明示
react-remove-scroll-bar@2.3.8 的精确发布版许可正文来源局限，没有把它隐藏。
使用和公开分发应按许可证保留这些内容，不能只抽取 EXE 重新打包并去掉署名/源码。

## 反馈问题

[在本 fork 提交 Issue](https://github.com/LUOJW5566/SpektraLab/issues)，附 Windows版本、显卡、
驱动、软件版本、复现步骤与报错。分享截图/日志前请自行去除私密路径与照片信息。
请勿把本 Windows 社区包的问题直接当作官方 macOS 版本的问题。
