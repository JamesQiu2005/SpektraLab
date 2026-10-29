# PRD 索引

新功能的需求文档。何时需要 PRD、状态含义与提交规则见 [开发流程](../process/DEVELOPMENT-PROCESS.md) §1–§2；新建时复制 [TEMPLATE.md](TEMPLATE.md)。
编号 `PRD-Wnnn`，下一个可用编号：**PRD-W001**。本表的状态必须与文件 front matter 一致（`check_process.py docs` 会检查）。

| ID | 标题 | 状态 | 负责人 | 更新 |
|---|---|---|---|---|

目前还没有按新模板写的 PRD。

## 等价文档（已有，不迁移）

| 主题 | 文档 |
|---|---|
| Windows 完整迁移的范围、功能清单 F01–F18、阶段 M0–M5 与验收标准 | [engine/WINDOWS_FULL_MIGRATION_PLAN.md](../../engine/WINDOWS_FULL_MIGRATION_PLAN.md) |
| 迁移的验证记录（2026-10-18 起） | [engine/WINDOWS_MIGRATION_VALIDATION_20261018.md](../../engine/WINDOWS_MIGRATION_VALIDATION_20261018.md) |
| 与 macOS 版逐区域的对等状态（ported / partial / stub / skipped） | [desktop/PARITY.md](../../desktop/PARITY.md) |
| Windows 功能覆盖（Qt 阶段，已是历史） | [engine/WINDOWS_FEATURE_COVERAGE.md](../../engine/WINDOWS_FEATURE_COVERAGE.md) |

macOS 版的发布 PRD（`PRD/PRD-v1.4.0.md`）只在 `main` 分支上；合并 1.3.4 时被有意排除在本分支之外（合并提交 `0d54048`）。移植其中的功能时，PRD 引用 `main` 上该文件的路径与 commit。
