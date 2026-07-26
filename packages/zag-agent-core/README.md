# zag-agent-core

Agent **Core** (Pi low-level loop analogue).

D-011 target: loop, authoritative in-memory Transcript, pure Provider/Tool/Cancel contracts, protocol-history validation,
and required policy/context/event seams. Durable session/Trace/redaction and concrete product policy/context move to
`zag-coding-agent` through the serialized `core-boundary-*` migration. Current source still contains those modules until
their ownership tasks merge.

Contract: [`docs/modules/core-boundary.md`](../../docs/modules/core-boundary.md).

## Does not include

- Wire clients / OpenAI / Anthropic adapters → `zag-ai`
- Default coding toolset / Agent facade / AGENTS.md → `zag-coding-agent`
- CLI / TUI → `zag-cli`

## Provider port

```zig
const Provider = core.Provider; // vtable chat only
// Coding-agent binds WireAdapter → Provider; core never sees Client.
```

## Dependency

```
zag-agent-core → zag-types only
```

Canonical messages and `ChatError` live in `zag-types`. Catalog budgets are applied in the product shell via `context.optionsFromBudget`.
