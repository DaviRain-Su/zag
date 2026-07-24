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

The accepted planning baseline is [the 2026-07-24 production-floor assessment](./analysis/2026-07-24-production-floor-assessment.md), including its dated corrections. The latest gate record is the [2026-07-25 Phase H final audit](./analysis/2026-07-25-phase-h-final-audit.md).

| Area | Status |
|------|--------|
| Phase H | **Blocked.** The final audit passed existing suites but found two unowned default file-surface L2 counterexamples. |
| P0 | Original queue is done; data preservation reopened narrowly as `h-edit-integrity-001` (ready). |
| P1 | Context/provider/redaction/doctor/shell are done; `h-read-search-bounds-001` is ready; retained integration evidence remains valid. |
| Integration | `h-integration-001` is blocked on both file-surface tasks, then must repeat the sentence-by-sentence audit. |
| Post-H | Zig SDK and headless gates remain pending; P2 sandbox/process-supervisor work stays separate. |

Priority definitions live only in the assessment. Module contracts live under `docs/modules/`; implementation tasks link to them.

## Task DAG

```text
original P0/P1 modules + doctor + shell ✅
                    │
      final audit found two file blockers
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
ready: h-edit-integrity-001   ready: h-read-search-bounds-001
single-file atomic preserve   bounded + explicit incomplete results
         └──────────┬──────────┘
                    ▼
          blocked: h-integration-001
          retained evidence + fresh final audit
                    ├───────────────────► sdk-contract-001
                    └───────────────────► headless-001
```

The two file tasks have independent code contracts but overlap global truth/teaching docs, so docs-sprint delivery serializes their develop→verify→merge cycles. Integration becomes `ready` only after both are `done`.

Doctor and shell keep their completed dependency contracts. Integration remains the convergence point: its original Agent chains are already verified, but it cannot resume the final audit until both newly owned file-surface contracts pass.

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
| [h-shell-001](./tasks/h-shell-001.md) | P1 | done | Synchronous shell-v1/budget/direct-child/Agent evidence |
| [h-edit-integrity-001](./tasks/h-edit-integrity-001.md) | P0 | ready | Target-preserving single-file write/edit commit |
| [h-read-search-bounds-001](./tasks/h-read-search-bounds-001.md) | P1 | ready | Bounded read/search bodies and explicit incomplete results |
| [h-integration-001](./tasks/h-integration-001.md) | P1 | blocked | Fresh Phase H sentence audit after both file tasks |
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
- Green module Gates enable the integration audit; they do not waive or predetermine its final Phase H verdict.
