# docs/

`Windows_Linux` 分支的流程与设计文档。

| 去哪里 | 内容 |
|---|---|
| [process/DEVELOPMENT-PROCESS.md](process/DEVELOPMENT-PROCESS.md) | 开发流程：什么时候写 PRD / RFC / ADR，窄门禁与集成门禁，先红后绿，测试隔离，接口变更同步规范，真实窗口检查，测量，CI，分支与合并 |
| [reference-audit.md](reference-audit.md) | 参照 SpektraLab 上游（`main` 与 `Windows_Linux`）的规范审计：读了哪些文件、逐条合规矩阵、不适用规则的理由、发现的偏差 |
| [prd/](prd/README.md) | 新功能的需求文档（PRD-Wnnn） |
| [rfc/](rfc/README.md) | 模块与设计记录（RFC-Wnnn） |
| [adr/](adr/README.md) | 单项决定（ADR-Wnnn） |

检查这些文档：

```
python tools/process/check_process.py docs audit
```

仓库整体结构仍以根目录的 [ARCHITECTURE.md](../ARCHITECTURE.md)、[AGENTS.md](../AGENTS.md) 和 `engine/`、`desktop/` 下的文档为准；本目录不重复它们。
