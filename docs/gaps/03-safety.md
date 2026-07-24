# Gap: Phase 3 Jail + Policy + Trace → L2

> Teaching chapter is tutorial-complete; its historical `production` name is not a maturity claim. Current truth: [maturity](../maturity.md).

## Teaching/current foundations

- lexical relative-path validation;
- `protect` shell denylist;
- ask/yolo product default flow;
- JSONL Tool/permission/usage/retry trace events;
- SECURITY warning that OS sandbox is absent.

## Remaining L2 gaps

| Gap | Production failure | Delivery |
|-----|--------------------|----------|
| ~~lexical jail follows escaping workspace symlinks~~ | **closed** realpath Guard + handler dual enforcement | done `h-workspace-001` |
| ~~custom Tool risk unknown→read~~ | **closed** D-007: mandatory capabilities | done |
| failed provider run may be finalized `ok=true/completed` | audit says success for failure | P0 `h-trace-001` |
| explicit trace I/O is swallowed | caller believes audit exists when it does not | P0 `h-trace-001` |
| trace schema absent | readers cannot evolve safely | P0/P1 trace task |
| no shared secret redaction | known keys may enter verbose/trace/session | P1 `h-redact-001` |
| policy/containment/fault matrix incomplete | safety story is not regression evidence | [quality/evals](../quality/evals.md) |
| no doctor/readiness | active controls/degradation are not visible | H5 |

## OS sandbox boundary

OS sandbox/network/process-tree enforcement is C7, not Phase H. Trusted-host L2 is allowed only with honest limitations and default ask. Higher-autonomy/background/untrusted executable extensions require a fail-closed sandbox/process-supervisor Gate.

## Next

Complete P0 Tool/workspace/trace tasks, then redaction/doctor and the security fixtures. See [Phase H](../phases/H-harden.md) and [C7](../phases/C7-sandbox.md).
