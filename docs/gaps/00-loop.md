# Gap: Phase 0 Loop → L2

> Teaching：[chapters/00-loop](../../chapters/00-loop/README.md) = **tutorial-complete**。  
> 对照：[maturity.md](../maturity.md) Loop / Tools·read / Provider / Quality。

## 教程已具备

- Message / transcript / `loop.run` / Phase0 tools（`list_dir`、`read_file`）
- Provider 端口 + OpenAI-compat 一条线
- Soft-fail：未知 tool / handler 错误以字符串回灌
- Mock provider 单测可跑通业务

## 离 L2 还差什么

| 缺口 | 为何算生产问题 | 落点 |
|------|----------------|------|
| Tool 错误不可机读 | 模型与 eval 难以分支处理；日志难聚合 | ✅ H1：`tool_error` `code=` |
| 无 cancel / 中断语义 | 长 turn 只能杀进程，transcript 半残 | H1 收口 |
| max_turns 等未稳定进 trace | 无法审计「为何停」 | ✅ `stop_reason`；超时仍待 |
| 无 golden transcript | 改 loop 易 silent 变笨 | H1 · [evals](../quality/evals.md) |
| ~~只读工具无 grep/glob~~ | — | ✅ H2 |
| 流式/部分 tool_call 不稳 | 生产常用 `--stream` | H6 · [zag-ai-provider](../modules/zag-ai-provider.md) |
| usage 仅 turn/trace 雏形 | session 文件元数据仍待 | H6（Ledger/CLI **已有**） |

## 非本阶段（勿塞进「修 Phase 0」）

- Subagent / Oracle / MCP  
- TUI  
- OS sandbox  

## 下一步

实现顺序跟 [phases/H-harden.md](../phases/H-harden.md) **H1**（可与 H6/H7 并行规格）。  
