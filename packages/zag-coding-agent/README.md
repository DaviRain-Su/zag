# zag-coding-agent

Product coding harness (Pi `pi-coding-agent` analogue).

| Module | Role |
|--------|------|
| `agent` | Session + Agent facade |
| `toolset` | Phase0/1 default tools |
| `project` | AGENTS.md injection |
| `doctor` | Provider-independent readiness report (h-doctor-001) |
| `wire_provider` | `WireAdapter` → core `Provider` |
| `runtime/*` | list/read/write/shell handlers |

Depends on **zag-agent-core** + **zag-ai**. CLI lives in repo `src/main.zig`.
