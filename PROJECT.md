# SpektraLab Windows 项目入口

目标：基于上游 2.4.0 的现有 C++/Vulkan 引擎与 Qt 编辑器，交付可重复构建、可实际编辑和导出的 Windows 数字暗房。

## 阅读顺序

1. AGENTS.md：工程约束。
2. tasks/STATE.md：当前事实、阻塞与下一步。
3. docs/PROJECT_PLAN.zh-CN.md：范围、架构选择、阶段和风险。
4. tasks/todo.md：执行任务。
5. tasks/acceptance.md：验收条件与证据。
6. docs/WINDOWS_REVIEW.zh-CN.md：模型原理、优势和边界。

## 工作位置

- 主目录：E:/user/ChatGPT/SPEKTRAlab（上游基线）。
- 当前开发 worktree：E:/user/ChatGPT/SPEKTRAlab/.claude/worktrees/windows-port。
- 开发分支：codex/windows-native。
- 上游基线：87de3b6c837f9e21ad67924c50b169b3bacbfc5e。
- 依赖、构建、验证产物都位于开发 worktree 的 build/，不提交。

## 协作与完成条件

每次接续先读 STATE，再查实际文件与日志。仅在完成条件满足后勾选任务；测试记录区分通过、失败、跳过和未运行。阶段通过后在开发分支本地提交；推送、合并和发布单独按授权执行。

原始照片及历史验证输出保留。新测试使用独立输入副本和新输出目录。材料配置不承担显示或解码问题的修复。版本、接口或参考数据发生变化时，重新判断受影响的验收范围。
