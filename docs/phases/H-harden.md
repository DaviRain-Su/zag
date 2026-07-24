# Phase H — Production Floor (hardening)

| Item | Content |
|------|---------|
| Status | **In progress; not L2** |
| Prerequisite | Teaching Phase 0–3 tutorial-complete |
| Goal | All critical existing surfaces satisfy [maturity L2](../maturity.md) |
| Non-goals | Graph, Memory Repo, full subagents, MCP, TUI, OS sandbox implementation |
| Assessment | [2026-07-24 production-floor assessment](../plan/analysis/2026-07-24-production-floor-assessment.md) |

## Reset after assessment

Earlier H notes treated H1/H3/H4 feature presence as closeout. Failure-path fixtures showed that several contracts remain open:

- schema exists, but resume/save can still lose data;
- built-in permission matrix exists, but custom Tool risk fails open;
- four prompt layers exist, but second-stage trim accounting is incomplete;
- trace events exist, but a provider failure may end as successful completion;
- lexical jail exists, but workspace symlinks escape it.

Therefore **feature landed ≠ L2 closed**. Current truth is `maturity.md`; priorities and task IDs live in the assessment/plan.

## Principles

1. Correctness and failure visibility before capability breadth.
2. Contract/spec → failing fixture → implementation → integration/E2E → maturity update.
3. Required data/metadata fails explicitly; silent fallback requires a documented optional lookup.
4. Product default remains `ask`; H does not claim OS sandbox.
5. Package separation does not imply SDK-ready.
6. Do not add Memory, Graph, TUI, MCP, or background jobs to avoid a P0/P1 fix.

## Delivery priorities

| Priority | Phase H meaning |
|----------|-----------------|
| **P0** | Data preservation, fail-closed permission, filesystem containment, truthful terminal/audit state |
| **P1** | Compaction accounting, redaction, deadline/cancel, SDK/headless gates |
| **P2** | Capability/packaging work after the contracts above |

Canonical table: [assessment § priorities](../plan/analysis/2026-07-24-production-floor-assessment.md#priority-meanings).

## P0 queue

| Task | Contract | Exit |
|------|----------|------|
| [h-session-001](../plan/tasks/h-session-001.md) | [D-006](../decisions/active/D-006-session-open-and-durability.md) | explicit create/resume; atomic preservation; visible errors; writer conflict |
| [h-tool-runtime-001](../plan/tasks/h-tool-runtime-001.md) | [D-007](../decisions/active/D-007-tool-runtime-descriptor.md) | stateful Tool; mandatory descriptor; fail-closed custom policy |
| [h-workspace-001](../plan/tasks/h-workspace-001.md) | [workspace-sandbox](../modules/workspace-sandbox.md) | symlink-aware file containment |
| [h-trace-001](../plan/tasks/h-trace-001.md) | [trace-observability](../modules/trace-observability.md) | exactly one truthful terminal; visible trace failure |

No P2 capability implementation is promoted while a P0 task remains open.

## H1 — Loop / lifecycle

Spec: [loop-turn](../modules/loop-turn.md).

### Landed

- stable machine-readable Tool-result errors;
- serial Tool order;
- `completed` / `max_turns` / between-call `cancelled` Result paths;
- pending Tool-call cancellation results keep transcript resume-safe;
- golden transcripts.

### Remaining

- provider/error/facade/trace terminal state agreement (P0 trace task);
- in-flight provider/stream cancellation/deadline (P1 provider task);
- partial Tool-call discard after cancellation.

H1 remains **L1+**, not closed L2.

## H2 — Edit/search/shell

Specs: [tools-edit](../modules/tools-edit.md), [tools-shell](../modules/tools-shell.md).

### Landed

- `search_replace` with unique anchor and stable error codes;
- `grep` / `glob` with result budgets;
- `write_file` for create/full replacement;
- optional post-write diff;
- shell policy/timeout/truncation basics.

### Remaining

- all file Tools must use descriptor-selected real containment;
- shell error/deadline/cancel shape must align with H lifecycle contracts;
- C4 edit sharpness/change review remains post-H capability.

## H3 — Tool runtime / permissions

Specs: [tool-runtime](../modules/tool-runtime.md), [permissions](../modules/permissions.md).

### Landed

- built-in read/write/execute matrix;
- write-path remember and `--no-remember`;
- Plan stub and permission trace event.

### Remaining (P0)

- separate model `ToolDefinition` from runtime capabilities;
- stateful Tool instance pointer/callback;
- descriptor-derived risk/path/cancel metadata;
- missing/invalid capability fails registration rather than defaulting to read;
- custom mutating Tool follows the same gate as built-ins.

H3 remains **L1+**, not closed L2.

## H4 — Context / Session

Specs: [context-compaction](../modules/context-compaction.md), [session-store](../modules/session-store.md).

### Landed

- four prompt layers;
- view-only heuristic compaction without transcript deletion;
- session schema v1 and legacy parsing;
- compaction metadata/trace event plumbing.

### Remaining

- P0 session explicit open, atomic save preservation, visible errors, exclusive writer;
- P1 final-view compaction accounting and summary lineage;
- persistence/trace integration fixtures.

H4 remains **L1+**, not closed L2. Repo map/fork/Memory stay C5.

## H5 — Safety

Spec: [workspace-sandbox](../modules/workspace-sandbox.md).

Required:

- symlink-aware containment for all file Tools (P0);
- fixed shell-policy matrix;
- shared secret redaction before verbose/trace/session (P1);
- doctor/readiness output;
- explicit trusted-host/non-OS-sandbox threat model.

OS sandbox/process supervisor remains C7, but is required before higher-autonomy/background/untrusted executable-extension claims.

## H6 — Provider

Spec: [zag-ai-provider](../modules/zag-ai-provider.md).

### Landed

- OpenAI-compatible and Anthropic wire adapters;
- canonical errors, retry, ChatOptions, usage/cost, provider fixtures;
- std/curl selectable transports.

### Remaining (P1)

- public timeout is enforced or explicitly rejected;
- cancel/deadline propagation through Provider/adapter/stream;
- incomplete Tool-call fragment discard;
- retry ownership/attempt traceability;
- redaction integration.

Until std deadlines are implemented, production deadline users must use the documented curl path; storing an ineffective timeout is not L2.

## H7 — Trace / quality

Specs: [trace-observability](../modules/trace-observability.md), [evals](../quality/evals.md), [contracts](../quality/contracts.md).

Required:

- trace schema version;
- exactly one truthful terminal event;
- provider/save/trace/cancel/timeout terminal fixtures;
- P0 persistence/tool/workspace failure fixtures;
- P1 compaction/redaction/provider cancellation fixtures;
- std/curl and external-consumer gates in CI.

## Dependency order

```text
P0 session + Tool + workspace + trace
  ├─► P1 context
  ├─► P1 provider deadline/cancel
  └─► P1 redaction
         │
         ▼
h-integration-001（real product composition + failure matrix）
         │
         ▼
Phase H L2 exit
  ├─► Zig SDK-ready gate
  ├─► headless/process gate
  ├─► C4 edit sharpness
  ├─► C5.1 repo map/fork
  └─► C7 sandbox/process supervisor
```

This is a DAG. Independent P0 work may overlap in isolated worktrees when task paths do not overlap; shared truth docs may require serialized merges.

## Exit

Phase H exits only when all [maturity production-floor conditions](../maturity.md#phase-h-production-floor-exit) and the linked task verifications pass. A green current test suite, package split, or partial checklist cannot waive an exit condition.
