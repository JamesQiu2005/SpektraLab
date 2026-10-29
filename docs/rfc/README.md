# RFC 索引

模块与设计记录。何时需要 RFC、状态含义与提交规则见 [开发流程](../process/DEVELOPMENT-PROCESS.md) §1–§2；新建时复制 [TEMPLATE.md](TEMPLATE.md)。
编号 `RFC-Wnnn`，下一个可用编号：**RFC-W002**。本表的状态必须与文件 front matter 一致（`check_process.py docs` 会检查）。

| ID | 标题 | 状态 | 负责人 | 更新 |
|---|---|---|---|---|
| [RFC-W001](RFC-W001-development-process-and-ci.md) | 开发流程与 CI 门禁：PRD/RFC 体系、规范同步检查、Windows 上的自动化测试 | Review | Sizhi | 2026-10-28 |

## 等价文档（已有，不迁移）

下面这些文档早于本索引，承担 RFC 的角色。修改它们时就地更新，并遵守同样的规则：写现状而不是愿景，数字有出处，接口变更同步规范。

| 主题 | 文档 |
|---|---|
| 内存：暂存缓冲上限、空闲回收、批量导出时的驻留、Windows 上的测量方法 | [engine/WINDOWS_MEMORY.md](../../engine/WINDOWS_MEMORY.md) |
| 色彩与显示：工作空间、显示/导出转换、广色域预览、导出与预览性能 | [engine/WINDOWS_WIDE_GAMUT.md](../../engine/WINDOWS_WIDE_GAMUT.md) |
| 原生 RAW 解码（LibRaw）：模式、拒绝的格式、报告字段 | [engine/WINDOWS_NATIVE_RAW.md](../../engine/WINDOWS_NATIVE_RAW.md) |
| 内核移植方法与验收 | [engine/PORT_PLAN.md](../../engine/PORT_PLAN.md)、[engine/PORT_COVERAGE.md](../../engine/PORT_COVERAGE.md) |
| 构建、依赖、交叉编译、Vulkan 对 Metal 的对照 | [engine/LINUX_WINDOWS.md](../../engine/LINUX_WINDOWS.md)、[engine/WINDOWS.md](../../engine/WINDOWS.md) |
| 宿主进程协议（`engine/host/` ↔ `desktop/`） | [desktop/HOST-PROTOCOL.md](../../desktop/HOST-PROTOCOL.md)、[desktop/PROTOCOL-REQUESTS.md](../../desktop/PROTOCOL-REQUESTS.md) |
| 渲染接口（`params_delta` 字段、`spk_*` C ABI） | [API-SPEC-callable-render-service.md](../../API-SPEC-callable-render-service.md)、[CONTRACT-frontend-backend.md](../../CONTRACT-frontend-backend.md) |
| Windows 安装包 | [desktop/docs/WINDOWS-INSTALLER.md](../../desktop/docs/WINDOWS-INSTALLER.md) |

上游代码注释里引用的 `RFC-014`（原生引擎）、`RFC-016`（日志）、`RFC-018`（色彩链）、`RFC-019` / `RFC-020`（内存）、`RFC-021`（更新检查）、`RFC-023`…`RFC-026`、`RFC-031`…`RFC-033` 等是上游本机文档，不在仓库里（`.gitignore:329`）；其结论摘要见 [ARCHITECTURE.md](../../ARCHITECTURE.md)。
