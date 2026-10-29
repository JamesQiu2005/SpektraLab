# ADR 索引

不属于某个具体模块的单项决定。属于模块的决定写进该模块 RFC 的“决策记录”。新建时复制 [TEMPLATE.md](TEMPLATE.md)；规则见 [开发流程](../process/DEVELOPMENT-PROCESS.md) §1。
编号 `ADR-Wnnn`，下一个可用编号：**ADR-W001**。本表的状态必须与文件 front matter 一致。

| ID | 决定 | 状态 | 日期 |
|---|---|---|---|

目前没有 ADR。记录在其他文档里的已有决定不重复登记，例如：

- 2026-10-06 所有者决定：五项功能在非 Apple 平台暂时保持拒绝，能力声明必须真实（[engine/PORT_PLAN.md](../../engine/PORT_PLAN.md) 开头）。其后的完整迁移已实现其中大部分（[engine/WINDOWS_FULL_MIGRATION_PLAN.md](../../engine/WINDOWS_FULL_MIGRATION_PLAN.md) §8），引擎现在只拒绝对比度蒙版（`engine/src/pipeline/engine.cpp` 的 `unsupported_features`）；`PORT_PLAN.md` 开头的状态行没有随之更新，见 [reference-audit.md](../reference-audit.md) 的“发现的偏差”。
- Windows/Linux 的现行编辑器是 `desktop/`（Tauri）（[engine/WINDOWS.md](../../engine/WINDOWS.md) “TypeScript desktop shell” 一节）。`engine/WINDOWS.md` 开头与根目录 README 仍把 `windows_UI/`（Qt Quick）写成 Windows 编辑器，见 [reference-audit.md](../reference-audit.md) 的“发现的偏差”第 8 条。
