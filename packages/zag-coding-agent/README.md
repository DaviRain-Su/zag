# zag-coding-agent

Product coding harness (Pi `pi-coding-agent` analogue).

| Module | Role |
|--------|------|
| `agent` | Session + Agent facade; run preflight/start/terminal owner |
| `toolset` | Phase0/1 default tools |
| `project` | AGENTS.md injection |
| `doctor` | Provider-independent readiness report (h-doctor-001) |
| `wire_provider` | `WireAdapter` → core `Provider` |
| `runtime/*` | list/read/write/shell handlers |

Depends on **zag-agent-core** + **zag-ai**. CLI lives in `packages/zag-cli` with thin entry `src/main.zig`.

D-011 makes this package the product owner for permission/workspace/shell policy, context/compaction, durable
session/Trace/redaction, event fan-out, Provider/model wiring, and concrete coding Tools. Migration is seam-first; current
L2 behavior and schemas remain required regressions. See [`docs/modules/core-boundary.md`](../../docs/modules/core-boundary.md).
