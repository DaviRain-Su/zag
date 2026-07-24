# Delivery plan (Active)

XPlan-style **Active** delivery track. Owned workflow: analysis → tasks → reviews → backlog.

```text
docs/plan/
├─ README.md          (this file)
├─ analysis/          topic analyses (not assigned to implementers)
├─ tasks/             {area}-{seq}.md
├─ reviews/           {id}-{seq}.md
└─ backlog.md         non-blocking findings / deferrals
```

## Current baseline

The accepted planning baseline is [the 2026-07-24 production-floor assessment](./analysis/2026-07-24-production-floor-assessment.md), including its dated planning corrections.

| Area | Status |
|------|--------|
| Phase H | **Not complete.** Shell review-fix package evidence landed, but independent re-review/main Gate and final integration audit remain L2 blockers. |
| P0 | **Complete:** session durability, Tool descriptor, file symlink containment, and truthful trace lifecycle. |
| P1 | Context/provider/redaction/doctor and the original integration evidence are complete; `h-shell-001` is in-progress after blocked review 01, while integration closeout stays blocked. |
| Post-H | Zig SDK and headless gates remain pending; P2 sandbox/process-supervisor work stays separate. |

Priority definitions live only in the assessment. Module contracts live under `docs/modules/`; implementation tasks link to them.

## Task DAG

```text
done: h-tool-runtime-001 + h-workspace-001 + h-redact-001
                              │
                              ▼
                           done: h-doctor-001

 done: h-tool-runtime-001 + h-trace-001
                              │
                              ▼
                   in-progress: h-shell-001
                   (review-fix package evidence landed; re-review/Gate pending)
                              │
                              ▼
all completed P0/P1 modules + doctor + shell
                              │
                              ▼
                        blocked: h-integration-001
                        (composition evidence merged and verified;
                         final Phase H audit waits for shell)
                              ├───────────────────► sdk-contract-001
                              └───────────────────► headless-001
```

Doctor has only the three dependencies shown above. Shell has only Tool runtime and trace dependencies. Shell review-fix implementation/module+Agent package evidence is now landed, but independent re-review/main Gate evidence is pending. Integration remains the convergence point: its original package evidence is complete, but its closeout dependency on shell is not.

`ready` means dependencies are satisfied, not that tasks may safely edit one shared checkout in parallel. Use task `path` overlap rules.

## Task index

| ID | Priority | Status | Scope |
|----|----------|--------|-------|
| [h-session-001](./tasks/h-session-001.md) | P0 | done | Session open/save/concurrency |
| [h-tool-runtime-001](./tasks/h-tool-runtime-001.md) | P0 | done | Tool descriptor + permission |
| [h-workspace-001](./tasks/h-workspace-001.md) | P0 | done | Filesystem containment after Tool descriptor |
| [h-trace-001](./tasks/h-trace-001.md) | P0 | done | Trace/run terminal lifecycle |
| [h-context-001](./tasks/h-context-001.md) | P1 | done | Compaction accounting |
| [h-provider-001](./tasks/h-provider-001.md) | P1 | done | Deadline/in-flight cancellation |
| [h-redact-001](./tasks/h-redact-001.md) | P1 | done | Secret redaction |
| [h-doctor-001](./tasks/h-doctor-001.md) | P1 | done | Provider-independent readiness/control report |
| [h-shell-001](./tasks/h-shell-001.md) | P1 | in-progress | Review-fix encoding/scoped-limit/fixed-deny/Agent evidence landed; re-review/Gate pending |
| [h-integration-001](./tasks/h-integration-001.md) | P1 | blocked | Verified composition evidence; final Phase H closeout waits for shell |
| [sdk-contract-001](./tasks/sdk-contract-001.md) | P1 | pending | Zig SDK-ready gate |
| [headless-001](./tasks/headless-001.md) | P1 | pending | Structured process interface |

## Task file skeleton

```yaml
---
id: h3-001
scope: permissions
status: pending   # pending | ready | in-progress | done | blocked
priority: P0      # assessment delivery priority
depends-on: []
---

# objective
…

# context
- docs/modules/permissions.md

# path
- packages/zag-agent-core/src/permissions.zig
- docs/modules/permissions.md

# verification
- zig build test
```

## Rules

- Design docs in **Product Spec** / **decisions** precede coding contract changes.
- Task `context` points at existing specs; analysis is background, not the sole contract.
- Blocking review findings must be fixed before merge; non-blocking findings go to `backlog.md`.
- Behavior changes update the relevant module doc, maturity row, and teaching chapter in the same delivery.
- No task may claim Phase H, SDK-ready, or headless-ready until its full gate passes.
- A green integration fixture cannot waive a different open module exit; `h-shell-001` must pass before final Phase H audit.
