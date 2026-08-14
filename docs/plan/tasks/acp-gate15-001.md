---
id: acp-gate15-001
scope: product-shell acp / coding-agent stream parse
status: draft
priority: P1
depends-on:
  - acp-001
---

# objective

Make ACP fixture `gate15_permission_remember_allow_always_no_second_ask`
green: after `allow_always` on a write path, a second identical write in
the same `--acp` process must **not** re-ask and must still run the tool.

**Status:** **`draft`** — residual named at acp-001 closeout (32/33).
Not a Wave 2 closeout blocker.

# status truth

| Track | Status |
|-------|--------|
| Symptom | Second prompt's run gets a well-formed tool-call SSE from the mock (`--tool-call-every 2`) but the agent returns `-32000 provider error` before the tool executes |
| Suspected owner | coding-agent / zag-ai streaming tool-call parse on a **second** tool-bearing turn in one Session — not the ACP adapter mapping |
| Adapter | already maps `allow_always` → remember store; gates 13/14/16 green |
| Maturity | no row; do not reopen acp-001 |

# context

Landing note in [acp-001](./acp-001.md): the mock is alive; the adapter
surfaces the run failure per acp.md §11.3. Root-cause belongs to a
coding-agent-focused change.

# path

| Path | Role |
|------|------|
| `packages/zag-cli/src/acp_process_fixture.zig` | gate15 (must stay; do not delete) |
| `packages/zag-coding-agent` / `packages/zag-ai` | likely fix site |
| Forbidden | Core protocol-history rewrite; ACP ≠ rpc-v1 merge |

# verification

- [ ] Isolated repro without the ACP host (coding-agent + mock) OR a
      documented reason the host is required
- [ ] gate15 green on std and curl process fixtures
- [ ] gates 13/14/16 still green
- [ ] No Session / Trace / headless schema change

# non-goals

- Reopening acp-001 closeout
- Deny-remember store
- Maturity raise

# related

- [acp-001](./acp-001.md) · [acp.md](../../modules/acp.md)
- [acp-001-01-architecture](../reviews/acp-001-01-architecture.md)
