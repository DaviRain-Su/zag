# Module: file tools — read/search/write/edit

| Item | Content |
|------|---------|
| Code | `packages/zag-coding-agent/src/runtime/{edit_tools,fs_tools}.zig`; `toolset.zig` |
| Current maturity | **L2** — write/edit after h-edit-integrity-001; read/search after h-read-search-bounds-001 closeout; Phase H closed at `d22ce6e` via fresh 11-sentence integration audit PASS/panel SHIP |
| Target | L2 H correctness → L3 C4 sharpness |
| Reference | Hyper hashline; omp; Codex apply_patch |

## Invariants

1. Every file/search Tool declares a D-007 runtime descriptor and uses real workspace containment.
2. Default editing is not limited to whole-file overwrite.
3. Anchor failure is machine-readable and non-mutating.
4. Every result body has a checked byte budget and every incomplete listing/search has explicit limit semantics.
5. A denied/failed mutation does not partially publish target bytes without an explicit partial-success contract.

## Tool surface

| Tool | Role |
|------|------|
| `search_replace` | preferred unique-content-anchor edit |
| `write_file` | create or explicit full replacement |
| `read_file` / `list_dir` | file exploration |
| `grep` / `glob` | bounded content/path search |

`search_replace` requires exactly one `old_string`; zero → `anchor_not_found`, multiple → `ambiguous_anchor`, oversize → `too_large`.

## Final-audit disposition

D-007 descriptors and h-workspace-001 symlink-aware containment are complete for every built-in file/search Tool. `list_dir`, `read_file`, `write_file`, and `search_replace` use required `path_field` descriptors; missing or present-empty required paths are `invalid_arguments` rather than cwd aliases. `grep` and `glob` use the explicit defaulted path descriptor (`field="path", default_path="."`) so provider calls that omit `path` or pass an empty `path` still pass through permission and jail as `.`. Unknown tool results use a generic bounded `unknown_tool` body that does not echo the model-supplied name. The final `h-integration-001` audit found two independent L2 counterexamples:

1. direct truncate/write could destroy prior bytes or publish a partial file — **closed** by [h-edit-integrity-001](../plan/tasks/h-edit-integrity-001.md);
2. count caps did not prove the shared result-byte ceiling, and walker/search cutoffs could look complete — **closed** by [h-read-search-bounds-001](../plan/tasks/h-read-search-bounds-001.md).

### Edit-integrity delivery evidence

Both production truncate writes are gone. One same-parent `Io.File.Atomic` helper validates endpoint shape, proves canonical target/parent containment, preallocates mandatory success and staged-failure bodies, writes complete bytes, flushes, rechecks Guard, and replaces the selected target. Failure cleanup explicitly closes/deletes/verifies and chooses prepared result ownership allocation-free. Contained final file symlinks retain their entry/text while the resolved target changes. A real signaled optional-diff child proves post-commit enrichment cannot replace mandatory success.

The independent reviews 01–04 review/fix cycle drove and verified endpoint/outside-staging, cleanup truth, post-staging OOM, and stdout-ownership fixes; final Oracle re-review shipped the cleanup boundary. After ff-only merge, main passed default **402/402** and curl **401/401**, with supported macOS fixtures reporting no skips. Write/edit is therefore L2 for the scoped contract below. Read/search is also L2 for the bounded-output contract below after its reviews 01–10 review/fix cycle, final review 10 PASS, final adversarial ship panel SHIP, and merged-main Gates. Overall Phase H closed at `d22ce6e` after the fresh 11-sentence integration audit PASS and panel SHIP; shell stays separately L2 under [`shell-v1`](./tools-shell.md).

## H read/search contract

All `list_dir`, `read_file`, `grep`, and `glob` success/limit bodies are at most `tool.max_result_bytes` (64 KiB) under checked arithmetic. A handler reserves its entire incomplete marker before appending an entry, hit, path, or file prefix.

A runtime cutoff that omits otherwise eligible output ends with exactly one complete marker:

```text
... incomplete: format=fs-v1 reason=<body_limit|entry_limit|hit_limit|node_limit|depth_limit|source_limit|io_skip|pattern_limit>
```

- `read_file` keeps bounded-prefix behavior: an exact-boundary file has no marker; a larger file returns a prefix plus `reason=body_limit`, still within 64 KiB.
- list/search count and byte cutoffs are independent and explicit.
- walker node, depth, per-directory, source-size/I/O skip, and glob-complexity exhaustion cannot masquerade as complete.
- `.git`, fixed common build directories, and likely-binary files are documented search-scope exclusions rather than runtime truncation; direct scopes and walk-discovered directories use the same fixed-directory exclusion boundary, while ordinary files with the same basename remain eligible.
- containment skips never leak outside bytes. Jail-deny Tool bodies use the stable generic `error: code=jail_deny ...` message and never interpolate raw paths; trace keeps its separate redacted/capped path contract. Search remains bounded and may be incomplete; it is not advertised as exhaustive under concurrent filesystem changes.

Private test-only limits or pure helpers may shrink boundaries for deterministic fixtures. They do not enter Tool JSON, Agent/Tool options, CLI, provider ABI, or production descriptors.

Closeout evidence in `h-read-search-bounds-001` implements and verifies shared `fs-v1` marker reservation, bounded read prefixes, exact N/N+1 and growth behavior, walker node/depth/per-directory/I/O reasons, source-size/binary-probe/pattern-limit reasons, fixed `.git`/build-directory exclusions, generic bounded path/name-free jail/unknown bodies, and required/defaulted descriptors with real Agent evidence. The task passed reviews 01–10 review/fix cycle, final review 10 PASS, final adversarial ship panel SHIP, and merged-main default/curl Gates. This is scoped read/search L2, not exhaustive concurrent traversal or generic enforcement for third-party Tool bodies.

## H write/edit integrity contract

Both mutators build complete new bytes before opening a commit temporary. Before parent creation/staging they reject trailing host separators, final `.`/`..`, workspace-root-resolving endpoints, and existing directory/non-file endpoints. Existing endpoints must be regular files strictly below Guard root. Interior normalization such as `dir/../file` remains valid only when Guard and the canonical selected parent prove containment.

After selection, the target is re-proven strictly below Guard root and the staging parent is proven root-or-descendant before opening it. Once `parent_dirs` is known, the handler preallocates the stable temp-create, write, flush, replace, final-containment, and cleanup-precedence bodies for the current operation before opening that parent. The temporary is then created in the selected target parent, receives all bytes, is writer-flushed, passes a final containment recheck, then atomically replaces the selected target.

After staging, cleanup classification and owned-body selection are allocation-free: one prepared body transfers to the caller and every unselected body is freed exactly once. A Guard OOM remains typed only when cleanup confirms temporary absence; if cleanup cannot confirm deletion, the prepared `temp_cleanup` result takes precedence, so a known artifact can never be masked by result-allocation OOM.

- Existing target: any pre-commit or replace failure preserves exact prior bytes.
- Absent `write_file` target: failure preserves absence.
- Once a temporary exists, failure handling explicitly closes it, attempts deletion, and verifies absence when possible. Confirmed deletion reports `temp_artifact=absent`; unconfirmed deletion reports `stage=temp_cleanup` and `temp_artifact=may_remain` without exposing the name.
- A contained final file symlink resolves to its contained real target; commit changes that target and leaves the symlink object/link text intact. Escaping, dangling, looping, or unresolvable links remain `jail_deny`.
- Success exposes complete bytes and cannot later become an ambiguous hard failure. Optional diff stdout has one owner: exited capture transfers it to enrichment; capture/non-exited term frees it once and retains the mandatory success body; merge-format allocation failure also retains that body.
- Missing parent directories created by `write_file` may remain after a later failure; rollback is forbidden. The target is still preserved/absent and this residue is reported as `parent_dirs=may_remain`; temporary state is reported independently by `temp_artifact`.
- `search_replace` never creates parent directories; missing/ambiguous/stale/oversized pre-commit outcomes remain non-mutating.

Expected commit failures with confirmed absence of any temporary use:

```text
error: code=edit_io_failed format=edit-v1 operation=<write_file|search_replace> stage=<parent_create|temp_create|write|flush|replace> target=preserved parent_dirs=<unchanged|may_remain> temp_artifact=absent
```

Cleanup failure takes precedence over the primary post-create failure:

```text
error: code=edit_io_failed format=edit-v1 operation=<write_file|search_replace> stage=temp_cleanup primary_stage=<write|flush|containment|replace> target=preserved parent_dirs=<unchanged|may_remain> temp_artifact=may_remain
```

The first line contains no raw OS error, temporary name, absolute path, or file content and fits the trace Tool-result cap. `temp_artifact=may_remain` is confined to `stage=temp_cleanup` and to the validated staging parent. A failed final containment recheck with confirmed cleanup keeps `jail_deny`, preserves the target, and reports `temp_artifact=absent`; cleanup failure instead uses the precedence form above. `OutOfMemory` remains typed before commit; no post-commit allocation may turn success into failure.

The Agent edit-fault fixture uses yolo to compose the production handler with transcript/session/resume/trace. It does not prove prompting. Ask/remember evidence lives in separate core fixtures. Trace correlation is single-call name/body/count correlation: transcript/session own Tool-call ID pairing, while trace `tool_result` has no call ID.

This is software-crash/ordinary-I/O preservation only. It does not claim `fsync`/power-loss durability, hostile concurrent-filesystem safety, compare-and-swap, metadata fidelity, or multi-file atomicity.

## Permission remember boundary

Phase H remember keys are exact lexical request-path strings. An alias re-prompts, remembered approval never bypasses the execution-time Guard, and a jail-denied alias cannot gain executable authorization. Canonical filesystem-object/path-domain authorization is L3 work; same-string retargeting remains within the trusted-host/check-time TOCTOU boundary.

## L2 acceptance

- [x] default descriptions prefer `search_replace` over large overwrite.
- [x] zero/multiple anchor failures do not mutate and are tested.
- [x] all built-in file/search Tools declare descriptors and use symlink-aware containment.
- [x] every read/list/grep/glob body is bounded and every resource cutoff has a complete `fs-v1` marker (`h-read-search-bounds-001`).
- [x] endpoint-shape/root/directory aliases reject before creation or staging, while valid interior normalization stays contained (`h-edit-integrity-001`).
- [x] write/edit faults preserve exact prior target state and expose cleanup-truthful `edit-v1` results with allocation-free post-staging selection (`h-edit-integrity-001`).
- [x] non-exited optional diff capture with owned stdout cannot abort or replace mandatory post-commit success (`h-edit-integrity-001`).
- [x] contained final-symlink target replacement and one Agent/session/trace edit-fault chain pass (`h-edit-integrity-001`).
- [x] lexical remember alias/jail fixtures prove the conservative H boundary (`h-edit-integrity-001`).
- [x] shell/error integration passes its separate lifecycle contract and independent/main Gate (`h-shell-001`).

## L3 (C4)

- hashline/apply_patch-grade path;
- hunk accept/reject;
- post-edit project verification;
- multi-file atomic/partial-success policy;
- optional canonical path/domain permission policy and external-writer compare-and-swap.

## Non-goals for H

- Full AST edit engine
- IDE/TUI diff rendering
- Power-loss durability or OS sandboxing
