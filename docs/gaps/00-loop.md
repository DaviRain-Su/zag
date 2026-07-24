# Gap: Phase 0 Loop → L2

> Teaching loop is tutorial-complete. Current contract: [loop-turn](../modules/loop-turn.md); maturity: [maturity](../maturity.md).

## Teaching/current foundations

- canonical messages/transcript and `loop.run`;
- pure Provider port;
- machine-readable expected Tool-result errors;
- serial Tool execution;
- between-call cooperative cancel with pending Tool-result completion;
- max-turns Result and golden transcripts;
- OpenAI-compatible + Anthropic model plane with retry/usage fixtures.

## Remaining L2 gaps

| Gap | Production failure | Delivery |
|-----|--------------------|----------|
| ~~provider failure and facade/trace terminal disagree~~ | **closed** facade owns single truthful terminal | done `h-trace-001` |
| Tool security metadata is name-derived | custom mutating Tool can bypass loop policy | P0 `h-tool-runtime-001` |
| no in-flight provider/stream cancel | SIGINT/deadline may wait indefinitely on active I/O | P1 `h-provider-001` |
| partial streamed Tool-call safety untested | incomplete arguments may leak into later execution paths | P1 provider contracts |
| public event/ownership contract incomplete | low-level composition is not SDK-ready | P1 `sdk-contract-001` |

## Non-goals for H

- Graph/subagents/Oracle
- MCP
- TUI
- parallel Tool batches
- OS sandbox implementation

## Next

Truthful terminal lifecycle closed (h-trace-001). Next: provider deadline/cancel and the SDK external-consumer Gate. See [Phase H](../phases/H-harden.md).
