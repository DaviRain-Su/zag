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
- built-in permission matrix + descriptor-driven custom Tool risk (D-007 L2);
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

- in-flight provider/stream cancellation/deadline (P1 provider task);
- partial Tool-call discard after cancellation.

Truthful API/error/trace terminals landed via facade (h-trace-001). H1 remains **L1+** until in-flight cancel closes.

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
Decision: [D-007](../decisions/active/D-007-tool-runtime-descriptor.md). Task: [h-tool-runtime-001](../plan/tasks/h-tool-runtime-001.md) (**in-progress** until merge).

### Landed (L2)

- model `ToolDefinition` separated from runtime `ToolCapabilities` / `ToolDescriptor`;
- stateful Tool instance pointer + instance-aware handler;
- mandatory risk / workspace / cancellation / shell metadata (no default-to-read);
- `buildTool` + `validateTools` fail closed; `loop.run` revalidates before provider;
- Gate / plan / remember / jail / shell selection are descriptor-driven (no `riskOf(name)`);
- custom write/execute/path/shell Tools share the same policy surface as built-ins;
- Provider port / WireProvider receive only `[]ToolDefinition`;
- write-path remember, Plan stub, permission trace with descriptor risk.

### Remaining (not H3 L2 blockers)

- mid-flight cancel for `.cooperative` handlers (P1 [h-provider-001](../plan/tasks/h-provider-001.md));
- full Plan UX / path-domain policies (L3 / capability);
- opaque/C ABI plugins (non-goal for H).

H3 tool-runtime + permissions are **L2** in [maturity](../maturity.md). File symlink containment is done (h-workspace-001); Workspace/Safety row stays **L1+** until redaction/doctor.

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

### Landed (h-trace-001)

- `schema_version` on `run_start` (`current_schema_version = 1`);
- facade-owned exactly one truthful terminal;
- provider/save/trace/cancel/max_turns/completed fixtures;
- typed `TraceIoFailed` / `InvalidPath` (not OOM);
- deinit release-only (no false success).

### Remaining

- timeout terminal fixtures (P1 provider);
- P1 compaction/redaction/provider cancellation fixtures;
- external-consumer gates in CI.

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
