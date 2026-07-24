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
| ~~Tool security metadata is name-derived~~ | **closed** D-007 mandatory descriptor + fail-closed custom policy | done `h-tool-runtime-001` |
| ~~no in-flight provider/stream cancel~~ | **closed** curl active control; std fails closed when control unsupported | done `h-provider-001` |
| ~~partial streamed Tool-call safety untested~~ | **closed** strict terminal + incomplete Tool-call discard | done `h-provider-001` |
| ~~accepted multi-Tool cancel lacks Agent/session/trace composition evidence~~ | **closed** exact IDs/handlers/session/parsed terminal; independent + main Gate passed | retained `h-integration-001` evidence |
| public event/ownership contract incomplete | low-level composition is not SDK-ready | pending `sdk-contract-001` |

## Non-goals for H

- Graph/subagents/Oracle
- MCP
- TUI
- parallel Tool batches
- OS sandbox implementation

## Next

The documented H Loop boundary is L2: Tool runtime, truthful terminal, provider control/stream safety, and accepted between-Tool Agent composition are closed. [h-shell-001](../plan/tasks/h-shell-001.md) package evidence is landed, but Phase H as a whole still waits on its independent/main Gate and the final integration audit; the SDK external-consumer Gate remains separate. See [Phase H](../phases/H-harden.md).
