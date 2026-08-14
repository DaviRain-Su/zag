# Process supervisor — long-lived stdio slots

> Binding draft for
> [process-supervisor-long-lived-001](../plan/tasks/process-supervisor-long-lived-001.md)
> (Wave 3a-A in the [08-14 plan](../plan/analysis/2026-08-14-next-delivery-plan.md)).
> Prerequisite: [process-supervisor.md](./process-supervisor.md) v1
> **implemented**.
>
> **Status:** **draft** — docs-only. v1 foreground supervisor **cannot**
> host zls or MCP. No product code until dual review PASS.

## 1. Purpose

Add a **persistent bidirectional stdio slot** so a product child
(Language Server, MCP server) has one owner for spawn, idle timeout,
bounded pipes, and kill-on-Agent-deinit — without Core process types
and without OS-sandbox claims.

## 2. Why a second slice

v1 `runForeground` is a bounded capture (`std.process.run`) with a
mandatory deadline. zls and MCP need:

- long-lived process
- framed stdin/stdout that stay open across many Tool calls
- idle timeout, not a per-call hard deadline that kills the server
- teardown on `Agent.deinit`

Do not pretend Wave 1 hosts those children.

## 3. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| `zag-coding-agent` Supervisor | Slot table; spawn/write/read/idle/kill | Core ports; Session PID fields |
| LSP / MCP modules | Protocol only; they *register* a slot | Raw `std.process.Child` after migration |
| `zag-live` | Its own Chez child (existing exception) | Import this slot API (L2 cannot import L3) |
| CLI / TUI | Cancel still via Guard | Direct kill of slot children |

## 4. API sketch (freeze at review)

```text
Slot
  spawn(spec) -> SlotHandle | spawn_failed
  write(handle, bytes) -> void | closed
  read(handle, budget) -> bounded Frame | timeout | eof
  cancel(handle, mode) -> void
  collect_stderr(handle) -> bounded
  kill_all_on_agent_deinit()
```

| Item | v1 slot freeze (proposed) |
|------|---------------------------|
| Transport | local pipes only |
| Deadline | idle timeout + per-request read budget; no mandatory process-lifetime deadline |
| Caps | stdin/stdout frame cap; stderr ring (reuse LSP 8 KiB unless review says otherwise) |
| Env | **explicit allow-list** (this is where LSP §12 Q2 should close) |
| Background jobs / PTY | out |
| Schemas | Session / Trace / headless unchanged |

## 5. Consumers (after this slice)

1. Migrate `code_intel` LSP child onto a slot (protocol unchanged).
2. `mcp-001` impl, only with a named server, must use a slot — never
   raw `Child`.

## 6. Tests (when implemented)

| # | Class | Expect |
|---|-------|--------|
| 1 | Echo child | write/read round-trip |
| 2 | Idle timeout | child gone; next read `eof` / `spawn` on next use |
| 3 | Agent deinit | no orphan under the harness |
| 4 | Output cap | truncated / fail-closed; finite memory |
| 5 | Env allow-list | injected `*KEY*` absent unless granted |
| 6 | Ownership | no Core process symbols |
| 7 | LSP regression | existing mock-server classes still green after migration |

## 7. Non-goals

- OS sandbox
- Process-group / full tree reaper
- Background job product surface
- zag-live migration onto this API

## Related

- [process-supervisor.md](./process-supervisor.md) · [lsp.md](./lsp.md)
- [mcp.md](./mcp.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
