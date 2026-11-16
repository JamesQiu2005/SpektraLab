# 执行任务

完整范围见 docs/PROJECT_PLAN.zh-CN.md；最新事实见 tasks/STATE.md；验收见 tasks/acceptance.md。

## M0 初始化

- [x] 获取 2.4.0 基线并创建独立分支/worktree。
- [x] 审读模型与平台结构，完成中文评估。
- [x] 建立项目入口、完整阶段规划、状态、任务、验收和经验文档。

## M1 环境与构建

- [x] 复现 Qt 下载 404 并更新官方包清单。
- [x] 修正 Vulkan CMake 变量与 C 编译入口；PowerShell 语法通过。
- [x] 建立隔离 Python 测试环境，47 项工具测试通过。
- [x] 定位并修复 Qt version check failed：部署检查缺少 MinGW runtime PATH。
- [x] 固定 glslang 16.6.0（commit、归档 SHA-256 和许可证），补齐可重复准备依赖的路径和说明。
- [x] 新目录 Release 配置和完整构建成功。
- [x] Debug 全目标构建与 CTest 通过（18/18）。
- [x] windeployqt、Qt offscreen 插件、MinGW runtime 和许可证复制成功。

## M2 引擎

- [x] Debug CTest 18/18、Release CTest 18/18，0 跳过；RTX 3060 Laptop GPU。
- [x] Windows 功能边界实际渲染：latitude、DI、contrast mask、片边、日期、漏光、柔光/像差、scan HDR、场景蒙版。
- [ ] Metal/私有 fork 同输入全图数值 parity；public Python 确定性核心已通过（最大绝对差 8.63e-06，0 个 count outlier）。
- [ ] 默认 halation/DIR couplers 与匹配参考对齐；public 包对照失败。
- [x] 错误输入、对象生命周期、无效编辑记录和导出覆盖保护检查。

## M3 用户闭环

- [x] 使用工作区内 Canon DNG 与无效 CRW 测试副本，不修改原始输入。
- [x] 可见窗口在开发环境和净化 PATH 下均成功启动并响应。
- [x] 导入、选择、缩放、胶片/相纸、曝光、效果和几何由真实 RAW 工作流覆盖。
- [x] 快速编辑、切图、撤销重做、重启恢复、收藏/评级/变体/双联由 217 项与 147 项检查覆盖。
- [x] 单张与批量导出的像素、位深、ICC、尺寸、HEIF、覆盖保护和命名由测试覆盖。
- [x] 无效 RAW、失败导出和取消后保留当前编辑。

## M4 交付

- [x] 独立 app 目录在无 SDK PATH 环境启动。
- [ ] 核查现有 CI，补原生 Windows/Qt 覆盖。
- [x] 交付运行说明、功能范围、已知限制和许可证。
- [ ] 按已通过 gate 本地提交，不推送或合并。

## 后续质量阶段

- [ ] M5：固定输入契约、跨后端参考、显示色彩管理。
- [ ] M6：分段性能实测、长期前端选型、按需补功能。
- [ ] M7：受控真实胶片校准。

## 复盘

首次运行暴露依赖清单与构建入口漂移；部署检查失败使后续编译未开始。后续状态以进程退出结果和实际产物为准，不能把命令已启动写成构建已完成。
