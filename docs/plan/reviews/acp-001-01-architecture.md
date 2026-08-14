# Review: acp-001 — architecture / ownership (closeout)

- Task: [acp-001](../tasks/acp-001.md)
- Binding: [acp.md](../../modules/acp.md)
- Code: `packages/zag-cli/src/acp/` + `acp_entry.zig` + `--acp`
- Track: Wave 2 closeout (architecture)
- Result: **PASS**

## Scope

ACP is a separately gated editor JSON-RPC adapter. It must not be rpc-v1
with a different flag, must not change Core, and must reuse framing
read-only.

## What holds

- No Core / zag-tui imports (fixture gate26).
- Reuses `rpc/framing.zig` read-only; `acp/framing.zig` deliberately absent.
- Same host surfaces as TUI/rpc. One-row session table (`sess_1`).
- Mutual exclusion vs `--rpc` / `--tui` / `--json` / `--doctor` / `-v`.
- Permission options map to existing Gate + server-owned remember store
  (`allow_always` / `allow_once` suppress).

## Non-blocking

- **N1 (P2).** gate15 (permission remember across two writes) is RED at
  landing: second-run tool-call streaming parse fails with provider
  `-32000` before the tool runs. Adapter surfaces the failure honestly.
  Residual: [acp-gate15-001](../tasks/acp-gate15-001.md). Other permission
  gates (13/14/16) are green. Closeout does **not** wait on that fix.

## Decision

**PASS** — closeout with named residual. No maturity row. ACP ≠ rpc-v1.
