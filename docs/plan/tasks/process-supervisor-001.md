---
id: process-supervisor-001
scope: tools/process-supervisor (D-012 item 3; shell execution owner)
status: implemented
priority: P0
depends-on:
  - edit-transaction-001
  - h-shell-001
---

# objective

Freeze a **docs-first** process-supervisor contract so every executable child
(shell today; LSP/MCP/subagent later) has bounded output, a truthful terminal,
and product-owned cancel/reap — without Core process ports, without OS-sandbox
claims, and without background-job product surface in v1.

**Binding specification:** [process-supervisor.md](../../modules/process-supervisor.md)

**Status:** **`implemented`** — dual review PASS + fixture closeout
2026-08-14. Not `ready`-then-impl: code landed first; Wave 1 closed the
review/fixture hole.

# status truth

| Track | Status |
|-------|--------|
| Contract | **frozen** — §8 four freezes binding; [architecture](../reviews/process-supervisor-001-01-architecture.md) PASS · [safety](../reviews/process-supervisor-001-02-safety.md) PASS |
| Implementation | **done** — `runtime/process_supervisor.zig`; `run_shell` uses `runForeground`; F1 reap-after-cancel; fixture 7 `rejectDeniedShell` |
| Maturity | **unchanged** — Shell/Workspace stay L2; no sandbox claim |
| Depends-on | edit-transaction **done**; shell L2 exists |
| Unblocks | long-lived stdio slots; MCP/E2; mid-flight shell preemption honesty. rpc/LSP/ACP/in-process subagent already landed as exceptions. |

# context

- Phase H shell is L2 **synchronous** capture; supervisor is now the
  execution owner without process-tree ownership claims
  ([tools-shell](../../modules/tools-shell.md)).
- Host-shell TUI / Theme / post-TUI remote Gate are **orthogonal**.

# path

| Path | Role |
|------|------|
| `docs/modules/process-supervisor.md` | **binding** (implemented) |
| `docs/plan/tasks/process-supervisor-001.md` | this task |
| Reviews | `docs/plan/reviews/process-supervisor-001-01-architecture.md` · `…-02-safety.md` |
| Impl | `packages/zag-coding-agent/src/runtime/process_supervisor.zig` |

# verification

- [x] Binding module authored
- [x] Independent architecture/ownership review PASS
- [x] Independent safety/lifecycle review PASS (F1 applied)
- [x] §8 open questions frozen
- [x] Fixture classes 1–8, 10 in `process_supervisor.zig`; class 9 = shell-v1 goldens via `runForeground`
- [x] No Core process symbols
- [x] Task → `implemented`

# non-goals

- PTY interactive shell; background monitor/scheduler
- Full multi-platform process-tree reaper claims
- OS sandbox / MCP / LSP protocol / process-backed subagent
- Maturity raise

# related

- [process-supervisor.md](../../modules/process-supervisor.md)
- [edit-transaction-001](./edit-transaction-001.md) · [h-shell-001](./h-shell-001.md)
- [tools-shell.md](../../modules/tools-shell.md)
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
- [2026-08-14 next delivery plan](../analysis/2026-08-14-next-delivery-plan.md)
