# SpektraLab Windows 版

[English](README.md) · **简体中文** · [macOS 项目](https://github.com/JamesQiu2005/SpektraLab/tree/main)

SpektraLab 模拟胶片和放大相纸。Windows v2 使用原生 Vulkan 引擎，提供图库、冲洗和编辑三个工作区；独立图库助手保存目录和编辑。

Windows v2 正在开发。已发布的 Windows 1.x 安装包和便携 ZIP 见 [Windows beta.3](https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-windows-v1.3.4-beta.3)。v2 测试安装包与便携版使用独立的应用标识，不改写 RAW/TIFF 文件关联。实际显影需要 Windows x64、WebView2 和 Vulkan 驱动。

- `desktop/` 包含 Tauri 应用、调度器及图库客户端。可在该目录运行 `npm ci`、`npm run check` 和 `npm run build:web`。
- `engine/` 包含 Vulkan 宿主与影像管线，见 [Windows 引擎构建说明](engine/WINDOWS.md) 和 [RAW 支持范围](RAW-SUPPORT-20261117.md)。
- [安装包构建说明](desktop/docs/WINDOWS-INSTALLER.md)涵盖 Windows x64 打包。面向 `Windows_Linux_v2` 的提交和 PR 会运行 Windows 检查，手动打包仅生成测试产物。
- [Windows 首次运行清单](desktop/docs/WINDOWS-V2-CHECKLIST.md)、[Windows 设计指南](desktop/design/windows/README.md)和[图库助手协议](API-SPEC-library-helper.md)记录了行为及验收要求。

## 致谢与许可

胶片过程模型、28 款实测配置与放大 LUT 来自 Andrea Volpato 的 [spektrafilm](https://github.com/andreavolpato/spektrafilm)。4 款黑白胶片配置由 Hanze Qiu 制作。SpektraLab Windows 版在原生 C++ Vulkan 引擎中运行这套模型。

| | |
|---|---|
| 应用与引擎 | GPL-3.0-or-later |
| 胶片与相纸配置、放大 LUT | CC BY-SA 4.0 |

项目和配置许可见 **关于 SpektraLab**。运行时依赖的许可也随打包文件附带。
