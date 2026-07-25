---
id: h-read-search-bounds-001
scope: phase-h/read-search-bounds
status: done
priority: P1
depends-on: [h-tool-runtime-001, h-workspace-001]
---

# objective

Close the Phase H bounded-output blocker for default `list_dir`, `read_file`, `grep`, and `glob`. Every returned Tool body must fit the shared 64 KiB ceiling, and every runtime cutoff or skipped eligible input that can make a result incomplete must be visible rather than masquerading as a complete listing/search.

This task does not make traversal exhaustive and does not add regex, ranking, repo maps, LSP, or C4 edit capability.

# contract

The owning contract is [`docs/modules/tools-edit.md`](../../modules/tools-edit.md), with containment cross-checked against [`docs/modules/workspace-sandbox.md`](../../modules/workspace-sandbox.md).

## shared body budget

- Every success or recoverable-limit body from all four handlers is `<= tool.max_result_bytes` using checked arithmetic.
- Before appending an entry/hit/path/prefix, reserve the complete limit marker; never append the marker after consuming its space.
- Count ceilings and byte ceilings are independent and have exact N/N+1 evidence.

## explicit incomplete marker

Any runtime cutoff that omits otherwise eligible output ends with one complete marker:

```text
... incomplete: format=fs-v1 reason=<body_limit|entry_limit|hit_limit|node_limit|depth_limit|source_limit|io_skip|pattern_limit>
```

The first terminating/observed reason is stable and sufficient to state that output is incomplete. The marker itself must always fit the body budget.

- `list_dir` reports entry, body, and iteration-I/O cutoffs.
- `read_file` keeps its documented bounded-prefix behavior: the returned prefix plus `reason=body_limit` marker fits 64 KiB; an exact-boundary file has no marker.
- `grep` and `glob` report hit/body, walker node/depth/per-directory, source-size/I/O skip, and glob-complexity exhaustion as applicable.
- `.git`, common build directories, and likely-binary files remain documented intentional search-scope exclusions, not accidental runtime truncation.
- Nested escaping/dangling paths remain safely skipped under the containment contract and must not leak outside bytes; the result must not claim full workspace completeness when an otherwise eligible contained path was skipped for a runtime resource/I/O reason.

# deterministic evidence

Use extracted pure helpers or private test-only limits so boundary tests remain small and fast; do not create brittle 4097-node physical trees. Test controls must not enter Tool JSON, `Agent.Options`, `tool.Context`, CLI flags, provider ABI, or production descriptors.

Fixtures must cover:

1. each handler body at exactly the budget and one byte/entry/hit over;
2. `read_file` exact boundary and oversized bounded prefix with a complete marker;
3. list entry and byte cutoffs;
4. grep hit/body cutoff and oversized/unreadable source indication;
5. glob hit/body cutoff and pattern-frame exhaustion indication;
6. walker node, depth, and per-directory cutoffs;
7. stable marker reservation under the longest supported reason;
8. existing symlink-loop, contained-symlink, nested-escape, and jail-deny behavior;
9. no OOM or arithmetic overflow is converted into a fake complete result.

# remains post-H

- exhaustive traversal under arbitrary concurrent filesystem changes;
- regex/fuzzy/ranked search;
- configurable ignore files beyond the documented fixed scope;
- repo maps, LSP, AST indexing, pagination, and streaming results;
- generic runtime enforcement for third-party Tool bodies unless separately specified.

# context

- `docs/modules/tools-edit.md`
- `docs/modules/workspace-sandbox.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-coding-agent/src/runtime/fs_tools.zig`
- `docs/modules/tools-edit.md`
- `docs/quality/evals.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/plan/tasks/h-read-search-bounds-001.md`
- `chapters/01-edit-permissions/README.md`
- `chapters/H-harden/README.md`

# closeout evidence

Task commits have been ff-only merged to local `main`. The delivery completed the reviews 01–10 review/fix cycle plus the final adversarial ship panel; the final independent review 10 verdict was **PASS** and the final adversarial ship panel verdict was **SHIP**. Earlier reviews and panels blocked several times and drove fixes, so this record intentionally does not claim that every intermediate review passed.

Merged-main evidence:

- `packages/zag-types`: **12/12**;
- `packages/zag-agent-core`: **157/157**;
- `packages/zag-coding-agent`: **138/138**;
- root default Gate: **432/432**;
- curl Gate: **431/431**;
- docs lint passed;
- readability **91/100**;
- security-awareness **65/100**;
- OpenAPI **287/287**;
- catalog **40** passed;
- required summaries had no explicit skips.

The closed scoped contract covers four handler bodies `<= 64 KiB`, complete first `fs-v1` incomplete markers, `read_file` N/N+1/growth evidence, walker node/depth/per-directory/I/O cutoffs, source/binary/pattern evidence, fixed search-scope exclusions, generic bounded path/name-free jail and unknown-tool bodies, required/defaulted descriptor behavior, and real Agent evidence. Fixed `.git` and build-directory exclusions are intentional search-scope exclusions, and likely-binary detection remains a probe heuristic. Generic bounded jail/unknown bodies are Tool body contracts only; trace/audit fields keep their separate redacted/capped path contract. Provider-visible schemas still contain only `ToolDefinition`; the public union surface is not SDK-ready.

This closes the read/search L2 blocker only. `h-integration-001` subsequently passed the fresh 11-sentence audit at `d22ce6e` (11/11 PASS, panel SHIP), closing Phase H at L2 for single-user trusted-host scope. This task does not claim OS sandboxing, process-tree ownership, mid-flight Tool preemption, exhaustive concurrent traversal, or generic third-party handler-body enforcement.

# verification

- every four-handler body is bounded by checked arithmetic;
- every defined cutoff emits the complete stable marker and no incomplete result is labeled complete;
- exact N/N+1 tests run through production helpers with small injected limits;
- existing containment and normal-path behavior do not regress;
- focused coding-agent tests pass under applicable backends;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- independent worktree review and merged-main std/curl Gate pass;
- `h-edit-integrity-001` is done; this task has passed, and `h-integration-001` subsequently passed the fresh 11-sentence audit at `d22ce6e` (11/11 PASS, panel SHIP), closing Phase H at L2 for single-user trusted-host scope.
