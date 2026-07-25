---
id: h-read-search-bounds-001
scope: phase-h/read-search-bounds
status: in-progress
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

# develop-stage evidence

This branch adds a private bounded-body helper with complete `fs-v1` marker reservation, rewires `list_dir`, `read_file`, `grep`, and `glob` to the shared body budget, and adds deterministic private-limit fixtures for exact/N+1 read, list/grep/glob count and byte limits, walker node/depth/per-directory limits, source/pattern/io markers, symlink containment retention, and OOM propagation. Review follow-ups distinguish nested containment exclusions from runtime resolve/I/O skips, drive handler-level list iterator plus grep stat/read I/O failures through private production-path seams, close read-file N/N+1/TOCTOU body races with one-handle sentinel reads, match glob patterns relative to normalized optional scope path spellings including contained interior normalization, and keep oversized NUL-bearing binary files as intentional grep exclusions before source-size cutoff, including short-read binary-probe continuation. This is **not** task closeout; independent verification, root default/curl Gates, and final integration audit remain pending.

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
- `h-edit-integrity-001` is done; only after this task passes may `h-integration-001` return to `ready`.
