# zag-agent-core

Agent **Core** (Pi `pi-agent-core` analogue): loop, session, permissions, context, pure `Provider` port.

## Does not include

- Wire clients / OpenAI / Anthropic adapters → `zag-ai`
- Default coding toolset / Agent facade / AGENTS.md → `zag-coding-agent`
- CLI / TUI → product shell (`src/main.zig`)

## Provider port

```zig
const Provider = core.Provider; // vtable chat only
// Coding-agent binds WireAdapter → Provider; core never sees Client.
```

## Dependency

```
zag-agent-core → zag-ai (types, isRetryableError, catalog helpers only)
```
