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

The accepted planning baseline is [the 2026-07-24 production-floor assessment](./analysis/2026-07-24-production-floor-assessment.md).

| Area | Status |
|------|--------|
| Phase H | **Not complete.** Functional foundations exist; P0/P1 correctness gates remain. |
| P0 | **Complete:** session durability, Tool descriptor, file symlink containment, and truthful trace lifecycle |
| P1 | Compaction, provider lifecycle, and redaction are complete; integration is ready, then Zig SDK and headless gates follow |
| P2 | Sandbox/process supervisor and capability work after their dependencies |

Priority definitions live only in the assessment. Module contracts live under `docs/modules/`; implementation tasks link to them.

## Task DAG

```text
done P0
  h-session-001
  h-tool-runtime-001
  h-workspace-001
  h-trace-001
        │
        ├─ done P1: h-context-001
        ├─ done P1: h-provider-001
        └─ done P1: h-redact-001
                         │
all module P0/P1 tasks ─► ready: h-integration-001
                              ├───────────────────► sdk-contract-001
                              └───────────────────► headless-001
```

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
| [h-integration-001](./tasks/h-integration-001.md) | P1 | ready | Phase H real-composition/E2E closeout |
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
