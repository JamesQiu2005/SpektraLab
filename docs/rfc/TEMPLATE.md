---
id: RFC-W000
title: {{模块或设计名称}}
status: Draft
owner: {{GitHub 用户名}}
created: {{YYYY-MM-DD}}
updated: {{YYYY-MM-DD}}
baseline: {{写作时 Windows_Linux 的 commit SHA}}
prd: {{PRD-Wnnn，或 none: <为什么这个模块不需要 PRD>}}
tests: []
---

# RFC-W000：{{模块或设计名称}}

<!--
用法：复制为 docs/rfc/RFC-Wnnn-<小写英文-slug>.md，在 docs/rfc/README.md 索引中加一行，状态从 Draft 开始。
状态：Draft → Review → Accepted（可以开始实现）→ Implemented（代码与测试已合入，tests: 列出守护它的测试）；
另有 Superseded（填 superseded_by:）、Rejected、Withdrawn。Accepted 之后的设计改动写进“决策记录”，不要静默改写正文。
编号用 RFC-Wnnn，避免与上游本地的 RFC-001…RFC-036 冲突（上游 rfc/ 目录不入库，代码注释里的 RFC-nnn 指的是它们）。
章节标题中括号里的英文关键词是检查器识别章节用的，请保留。不涉及时写“不涉及：<理由>”。
-->

## 1. 摘要（Summary）

<!-- 三五句话：这个模块是什么、解决什么、对外暴露什么。 -->

## 2. 现状与动机（Context）

<!-- 现在的代码怎么做（path:line），哪里不够；对应的 PRD 需求编号；macOS 版（main）的对应实现（path:line）。 -->

## 3. 设计（Design）

<!-- 结构、数据流、线程与生命周期、错误处理。哪个阶段拥有这个决定（AGENTS.md：修正属于拥有该决定的阶段；
     不得为修渲染问题去改胶片/相纸配置数据）。 -->

## 4. 接口与契约（Contracts）

<!-- 改了哪些边界：params_delta 字段（API-SPEC-callable-render-service.md 对应小节）、C ABI（spk_engine.h）、
     宿主协议（desktop/HOST-PROTOCOL.md，hello.protocol 是否需要升级）、sidecar 格式、设置项。
     规则：接口变更在同一提交范围内更新对应规范（tools/process/sync_rules.json 会检查）；只做增量变更；
     破坏性变更先新增、旧的标记弃用、下个周期再删除（CONTRACT-frontend-backend.md §2）。 -->

## 5. 影响评估（Impact）

<!-- 逐项写“影响 / 无影响 + 依据”：
     内存（预算、峰值、释放时机；Windows 用进程提交量 / 私有字节 / 工作集，不能相加）；
     缓存（键、失效、上限、命中≠完成解码）；色彩管理（工作空间、显示转换、导出转换只做一次）；
     导出（与画布一致、原子写入、不覆盖）；诊断（日志字段、计时开关）；性能（完整调用计时，不是节点时间之和）；
     许可证（新依赖的许可证、是否 GPL-3.0-or-later 兼容、需要随包分发的声明）。 -->

## 6. 测试计划（Test plan）

<!-- 窄门禁：开发时跑哪些测试（命令）。集成门禁：合并前跑什么。先红后绿：新回归测试在旧代码上如何失败。
     测试隔离：设置注入、夹具复制到临时目录、绝不写用户真实文件。真实窗口检查：离屏截图不能代替。
     表面一致性：显示画面的表面要加一致性用例。 -->

## 7. 备选方案（Alternatives）

<!-- 考虑过的方案与否决理由。 -->

## 8. 发布与迁移（Rollout）

<!-- 旧 sidecar / 设置如何迁移；功能开关；回滚方式；需要同步更新的文档。 -->

## 9. 决策记录（Decision log）

<!-- 日期 · 决策 · 决策人 · 理由。只追加。 -->

## 10. 待决问题（Open questions）

<!-- 需要谁、在什么时候之前回答。 -->
