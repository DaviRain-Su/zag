---
id: process-supervisor-001
scope: tools/process-supervisor (D-012 item 3; shell execution owner)
status: draft
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

**Status:** **`draft`** — not ready for implementation Goal until dual
independent reviews PASS (architecture/ownership + safety/lifecycle) and this
task moves to `ready`.

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — module + this task authored; dual review **not** started |
| Implementation | **not started** |
| Maturity | **unchanged** — Shell/Workspace stay L2; no sandbox claim |
| Depends-on | edit-transaction **done**; shell L2 exists |
| Unblocks | LSP, rpc-v1 clients that spawn helpers, typed subagents, MCP/E2, mid-flight shell preemption honesty |

# context

- Phase H shell is L2 **synchronous** capture without process-tree ownership
  claims ([tools-shell](../../modules/tools-shell.md)).
- D-012 dependency order: edit-transaction → **supervisor** → LSP / rpc / ACP /
  subagents / MCP.
- Semantic refs: Hyper Computer/terminal lifecycle; OMP bash runtime — not
  parity (D-009).
- Host-shell TUI / Theme / post-TUI remote Gate are **orthogonal**.

# path

| Path | Role |
|------|------|
| `docs/modules/process-supervisor.md` | **binding draft** |
| `docs/plan/tasks/process-supervisor-001.md` | this task |
| Future reviews | `docs/plan/reviews/process-supervisor-001-01-*.md` |
| Future impl (after ready + Goal) | `packages/zag-coding-agent/src/runtime/**` |
| Forbidden until ready | product/build/CI; Core; new package without ownership decision |

# contract summary (draft)

| Topic | Draft freeze |
|-------|----------------|
| Owner | `zag-coding-agent` only; no Core process types |
| Surface | Internal Supervisor API; `run_shell` migrates onto it; no new model Tool required in v1 |
| Lifecycle | spawn → pump under caps → one Terminal; cooperative cancel then hard kill |
| Caps | ≥ shell-v1 stream/envelope; Tool body ≤ 64 KiB path |
| Background jobs | **out of v1** |
| Schemas | Session/Trace/headless **unchanged** |
| Maturity | no row raise; no OS sandbox |

# verification (contract track)

- [x] Binding module draft authored
- [x] Task frontmatter `status: draft`
- [ ] Independent architecture/ownership review PASS
- [ ] Independent safety/lifecycle review PASS
- [ ] Open questions in module §8 closed
- [ ] Task → `ready` (impl Goal eligible)
- [ ] Implementation Goal / product code (later)

# non-goals

- Impl on this tip
- PTY interactive shell; background monitor/scheduler
- Full multi-platform process-tree reaper claims without evidence
- OS sandbox / MCP / LSP protocol / subagent product
- Maturity raise

# related

- [process-supervisor.md](../../modules/process-supervisor.md)
- [edit-transaction-001](./edit-transaction-001.md) · [h-shell-001](./h-shell-001.md)
- [tools-shell.md](../../modules/tools-shell.md)
- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
- [roadmap D-012 route](../../roadmap.md#d-012-capability-route)
