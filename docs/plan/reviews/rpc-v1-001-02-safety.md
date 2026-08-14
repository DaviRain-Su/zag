# Review: rpc-v1-001 — safety / lifecycle (closeout)

- Task: [rpc-v1-001](../tasks/rpc-v1-001.md)
- Binding: [rpc-v1.md](../../modules/rpc-v1.md)
- Track: Wave 2 closeout (safety)
- Result: **PASS**

## What holds

- One conversation per process. Resume is idle-only via existing Session
  open modes.
- Cancel / steer / follow-up reuse Session queues and Cancel; no second
  lifecycle channel.
- Redaction fixture: secret in prompt / tool args never appears in frames.
- Mode-matrix violations exit 2 with empty stdout (no silent REPL fallback).
- Startup failures use the headless numeric exit matrix; no protocol
  bytes on stdout before a successful bind.
- PTY + SIGINT gates exist (rpc fixture classes 17–18).

## Non-blocking

- **N1 (P3).** Long-lived client disconnect vs durable save is covered by
  the fixture; power-loss / fsync is not claimed (Session L2 unchanged).

## Decision

**PASS** — closeout. Session v1 / Trace v1 / headless-v1 unchanged.
