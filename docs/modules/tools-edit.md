# Module: file tools — read/search/write/edit

| Item | Content |
|------|---------|
| Code | `packages/zag-coding-agent/src/runtime/{edit_tools,fs_tools}.zig`; `toolset.zig` |
| Current maturity | **L1+** — descriptors and symlink-aware containment landed; final Phase H audit exposed bounded-read/search and single-file commit-integrity blockers |
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

## Final-audit blockers

D-007 descriptors and h-workspace-001 symlink-aware containment are complete for every built-in file/search Tool. The final `h-integration-001` audit found two independent L2 counterexamples:

1. `write_file` and `search_replace` still use in-place truncate/write, so a later write failure can destroy prior bytes or publish a partial file.
2. count caps do not prove the shared result-byte ceiling: `list_dir`/`glob` can exceed it, `read_file` does not reliably produce its advertised oversized prefix on Zig 0.16, and walker/search cutoffs can silently present incomplete output as complete.

These are owned by [h-edit-integrity-001](../plan/tasks/h-edit-integrity-001.md) and [h-read-search-bounds-001](../plan/tasks/h-read-search-bounds-001.md). Shell remains independently L2 under [`shell-v1`](./tools-shell.md); its passing Gate does not waive file-tool contracts.

## H read/search contract

All `list_dir`, `read_file`, `grep`, and `glob` success/limit bodies are at most `tool.max_result_bytes` (64 KiB) under checked arithmetic. A handler reserves its entire incomplete marker before appending an entry, hit, path, or file prefix.

A runtime cutoff that omits otherwise eligible output ends with exactly one complete marker:

```text
... incomplete: format=fs-v1 reason=<body_limit|entry_limit|hit_limit|node_limit|depth_limit|source_limit|io_skip|pattern_limit>
```

- `read_file` keeps bounded-prefix behavior: an exact-boundary file has no marker; a larger file returns a prefix plus `reason=body_limit`, still within 64 KiB.
- list/search count and byte cutoffs are independent and explicit.
- walker node, depth, per-directory, source-size/I/O skip, and glob-complexity exhaustion cannot masquerade as complete.
- `.git`, fixed common build directories, and likely-binary files are documented search-scope exclusions rather than runtime truncation.
- containment skips never leak outside bytes. Search remains bounded and may be incomplete; it is not advertised as exhaustive under concurrent filesystem changes.

Private test-only limits or pure helpers may shrink boundaries for deterministic fixtures. They do not enter Tool JSON, Agent/Tool options, CLI, provider ABI, or production descriptors.

## H write/edit integrity contract

Both mutators build complete new bytes before opening a commit temporary. The temporary is created in the selected target's parent, receives all bytes, is writer-flushed, passes a final containment recheck, then atomically replaces the selected target.

- Existing target: any pre-commit or replace failure preserves exact prior bytes.
- Absent `write_file` target: failure preserves absence.
- Ordinary error paths clean the uncommitted temporary.
- A contained final file symlink resolves to its contained real target; commit changes that target and leaves the symlink object/link text intact. Escaping, dangling, looping, or unresolvable links remain `jail_deny`.
- Success exposes complete bytes and cannot later become an ambiguous hard failure because success text or optional diff enrichment could not allocate.
- Missing parent directories created by `write_file` may remain after a later failure; rollback is forbidden. The target is still preserved/absent, no temporary remains, and this narrow residue is reported as `parent_dirs=may_remain`.
- `search_replace` never creates parent directories; missing/ambiguous/stale/oversized pre-commit outcomes remain non-mutating.

Expected commit failures use:

```text
error: code=edit_io_failed format=edit-v1 operation=<write_file|search_replace> stage=<parent_create|temp_create|write|flush|replace> target=preserved parent_dirs=<unchanged|may_remain>
```

The first line contains no raw OS error, temporary name, absolute path, or file content and fits the trace Tool-result cap. A failed final containment recheck keeps the existing `jail_deny` result and preserves the target. `OutOfMemory` remains typed before commit; no post-commit allocation may turn success into failure.

This is software-crash/ordinary-I/O preservation only. It does not claim `fsync`/power-loss durability, hostile concurrent-filesystem safety, compare-and-swap, metadata fidelity, or multi-file atomicity.

## Permission remember boundary

Phase H remember keys are exact lexical request-path strings. An alias re-prompts, remembered approval never bypasses the execution-time Guard, and a jail-denied alias cannot gain executable authorization. Canonical filesystem-object/path-domain authorization is L3 work; same-string retargeting remains within the trusted-host/check-time TOCTOU boundary.

## L2 acceptance

- [x] default descriptions prefer `search_replace` over large overwrite.
- [x] zero/multiple anchor failures do not mutate and are tested.
- [x] all built-in file/search Tools declare descriptors and use symlink-aware containment.
- [ ] every read/list/grep/glob body is bounded and every resource cutoff has a complete `fs-v1` marker (`h-read-search-bounds-001`).
- [ ] write/edit faults preserve exact prior target state, clean temporary state, and expose stable `edit-v1` results (`h-edit-integrity-001`).
- [ ] contained final-symlink target replacement and one Agent/session/trace edit-fault chain pass (`h-edit-integrity-001`).
- [ ] lexical remember alias/jail fixtures prove the documented conservative H boundary (`h-edit-integrity-001`).
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
