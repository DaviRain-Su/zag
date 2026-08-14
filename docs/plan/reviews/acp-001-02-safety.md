# Review: acp-001 — safety / lifecycle (closeout)

- Task: [acp-001](../tasks/acp-001.md)
- Binding: [acp.md](../../modules/acp.md)
- Track: Wave 2 closeout (safety)
- Result: **PASS** (gate15 residual named, not a closeout blocker)

## What holds

- Ask-mode `session/request_permission` blocks the run; yolo never emits it.
- `allow_once` suppresses remember for that check only; `allow_always`
  records the write path in the server-owned store.
- Cancel-while-permission-pending ends the run cancelled (gate16).
- Redaction: fixture secret never appears in frames, including permission
  `fields`.
- Startup failure: no stdout bytes, headless exit codes (gate25).
- Disconnect / first SIGINT → graceful 0; second → 130 (std).
- Image / resource content blocks rejected (`-32602`); text flattened.

## Residual (not blocking closeout)

- **gate15** — see [acp-gate15-001](../tasks/acp-gate15-001.md). Root cause
  is coding-agent streaming tool-call parse on a second tool-bearing turn
  in the same Session, not the adapter mapping.

## Decision

**PASS** — 32/33 fixture gates. Remember-across-runs is a follow-up, not
silence. Session / Trace / headless schemas unchanged.
