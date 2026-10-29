---
id: RFC-W001
title: 开发流程与 CI 门禁：PRD/RFC 体系、规范同步检查、Windows 上的自动化测试
status: Review
owner: Sizhi
created: 2026-10-28
updated: 2026-10-28
baseline: 1e727cd6cbd25e0292013e3b4dbb6ac237c0231f
prd: "none: 开发流程与 CI 是工程基础设施，没有用户可见的功能"
tests:
  - tools/process/tests/test_check_process.py
---

# RFC-W001：开发流程与 CI 门禁

## 1. 摘要（Summary）

为 `Windows_Linux` 分支建立可检查的开发流程：新功能写 PRD，模块写 RFC，单项决定写 ADR，全部入库在 `docs/`；一个只用 Python 标准库的检查器 `tools/process/check_process.py` 检查这些文档、参考审计矩阵，以及“接口变更在同一提交范围内更新规范”；CI 新增 `process.yml`，并让桌面前端的检查在 Windows 上也跑一遍。流程本身写在 [DEVELOPMENT-PROCESS.md](../process/DEVELOPMENT-PROCESS.md)，对上游规范的逐条取舍写在 [reference-audit.md](../reference-audit.md)。

## 2. 现状与动机（Context）

基线：`Windows_Linux` @ `1e727cd6cbd25e0292013e3b4dbb6ac237c0231f`（2026-10-29 08:39 +0800）。

- **上游有流程，但文档不入库。** 上游先写 PRD、RFC 再编码，代码注释大量引用 `RFC-014`、`RFC-018` 等；但 `.gitignore:329-330` 把 `/rfc/`、`/PRD/` 设为本机保存（2026-10-13 起），协作者看不到。Windows 侧的设计记录散落在 `engine/WINDOWS_*.md`、`desktop/NOTES.md` 等处，格式各异，没有索引和状态。
- **“接口变更同一提交改规范”只靠自觉。** 规则见 `AGENTS.md:62-68`、`ARCHITECTURE.md:662-665`、`desktop/HOST-PROTOCOL.md:15-17`。按本 RFC 的规则回放 `Windows_Linux` 上提交时间在 2026-09-11 00:00（+0800）之后、截至 `1e727cd` 的 343 个非合并提交（§6.3）：
  - `kFields` 字段变化 20 次，其中 9 次没有在同一提交改 `API-SPEC-callable-render-service.md`；`glare_amount`、`grain_amount`、`strip_budget_bytes`、`extended_dynamic_range`、`digital_intermediate` 这些字段名在当前的 API-SPEC 里一次也没有出现；`auto_exposure_method` 只记在 `CONTRACT-frontend-backend.md` §6。
  - C ABI 不在此列：上游没有“C ABI 变化须改 API-SPEC”的规则，`spk_engine.h` 的注释就是它的文档（`spk_engine.h` 声明的 29 个 `spk_*` 函数，API-SPEC 只点名 12 个）。本 RFC 因此不为它设同步规则（§7）。
  - 宿主协议变化 9 次，4 次未同步。宿主方法集的 5 次变化都同步了；4 次未同步都是 `protocol.ts` 的改动，其中 3 次是前端类型追上协议文档里已有的字段，1 次是真遗漏：`no_film` 与 `hello.frame_options`（宿主侧 `445e314`、前端侧 `f40ff32`）写进了 API-SPEC §19，却没有写进 `desktop/HOST-PROTOCOL.md`。
- **CI 的 Windows 覆盖有空洞。** `desktop.yml` 的前端检查（tsc、eslint、vitest、`cargo test`）只在 Ubuntu 上跑；Windows 只用于打包和静默安装。`engine/tests/test_*.py` 里只有 `test_*codec*.py` 两个文件进了 CI（`desktop.yml:108-109`），另外 4 个文件的单元测试（`test_windows_fixture.py` 等，Windows 工具本身）从未在 CI 上运行。推送到新分支不会触发 `desktop.yml`（它只监听 `main`、`Windows_Linux`、`claude/**`）。
- **用户要求（2026-10-28）**：规范开发流程，新功能写 PRD，模块写 RFC，加自动化测试，配置 CI；完成本地验证后推送到 `windows_linux2`，经批准再合并进 `Windows_Linux`。

## 3. 设计（Design）

### 3.1 文档体系

- `docs/prd/`、`docs/rfc/`、`docs/adr/`：各有 `README.md`（索引）与 `TEMPLATE.md`。文件名 `<类型>-Wnnn-<slug>.md`。编号加 `W`，避免与上游本机 RFC-001…RFC-036 冲突。
- front matter 用极小的 YAML 子集（`key: value`、`key: [a, b]`、缩进 `- item`），检查器自己解析，不依赖 PyYAML，Windows 上装了 Python 就能跑。
- 章节用标题括号里的英文关键词识别（如“设计（Design）”），正文可以全中文。
- 已有的 `engine/WINDOWS_*.md`、`desktop/*.md` 作为“等价文档”登记在索引里，不迁移、不改格式。

### 3.2 检查器 `tools/process/check_process.py`

| 子命令 | 检查 | 结果代码 |
|---|---|---|
| `docs` | 文件名；front matter 必需键；`id` 与文件名一致；状态词汇；日期；`baseline` 是 SHA；必需章节存在且非空（Draft 只警告）；Draft 以后不得残留 `{{…}}`；索引行存在且状态一致、不指向缺失文件；`docs/` 内相对链接可达；RFC 的 `prd` 指向存在的 PRD 或写明 `none: 理由`；Implemented 的 RFC 列出存在的测试；编号不重复；`sync_rules.json` 的每条规则在流程文档中以 `` `sync:<id>` `` 出现，反之亦然 | DOC000–DOC017 |
| `audit` | 参考基线（仓库 URL、`main` 与 `Windows_Linux` 的 40 位 SHA、检查日期；有 git 时确认 SHA 在历史中）；矩阵表头六列；行 ID 格式与唯一；单元格非空；“是否完全适用”只能是“完全适用 / 调整后适用 / 经评估后不适用”；后两者必须写理由；“对应代码/测试”里反引号中的路径必须存在；`audit-counts` 注释与矩阵实际计数一致 | AUD000–AUD011 |
| `sync` | 对 `merge-base(base, head)..head`（`--worktree` 再加未提交与未跟踪文件）应用 `sync_rules.json`；提交信息 `Spec-Sync-Waiver: <规则>: <理由>` 可豁免；改了代码却没有 `Gate:` / `Test:` 等记录行的提交给出警告 | SYN001、SYN003、SYN010 |

退出码：0 无错误；1 有错误；2 检查无法运行（没有 git、引用不存在、规则文件损坏）。**无法运行从不报告通过**——对应上游“跳过的检查不能看起来像通过”（`AGENTS.md:798-822`）。

### 3.3 规范同步规则的三种触发方式

- `file`：路径匹配即触发（工作流、`protocol.ts`、检查器自身）。
- `keys`：从 diff 的增删行用正则取出键（字段名、方法名），键集合变化才触发；代码搬动、改缩进不触发。
- `entries`：同一个键的整行（去空白后）在增删两侧不同也触发——字段的类型、层、范围变化都是接口变化。

各规则见 `tools/process/sync_rules.json` 与流程文档 §4。

宿主协议规则比上游更严：`desktop/HOST-PROTOCOL.md:15-17` 只要求破坏性变更在同一提交改文件，本项目把增量变更（新方法、新的 `hello` 能力）也纳入。理由是回放中唯一的真遗漏，`no_film` 与 `hello.frame_options`，正是增量变更（§6.3）。

### 3.4 CI

- 新增 `.github/workflows/process.yml`：
  - `process-gate`（ubuntu-24.04）：检查器单元测试（`SPK_REQUIRE_GIT=1`）→ `docs audit` → `sync`。sync 的基准：PR 用 PR 的基准提交；推送到 `Windows_Linux` 用推送前的提交；其他分支用 `origin/Windows_Linux` 的合并基准。
  - `python-unit`（ubuntu-24.04、windows-latest）：`engine/tests/test_*.py` 全部与检查器测试；numpy 固定版本。
- 修改 `.github/workflows/desktop.yml`：
  - 推送触发增加集成暂存分支 `windows_linux2`，让它有完整 CI。
  - 新增 `desktop-checks-windows`（windows-latest）：`npm run check`、`build:web`、`cargo test --locked`。不加 Playwright（它跑浏览器里的 mock host，平台无关，Linux 上已覆盖）。不作为打包任务的前置条件，红了也不阻塞打包，但会在 PR 上显示。
- 新增 `.github/pull_request_template.md`：关联的 PRD/RFC、门禁记录、先红后绿、规范同步、真实窗口检查、测量。

## 4. 接口与契约（Contracts）

本 RFC 不改产品的任何接口：没有 `params_delta` 字段、C ABI、宿主协议、sidecar 或设置项的变化。新增的是开发者接口：

- 命令行：`check_process.py {all|docs|audit|sync} [--base REF] [--head REF] [--worktree] [--waive "规则: 理由"] [--strict] [--strict-trailers] [--root DIR]`，退出码见 §3.2。
- `tools/process/sync_rules.json`：`{"version": 1, "rules": [{"id", "description", "source", "triggers": [{"path", "mode": "file|keys|entries", "regex"}], "require_all": [...]}]}`。新增规则是增量变更；改变已有规则的含义要在本 RFC 的决策记录里写明。
- 提交信息约定：`Gate:`（跑了什么、结果、耗时）、`Red before:`（新测试怎样先失败）、`Spec-Sync-Waiver: <规则>: <理由>`。
- 文档 front matter 的键与状态词汇（见各 `TEMPLATE.md`）。

## 5. 影响评估（Impact）

- **内存、缓存、色彩管理、导出、诊断**：无影响。没有修改 `desktop/src`、`desktop/src-tauri`、`engine/src`、`engine/host` 的代码。
- **性能（CI 时长）**：本地实测检查器 52 个测试 1.6 s（Linux，Python 3.13）；`docs audit` 对本仓库 < 1 s。`desktop-checks-windows` 与 Windows 上 `python-unit` 的时长要以 `windows_linux2` 首次 CI 运行为准，届时补进 §9。
- **许可证**：检查器只用 Python 标准库；CI 安装的 numpy（BSD-3-Clause）只用于测试，不随产品分发。没有新增随包依赖。
- **对协作者的影响**：PRD/RFC 只对新功能和新模块要求；豁免机制让非接口改动不被卡住；`Gate:` 缺失目前只警告。

## 6. 测试计划（Test plan）

### 6.1 单元测试

`tools/process/tests/test_check_process.py`，52 个用例：每个检查都有通过的夹具，以及检查器能报出的 33 个结果代码各至少一个必须出现该代码的夹具；sync 测试在临时 git 仓库里构造提交；包括带空格和中文的文件名、未提交与未跟踪文件、无 git 时必须报“无法运行”、规则文件损坏必须报“无法运行”；最后一条测试检查本仓库自己的文档通过 `docs` 与 `audit`。

### 6.2 先红后绿：检查项逐个屏蔽

2026-10-28 本地（Linux，Python 3.13）把 `Report.add` 改成丢弃某一个结果代码，再跑全部用例；未屏蔽时 0/51 失败（不含仓库自检用例）。逐个屏蔽检查器里全部 33 个结果代码，每一个都至少让 1 个用例变红（SYN001 屏蔽后 7 个，DOC008、AUD001 各 2 个，其余各 1 个）。第一版只覆盖了 29 个：独立核查发现 DOC000、AUD000、AUD002、SYN003 屏蔽后测试仍全绿，随后为它们补了用例。

### 6.3 在历史上回放规则

用本 RFC 的规则逐个回放 `Windows_Linux` 上提交时间在 2026-09-11 00:00（+0800）之后、截至 `1e727cd` 的 343 个非合并提交（每个提交对比其父提交）：

| 规则 | 触发 | 同一提交改了规范 | 未改 |
|---|---:|---:|---:|
| `wire-schema` | 20 | 11 | 9 |
| `wire-schema-parity` | 19 | 17 | 2 |
| `host-protocol` | 9 | 5 | 4 |

对比只按文件触发：同一时期改过 `params.cpp` 的提交 22 个，改过 `main.cpp` 或 `protocol.ts` 的 12 个。`wire-schema` 未同步的 9 次里，5 个字段名到今天仍不在 API-SPEC（§2），是真实偏差。`host-protocol` 未同步的 4 次里只有 1 次是真遗漏，另 3 次是前端类型追上已有文档，需要豁免；这是按文件触发 `protocol.ts` 的代价，接受它，因为那 1 次遗漏正是增量变更（§3.3）。

### 6.4 门禁

- 窄门禁：`python -m unittest discover -s tools/process/tests`；`python tools/process/check_process.py all --base origin/Windows_Linux --worktree`。
- 集成门禁：`windows_linux2` 上 `process.yml` 与 `desktop.yml` 全部任务。

## 7. 备选方案（Alternatives）

- **git pre-commit 钩子**：不强制、每台机器要单独安装，Windows 上还涉及钩子的 shell。否决；检查器可以手动或在 CI 跑。
- **只按文件触发**：实现最简单，但代码搬动、注释和无关修改也会触发；不同步时豁免会变成常态。否决，按 `keys` / `entries` 判断（`protocol.ts` 例外，见 §6.3）。
- **为 C ABI（`spk_engine.h`）设同步规则，要求同一范围改 API-SPEC**：上游没有这条规则，C ABI 的文档是头文件本身；API-SPEC 只点名 29 个函数中的 12 个。强加它会让几乎每次头文件改动都要豁免。否决（2026-10-28 独立核查后撤下了第一版里的这条规则）。
- **用 PyYAML 或 markdownlint**：引入第三方依赖，Windows 协作者要先装包。否决，只用标准库。
- **文档放进根目录 `rfc/`、`PRD/`**：会被上游 `.gitignore` 忽略。否决。
- **把 `Gate:` 缺失直接判失败**：2026-10-01 00:00（+0800）以来 `Windows_Linux` 上 139 个改了代码的非合并提交中只有 52 个有 `Test` / `Gate` / `Verified` / `Measured` 开头的行，立刻强制会卡住所有协作者。先警告，见 §10。

## 8. 发布与迁移（Rollout）

1. 在 `windows_linux2` 落地，CI 全绿，负责人批准后合并进 `Windows_Linux`。
2. 已有文档不迁移，作为等价文档登记在索引里。
3. sync 规则只检查合并基准之后的改动；§2 列出的已有偏差不会让 CI 变红，记录在 `reference-audit.md` 的“发现的偏差”一节，由负责的人逐项补规范。
4. 回滚：删除 `process.yml`，并把 `desktop.yml` 的触发分支与新任务恢复原状；文档可以保留。

## 9. 决策记录（Decision log）

- 2026-10-28 · 文档放在 `docs/prd|rfc|adr/`，编号 `W` 前缀 · 用户要求入库的 PRD/RFC；上游根目录 `rfc/`、`PRD/` 被忽略、编号被占用。
- 2026-10-28 · `Gate:` 缺失先警告，不阻塞 · 回放历史后发现大多数提交没有这一行（§7）。
- 2026-10-28 · 集成流程：推送到 `windows_linux2`，经用户批准再合并进 `Windows_Linux` · 用户指示（2026-10-28 21:30 CDT）。
- 2026-10-28 · 集成暂存分支定名 `windows_linux2`（从 `Windows_Linux` 分出） · 用户指示（2026-10-28 22:08 CDT）。
- 2026-10-28 · 撤下第一版的 `c-abi` 规则；补齐 DOC000、AUD000、AUD002、SYN003 的测试；回放窗口改为明确的起始时刻（343 个提交） · 独立核查发现：上游没有 C ABI 同步规则，四个结果代码屏蔽后测试仍全绿，`--since` 带当前时刻导致计数随运行时间变化。
- 2026-10-28 · `desktop-checks-windows` 不阻塞打包任务 · 让 Windows 上的平台问题可见，又不因新增检查把已有的打包证据一起挡住。

## 10. 待决问题（Open questions）

1. 什么时候把 `--strict-trailers` 打开，让缺少 `Gate:` 的代码提交判失败？（建议：团队适应两周后）
2. Windows 安装包签名：继续不签名，还是购买代码签名证书 / 使用 Azure Trusted Signing？发布前要定。
3. 是否需要带 GPU 的自托管 Windows 运行器，让 Vulkan 渲染、`host_hello.py --require-vulkan` 与性能测量进 CI？
4. `build.yml`（macOS 编译）只在推送到 `main`、PR 和手动触发时运行；`Windows_Linux` 上修改共享引擎时，是否也要触发 macOS 编译？
5. 上游所有者是否接受在 `Windows_Linux` 上入库 `docs/`？如果他希望保持“PRD/RFC 只在本机”，这些文档需要换个位置。
