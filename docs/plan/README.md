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
| Phase H | **Blocked.** Final audit found two file-surface counterexamples; edit integrity is closed and read/search bounds remains open. |
| P0 | **Complete:** `h-edit-integrity-001` completed the reviews 01–04 review/fix cycle, then passed final Oracle, ff-only merge, and main default/curl Gate; write/edit is L2 for its scoped single-file contract. |
| P1 | Context/provider/redaction/doctor/shell are done; `h-read-search-bounds-001` is in-progress; retained integration evidence remains valid. |
| Integration | `h-integration-001` is blocked only on `h-read-search-bounds-001`, then must repeat the sentence-by-sentence audit. |
| Product CLI | `cli-repl-001` is done; multi-turn delimiter consumption passed independent and merged-main default/curl Gates. |
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
done: h-edit-integrity-001          in-progress: h-read-search-bounds-001
single-file write/edit L2           bounded + explicit incomplete results
         └──────────┬──────────┘
                    ▼
          blocked: h-integration-001
          retained evidence + fresh final audit
                    ├───────────────────► sdk-contract-001
                    └───────────────────► headless-001
```

The two file tasks have independent code contracts but overlap global truth/teaching docs, so docs-sprint serializes their develop→verify→merge cycles. Edit integrity is done; read/search bounds is the only remaining file dependency.

Doctor, shell, and edit integrity keep their completed contracts. Integration remains the convergence point: its original Agent chains are already verified, but it cannot resume the final audit until read/search bounds passes.

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
| [h-edit-integrity-001](./tasks/h-edit-integrity-001.md) | P0 | done | Target-preserving single-file write/edit commit |
| [h-read-search-bounds-001](./tasks/h-read-search-bounds-001.md) | P1 | in-progress | Bounded read/search bodies and explicit incomplete results |
| [h-integration-001](./tasks/h-integration-001.md) | P1 | blocked | Fresh Phase H sentence audit after read/search bounds |
| [cli-repl-001](./tasks/cli-repl-001.md) | P1 | done | Multi-turn interactive input delimiter consumption |
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
