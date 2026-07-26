---
id: core-boundary-001
scope: architecture/agent-core-boundary
status: done
evidence: `d89cdbc` docs commit; independent verify PASS with no blocking findings; ff-only local-main merge; merged-main default and curl full Gates passed; docs lint/readability 91/security 71/OpenAPI 287/catalog 40; no push
priority: P0
depends-on: []
---

# objective

Replace the over-broad Agent Core ownership model with an accepted thin-loop Product Spec and a serialized migration
DAG. Supersede the proposed core `lifecycle.zig` direction before any additional lifecycle implementation merges.

This task is documentation-only. It changes target ownership and delivery order, not current runtime behavior or L2
maturity.

# context

- `docs/decisions/active/D-007-tool-runtime-descriptor.md`
- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/analysis/2026-07-26-thin-core-boundary.md`

# path

- `README.md`
- `docs/INDEX.md`
- `docs/vision.md`
- `docs/architecture.md`
- `docs/packaging.md`
- `docs/roadmap.md`
- `docs/maturity.md`
- `docs/decisions/README.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/README.md`
- `docs/modules/core-boundary.md`
- `docs/modules/loop-turn.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/context-compaction.md`
- `docs/modules/session-store.md`
- `docs/modules/trace-observability.md`
- `docs/modules/harness-events.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/README.md`
- `docs/plan/backlog.md`
- `docs/plan/analysis/2026-07-26-thin-core-boundary.md`
- `docs/plan/analysis/2026-07-26-harness-events-contract.md`
- `docs/plan/analysis/2026-07-26-pi-zig-alignment.md`
- `docs/plan/tasks/core-boundary-001.md`
- `docs/plan/tasks/core-seams-001.md`
- `docs/plan/tasks/core-session-ownership-001.md`
- `docs/plan/tasks/core-observation-ownership-001.md`
- `docs/plan/tasks/core-policy-ownership-001.md`
- `docs/plan/tasks/core-context-ownership-001.md`
- `docs/plan/tasks/harness-events-001.md`
- `packages/zag-agent-core/README.md`
- `packages/zag-coding-agent/README.md`
- generated documentation quality reports if scoring changes them

# contract

1. Core target ownership is limited to loop invariants, message/Transcript state, Provider/Tool/Cancel contracts,
   protocol-history validation, and source loop events.
2. Product permission, workspace, shell, context compaction, session persistence, Trace/redaction, Provider/model
   composition, concrete Tools, and run lifecycle belong to coding-agent.
3. `ToolPolicy`, `Jail`, `ShellPolicy`, `ContextView`, and `LoopEventSink` are explicit Core dependencies; policy/jail/shell
   have no implicit allow/yolo behavior.
4. Core retains policy → jail → shell → execute ordering, Tool metadata validation, and exactly-once transcript semantics.
5. Run preflight/start/terminal remain facade-owned. No core `lifecycle.zig` or third event channel is planned.
6. Existing L2 behavior/schema evidence is unchanged and becomes a regression Gate for every migration task.
7. No new Zig package is created solely for this migration.
8. The existing `harness-events-001` task is re-queued behind the boundary DAG and its current implementation branch is
   not merged.

# verification

1. All Product Spec and plan documents agree on Core versus coding-agent ownership.
2. The Pi comparison distinguishes low-level source layering from NPM package membership and cites the pinned snapshot.
3. Every current `zag-agent-core/src/*.zig` file has an explicit keep/split/move disposition.
4. The five required ports, missing-state behavior, fixed Tool gate order, and low-level caller trust boundary are stated.
5. Loop events and facade run events have distinct owners; Trace/headless/session mappings remain independently versioned.
6. The migration DAG enumerates all real creation/injection/call chains and uses serialized tasks with path-aware gates.
7. `harness-events-001` is no longer `ready` and cannot add `packages/zag-agent-core/src/lifecycle.zig`.
8. Documentation lint and score checks pass.
9. Independent design verification records no blocking contradiction or missing safety/ownership contract.

# non-goals

- source-code movement or API implementation;
- changing runtime behavior, L2 maturity, Trace/session/headless schemas, or CLI defaults;
- deleting or merging the existing harness-events worktree;
- pushing any local commits;
- adding steering, session fork, TUI, RPC, extensions, Graph, or sandbox behavior.

# closeout

- Product Spec and migration DAG committed at `d89cdbc` (`docs: define thin agent core boundary`).
- Independent docs-sprint verify: **pass**, no P1/blocking findings.
- Local `main` fast-forwarded from `01e330a` to `d89cdbc`; no push.
- Merged-main default `zig build test`: PASS.
- Merged-main curl `zig build test -Dhttp_backend=curl`: PASS.
- Docs lint: PASS; readability **91/100** (50 files); security **71/100** (50 files).
- OpenAPI coverage: **287/287**; model catalog: **40**, up to date.
- No `.zig` runtime code, L2 row, Trace/session/headless schema, or product default changed.
- `core-seams-001` is the next ready task. The existing Core-lifecycle harness-events branch remains unmerged and
  ineligible; no destructive cleanup or push was performed.
