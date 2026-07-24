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

### Remaining for H

- h-integration-001 must prove a complete accepted multi-Tool turn cancelled **between** invocations remains ID-paired, save/resume-safe, and truthfully terminal across the Agent product path.

Provider in-flight cancel/deadline landed in h-provider-001. Preempting an already running Tool/shell handler requires process ownership and bounded cleanup; it remains explicit post-H shell/process work and is not assigned to h-provider-001. H1 remains **L1+** until the real-composition Gate passes, not because H claims mid-flight handler preemption.

## H2 — Edit/search/shell

Specs: [tools-edit](../modules/tools-edit.md), [tools-shell](../modules/tools-shell.md).

### Landed

- `search_replace` with unique anchor and stable error codes;
- `grep` / `glob` with result budgets;
- `write_file` for create/full replacement;
- optional post-write diff;
- all built-in file Tools use descriptor-selected real containment (h-workspace-001);
- shell policy/timeout/truncation basics.

### Remaining

- shell error/deadline/cancel shape must align with H lifecycle contracts;
- C4 edit sharpness/change review remains post-H capability.

## H3 — Tool runtime / permissions

Specs: [tool-runtime](../modules/tool-runtime.md), [permissions](../modules/permissions.md).
Decision: [D-007](../decisions/active/D-007-tool-runtime-descriptor.md). Task: [h-tool-runtime-001](../plan/tasks/h-tool-runtime-001.md) (**done**).

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

- mid-flight preemption for `.cooperative` handlers (post-H shell/process ownership; not h-provider-001 and not an H3 L2 blocker);
- full Plan UX / path-domain policies (L3 / capability);
- opaque/C ABI plugins (non-goal for H).

H3 tool-runtime + permissions are **L2** in [maturity](../maturity.md). File symlink containment, secret redaction, and the doctor report are implemented (h-workspace-001, h-redact-001, h-doctor-001 in-progress); Workspace/Safety row stays **L1+** until independent doctor acceptance and h-integration-001.

## H4 — Context / Session

Specs: [context-compaction](../modules/context-compaction.md), [session-store](../modules/session-store.md).

### Landed

- four prompt layers;
- view-only heuristic compaction without transcript deletion;
- session schema v1 and legacy parsing;
- compaction metadata/trace event plumbing.

### Remaining (capability / C5)

- repo map, session fork/tree, optional LLM summary (not H L2 blockers).

### Closed for H4 L2

- P0 session explicit open, atomic save preservation, visible errors, exclusive writer (D-006);
- P1 final-view compaction accounting and summary lineage (h-context-001);
- session/trace integration fixtures for the same final event.

H4 Context/Compaction is **L2** in [maturity](../maturity.md). Repo map/fork/Memory stay C5.

## H5 — Safety

Spec: [workspace-sandbox](../modules/workspace-sandbox.md).

### Landed

- symlink-aware containment for all file Tools (P0 h-workspace-001);
- fixed shell-policy matrix (denylist; not OS sandbox);
- explicit trusted-host/non-OS-sandbox threat model in SECURITY + module docs.

### Landed

- shared secret redaction before verbose/trace/session (P1 h-redact-001); known-key/shape only; `.zag/` still sensitive; no DLP/zeroization claim.

### Landed (doctor)

- provider-independent, path-free doctor/readiness output: [h-doctor-001](../plan/tasks/h-doctor-001.md) (**in-progress** — typed report + `zag --doctor` before resolve; no-key/matrix/unresolvable/secret fixtures).

### Remaining

- formal doctor acceptance after independent review / main-branch verification (row stays L1+);
- default Agent policy/containment real-composition evidence: [h-integration-001](../plan/tasks/h-integration-001.md) (waits on doctor Gate);
- OS sandbox/process supervisor remains C7 (required before higher-autonomy claims).

## H6 — Provider

Spec: [zag-ai-provider](../modules/zag-ai-provider.md).

### Landed

- OpenAI-compatible and Anthropic wire adapters;
- canonical errors, retry, ChatOptions, usage/cost, provider fixtures;
- std/curl selectable transports;
- curl active deadline/cancel; std capability-truth `unsupported_control` (h-provider-001);
- incomplete Tool-call fragment discard; retry ownership;
- HTTP/openai-zig diagnostics: status + body length only; never Authorization/body (h-redact-001).

### Remaining

- broader contract matrix / multi-key fallback (capability).

## H7 — Trace / quality

Specs: [trace-observability](../modules/trace-observability.md), [evals](../quality/evals.md), [contracts](../quality/contracts.md).

### Landed (h-trace-001)

- `schema_version` on `run_start` (`current_schema_version = 1`);
- facade-owned exactly one truthful terminal per reply-run;
- non-destructive preflight + atomic final replace (prior bytes preserved on fault);
- per-reply buffer/ledger reset; durable path = latest completed reply;
- transactional `writeObj`; fail-closed precedence when failure-terminal persist fails;
- provider/save/trace/cancel/max_turns/completed + invalid_toolset fixtures;
- typed `TraceIoFailed` / `InvalidPath` (not OOM);
- deinit release-only (no false success).

### Landed (h-redact-001)

- secret redaction before serialize when redactor attached (product path);
- public `stop_reason` redaction; Agent-controlled vocabulary allocation-free;
- Agent clears `trace.redactor` on every reply exit.

### Remaining

- external-consumer gates in CI;
- dashboard / correlation (L3).

## Dependency order

```text
P0 session + Tool + workspace + trace
  ├─► P1 context ✅
  ├─► P1 provider deadline/cancel ✅
  └─► P1 redaction ✅
         │
         ▼
h-doctor-001（provider-independent readiness truth）in-progress
         │
         ▼
h-integration-001（two missing Agent composition chains + matrix audit）
         │
         ▼
Phase H L2 exit decision
  ├─► Zig SDK-ready gate
  ├─► headless/process gate
  ├─► C4 edit sharpness
  ├─► C5.1 repo map/fork
  └─► C7 sandbox/process supervisor
```

This is a DAG. Independent P0 work may overlap in isolated worktrees when task paths do not overlap; shared truth docs may require serialized merges.

## Exit

Phase H exits only when h-doctor-001 and h-integration-001 pass independent review, both backends pass again on main, and all [maturity production-floor conditions](../maturity.md#phase-h-production-floor-exit) remain true. A green current test suite, package split, or partial checklist cannot waive an exit condition. The exit does not claim preemption of an already running Tool/shell handler.
