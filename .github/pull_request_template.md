<!--
Windows / Linux 的改动以 Windows_Linux（或集成暂存分支 windows_linux2）为目标，不要以 main 为目标。
流程：docs/process/DEVELOPMENT-PROCESS.md。不适用的项写“不涉及：<理由>”，不要删掉。
-->

## 做了什么、为什么

## 关联文档

- PRD：<!-- PRD-Wnnn，或“不涉及：缺陷修复 / 重构” -->
- RFC：<!-- RFC-Wnnn，或“不涉及：<理由>” -->
- 修改的规范文档：<!-- API-SPEC §n、desktop/HOST-PROTOCOL.md §n、ARCHITECTURE.md §n …；或“无” -->

## 门禁

- [ ] 窄门禁（写命令、结果、耗时）：
- [ ] 集成门禁：`python tools/process/check_process.py all --base origin/Windows_Linux` 通过；desktop / engine 的相关全量测试通过（写用例数与耗时，不只写“0 失败”）
- [ ] 新回归测试先红后绿（写它在旧代码上怎样失败）：
- [ ] 规范同步：接口变更在本 PR 中改了规范；或提交信息里有 `Spec-Sync-Waiver: <规则>: <理由>`

## 证据（分开写自动化与人工）

- 自动化（CI、mock host、lavapipe / wine）：
- 人工（Windows 真实窗口：缩放比例 100% / 125% / 150%，单屏 / 多屏，sRGB / P3；真实 GPU；真实相机 RAW）：
- 测量（日期、commit、硬件与驱动、方法、轮数、是否交替；内存指标不相加）：

## 自查

- [ ] 没有提交个人照片、日志、导出结果、本机路径（如 `D:/…`）
- [ ] 预览、画布、缩略图、导出显示同一帧（新表面加了 surfaces 测试）
- [ ] 改变当前帧的新操作检查了 `batchExporting`
- [ ] 测试没有读写真实的 `%APPDATA%`、照片文件夹或用户导出目录
- [ ] 新依赖的许可证已写进 RFC，与 GPL-3.0-or-later 兼容
- [ ] Windows 平台习惯（标题栏、菜单、快捷键、文件对话框、高 DPI、触控板）没有为了像 macOS 而被破坏
