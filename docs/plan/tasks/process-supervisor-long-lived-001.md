---
id: process-supervisor-long-lived-001
scope: tools/process-supervisor long-lived stdio slots
status: draft
priority: P0
depends-on:
  - process-supervisor-001
---

# objective

Docs-first contract for persistent bidirectional stdio slots (idle
timeout, kill on Agent deinit, env allow-list) so LSP/MCP children have
an owner. Wave 1 v1 cannot host them.

**Binding:** [process-supervisor-long-lived.md](../../modules/process-supervisor-long-lived.md)

**Status:** **`draft`**. Implementation only after dual review PASS **and**
process-supervisor-001 closeout (already **implemented**).

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** |
| Implementation | not started |
| Prerequisite | [process-supervisor-001](./process-supervisor-001.md) **implemented** |
| Unblocks | LSP slot migration; mcp-001 impl |

# path

| Path | Role |
|------|------|
| `docs/modules/process-supervisor-long-lived.md` | binding |
| Future impl | `packages/zag-coding-agent/src/runtime/process_supervisor.zig` (extend) or sibling file in the same package |
| Forbidden | Core process ports; new package without ownership pressure; zag-live import |

# verification (contract track)

- [x] Binding drafted
- [ ] Dual review PASS
- [ ] Task → `ready`

# non-goals

- OS sandbox / process-group reaper
- Background jobs / PTY
- MCP protocol (mcp-001)
- Maturity raise

# related

- [process-supervisor-001](./process-supervisor-001.md)
- [lsp-001](./lsp-001.md) · [mcp-001](./mcp-001.md)
- [2026-08-14 next delivery plan](../analysis/2026-08-14-next-delivery-plan.md) Wave 3
