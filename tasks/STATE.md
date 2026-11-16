# 当前状态

更新时间：2026-11-15。此文件是接续入口；未运行的项目不记为通过。

## 基线与位置

- 根目录：E:/user/ChatGPT/SPEKTRAlab。
- 工作目录：E:/user/ChatGPT/SPEKTRAlab/.claude/worktrees/windows-port。
- 分支：codex/windows-native；基线 87de3b6c837f9e21ad67924c50b169b3bacbfc5e。
- 当前功能集尚未推送、合并或发布。

## 当前实现

- 库：持久目录、链接文件夹、搜索/排序、评级、色标、收藏、回收站；每条目录记录有独立编辑状态。
- 编辑：变体、135 半格双联、裁切/方向/拉直、逐图撤销重做、重启恢复、批量选择与同步设置。
- 引擎特效：场景宽容度、contrast mask、Cineon DI、场景蒙版、scan HDR、片边/日期后背/漏光、柔光滤镜和镜头像差，均通过 Windows Vulkan 后端执行。
- 输出：TIFF16、PNG8/16、JPEG8、HEIF8；sRGB、Display P3、Adobe RGB、ProPhoto RGB；导出配方和被显示画面的不可变导出。
- 跨后端对照：`windows_fixture.py` 提供 `default` 与 `core` 两种确定性 fixture；`windows_python_reference.py` 从 public `spektrafilm` 生成同输入参考，`compare` 校验输入、参数、资源哈希和数值门禁。

## 已核实

- 依赖已固定：Qt 6.11.3、MinGW 13.1.0、CMake 3.25.0、LibRaw 0.22.2、Vulkan-Headers 固定 tag、glslang 16.6.0（含 commit 与 SHA-256）。
- Debug 全目标构建通过；Release 干净配置、全目标构建和部署通过，产物为 build/qt-release-final/app/SpektraLabQt.exe。
- Debug CTest：18/18 通过，0 失败，34.22 秒；Release CTest：18/18 通过，0 失败，39.64 秒。设备为 NVIDIA GeForce RTX 3060 Laptop GPU，驱动 617.42。
- spk_windows_feature_boundaries 实际渲染并检查 latitude、DI、contrast mask、片边、日期后背、漏光、柔光滤镜、镜头像差、scan HDR 和场景蒙版。
- 真实 RAW 编辑闭环：Debug 与 Release 都通过 217 项检查，使用 Canon EOS 5D Mark III DNG 和无效 CRW；输出分别位于 build/verify-editing-final 与 build/verify-editing-release-212917。
- 真实 RAW 库闭环：Debug 与 Release 都通过 147 项检查，使用同一对隔离输入；输出分别位于 build/verify-library-final 与 build/verify-library-release-212917。
- Vulkan 与 public `spektrafilm` 0.3.4 的确定性核心全图对照通过：240×180、129,600 个 RGB 值，最大绝对差 8.629775545831997e-06，最大 1 个 uint16 count，0 个 count outlier；Vulkan 全图渲染与缓存重印逐位一致。证据在 build/parity-acceptance-20261115/parity-report.json。
- 默认空间特效（halation、DIR couplers）对同一 public 参考不通过，最大绝对差 0.8277110063785368；两者分别单独关闭后仍不通过。不能据此判定 Metal 或 Vulkan 缺陷，因为 public 包不是生成 Mac oracle 的私有 fork。
- 本轮 Python 工具测试 50 项通过（0.940 秒）。
- 跨后端对照提交为 c103c4a；此前 Release 可见窗口启动和净化 PATH 启动已验收，截图在 build/qt-m1/spektralab-printwindow.png。

## 下一步

1. 取得私有 fork/Metal 的同输入参考或 golden 输出，运行现有 `compare`，判定默认 halation/DIR couplers 差异是否属于跨后端问题。
2. 在 1 MP 或更大整幅图上重跑 `core` fixture，确认当前 240×180 结论不依赖小图。
3. 增加原生 Windows CI，至少覆盖 Debug/Release 构建与 CTest。
4. 验收显示器 ICC、广色域/HDR；当前界面仍是 8-bit SDR sRGB 显示路径。
5. 做解码、上传、计算、回读和写盘的分段性能测量，再设性能目标。
6. 进行受控实拍胶片对照；现有测试不证明任意拍摄/冲洗条件下的科学准确性。

## 证据

- build/ctest-qt-debug-final.log
- build/qt-release-final/qt-build.json
- build/verify-editing-final/report.json
- build/verify-editing-release-212917/report.json
- build/verify-library-count-debug-213238/library-workflow.json
- build/verify-library-count-release-213238/library-workflow.json
- build/parity-acceptance-20261115/parity-report.json
- build/parity-default-20261115/parity-report.json
- engine/tools/windows_python_reference.py
- tasks/parity/WINDOWS-PARITY-2026-11-15.md

## 限制

public Python 的确定性核心跨后端数值对照已通过；私有 fork/Metal、默认空间特效、显示色彩管理、Windows CI、性能和真实胶片校准仍未完成。HEIF 依赖 Windows HEIF 图像扩展；界面导出仍为 SDR。
