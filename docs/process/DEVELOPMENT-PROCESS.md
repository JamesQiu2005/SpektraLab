# 开发流程（Windows_Linux 分支）

| | |
|---|---|
| **适用范围** | `Windows_Linux` 分支上的全部工作：`desktop/`（Tauri 前端，Windows/Linux 现行编辑器）、`engine/host/`、`engine/` 中 Windows/Linux 相关部分、`windows_UI/`（Qt Quick 编辑器，不是现行编辑器）、`.github/`、`docs/`、`tools/` |
| **性质** | 现行事实，不是愿景。CI 或检查器一变，本文件在同一提交范围内一起改（`sync:ci-gates-doc` 会检查） |
| **设计记录** | [RFC-W001](../rfc/RFC-W001-development-process-and-ci.md)：为什么这样设计、测过什么 |
| **来源与取舍** | [reference-audit.md](../reference-audit.md)：SpektraLab 上游规范逐条的采用、调整与不适用理由 |

---

## 0. 一页概览

```
需求 ──► PRD（新功能，docs/prd/）──► RFC（模块/设计，docs/rfc/）──► 实现
     （小步提交，每个提交写明跑了哪个门禁；新回归测试先红后绿）
  ──► 窄门禁（开发中，只跑受影响的测试）
  ──► 集成门禁（推送前，全量）
  ──► 推送到集成暂存分支 windows_linux2 ──► CI 全绿
  ──► 负责人批准 ──► 合并进 Windows_Linux
```

三件事不可省：**先写文档再写代码**、**接口变更同一范围内更新规范**、**每个声明有测试或测量支撑**。

## 1. 什么时候写什么

| 改动 | 需要 | 说明 |
|---|---|---|
| 新的用户可见功能，或改变已有行为 | PRD → RFC | PRD 写“做什么、为什么、怎样算完成”；RFC 写“怎么做” |
| 新模块；跨进程/跨层接口；数据或文件格式；内存、缓存、色彩、导出、诊断、性能策略 | RFC | 没有对应功能时 `prd: none: <理由>` |
| 不属于某个模块的单项决定（如安装包签名方式） | ADR | 属于模块的决定写进该模块 RFC 的“决策记录” |
| 从 `main`（macOS 版）移植已有功能 | 简短 PRD + RFC | PRD 引用 `main` 的实现（path:line + commit）与 `desktop/PARITY.md` 的行；RFC 写 Windows 的差异 |
| Bug 修复、重构、补测试 | 不需要 PRD/RFC | 提交信息写清楚做了什么、为什么；回归测试先红后绿；若改动触及接口，按 §4 同步规范 |

**PRD 状态**：Draft → Review → Approved → Building → Shipped（或 Withdrawn）。
**RFC 状态**：Draft → Review → Accepted（可以开始实现）→ Implemented（代码与测试已合入，`tests:` 列出守护它的测试）；另有 Superseded / Rejected / Withdrawn。
**ADR 状态**：Proposed → Accepted；Superseded / Rejected。

## 2. 文档规则

- **位置与命名**：`docs/prd/PRD-Wnnn-<slug>.md`、`docs/rfc/RFC-Wnnn-<slug>.md`、`docs/adr/ADR-Wnnn-<slug>.md`，从各目录的 `TEMPLATE.md` 复制，并在该目录 `README.md` 索引加一行（状态与文件一致）。
  - 不放在根目录 `rfc/`、`PRD/`：上游 `.gitignore:329-330` 把它们设为仅本机保存，放进去的文件不会入库。
  - 编号带 `W`：上游代码注释里的 `RFC-014`、`RFC-018` 等指向上游本机的 RFC-001…RFC-036，编号不能复用。
- **架构文档是当前事实**：行为改了，就在同一范围内改 `ARCHITECTURE.md`、`engine/WINDOWS*.md`、`desktop/*.md` 的对应段落。文档里的数字写出处（测量记录或测试名），不写“更快”“更稳”之类的形容词。描述已删除事物的文档是缺陷（`AGENTS.md:33-43`）。
- **遗留文档**：`engine/WINDOWS_*.md`、`engine/PORT_*.md`、`desktop/HOST-PROTOCOL.md`、`desktop/PARITY.md`、`desktop/NOTES.md` 等已有文档不迁移，在 PRD/RFC 索引里登记为等价文档，就地更新。
- **检查器**：`python tools/process/check_process.py docs` 检查命名、front matter、状态、必需章节、索引、交叉引用、相对链接。

## 3. 测试与门禁

### 3.1 窄门禁（开发中）

只跑能抓到这次改动的最小集合；提交信息用 `Gate:` 一行写明跑了什么、结果、耗时（`AGENTS.md:211-226`）。

| 改动范围 | 窄门禁 |
|---|---|
| `desktop/src/**` | `cd desktop; npx vitest run <相关测试文件>`；提交前 `npm run check`（三套 tsc + eslint 0 警告 + vitest） |
| `desktop/src-tauri/**` | `cd desktop; npm run build:web; cd src-tauri; cargo test --locked`（`generate_context!` 需要 `dist/`） |
| `desktop` 界面行为 | `cd desktop; npx playwright test <spec>`（Chromium + 页内 mock host；不是真实窗口，见 §5） |
| `engine/host/**`、宿主协议 | Linux：`engine/build-linux.sh --test`；Windows：`engine/build-windows.ps1`（原生 MinGW + CTest）；`python engine/tests/host_smoke.py --host <exe> --resources <dir>` |
| `engine/src/**`（与 macOS 共享的引擎） | 相关 CTest；改动渲染边界时在 Mac 上跑 `engine/tests/parity_metal_vulkan.py`（Vulkan 对 Metal） |
| `engine/tests/`、`engine/tools/` 的 Python | `python -m unittest discover -s engine/tests -p "test_*.py"` |
| `docs/`、`tools/process/`、`.github/` | `python tools/process/check_process.py all --base origin/Windows_Linux --worktree`；`python -m unittest discover -s tools/process/tests` |

### 3.2 集成门禁（推送前、合并前）

1. `python tools/process/check_process.py all --base origin/Windows_Linux`
2. `python -m unittest discover -s tools/process/tests` 与 `python -m unittest discover -s engine/tests -p "test_*.py"`
3. `cd desktop; npm run check; npm run build:web; npx playwright test`；`cd src-tauri; cargo test --locked`
4. 引擎与宿主：`engine/build-linux.sh --test`，或 Windows 上 `engine/build-windows.ps1`
5. 界面改动：真实窗口检查（§5）
6. **读耗时，不只读失败数**：跳过的套件和完整的套件都报告 0 失败（`AGENTS.md:798-822`，trap 26）。

### 3.3 先红后绿

- 新回归测试先在旧代码（或故意破坏的代码）上失败，再在修复后通过；提交信息写 `Red before: <怎么看到它失败的>`。
- 守卫必须能触发：检查要有能让它变红的负向对照（`AGENTS.md:565-585`，trap 16）。检查器本身的做法见 RFC-W001 §6（逐个屏蔽检查项，确认有测试变红）。
- 已知缺陷用“严格的预期失败”固定（vitest 的 `test.fails`，对应上游的 `XCTExpectFailure(strict: true)`），修复它的提交里才能去掉标记。

### 3.4 测试隔离

- 共享设置注入，不读真实存储：`createSettingsStore(storage)`（`desktop/src/state/settings.ts`）；Rust 用临时目录；Python 用 `tempfile`；需要 `APPDATA` 的进程把它指向临时目录（`desktop/agent/smoke.py` 是范例）（`AGENTS.md:696-752`，trap 24）。
- 夹具先复制到临时目录再打开；相机 RAW 不入库；输出路径必须是新的，工具拒绝覆盖。
- 测试和工具不写真实的 `%APPDATA%\app.spektralab.desktop`、照片文件夹或用户的导出目录。

### 3.5 预览、画布、缩略图、导出一致

- 显示画面的每个表面都显示画布那一帧：新表面在 `desktop/src/shared/surfaces.test.ts` 加用例（裁切 + 90° 旋转后与画布比较；`AGENTS.md:964-984`，trap 33）。
- 导出保存已经显示的那一帧，不重新抽取颗粒（`engine/WINDOWS_DESKTOP.md`、`engine/WINDOWS_WIDE_GAMUT.md:25-26`）。
- 批量导出期间，任何改变当前帧的操作都检查 `batchExporting`（trap 34）。

## 4. 接口变更与规范同步

接口变更在**同一提交范围**内更新它的规范。`tools/process/sync_rules.json` 定义规则，`check_process.py sync` 在本地和 CI 检查：

| 规则 | 什么时候触发 | 同一范围内必须改 | 依据 |
|---|---|---|---|
| `sync:wire-schema` | `engine/src/core/params.cpp` 的 `kFields` 表中有字段新增、删除或定义变化（名称、路径、类型、层、live、范围） | `API-SPEC-callable-render-service.md` | `AGENTS.md:62-68`；`ARCHITECTURE.md:662-665` |
| `sync:wire-schema-parity` | `kFields` 字段名集合变化 | `engine/tests/parity_schema.py` | `ARCHITECTURE.md:662-665` |
| `sync:host-protocol` | `engine/host/main.cpp` 的方法集合变化，或 `desktop/src/shared/protocol.ts` 改动 | `desktop/HOST-PROTOCOL.md` | `desktop/HOST-PROTOCOL.md:15-17` 只对破坏性变更要求同一提交改文件；本项目扩展到增量变更（RFC-W001 §3.3） |
| `sync:ci-gates-doc` | `.github/workflows/**` 改动 | 本文件（§7 的 CI 表） | 文档是现行事实 |
| `sync:process-rules-doc` | 检查器或规则文件改动 | `docs/rfc/RFC-W001-development-process-and-ci.md` | RFC-W001 |

- **不是接口变更时**：在提交信息里加一行 `Spec-Sync-Waiver: <规则>: <至少 8 个字的理由>`；本地运行可用 `--waive "<规则>: <理由>"`。豁免会出现在 CI 输出里，评审时要看。
- **只做增量**：新方法、新的可选字段。破坏性变更：先加新的、旧的标记弃用、写进变更记录，下个周期再删（`CONTRACT-frontend-backend.md:91-111`）。宿主协议的破坏性变更升级 `hello.protocol` 并在同一提交改 `desktop/HOST-PROTOCOL.md`。
- **前端需要宿主新能力**：先在 `desktop/PROTOCOL-REQUESTS.md` 追加请求（`[open]` → `[landed <commit>]` / `[declined: 理由]`），落地时更新标记；落地前前端按能力探测降级。

## 5. 真实窗口与界面检查

- Playwright 跑的是浏览器里的页面和 mock host，离屏截图证明不了真实窗口（`AGENTS.md:265-291`）。界面改动要在 Windows 上用真实 Tauri 窗口（`npm run tauri dev`，或安装包）检查一遍，PR 里写：检查了什么、缩放比例（100% / 125% / 150%）、显示器（单屏 / 多屏、sRGB / P3）、截图。
- Windows 平台习惯优先于模仿 macOS：系统标题栏（Snap Layouts、DPI、无障碍）、`&` 菜单助记符、Ctrl 快捷键、Ctrl+Y 重做、F11 全屏、系统文件对话框、每显示器 DPI。偏离写进 PRD 的“Windows 平台习惯”一节。
- 根目录 `screenshots/` 是所有者的 macOS 截图，不替换；Windows 截图放 PR 里，不入库个人照片。

## 6. 性能与内存测量

- 先测量再声明。测量记录写：日期、commit、硬件与驱动、方法、轮数、是否交替测量、工具与原始数据位置。
- Windows 内存指标：进程提交量（commit / Private Bytes）、工作集、GPU 账本（`memory_report`）、整卡 GPU 占用，**四者不能相加**（`engine/WINDOWS_MEMORY.md:75-80`）。
- 计时测完整调用：三个独立进程 × 首次 + 5 次热调用，新旧版本交替；关闭节点计时诊断；不用节点时间之和代表界面耗时（`engine/WINDOWS_WIDE_GAMUT.md:123-128`）。
- lavapipe 上的计时不是基准（`engine/LINUX_WINDOWS.md:173-176`）；本项目同样不把 wine 和托管 CI 运行器上的计时当作基准。
- 工具：`engine/tools/windows_performance.py`、`engine/tests/host_memory.py`。

## 7. CI（现行事实）

| 工作流 / 任务 | 运行在 | 做什么 |
|---|---|---|
| `process.yml` / `process-gate` | ubuntu-24.04 | 检查器单元测试（`SPK_REQUIRE_GIT=1`：没有 git 判失败而不是跳过）；`docs` + `audit` 检查；`sync` 检查（PR：对比 PR 基准；推送到 `Windows_Linux`：对比推送前的提交；其他分支：对比 `origin/Windows_Linux`）；缺少 `Gate:` 行的代码提交列为警告 |
| `process.yml` / `python-unit` | ubuntu-24.04、windows-latest | `engine/tests/test_*.py`（numpy 固定版本）与检查器测试，两个平台都跑 |
| `desktop.yml` / `engine-linux` | ubuntu-24.04 | 引擎 + 宿主构建，CTest 与 `host_smoke.py`（lavapipe） |
| `desktop.yml` / `engine-windows-cross` | ubuntu-24.04 | MinGW 交叉编译 `spektralab-host.exe`、DLL 导入白名单、依赖脚本单元测试、wine 下 `host_smoke.py` |
| `desktop.yml` / `desktop-checks` | ubuntu-24.04 | `npm run check`、`build:web`、`build:agent`、`cargo test --locked`、Playwright |
| `desktop.yml` / `desktop-checks-windows` | windows-latest | `npm run check`、`build:web`、`cargo test --locked`：Windows 路径、换行、文件 ID 等平台代码在 Windows 上跑 |
| `desktop.yml` / `package-linux` | ubuntu-24.04 | `.deb` + AppImage |
| `desktop.yml` / `package-windows` | windows-latest | 真实 Windows 上宿主回应 `hello`；NSIS 安装包；静默安装后再问已安装的宿主 |
| `build.yml` / `build` | macos-26 | macOS 应用能否从干净检出编译（只在推送到 `main`、PR 和手动触发时运行） |

**触发**：`process.yml` 对所有分支的推送和所有 PR 运行；`desktop.yml` 对 `main`、`Windows_Linux`、`windows_linux2`、`claude/**` 的推送、所有 PR 和手动触发运行。

**CI 回答不了的问题**（需要人工或专用机器）：真实 GPU 上的渲染（托管的 Windows 机器没有 Vulkan 驱动，`host_hello.py` 接受 `backend.available:false`）、Vulkan 与 Metal 的整图对照（需要 Mac）、相机 RAW（夹具不入库）、真实显示器的 ICC / 广色域 / HDR / 高 DPI、安装包签名（目前未签名）。这些写进 PR 的“人工验证”一栏。

## 8. 分支、提交与合并

- Windows / Linux 工作只进 `Windows_Linux`，不进 `main`（`README.md:136-146`）。
- **集成暂存**：开发 → 本地验证 → 推送到 `windows_linux2` → CI → 负责人批准 → 合并进 `Windows_Linux`。未经批准不合并，不对他人可能已读取的分支 rebase 或强推（`CONTRACT-frontend-backend.md:148-174`）。
- 一个提交做一件事；标题说做了什么，正文说为什么；正文写 `Gate:`（跑了什么、结果、耗时），新测试写 `Red before:`，豁免写 `Spec-Sync-Waiver:`。
- 不提交：个人照片、日志、导出结果、带本机路径的证据（如 `D:/…`）、`.claude/`、`CLAUDE.md`。
- 合并 `main` → `Windows_Linux` 时按模块合并，先保留本地工作，按文件内容比较而不是按提交数比较（`engine/WINDOWS_FULL_MIGRATION_PLAN.md:16`）。

## 9. 构建、打包、许可与发布

- 依赖由 `engine/setup-*.sh|ps1|py` 按版本和 SHA-256 固定并校验；CMake 不下载任何东西；校验不符时拒绝，不“修复”。
- 安装包：`desktop/scripts/package.mjs`（NSIS / `.deb` / AppImage）。Windows 安装包目前**未签名**（`desktop/docs/WINDOWS-INSTALLER.md:88-91`），发布前要做的决定记录在 RFC-W001 待决问题。
- 许可：应用与引擎 GPL-3.0-or-later；胶片与相纸配置、放大 LUT 为 CC BY-SA 4.0，保留署名与修改记录；宿主随包的第三方声明由 `engine/stage-host.sh` 汇集。新依赖在 RFC 的“影响评估”写明许可证及是否与 GPL-3.0-or-later 兼容。
- 版本号：`desktop/package.json`、`desktop/src-tauri/tauri.conf.json`、`desktop/src-tauri/Cargo.toml` 一起改。

## 10. 踩坑记录

真实踩过的坑写下来，格式：现象 → 原因 → 修复 → 守护它的测试。跨模块的写进 `AGENTS.md` 末尾的 Windows_Linux 一节；模块内的写进该模块文档（`engine/WINDOWS_*.md`、`desktop/NOTES.md`），并在 `AGENTS.md` 留一行指针。

## 附：Windows 本地自检（PowerShell，在仓库根目录）

```powershell
python tools/process/check_process.py all --base origin/Windows_Linux --worktree
python -m unittest discover -s tools/process/tests
python -m unittest discover -s engine/tests -p "test_*.py"
cd desktop; npm ci; npm run check; npm run build:web; npx playwright test
cd src-tauri; cargo test --locked
```

没有 git 的源码副本（例如 ZIP 解压）只能跑 `docs` 和 `audit`；`sync` 会明确报告“无法运行”（退出码 2），不会假装通过。
