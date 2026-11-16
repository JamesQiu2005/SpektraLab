# 验收记录

状态用：通过 / 失败 / 未运行 / 受外部条件阻塞。每个阶段保存命令、输入、参数、设备/工具版本、结果与产物路径。未运行不能记为通过。

| 层级 | 门禁 | 当前结果 | 下一步或证据 |
|---|---|---|---|
| 初始化 | 入口、规划、状态和任务引用可访问 | 通过 | 7 份文档存在、内容有效，M0–M7 与状态事实检查通过 |
| 工具 | 两个修改后的 PowerShell 构建脚本语法 | 通过 | 上一轮 PowerShell AST 检查 |
| 工具 | Python 工具测试 | 通过，47 项 / 2.671 秒 | Python 3.12 隔离环境；仅工具逻辑 |
| 环境 | Qt SDK 部署 | 通过 | Qt 6.11.3、MinGW 13.1.0；修复 qmake 加载 MinGW runtime DLL 的 PATH |
| 构建 | Release 全目标 | 通过 | build/qt-release-final；干净配置、构建、部署和 CTest |
| 构建 | Debug 全目标 | 通过 | build/qt-debug；全目标构建和 CTest |
| 引擎 | Debug CTest | 通过，18/18 | 0 失败，34.22 秒；build/ctest-qt-debug-final.log |
| 引擎 | Release CTest | 通过，18/18 | 0 失败，39.64 秒；build/qt-release-final/qt-build.json |
| 引擎 | Windows 功能边界实际渲染 | 通过 | RTX 3060 Laptop GPU，驱动 617.42；latitude、DI、contrast mask、片边、日期、漏光、柔光/像差、scan HDR、场景蒙版 |
| 引擎 | 新 Vulkan 特效数值 parity | 未运行 | 需要 Metal/Python 同输入参考帧与 3e-5 parity 门禁 |
| 界面 | 可见窗口、主要控件渲染 | 通过 | build/qt-m1/spektralab-printwindow.png；进程响应正常 |
| 闭环 | RAW→编辑→持久化→导出读回 | 通过 | Debug 与 Release 均为 217 项编辑、147 项库检查；Canon DNG + 无效 CRW 隔离副本 |
| 交付 | 无 SDK PATH 的独立目录启动 | 通过 | 仅保留 System32/Windows 的 PATH；主窗口启动且加载 app 内 Qt6Core.dll |
| 交付 | 原生 Windows CI | 未运行 | 新增工作流后再验收；当前证据是本机命令 |
| 颜色 | Metal/Python 全图 parity | 受外部条件阻塞 | 匹配参考实现和输入尚未准备 |
| 显示 | 目标显示器 ICC、广色域/HDR | 未运行 | 首版限定实际 SDR 范围 |
| 科学 | 受控实拍胶片对照 | 受外部条件阻塞 | 需要拍摄、冲洗、扫描条件与原始数据 |

性能验收在性能优化阶段先建立本机基线，再设目标；本次不预设无实测依据的毫秒阈值。确定性比较关闭随机效果，颗粒与眩光另做统计验证。当前没有工程完成或科学准确性的结论。
