# SpektraLab 参考审计（Windows_Linux 协同开发）

| | |
|---|---|
| **用途** | 记录 Windows 版协同开发参照了 SpektraLab 上游的哪些规范、读了哪些文件、每条规范在本项目中怎样采用；不适用的规则写明理由，不静默忽略 |
| **本项目** | SpektraLab 仓库的 `Windows_Linux` 分支（Windows / Linux 移植）。集成暂存分支 `windows_linux2`，经负责人批准后合并进 `Windows_Linux` |
| **两种参考角色** | `main`（macOS 产品）是 **UI 参考**与**开发规范参考**；`Windows_Linux` 是本项目的**代码基线** |
| **维护** | 更新参考基线时：重新读取 §2 所列文件，改 §1 的 SHA 与日期，逐行复核 §5。格式由 `python tools/process/check_process.py audit` 检查（表头、适用性词汇、理由、路径存在、计数） |
| **流程文档** | [process/DEVELOPMENT-PROCESS.md](process/DEVELOPMENT-PROCESS.md)；设计记录 [RFC-W001](rfc/RFC-W001-development-process-and-ci.md) |

---

## 1. 参考基线

| 字段 | 值 |
|---|---|
| 仓库 URL | https://github.com/JamesQiu2005/SpektraLab |
| UI 与规范参考分支 | `main` @ `fd891c6bc5eb350387602deb5c1ef9b6dcdab948`（2026-10-28 11:10:50 +0800，“feat(film): Don't Apply Film Simulation in the Film section's menu”） |
| 本项目基线分支 | `Windows_Linux` @ `1e727cd6cbd25e0292013e3b4dbb6ac237c0231f`（2026-10-29 08:39:50 +0800，合并 PR #23） |
| 分支关系 | `main` 是 `Windows_Linux` 的祖先（合并基准即 `main` 的 HEAD），`Windows_Linux` 领先 40 个提交 |
| 协作者分支（只读对照，未并入） | evanfan005-bit/SpektraLab-Windows 的 Windows_Linux 分支，commit 4297621a7b150595de9dcb1beafbe7645b0f8076（在本基线之上多两个提交：本地内存与 no-film 修复，72 个文件 +3535/−752） |
| 检查日期 | 2026-10-28（America/Chicago；UTC 2026-10-29） |
| 本地工作副本 | 上述 `Windows_Linux` SHA 的源码快照（无 `.git`），按文件大小逐一比对确认，不是协作者分支 |

## 2. 实际读取的文件

“全文”指逐行读完；“摘读”指读了文件头、目录和与审计有关的段落。行号都以 §1 的 SHA 为准。

| 类别 | 文件 | 分支 | 深度 |
|---|---|---|---|
| README | `README.md`、`README.zh-CN.md` | main、Windows_Linux（两分支相同） | 全文 |
| 开发约定与踩坑 | `AGENTS.md`（1072 行，trap 1–35） | 两分支相同 | 全文 |
| 架构 | `ARCHITECTURE.md`（§0–§9） | 两分支相同 | 全文 |
| PRD | `PRD/PRD-v1.4.0.md` | 仅 main（合并 `0d54048` 时有意排除在 Windows_Linux 之外） | 全文 |
| API 规范 | `API-SPEC-callable-render-service.md`（main 1052 行；Windows_Linux 1185 行，并逐行比较差异）；`API-SPEC-library-helper.md`（仅 main） | 两分支 | 全文 |
| 前后端契约 | `CONTRACT-frontend-backend.md` | 两分支相同 | 全文 |
| CI | `.github/workflows/build.yml`、`.github/workflows/desktop.yml`、`.github/scripts/host_hello.py` | 两分支（比较差异） | 全文 |
| macOS 应用（UI 参考） | `modern_UI/Spektrafilm/README.md`；`Theme/Theme.swift`（令牌）；`Panels/`、`Panels/Sections/`、`Windows/`、`Canvas/`、`Controls/` 的文件结构；`Tools/` 下全部脚本；`SpektrafilmTests/` 的文件清单及 SurfaceAgreement、Licensing、Diagnostics、TypingKeyGuard、CompareAndFlags 等测试的文件头 | main | README 全文；其余摘读 |
| Windows UI | `windows_UI/README.md`、`DESIGN_ALIGNMENT.md`、`THIRD_PARTY.md`、`build.ps1`、`setup-qt.ps1`、`CMakeLists.txt`、`dependencies/*.json`、`qml/*.qml`、`tests/*.cpp` | Windows_Linux | 文档与脚本全文；QML、测试摘读 |
| Windows 前端（现行） | `desktop/HOST-PROTOCOL.md`、`NOTES.md`、`PARITY.md`、`PROTOCOL-REQUESTS.md`、`AGENTS-CLI.md`、`docs/WINDOWS-INSTALLER.md`、`package.json`、`src-tauri/tauri.conf.json`、`Cargo.toml`、`capabilities/default.json`；`src/`、`src-tauri/src/`、`tests/e2e/`、`scripts/`、`mock-host/` 的源码结构与相关段落 | Windows_Linux | 文档全文；源码摘读 |
| 截图 | `screenshots/Screenshot_English.png`、`Screenshot_ZH_HANS.png`、`natural_halation.png`（`physically_accurate_grain.png` 只核对了存在） | 两分支相同 | 逐张查看 |
| UI 参考图 | 原始参考图 `modern_UI/reference_layout/Main/sample_frontend.svg` 不在仓库（见下）；使用其等价物：`modern_UI/Spektrafilm/README.md` §1 的 SVG 实测数值表、`Theme.swift` 令牌、`windows_UI/DESIGN_ALIGNMENT.md`（对作者 `sample_frontend_v4.pdf` 的逐区转录） | main、Windows_Linux | 全文 |
| 测试说明 | `README.md` “Test”；`AGENTS.md` “Building and testing”、“Test gates”；`ARCHITECTURE.md` §9；`modern_UI/Spektrafilm/README.md` §7；`desktop/NOTES.md`；`engine/tests/` 75 个文件（另有 `fixtures/` 目录）与 `engine/tools/` 15 个文件的文件头 | 两分支 | 全文 / 摘读 |
| 构建脚本 | `engine/build.sh`、`build-linux.sh`、`build-windows.ps1`、`build-windows-cross.sh`、`setup-deps.sh`、`setup-libraw.sh/.ps1`、`setup-codecs.sh/.ps1`、`setup-input-codecs.py`、`setup-lens-codecs.py`、`stage-host.sh`、`cmake/*.cmake`、`cmake/*pins.json`、`engine/CMakeLists.txt`、`engine/host/CMakeLists.txt` | Windows_Linux（与 main 比较） | 全文 |
| 发布脚本 | `modern_UI/Spektrafilm/Tools/package.sh`、`bundle-licenses.sh`、`check-bundle-resources.sh`；`desktop/scripts/package.mjs`、`build-agent.mjs`；`vendor/spklib/macos/spklib-host.sha256`（仅 main，并核对了哈希） | 两分支 | 全文 |
| 内存、缓存、导出、色彩、诊断、性能的 RFC 或等价文档 | 上游 RFC 不在仓库（见下）。等价文档：`ARCHITECTURE.md` §4（内存）、§7.5（色彩链）、§7.6（状态与日志）、§7.8（导出）、§8.5（缓存）、§8.7–§8.9（速度与计时）；`engine/WINDOWS_MEMORY.md`、`WINDOWS_WIDE_GAMUT.md`、`WINDOWS_NATIVE_RAW.md`、`WINDOWS.md`、`LINUX_WINDOWS.md`、`PORT_PLAN.md`、`PORT_NOTES.md`、`PORT_COVERAGE.md`、`WINDOWS_FEATURE_COVERAGE.md`、`WINDOWS_DESKTOP.md`、`WINDOWS_FULL_MIGRATION_PLAN.md`、`WINDOWS_MIGRATION_VALIDATION_20261018.md`；`API-SPEC` §7、§17 | 两分支 | 全文 |
| 许可 | `license/LICENSE`、`license/SPEKTRAFILM_LICENSE.txt`、`CITATION.cff`、`engine/resources_product/NOTICE.md`、`engine/resources_product/fonts/README.md`、`engine/third_party/README.md`、`engine/third_party/stb/README.md` | 两分支 | 全文 |
| 协作者分支 | 相对本基线的 `git diff --stat` 与提交说明 | evanfan005-bit/SpektraLab-Windows | 摘读 |

**要求读取、但仓库里没有的文件**（记录在案，不假装读过）：

- `rfc/`（RFC-001…RFC-036，代码注释大量引用）、`PRD/` 的其余文件、`research/`、`usage-guide/`：上游 `.gitignore:329-333` 把它们设为本机保存（2026-10-13 起）；`handoff/` 更早已被忽略（`.gitignore:322`）。`PRD/PRD-v1.4.0.md` 是 `main` 上唯一被强制入库的 PRD。
- `modern_UI/reference_layout/`（布局参考图）、`modern_UI/UI-GUIDELINE-swiftui.md`、`modern_UI/frontend_architecture.md`、`modern_UI/design/`：`.gitignore:334-335` 只放行 `modern_UI/Spektrafilm/`。
- `desktop/README.md`：`engine/WINDOWS.md:79` 链接了它，但文件不存在。
- 相机样片 `tests/Test_image/` 与 Python 参考实现 `src/spektrafilm`：在上游 fork 中，不在本仓库。

## 3. 借鉴的规范（摘要）

完整清单与对应代码见 §5。

- **先文档后代码**：新功能 PRD、模块 RFC、单项决定 ADR，带状态、决策记录和待决问题（P-01–P-03）。
- **文档是现行事实**：数字带出处，描述已删除的东西算缺陷（P-04、P-09）。
- **正式契约与同步**：渲染接口（API-SPEC、CONTRACT）与宿主协议（HOST-PROTOCOL）是契约；接口变更在同一提交范围内改规范，只做增量；前端向后端提请求有固定流程（P-05–P-08）。本项目把“同步”做成了自动检查。
- **测试门禁**：开发中窄门禁、集成时全量、提交记录所跑门禁、先红后绿、守卫必须能触发、读耗时不只读失败数、跳过的检查不能看起来像通过（T-01–T-07）。
- **测试隔离与不污染用户文件**：注入设置存储、夹具先复制、输出路径必须新建（T-08–T-10）。
- **一致性**：画布、导航图、缩略图、软打样、导出显示同一帧；批量导出锁定当前帧；文件原子落盘；一个工作色彩空间、每个目的地只转换一次（C-01–C-06）。
- **真实窗口**：离屏截图不能代替真实窗口检查（X-02）。
- **测量**：先测量再声明，交替测量，计时测完整调用，机器不是基准，CI 与 lavapipe 计时不是基准（M-01–M-09）。
- **构建、依赖、许可、发布可复现**：依赖按 SHA 固定、校验不符就拒绝，许可文本随包并检查，安装后再验证（B-01–B-12）。
- **协作**：Windows/Linux 工作只进 `Windows_Linux`，可审阅的小提交，不强推他人读过的分支，按模块合并（G-01–G-08）。
- **UI 信息架构**：以画布为中心，左侧“胶片与相纸”功能轨，右侧“参数”轨（显影前 / 显影后），底部胶片条，深色克制的界面，原图对比与滑动对比，100% 与导航，预览 / 全分辨率状态，批量选择与每张照片独立状态，参数变化代价按轨区分（UI-01–UI-16）。

## 4. 因产品或平台差异不能直接采用的规范（摘要）

- **macOS 工具链专属**：Xcode 工程生成（X-01）、Swift `@Observable` 递归陷阱（X-04）、ImageIO 缩略图陷阱（X-05）、`footprint` 内存工具（M-02 调整为 Windows 指标）、Developer ID 签名与公证（B-06）、“发布是 ad-hoc zip”（X-06，在上游也已过时）。
- **胶片模型专属的业务约束**：固定实验设置与 45 MP 样片路径（F-02）、Python 参考实现对照（F-03）、新增胶片的流程（F-10）。它们只约束共享引擎和胶片数据；Windows 前端与流程本身不受它们约束。仍然适用于共享引擎的规则（不污染材料模型、安全数学、对照门槛、光谱网格）标为“调整后适用”并限定范围（F-01、F-04–F-06）；随机效果的比较方法与配置数据的许可照原样适用（F-07、F-08）。
- **形式调整**：PRD/RFC 从“本机不入库”改为入库 `docs/`，编号加 `W`（P-01、P-02）；Mac 的 Xcode 测试类门禁换成 vitest / cargo / CTest / unittest（T-01、T-02）；`XCTExpectFailure(strict:)` 换成 vitest `test.fails`（T-11）；`UserDefaults` 套件注入换成注入的 `localStorage` 与临时 `APPDATA`（T-08）；`TypingKeyGuard` 换成 WebView 键盘守卫（X-03）。
- **用户要求中的品牌条款**：本项目就是 SpektraLab 仓库自己的 Windows 分支，品牌归仓库所有者，可以使用；但 Apple 平台专属素材不得搬到 Windows，第三方商标与 spektrafilm 名称另有限制（UI-17）。
- **Windows 平台习惯优先**：标题栏、菜单、快捷键、文件对话框、高 DPI、触控板按 Windows 习惯，不为了像 macOS 而破坏（W-01–W-11）。

## 5. 合规矩阵

“是否完全适用”只用三种值：**完全适用**（照原样采用）、**调整后适用**（采用其目的，形式或范围改变）、**经评估后不适用**（评估后不采用）。后两种必须在“调整理由”写明原因。“对应代码/测试”里反引号中的路径都由检查器确认存在。

### 5.1 流程与文档（P）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| P-01 | 先建立 PRD 再编码：PRD 写清现状、要做什么、规则、验收、决策与待决问题，“nothing here is built”（main `PRD/PRD-v1.4.0.md` 开头、§7–§9） | 新功能先写 `docs/prd/PRD-Wnnn`；模板含背景、目标、需求、Windows 平台习惯、约束、验收、测量、决策、待决问题、范围之外；检查器校验章节与状态 | 调整后适用 | 上游 PRD 按发布版本写、且 `/PRD/` 被 `.gitignore:330` 设为本机保存，协作者看不到；本项目按功能写并入库，编号加 W 避免冲突 | `docs/prd/TEMPLATE.md`、`docs/prd/README.md`、`tools/process/check_process.py`、`tools/process/tests/test_check_process.py` |
| P-02 | 模块与重大设计写 RFC（代码注释引用 RFC-014、RFC-018、RFC-019/020 等；PRD §10“每个功能变成一个 RFC”） | 模块写 `docs/rfc/RFC-Wnnn`；模板含摘要、现状、设计、接口与契约、影响评估（内存/缓存/色彩/导出/诊断/性能/许可）、测试计划、备选方案、发布迁移、决策记录 | 调整后适用 | 上游 `/rfc/` 不入库（`.gitignore:329`），编号 RFC-001…036 已占用；入库并加 W 前缀 | `docs/rfc/TEMPLATE.md`、`docs/rfc/RFC-W001-development-process-and-ci.md` |
| P-03 | 重大决策带日期与决策人记录（`PRD-v1.4.0.md` §8；`AGENTS.md` 中“owner's decision, 2026-10-03”；`engine/PORT_PLAN.md` 开头 2026-10-06 决定） | PRD“决策”、RFC“决策记录”只追加；不属于模块的单项决定写 ADR | 完全适用 | — | `docs/adr/TEMPLATE.md`、`docs/adr/README.md` |
| P-04 | 架构文档是当前事实而非事后宣传（`ARCHITECTURE.md` 标注“Current as of”；`AGENTS.md:33-43` 截图揭穿过时描述） | 流程文档标为现行事实；工作流一改，同一范围必须改流程文档的 CI 表（`sync:ci-gates-doc`）；检查器改动必须改 RFC-W001 | 完全适用 | — | `docs/process/DEVELOPMENT-PROCESS.md`、`tools/process/sync_rules.json` |
| P-05 | API 与前后端边界有正式契约：线上只有约定的通道，字段、层级、分辨率档名都属契约（`CONTRACT-frontend-backend.md` §1；`API-SPEC-callable-render-service.md`） | 沿用：渲染接口以 API-SPEC 为准；Windows 进程边界以宿主协议为准 | 完全适用 | — | `API-SPEC-callable-render-service.md`、`desktop/HOST-PROTOCOL.md`、`desktop/src/shared/protocol.ts` |
| P-06 | 接口变更同步更新规范：“a wire change edits its section in the same commit”（`AGENTS.md:62-68`、`ARCHITECTURE.md:662-665`）；宿主协议的破坏性变更同一提交改协议文档（`desktop/HOST-PROTOCOL.md:15-17`） | 做成自动检查：`kFields` 表、宿主方法集与 `protocol.ts` 变化时，同一提交范围必须改对应规范，否则 CI 失败；非接口改动用 `Spec-Sync-Waiver` 说明理由 | 调整后适用 | 比上游更严：宿主协议的增量变更也要同步改文档，因为回放历史时唯一的真遗漏（`no_film`、`hello.frame_options`）就是增量变更；C ABI 不设规则，上游以头文件注释为其文档（RFC-W001 §7） | `tools/process/sync_rules.json`、`tools/process/check_process.py`、`.github/workflows/process.yml` |
| P-07 | 版本协商与破坏性变更流程：transport / schema 版本只在规定情况下升级；破坏性变更先加新、旧的弃用、下个周期再删（`CONTRACT-frontend-backend.md` §2） | 沿用；宿主协议的破坏性变更升级 `hello.protocol` 并同提交改协议文档；CI 用 `host_hello.py` 确认协议号 | 完全适用 | — | `.github/scripts/host_hello.py`、`docs/process/DEVELOPMENT-PROCESS.md` |
| P-08 | 跨边界请求只追加、不改别人的条目，标注状态（`CONTRACT-frontend-backend.md` §5；`desktop/PROTOCOL-REQUESTS.md` 的 open / landed / declined） | 沿用；落地时更新标记（R4 目前标记滞后，见 §6） | 完全适用 | — | `desktop/PROTOCOL-REQUESTS.md` |
| P-09 | 每个声明都要有测量或测试支撑：“Measure, then claim”（`AGENTS.md` Conventions；`PRD-v1.4.0.md` 规则 7） | PRD 必须有“测量计划”，RFC 必须有“影响评估”和“测试计划”；PR 模板要求附测量与门禁记录 | 完全适用 | — | `docs/prd/TEMPLATE.md`、`docs/rfc/TEMPLATE.md`、`.github/pull_request_template.md` |
| P-10 | 规范文档由改动者维护（`AGENTS.md:62-68`，所有者 2026-10-03 决定）；同文件另有旧规则“编辑前先说明”（`AGENTS.md:1048-1050`） | 按较新的所有者决定：改动者负责同步改文档，并在提交信息和 PR 中写明改了哪些规范文档 | 调整后适用 | 上游两条规则互相矛盾；后者属于双会话分工时期，所有者已在前者中取消“先说明”的要求 | `.github/pull_request_template.md` |
| P-11 | 记录真实踩坑，持续更新 `AGENTS.md`（trap 1–35，每条写现象、原因、如何发现、守护测试） | 跨模块的 Windows 坑写进 `AGENTS.md` 末尾 Windows_Linux 一节，模块内的写进模块文档并在 `AGENTS.md` 留指针；格式：现象 → 原因 → 修复 → 守护测试 | 调整后适用 | `AGENTS.md` 与 `main` 共用，大段改写会造成每次合并冲突；集中在文件末尾一节追加 | `AGENTS.md`、`docs/process/DEVELOPMENT-PROCESS.md` |
| P-12 | 覆盖矩阵用固定状态词汇，改动者负责更新（`desktop/PARITY.md` 的 ported / partial / stub / skipped；`engine/PORT_COVERAGE.md`） | 沿用；参考审计矩阵同样使用固定词汇，并由检查器核对计数 | 完全适用 | — | `desktop/PARITY.md`、`engine/PORT_COVERAGE.md`、`tools/process/check_process.py` |
| P-13 | 能力声明必须真实：未移植就是不支持，请求被拒绝时会话不变（`engine/PORT_PLAN.md` 开头；`engine/WINDOWS_FEATURE_COVERAGE.md`） | 沿用：引擎在 `unsupported_features` 中声明，前端据此禁用控件并说明原因 | 完全适用 | — | `engine/src/pipeline/engine.cpp`、`desktop/src/panels/gate.ts` |

### 5.2 测试与门禁（T）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| T-01 | 使用最小测试门禁开发：只跑能抓到改动的测试类（`AGENTS.md:211-226`） | 按改动范围列出窄门禁：vitest 单文件、`cargo test`、Playwright 单个 spec、CTest、Python unittest、流程检查 | 调整后适用 | 上游门禁是 Xcode 测试类（`-only-testing:`）；Windows 端的测试框架不同，目的相同 | `docs/process/DEVELOPMENT-PROCESS.md` |
| T-02 | 集成节点运行完整测试：一组提交后、推送前跑一次全量（`AGENTS.md:219-222`） | 推送前本地跑集成门禁；推送到 `windows_linux2` 后 CI 跑全部任务，作为批准合并的证据 | 调整后适用 | 上游全量测试只在本机跑（CI 只编译，`build.yml:1-7`）；Windows 端大部分检查能在托管运行器上跑，于是放进 CI | `.github/workflows/process.yml`、`.github/workflows/desktop.yml` |
| T-03 | 提交记录所跑的窄门禁（`AGENTS.md:225-226`） | 提交正文写 `Gate:`；改了代码却没有门禁记录的提交，CI 给出警告 | 调整后适用 | 先警告不阻塞：2026-10-01 以来 139 个改代码的提交只有 52 个有这类记录，立即强制会卡住协作者（RFC-W001 §7） | `tools/process/check_process.py` |
| T-04 | 新回归测试先证明能够失败，再证明修复后通过（`AGENTS.md:216-218`；`ARCHITECTURE.md` §9） | 提交写 `Red before:`；PR 模板必填；检查器的 33 个结果代码逐个屏蔽，每个都有测试变红（RFC-W001 §6.2） | 完全适用 | — | `tools/process/tests/test_check_process.py`、`.github/pull_request_template.md` |
| T-05 | 守卫必须能触发，测试要带能复现缺陷的对照（trap 16；`TypingKeyGuardTests` 对照；`check_math_guard.sh`） | 沿用：Vulkan 数学门有故意破坏的对照着色器；检查器的每个结果代码都有必须出现该代码的负向夹具 | 完全适用 | — | `engine/tests/gpu_vulkan_math_gate.cpp`、`engine/tests/math_gate_fault.comp`、`tools/process/tests/test_check_process.py` |
| T-06 | 读耗时，不只读失败数：跳过的套件与完整套件都报 0 失败（trap 26） | 门禁记录写耗时与用例数；CI 中缺少 git 判失败（`SPK_REQUIRE_GIT=1`）；真实宿主测试在环境变量已设而路径无效时失败而非跳过 | 完全适用 | — | `.github/workflows/process.yml`、`desktop/src/export/realhost.test.ts` |
| T-07 | 跳过的检查不能看起来像通过（缺少 `objdump` 时导入检查失败） | 沿用；流程检查无法运行时退出码 2，从不报告通过 | 完全适用 | — | `engine/build-windows-cross.sh`、`tools/process/check_process.py` |
| T-08 | 测试必须隔离共享设置：注入一次性的 `UserDefaults` 套件，不读共享存储（trap 24） | 前端注入设置存储；Rust 测试用临时目录；需要 `APPDATA` 的冒烟测试把它指向临时目录 | 调整后适用 | 平台机制不同（`localStorage`、`%APPDATA%`），原则相同 | `desktop/src/state/settings.ts`、`desktop/agent/smoke.py`、`desktop/src/controls/PanelResize.test.tsx` |
| T-09 | 夹具先复制再打开，相机文件不入库（`AGENTS.md:1025-1027`；`engine/LINUX_WINDOWS.md:173-176`） | 沿用：宿主测试生成自己的 PNG / TIFF / EXR，RAW 先复制到临时目录 | 完全适用 | — | `engine/tests/host_lens.py`、`engine/tests/host_source.py`、`engine/tests/fixtures/windows` |
| T-10 | 不污染用户真实文件：除导出外不写照片文件夹，sidecar 在应用数据目录（`ARCHITECTURE.md` §7.6；trap 35） | 沿用：sidecar 在 `%APPDATA%\app.spektralab.desktop\Sidecars`，旧的同目录 sidecar 首次读取时迁走（与 Mac 相同）；输出路径必须新建，工具拒绝覆盖 | 完全适用 | — | `desktop/src-tauri/src/files.rs`、`engine/tools/windows_preview_smoke.py` |
| T-11 | 已知缺陷用严格的预期失败固定，修复它的提交才能去掉标记（`XCTExpectFailure(strict: true)`，trap 33） | 用 vitest `test.fails` 表达同一语义；目前没有被固定的已知缺陷 | 调整后适用 | XCTest 机制只在 macOS；换成前端测试框架的等价写法 | `docs/process/DEVELOPMENT-PROCESS.md` |
| T-12 | 断言独立事实而不是代码自己的输出（`ColourManagementTests` 手算答案；Metal 为参照） | Vulkan 引擎以 Metal 为参照评分；前端几何测试以手算点对为参照 | 完全适用 | — | `engine/tests/parity_metal_vulkan.py`、`desktop/src/shared/geometry.test.ts` |
| T-13 | 检测工具向引擎询问配置，不自带一份约定（trap 28） | 前端按 `hello` 方法表和 `unsupported_features` 探测能力，不自带假设；但前端没有检查 `hello.protocol`（见 §6） | 完全适用 | — | `desktop/src/panels/gate.ts`、`desktop/src/export/exporter.ts` |
| T-14 | 区分本机执行与外部对照，报告写明是哪一种（`engine/WINDOWS.md`；`desktop/NOTES.md` 把真实宿主与 mock 浏览器的证据分开） | 沿用；PR 模板要求分开写“自动化（mock / lavapipe）”与“人工（真实窗口 / 真实 GPU）” | 完全适用 | — | `desktop/NOTES.md`、`.github/pull_request_template.md` |

### 5.3 一致性与契约（C）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| C-01 | 预览、画布、缩略图和导出结果保持一致：显示画面的表面都显示画布那一帧，用“裁切 + 90° 旋转”测试（trap 33；`ARCHITECTURE.md` §7.7） | 沿用：新表面在 surfaces 测试中加用例 | 完全适用 | — | `desktop/src/shared/surfaces.test.ts`、`desktop/src/shared/geometry.test.ts` |
| C-02 | 导出与画布一致是硬性要求（`modern_UI/Spektrafilm/README.md` §8.1；PRD 规则 5） | 导出保存当前已显示的帧，不重抽颗粒；软打样按文件分辨率 | 完全适用 | — | `desktop/src/export/exporter.test.ts`、`engine/tests/host_proof.py` |
| C-03 | 批量导出锁定当前帧：改变当前帧的操作都检查 `batchExporting`（trap 34） | 沿用：批量导出期间编辑器忽略指针、按键与菜单 | 完全适用 | — | `desktop/src/state/session.ts`、`desktop/src/windows/keys.ts`、`desktop/src/windows/menus.ts` |
| C-04 | 文件整体落盘：先写隐藏的 partial 文件再改名，崩溃不留半个文件（`ARCHITECTURE.md` §7.8） | 沿用：宿主写入走原子写，默认拒绝覆盖 | 完全适用 | — | `engine/host/main.cpp`、`desktop/HOST-PROTOCOL.md` |
| C-05 | 一个工作色彩空间，每个目的地只转换一次；从引擎回复读取解析后的输出空间而非假设（`ARCHITECTURE.md` §7.5；trap 27、28） | 沿用：显示经浏览器色彩管理（Auto / sRGB / P3），导出用 CAM16 映射；预览不构建导出用的表 | 完全适用 | — | `engine/WINDOWS_WIDE_GAMUT.md`、`desktop/src/canvas/colorSpace.ts`、`desktop/src/canvas/colorSpace.test.ts` |
| C-06 | Layer 1（引擎参数）与 Layer 2（画布调整）分开，控件放错层就是速度问题（`ARCHITECTURE.md` §7.2） | 沿用 | 完全适用 | — | `desktop/src/shared/params.ts`、`desktop/src/shared/adjustments.ts` |

### 5.4 UI 参考（UI）

macOS 版的界面是信息架构与视觉语言的参考；具体做法在 Windows 上以平台习惯为准（§5.5）。

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| UI-01 | 以影像画布为中心：三个区域加胶片条，区域互相贴合（`ARCHITECTURE.md` §7.1；`modern_UI/Spektrafilm/README.md` §1；`screenshots/Screenshot_English.png`） | 编辑窗口为左轨、中央画布（顶栏 + 画布 + 胶片条）、右轨 | 完全适用 | — | `desktop/src/windows/EditorWindow.tsx`、`desktop/src/canvas/Canvas.tsx` |
| UI-02 | 左侧功能轨“Film and Print”：导航图、设置剪贴板、胶片、片边、日期、相纸、裁切、放大机 | 同样的分区与顺序 | 完全适用 | — | `desktop/src/panels/LeftRail.tsx`、`desktop/src/panels/StockList.tsx` |
| UI-03 | 右侧参数轨“Parameters”，分显影前（引擎）/ 显影后（Layer 2）两页 | 同样的两页与分区 | 完全适用 | — | `desktop/src/panels/RightRail.tsx` |
| UI-04 | 底部胶片条：整张照片、裁切外 82% 遮罩、拖动排序、顺序按文件夹保存 | 同样；指针手势代替 HTML5 拖放（Windows 文件拖放处理器会吞掉后者） | 完全适用 | — | `desktop/src/windows/Filmstrip.tsx`、`desktop/src/windows/frameDrag.ts`、`desktop/src/state/frameOrder.ts` |
| UI-05 | 清晰的功能分区：控件在哪条轨就说明移动它的代价（`ARCHITECTURE.md` §7.1“Which rail a control is on says what moving it costs”） | 同样的分区规则；新控件按代价放置 | 完全适用 | — | `desktop/src/panels/LeftRail.tsx`、`desktop/src/panels/RightRail.tsx` |
| UI-06 | 深色摄影工作环境，克制的颜色和层级：中灰底、深色轨、唯一强调色、1 pt 分隔线（`Theme.swift` 令牌） | 令牌从 `Theme.swift` 移植 | 完全适用 | — | `desktop/src/styles/theme.css` |
| UI-07 | 原图 / 处理后对比：“Original”按钮，按住空格看解码原图 | 同样 | 完全适用 | — | `desktop/src/windows/TopBar.tsx`、`desktop/src/canvas/Canvas.tsx` |
| UI-08 | 滑动对比：Before / After 分割线可拖动（`screenshots/natural_halation.png`） | 同样，Y 键切换 | 完全适用 | — | `desktop/src/canvas/Canvas.tsx`、`desktop/tests/e2e/preview.spec.ts` |
| UI-09 | 100% 查看：100% 等于一个设备像素；颗粒在 1:1 下检查 | 100% 按物理像素计算，跟随 `devicePixelRatio` | 完全适用 | — | `desktop/src/canvas/Canvas.tsx`、`desktop/src/canvas/zoom.ts`、`desktop/src/canvas/zoom.test.ts` |
| UI-10 | 缩放与导航：导航图显示裁切后的输出与可见区域，点击拖动平移；围绕指针缩放 | 同样 | 完全适用 | — | `desktop/src/panels/LeftRail.tsx`、`desktop/tests/e2e/wheel-zoom.spec.ts` |
| UI-11 | 预览分辨率与全分辨率状态提示：编辑后 400 ms 开始原尺寸渲染，落地前显示 preview，之后显示 full（`ARCHITECTURE.md` §7.3） | 同样的徽标与时序；另有导入预览进度 | 完全适用 | — | `desktop/src/canvas/Canvas.tsx`、`desktop/src/windows/PreviewBuildStatus.tsx`、`desktop/src/state/session.ts` |
| UI-12 | 批量选择：当前照片与选中集合分开，⌘-点击增减，⌘A 全选，同步到 N 张（`README.md` “Select and sync photos”） | Ctrl-点击、Ctrl+A；缺少 Shift-点击范围选择（W-08） | 完全适用 | — | `desktop/src/state/session.ts`、`desktop/src/windows/Filmstrip.tsx` |
| UI-13 | 每张照片独立状态：每帧一个 sidecar，移动或改名后靠指纹认回（`ARCHITECTURE.md` §7.6） | 同样格式的 sidecar；Windows 用文件 ID 认回移动的文件 | 完全适用 | — | `desktop/src-tauri/src/files.rs`、`desktop/src/shared/sidecar.ts`、`desktop/src/shared/sidecar.test.ts` |
| UI-14 | 参数变化成本明确：重新解码、引擎渲染、只重绘一次各有其位置（`ARCHITECTURE.md` §7.1 代价表） | 同样的分区；预览构建状态显示正在做什么 | 完全适用 | — | `desktop/src/windows/PreviewBuildStatus.tsx`、`desktop/src/state/previewQueue.ts` |
| UI-15 | 界面在长任务中保持响应：渲染合并（发送 / 需要）、过期结果丢弃、批量导出逐张可取消 | 同样；引擎在独立进程，超时、重启与租约防止界面卡死 | 完全适用 | — | `desktop/src/state/previewQueue.ts`、`desktop/src-tauri/src/host.rs`、`desktop/tests/e2e/preview-switch.spec.ts` |
| UI-16 | 界面显示内容与最终导出内容一致 | 见 C-01、C-02 | 完全适用 | — | `desktop/src/shared/surfaces.test.ts`、`desktop/src/export/exporter.test.ts` |
| UI-17 | （本次任务要求）不得直接复制 SpektraLab 的品牌、图标、商标、专用素材或产品名称 | 本项目就是 SpektraLab 仓库自己的 Windows 分支，名称与应用图标归仓库所有者，继续使用；不把 Apple 平台专属素材搬到 Windows（SF Symbols 已改为自绘 SVG）；第三方商标（胶片包装封面）与 spektrafilm 名称的使用列为待处理问题（§6） | 调整后适用 | 这条要求针对“另做一个产品”；评估后本项目不是另一个产品。真正需要遵守的是 Apple 素材许可、第三方商标和 spektrafilm 许可中“名称不在授权范围”的要求 | `desktop/src/controls/icons.tsx`、`desktop/scripts/copy-assets.mjs`、`desktop/src-tauri/tauri.conf.json` |
| UI-18 | 本地化：英文与简体中文，胶片与相纸名称不翻译，字符串从 Swift 源生成 | 同样 | 完全适用 | — | `desktop/src/i18n/en.json`、`desktop/src/i18n/zh-Hans.json`、`desktop/scripts/extract-strings.mjs` |
| UI-19 | 布局按参考图实测（SVG 数值 ÷ 2，误差 2 pt；`measure-layout.swift`） | 令牌从 `Theme.swift` 移植；用 Playwright 布局与交互用例守护 | 调整后适用 | 参考图不在仓库（`.gitignore:334-335`），Windows 无法跑 Swift 测量工具；以已移植的令牌和端到端用例为准 | `desktop/src/styles/theme.css`、`desktop/tests/e2e/editor.spec.ts`、`desktop/playwright.config.ts` |

### 5.5 Windows 平台习惯（W）

上游迁移计划已经规定标题栏、快捷键、安装程序和权限采用 Windows 原生做法，不照搬 Apple（`engine/WINDOWS_FULL_MIGRATION_PLAN.md` §4）。本节逐项核对。

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| W-01 | 窗口行为（macOS：AppKit 窗口、自绘红绿灯按钮） | 系统窗口：Snap、最小 1100×680、单实例（第二次启动把文件交给已有窗口）、记住窗口位置 | 调整后适用 | 按 Windows 窗口习惯；自绘按钮会丢失 Snap Layouts 与无障碍 | `desktop/src-tauri/tauri.conf.json`、`desktop/src-tauri/src/lib.rs` |
| W-02 | 菜单习惯（macOS 菜单栏，菜单先于文本框收到按键，trap 32） | 原生菜单，`&` 助记符；WebView2 持有键盘，菜单只显示快捷键文字 | 调整后适用 | Windows 菜单约定与 WebView2 的键盘模型不同 | `desktop/src/windows/menus.ts` |
| W-03 | 文件选择器（macOS 打开面板、Finder 拖入） | 系统文件 / 文件夹对话框；资源管理器拖入；NSIS 注册 RAW / TIFF 关联 | 调整后适用 | 使用 Windows 系统对话框 | `desktop/src/platform/tauri.ts`、`desktop/src/shared/fileTypes.ts` |
| W-04 | 快捷键（⌘ 组合；Capture One 单键工具） | Ctrl 组合；增加 Ctrl+Y 重做、F11 全屏，Alt+F4 由系统处理；单键工具保留并在文本框中让位；Ctrl+Q、Ctrl+, 来自 macOS 习惯，需在 PRD 中复核 | 调整后适用 | 修饰键与重做、全屏按 Windows 习惯；单键工具是产品自身的操作模型 | `desktop/src/windows/keys.ts`、`desktop/src/windows/keys.test.ts` |
| W-05 | 标题栏（macOS：工具条与标题合并的全尺寸内容视图） | 使用系统标题栏，标题为“SpektraLab — 文件夹名”，macOS 的顶栏布局放在其下 | 调整后适用 | 自绘标题栏会丢失 Snap、DPI 处理与无障碍（`desktop/NOTES.md`） | `desktop/NOTES.md`、`desktop/src-tauri/tauri.conf.json` |
| W-06 | 高 DPI（macOS 以点为单位，Retina 自动处理） | 跟踪 `devicePixelRatio`，窗口跨显示器移动或缩放变化时重新测量；另有界面缩放 100/115/130% | 调整后适用 | Windows 每显示器 DPI 需要显式处理；真实多显示器与 125%/150% 缩放尚未验收（§6） | `desktop/src/canvas/Canvas.tsx`、`desktop/src/state/settings.ts` |
| W-07 | 触控板和鼠标（macOS：捏合缩放、双指滚动） | 滚轮无修饰键时围绕指针缩放（Capture One 习惯），Ctrl+滚轮按捏合速度缩放，中键或手形工具平移 | 调整后适用 | 精确式触控板的双指滑动目前也被当作缩放、横向位移被忽略，与 Windows 习惯（双指平移、捏合缩放）不符，列为待决问题（§6） | `desktop/src/canvas/Canvas.tsx`、`desktop/tests/e2e/wheel-zoom.spec.ts` |
| W-08 | 多选习惯（macOS ⌘-点击） | Ctrl-点击切换；缺少 Shift-点击范围选择 | 调整后适用 | Windows 用户预期 Shift 范围选择；记为缺口（§6） | `desktop/src/windows/Filmstrip.tsx` |
| W-09 | 不能为了视觉上模仿 macOS 而破坏 Windows 平台习惯（本次任务要求；与 `engine/WINDOWS_FULL_MIGRATION_PLAN.md` §4 一致） | PRD 模板必须填写“Windows 平台习惯”一节；真实窗口检查列出缩放比例与显示器 | 完全适用 | — | `docs/prd/TEMPLATE.md`、`docs/process/DEVELOPMENT-PROCESS.md` |
| W-10 | 标准位置存放应用数据（macOS：`~/Library/Application Support`、`Caches`、`Logs`） | sidecar、导出配方、代理文件在 `%APPDATA%\app.spektralab.desktop`，界面设置在 WebView2 的 localStorage，缓存与日志在本地应用数据目录；命令行包装器装到 `%USERPROFILE%\.local\bin` 属 Unix 习惯（§6） | 调整后适用 | Windows 有自己的标准目录 | `desktop/src-tauri/src/lib.rs`、`desktop/src-tauri/src/agent_files.rs`、`desktop/src-tauri/src/diagnostics.rs` |
| W-11 | 路径与编码（macOS 无此类问题） | 宽字符 API，`\\?\` 长路径，中文路径冒烟测试 | 调整后适用 | Windows 特有：非 ASCII 安装目录曾导致启动失败 | `engine/tests/resource_paths.cpp`、`engine/tests/host_source.py` |

### 5.6 性能、内存、缓存、导出、色彩与诊断（M）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| M-01 | 先测量再声明；机器不是基准，交替测量，引用数字时说明负载（trap 17） | 沿用；测量记录写日期、commit、硬件、驱动、方法、轮数 | 完全适用 | — | `engine/tools/windows_performance.py`、`docs/prd/TEMPLATE.md` |
| M-02 | 内存用 `footprint -p` 测，RSS 看不到 Metal 池（`AGENTS.md` Conventions） | Windows 指标：进程提交量（私有提交）、工作集、GPU 账本、整卡 GPU 占用，四者分开报告，不能相加 | 调整后适用 | `footprint` 只有 macOS；Windows 没有单一等价工具，按 `engine/WINDOWS_MEMORY.md:75-80` 分开报告 | `engine/WINDOWS_MEMORY.md`、`engine/tests/host_memory.py` |
| M-03 | 一次只做一个全分辨率渲染，导出逐张进行（`ARCHITECTURE.md` §4、§7.8） | 沿用；暂存缓冲每方向 ≤64 MiB，空闲 5 s 回收，批量导出时编辑器缓存挂起到临时文件 | 完全适用 | — | `engine/WINDOWS_MEMORY.md`、`engine/tests/host_memory.py` |
| M-04 | 缓冲“空闲且闲置”才复用、节点边界刷新（trap 19；`ARCHITECTURE.md` §8.3） | 共享引擎规则，Vulkan 后端同样遵守 | 调整后适用 | 只约束共享引擎的 GPU 层，与 Windows 前端和流程无关 | `engine/src/gpu` |
| M-05 | 磁盘缓存是可丢弃的：删了只损失速度（`ARCHITECTURE.md` §4、§7.6）；缓存键要在引擎版本可知之后才构建（`modern_UI/Spektrafilm/README.md` §8.1） | 显示缓存键包含文件身份、纳秒修改时间与引擎指纹；命中不等于完成解码，缓存像素不用于导出 | 完全适用 | — | `desktop/src-tauri/src/frame_cache.rs`、`desktop/src/state/displayCache.test.ts` |
| M-06 | 导出带色彩标签，输出转换一次完成（`ARCHITECTURE.md` §7.5 第 7b 行） | 宿主内嵌固定的 sRGB ICC 与各导出空间的 ICC；软打样与文件一致 | 完全适用 | — | `engine/resources/io/README.txt`、`engine/tests/host_proof.py` |
| M-07 | 诊断：会话日志可设保留期（`ARCHITECTURE.md` §7.6），诊断包匿名化文件名与路径（main `PRD/PRD-v1.4.0.md` §0.1），计时仪表不得删除（`AGENTS.md` “Do not”） | 日志轮转（7 天 / 100 MB / 20 个文件），诊断 ZIP 默认省略路径；`SPEKTRAFILM_TRANSFER_TIMINGS` 等开关 | 调整后适用 | macOS 的 `Session.LoadClock` 与 `SPEKTRAFILM_CANVAS_LOG` 属 Swift 应用；Windows 端用宿主与 Rust 的对应机制 | `desktop/src-tauri/src/diagnostics.rs`、`desktop/src/windows/diagnosticReport.ts`、`desktop/src/windows/diagnosticReport.test.ts` |
| M-08 | 不经用户不联网：只有用户按下的更新检查（`ARCHITECTURE.md` §5；PRD 规则 8） | 同样：点击才检查，匿名，CSP 只放行 api.github.com | 完全适用 | — | `desktop/src/windows/updateCheck.ts`、`desktop/src/windows/updateCheck.test.ts`、`desktop/src-tauri/tauri.conf.json` |
| M-09 | 计时测完整调用，节点计时只在显式开关下才有意义（`ARCHITECTURE.md` §8.9） | 三进程 × 首次 + 5 次热调用，新旧交替，诊断关闭（`engine/WINDOWS_WIDE_GAMUT.md:123-128`） | 完全适用 | — | `engine/tools/windows_performance.py`、`engine/WINDOWS_WIDE_GAMUT.md` |
| M-10 | 不为速度降低质量，不悄悄放宽容差（`engine/WINDOWS_NATIVE_RAW.md`；JPEG Q96–100 保留旧编码器） | 沿用 | 完全适用 | — | `engine/tests/parity_metal_vulkan.py`、`engine/tests/image_writer_test.cpp` |

### 5.7 构建、打包、许可、签名与发布（B）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| B-01 | 构建有可复现脚本，工程文件由生成器确定性生成（`engine/build.sh`、`Tools/gen-project.py`） | 引擎：`build-linux.sh`、`build-windows-cross.sh`、`build-windows.ps1`；前端：`npm ci` + 锁文件、`cargo --locked` | 调整后适用 | Windows 原生构建依赖手工准备的 `..\deps`（cmake、glslang、Vulkan-Headers），尚无脚本（§6） | `engine/build-linux.sh`、`engine/build-windows-cross.sh`、`engine/build-windows.ps1`、`desktop/package-lock.json` |
| B-02 | 依赖按版本与 SHA 固定，校验不符就拒绝而不是修复，CMake 不下载 | 沿用 | 完全适用 | — | `engine/setup-deps.sh`、`engine/setup-libraw.ps1`、`engine/cmake/input-codecs-pins.json`、`engine/cmake/lens-codecs-pins.json` |
| B-03 | 发出去的就是测过的：用打包后的资源再跑检查（`AGENTS.md:189-197`；`check-bundle-resources.sh`） | CI 在真实 Windows 上静默安装安装包，再问已安装的宿主 `hello` | 调整后适用 | 机制不同（安装包而非 .app 包）；目前不检查安装目录里的许可文件（§6 第 25 条） | `.github/workflows/desktop.yml`、`.github/scripts/host_hello.py` |
| B-04 | 许可文本随包，并测试其内容与 About 面板读取路径（`bundle-licenses.sh`、`LicensingTests`） | 宿主的第三方声明由 `stage-host.sh` 汇集，缺文件即失败 | 调整后适用 | Windows 端尚无内容测试；About 面板显示的是 macOS 的 README，随包还带着用不到的 metal-cpp 许可（§6 第 13 条） | `engine/stage-host.sh`、`desktop/scripts/copy-assets.mjs` |
| B-05 | 不引入与 GPL 不兼容的依赖（`AGENTS.md` “Do not”） | 沿用；RFC 的影响评估必须写新依赖的许可证 | 完全适用 | — | `engine/LINUX_WINDOWS.md`、`docs/rfc/TEMPLATE.md` |
| B-06 | 签名、公证、Gatekeeper 验证（`Tools/package.sh`：Developer ID → notarytool → spctl） | 不采用 macOS 机制；Windows 等价物（Authenticode 代码签名）尚未实现 | 经评估后不适用 | macOS 专属；Windows 签名方案是待决问题（RFC-W001 §10），当前安装包未签名 | `desktop/docs/WINDOWS-INSTALLER.md` |
| B-07 | 版本号只在一处定义（`gen-project.py` 的 `MARKETING_VERSION`） | Windows 版本号在三个文件中，必须一起改 | 调整后适用 | Tauri 的版本号分布在 npm、Tauri 配置与 Cargo 三处 | `desktop/package.json`、`desktop/src-tauri/tauri.conf.json`、`desktop/src-tauri/Cargo.toml` |
| B-08 | CI 只做本地看不到的事：干净检出能否构建（`build.yml:1-7`） | 沿用并扩展：干净检出的构建、测试、打包、安装都在 CI | 调整后适用 | Windows 端的测试不依赖相机样片和 Mac GPU，能在托管运行器上跑，因此 CI 做得比上游多 | `.github/workflows/desktop.yml`、`.github/workflows/process.yml` |
| B-09 | 发布有端到端脚本（`package.sh`：归档 → 导出 → 校验 → DMG → 公证） | NSIS / .deb / AppImage 由脚本生成；发布上传与便携 ZIP 仍是手工 | 调整后适用 | 平台不同；发布自动化尚缺（§6） | `desktop/scripts/package.mjs`、`desktop/scripts/build-agent.mjs` |
| B-10 | 导入白名单：Windows 可执行文件只能导入系统 DLL，检查工具缺失即失败 | 沿用 | 完全适用 | — | `engine/build-windows-cross.sh` |
| B-11 | 构建证据清单：工具链、源码、着色器、产物哈希（`toolchain.json`） | 沿用；清单尚不含 `engine/host/` 源码与宿主可执行文件的哈希（§6） | 调整后适用 | 现有清单覆盖不全，补齐前不能当作宿主构建的完整证据 | `engine/build-windows.ps1` |
| B-12 | 打包前从干净工作区重新生成源码与许可清单，个人照片、日志不进包（`engine/WINDOWS_MIGRATION_VALIDATION_20261018.md`） | 沿用为人工步骤；PR 模板列出不得提交的内容 | 调整后适用 | 上游的打包脚本不在仓库，只能作为人工检查 | `.github/pull_request_template.md`、`docs/process/DEVELOPMENT-PROCESS.md` |

### 5.8 协作与 Git（G）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| G-01 | Windows 与 Linux 的工作只进 `Windows_Linux`，不进 `main`（`README.md:138-140`） | 沿用；先推到暂存分支 `windows_linux2`，批准后合并进 `Windows_Linux` | 完全适用 | — | `docs/process/DEVELOPMENT-PROCESS.md` |
| G-02 | 拆成可审阅的提交，一个提交一件事，说明做了什么和为什么（`README.md:141-144`） | 沿用；PR 模板要求 | 完全适用 | — | `.github/pull_request_template.md` |
| G-03 | 尊重开源社区：保留许可与致谢（`README.md:145-146`） | 沿用 | 完全适用 | — | `license/LICENSE`、`license/SPEKTRAFILM_LICENSE.txt`、`CITATION.cff` |
| G-04 | 未经要求不提交、不推送（`AGENTS.md` “Do not”；`engine/WINDOWS_MEMORY.md` 末尾） | 按用户指示：本地验证后推送到 `windows_linux2`；合并进 `Windows_Linux` 必须等负责人批准 | 调整后适用 | 用户明确要求推送暂存分支；合并仍需批准 | `docs/process/DEVELOPMENT-PROCESS.md` |
| G-05 | 不 rebase、不强推对方可能已读的分支；不在仓库根目录 stash / clean（`CONTRACT-frontend-backend.md` §4.1） | 沿用 | 完全适用 | — | `docs/process/DEVELOPMENT-PROCESS.md` |
| G-06 | 前后端文件所有权划分（`CONTRACT-frontend-backend.md` §4） | 不按 FE / BE 划分目录；保留其仍有效的部分：宿主协议归后端，前端只追加请求 | 调整后适用 | 上游已说明 §4 是历史，不再分派任何东西（`AGENTS.md:57-62`） | `desktop/PROTOCOL-REQUESTS.md`、`desktop/HOST-PROTOCOL.md` |
| G-07 | 合并 main 时按模块合并，先保留本地工作，按内容而非提交数比较（`engine/WINDOWS_FULL_MIGRATION_PLAN.md:16`） | 沿用 | 完全适用 | — | `engine/WINDOWS_FULL_MIGRATION_PLAN.md` |
| G-08 | 外部补丁要审查，不继承其声明（`engine/PORT_NOTES.md` 关于外部 FMA 补丁的记录） | 沿用；协作者分支的改动按模块审阅后再并入 | 完全适用 | — | `engine/PORT_NOTES.md` |

### 5.9 胶片模型专属规则（F）

本节逐条评估“只属于胶片模拟模型”的业务约束。本项目与 macOS 版共用同一个引擎和胶片数据，所以这些规则对**共享引擎与资源**仍然有效；对 Windows 前端、宿主协议和流程则不适用，不机械照搬。

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| F-01 | 不为修渲染问题去污染材料模型：配置描述测得的能力，不是控制面（`AGENTS.md:17-23`） | 只在修改 `engine/src`、`engine/resources*` 时适用 | 调整后适用 | 约束共享引擎与数据；Windows 前端与流程不涉及材料模型 | `engine/resources/profiles`、`engine/resources_product/NOTICE.md` |
| F-02 | 固定实验设置：Portra 400 + Portra Endura，1 MP 冒烟图，45 MP NEF（`AGENTS.md` “Fixed experimental setup”） | 不采用；Windows 使用自带的合成夹具与开发者自己的 RAW | 经评估后不适用 | 所列样片不在仓库，路径是作者的 Mac；Windows 测试自己生成输入 | `engine/tests/fixtures/windows`、`engine/tests/host_smoke.py` |
| F-03 | 用 Python 参考实现（`PYTHONPATH` 指向作者机器上的 fork）跑 parity 套件（`AGENTS.md` “The engine”） | 不在 Windows 上采用；改用 Mac 上的 Vulkan 对 Metal 对照，以及本地 float64 / 解析参照的内核门 | 经评估后不适用 | 参考实现与 Mac dylib 都不在 Windows；对照方式由 `engine/LINUX_WINDOWS.md` §7 规定 | `engine/tests/parity_metal_vulkan.py`、`engine/tests/gpu_vulkan_pointwise.cpp` |
| F-04 | 内核使用安全数学，数学探针能拒绝快速数学（`engine/build.sh` 的 Metal 选项；`check_math_guard.sh`） | Vulkan 的等价物：FMA 门与 split product，带故意破坏的对照 | 调整后适用 | Metal 选项只在 macOS；Vulkan 有自己的门 | `engine/tests/gpu_vulkan_math_gate.cpp`、`engine/tests/math_gate_fault.comp` |
| F-05 | 渲染对照门槛实测而定，不收紧到 float32 epsilon，不放宽（`ARCHITECTURE.md` §8.6，3e-5） | 跨后端门槛以 8 位码值表示（最大 ≤1、平均 ≤0.01、CIEDE2000），并配负向对照 | 调整后适用 | 对照对象从 Python 参考变成 Metal，单位随之改变 | `engine/tests/parity_metal_vulkan.py` |
| F-06 | 不改光谱形状（81 × 5 nm）、配置数据与对数曝光轴；共享引擎实现陷阱（trap 20、21、22） | 只在修改共享引擎时适用 | 调整后适用 | 约束共享引擎；Windows 前端与流程不涉及 | `engine/src/core` |
| F-07 | 逐像素比较前关闭随机效果（颗粒、眩光）（trap 1） | 精确比较关闭颗粒、眩光与自动曝光；默认效果用分布或行为检查 | 完全适用 | — | `engine/WINDOWS.md`、`engine/tests/gpu_vulkan_grain.cpp` |
| F-08 | 胶片与相纸配置、放大 LUT 为 CC BY-SA 4.0：不修改原文件，修改记入 CHANGELOG，各处保留署名 | 沿用；宿主随包携带许可文本 | 完全适用 | — | `license/SPEKTRAFILM_LICENSE.txt`、`engine/stage-host.sh` |
| F-09 | 产品只编辑物理过程，不做打印后的润饰（`ARCHITECTURE.md` §7.4） | 沿用为产品定位 | 完全适用 | — | `desktop/src/panels/RightRail.tsx` |
| F-10 | 新增胶片的流程：配置 JSON、中性滤镜行、片边、目录、测试、研究记录（`PRD-v1.4.0.md` §4.2；RFC-022 求解器） | Windows 不新增胶片，目录在构建时从 macOS 资源复制 | 经评估后不适用 | 胶片目录由共享资源与 Mac 端生成器维护；Windows 只消费 | `desktop/scripts/copy-assets.mjs` |

### 5.10 macOS 专属机制（X）

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| X-01 | 增删源文件后运行 `Tools/gen-project.py` 重新生成 Xcode 工程 | 不采用 | 经评估后不适用 | Xcode 专属；Windows 端用 CMake、npm 与 Cargo，不需要生成工程文件 | —（Xcode 专属） |
| X-02 | 离屏截图看不到 `CAMetalLayer`，只有真实窗口截图能证明画布在绘制（`AGENTS.md:265-291`；`capture-live.sh`） | 原则采用：Playwright（mock host）之外，界面改动要在 Windows 真实窗口检查，PR 写明缩放与显示器 | 调整后适用 | 工具是 macOS 的；原则平台无关 | `docs/process/DEVELOPMENT-PROCESS.md`、`.github/pull_request_template.md` |
| X-03 | AppKit 先把按键交给菜单，单键快捷键会在文本框里触发（trap 32，`TypingKeyGuard`） | 同一问题在 WebView 中的守卫：单键不注册为菜单加速键，文本框中让位 | 调整后适用 | 机制不同，问题相同 | `desktop/src/windows/keys.ts`、`desktop/src/windows/keys.test.ts` |
| X-04 | `@Observable` 中自赋值的 `didSet` 会无限递归（trap 25） | 不采用 | 经评估后不适用 | Swift 专属，Windows 端没有 Swift 代码 | —（Swift 专属） |
| X-05 | `kCGImageDestinationEmbedThumbnail` 对 TIFF 无效，预览要按页读取（trap 29） | 不采用其机制；TIFF 预览页由宿主自己写 | 经评估后不适用 | ImageIO 专属 | `engine/host/tiff_ifd.cpp` |
| X-06 | “Releases are ad-hoc zips … do not re-propose”（`AGENTS.md:1032-1033`） | 不采用 | 经评估后不适用 | macOS 发布方式，且已与 README、PRD 所述的签名公证 DMG 矛盾（§6） | —（macOS 发布方式） |
| X-07 | 引擎数据从应用包里解析，回退到检出目录时可能读到过期数据（trap 14） | 同类风险：宿主按 `SPEKTRALAB_HOST_DIR`、随包目录、检出目录的顺序寻找；PR 中写明测的是哪一份 | 调整后适用 | 解析顺序不同，风险相同 | `desktop/src-tauri/src/host.rs`、`engine/tests/resource_paths.cpp` |

<!-- audit-counts: total=110 full=60 adjusted=42 na=8 -->

## 6. 发现的偏差与待处理问题

审计中发现、本次**没有修改**的问题。它们涉及产品代码或别人负责的文档，按流程应由负责人在各自的提交中处理；规范同步规则（`sync:*`）只检查今后的改动，不会因下列历史偏差让 CI 变红。

**规范与代码不同步**

1. 以下 `params_delta` 字段在 `engine/src/core/params.cpp` 的 `kFields` 中存在，但字段名在 `API-SPEC-callable-render-service.md` 中没有出现：`glare_amount`、`grain_amount`、`strip_budget_bytes`、`extended_dynamic_range`、`digital_intermediate`；`auto_exposure_method` 只记在 `CONTRACT-frontend-backend.md` §6。
2. C ABI 只在 `engine/include/spektrafilm/spk_engine.h` 的注释里有完整记录：声明的 29 个 `spk_*` 函数中 API-SPEC 点名 12 个，其余 17 个（包括 `spk_render`、`spk_solve`、`spk_cancel`）在 API-SPEC、CONTRACT、ARCHITECTURE 里都没有出现。上游没有要求 C ABI 写进 API-SPEC 的规则，这一条只是记录，供负责人判断是否需要一份 C ABI 目录。
3. `no_film` 与 `hello.frame_options` 写进了 `API-SPEC-callable-render-service.md` §19（宿主侧提交 `445e314`），但 `desktop/HOST-PROTOCOL.md` 没有记录（宿主的 `frame_options` 广播见 `engine/host/main.cpp:443-444`，前端侧提交 `f40ff32`）；`desktop/PROTOCOL-REQUESTS.md:76` 的 R4 仍标记 `[open]`。
4. API-SPEC 的小节编号在两个分支间不同（CineStill 在 `main` 是 §16，在 `Windows_Linux` 是 §18），代码注释按 Windows_Linux 的编号引用。
5. 前端从不检查 `hello.protocol`（`desktop/src/shared/protocol.ts:84` 只有类型），宿主协议若有破坏性变更，只会表现为方法缺失或数据错误。

**文档自相矛盾或过时**

6. `engine/PORT_PLAN.md:3-9`、`engine/PORT_COVERAGE.md`、`engine/WINDOWS_FEATURE_COVERAGE.md` 仍说五项功能被拒绝；`engine/WINDOWS_FULL_MIGRATION_PLAN.md` §8 与代码（`engine/src/pipeline/engine.cpp:355-360` 只拒绝 `contrast_mask`）表明只剩对比度蒙版。mock 宿主仍拒绝 `overscan` 与 `date_imprint`（`desktop/mock-host/core.ts:116-120`），因此基于 mock 的测试看到的片边与日期是禁用状态。
7. `engine/WINDOWS.md:169` 写“34 registered kernels”，`engine/CMakeLists.txt:136-150` 列出 48 个。
8. `README.md:130-131`、`README.zh-CN.md:90` 仍把 Qt Quick 前端介绍为 Windows 编辑器；现行编辑器是 `desktop/`（`engine/WINDOWS.md:78`）。`engine/WINDOWS.md:79` 链接的 `desktop/README.md` 不存在。
9. `desktop/PARITY.md` 约七行已过时（镜头校正、磁盘缓存、移动文件识别、软打样、显示配置、被拒绝的功能等），`engine/WINDOWS_FULL_MIGRATION_PLAN.md:18` 也承认。
10. `AGENTS.md:1032-1033` 说发布是 ad-hoc zip、不用 Developer ID；`README.md` 与 `PRD-v1.4.0.md` §1.1 说自 1.3.3 起是签名并公证的 DMG。`AGENTS.md:62-68` 与 `AGENTS.md:1048-1050` 关于谁能改规范文档的说法相反（见 P-10）。
11. `CITATION.cff` 的版本为 0.3，描述只有 macOS。
12. 多份验证记录引用本机路径 `D:/SpektraLab-win/...`（`engine/WINDOWS_FULL_MIGRATION_PLAN.md`、`engine/WINDOWS_MIGRATION_VALIDATION_20261018.md`、`engine/WINDOWS_WIDE_GAMUT.md`、`desktop/NOTES.md`），证据不在仓库，协作者无法复现。

**许可与商标**

13. Windows 的 About 对话框显示 macOS 的 `README.txt`（其中写“native macOS application”），并把用不到的 metal-cpp 许可也一起打包（`desktop/scripts/copy-assets.mjs:16-19`、`desktop/src/windows/Dialogs.tsx:235-237`），宿主的第三方声明（LibRaw、Lensfun、GLib、编解码器）没有在界面上出现；npm 与 crate 依赖没有汇总声明。
14. `desktop/package.json:10` 与 `desktop/src-tauri/tauri.conf.json:51` 的 `homepage` 是 `https://github.com/spektrafilm`，既不是本仓库也不是上游（andreavolpato/spektrafilm）；spektrafilm 许可的前言要求不要把 spektrafilm 名称用于产品品牌。
15. `engine/stage-host.sh:10` 把 `license/SPEKTRAFILM_LICENSE.txt` 标为“spektrafilm (upstream engine), GPL-3.0”，该文件实际是配置与 LUT 的 CC BY-SA 4.0 许可。
16. 胶片封面图是厂商包装（带 Kodak / Fujifilm 商标与外观），且 `kodak_portra_400.jpg` 与 `kodak_gold_200.jpg` 字节完全相同（`modern_UI/Spektrafilm/Spektrafilm/Resources/FilmCovers/`），Portra 400 显示的是 Gold 200 的盒子。

**Windows 平台习惯的缺口**

17. 胶片条没有 Shift-点击范围选择（`desktop/src/windows/Filmstrip.tsx`）。
18. 精确式触控板的双指滑动被当作缩放，横向位移被忽略（`desktop/src/canvas/Canvas.tsx:479`）。
19. 退出用 Ctrl+Q、设置用 Ctrl+,（`desktop/src/windows/menus.ts:81-83`），来自 macOS 习惯；命令行包装器装到 `%USERPROFILE%\.local\bin`（`desktop/src-tauri/src/agent_files.rs:55`）。
20. 高 DPI（125% / 150%）、多显示器、广色域与 10 位显示链、非 NVIDIA GPU 尚未在真实硬件上验收（`engine/WINDOWS_FULL_MIGRATION_PLAN.md` §6）。

**构建、CI 与发布**

21. Windows 安装包与可执行文件未签名（`desktop/docs/WINDOWS-INSTALLER.md:91`）；没有卸载与升级测试；`.deb` / AppImage 没有安装测试；产物只保留 14 天、不发布。
22. 原生 Windows 构建依赖手工准备的 `..\deps`（cmake 3.25、glslang、Vulkan-Headers），没有对应的准备脚本；`engine/build-windows.ps1` 会到 MATLAB 安装目录里找 cmake。
23. `engine/build-windows.ps1` 写出的 `toolchain.json` 不含 `engine/host/` 源码与 `spektralab-host.exe` 的哈希。
24. 推送到 `Windows_Linux` 不会触发 macOS 编译（`build.yml` 只监听 `main`），在本分支修改共享引擎可能悄悄破坏 Mac 构建，直到开 PR 才发现。
25. CI 静默安装后只检查应用、宿主与引擎资源是否装上（`.github/workflows/desktop.yml` 的 `package-windows`），不检查安装目录里的许可与第三方声明。
