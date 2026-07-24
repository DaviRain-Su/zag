# zag-agent-core

Agent **Core** (Pi `pi-agent-core` analogue): loop, session, permissions, context, pure `Provider` port.

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
