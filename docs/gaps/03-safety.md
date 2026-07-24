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
| ~~failed provider run finalized `ok=true/completed`~~ | **closed** facade single terminal | done `h-trace-001` |
| ~~explicit trace I/O swallowed~~ | **closed** `TraceIoFailed` / preflight | done `h-trace-001` |
| ~~trace schema absent~~ | **closed** `schema_version=1` on `run_start` | done `h-trace-001` |
| ~~shared secret redaction~~ | **closed** h-redact-001 — known-key/shape only; `.zag/` still sensitive; not DLP | done `h-redact-001` |
| ~~default Agent policy/containment composition absent~~ | **closed** ask-deny write + escaping-symlink jail persisted/traced; independent + main Gate passed | retained `h-integration-001` evidence |
| shell runtime/trace delivery Gate incomplete | review-fix fixed-deny/encoding/scoped-limit/direct-PID/parsed single-call trace matrix landed; shell remains a separate non-path-jail boundary | in-progress `h-shell-001` |
| ~~no doctor/readiness~~ | **closed:** fixed/path-free active-control report + no-key process fixture | done `h-doctor-001` |

## OS sandbox boundary

OS sandbox/network/process-tree enforcement is C7, not Phase H. Trusted-host L2 is allowed only with honest limitations and default ask. Higher-autonomy/background/untrusted executable extensions require a fail-closed sandbox/process-supervisor Gate.

## Next

Trusted-host file containment, redaction, doctor, and default Agent policy/containment composition are closed. [h-shell-001](../plan/tasks/h-shell-001.md) has landed review-fix synchronous shell-v1/body/direct-PID/trace evidence; independent re-review/main Gate remains before blocked integration resumes its final audit. OS sandbox/process-tree ownership remains [C7](../phases/C7-sandbox.md).
