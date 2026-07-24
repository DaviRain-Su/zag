# Module: tools-edit

| Item | Content |
|------|---------|
| Code | `packages/zag-coding-agent/src/runtime/{edit_tools,fs_tools}.zig`; `toolset.zig` |
| Current maturity | **L1+** — descriptors and symlink-aware containment landed; write-fault claims remain conservative; shell package evidence landed but its Gate is pending |
| Target | L2 H correctness → L3 C4 sharpness |
| Reference | Hyper hashline; omp; Codex apply_patch |

## Invariants

1. Every file/search Tool declares a D-007 runtime descriptor and uses real workspace containment.
2. Default editing is not limited to whole-file overwrite.
3. Anchor failure is machine-readable and non-mutating.
4. Results/output have byte budgets and explicit limit semantics.
5. A denied/failed operation does not partially mutate without an explicit partial-success contract.

## Current Tool surface

| Tool | Role |
|------|------|
| `search_replace` | preferred unique-content-anchor edit |
| `write_file` | create or explicit full replacement |
| `read_file` / `list_dir` | file exploration |
| `grep` / `glob` | bounded content/path search |

`search_replace` requires exactly one `old_string`; zero → `anchor_not_found`, multiple → `ambiguous_anchor`, oversize → `too_large`.

## Current gaps

D-007 descriptors and h-workspace-001 symlink-aware containment are complete for every built-in file/search Tool. The remaining L2 claims are narrower:

- canonical contained-path identity is not yet shared/proven for permission remember;
- write/edit fault fixtures do not yet establish an atomic truncate-write or general no-partial-write guarantee;
- the separate [`shell-v1` contract](./tools-shell.md) and Agent/trace package evidence have landed in `h-shell-001`, whose independent/main Gate is still pending.

Do not infer an atomic write guarantee merely from containment success. Read/search containment evidence may be promoted independently after its row is audited; it does not waive write/edit failure requirements.

## L2 acceptance

- [x] default descriptions prefer `search_replace` over large overwrite.
- [x] zero/multiple anchor failures do not mutate and are tested.
- [x] grep/glob/output budgets exist.
- [x] all built-in file/search Tools declare descriptors and use symlink-aware containment.
- [ ] contained-path identity is shared with permission remember.
- [ ] write/edit failure fixtures prove no unintended partial mutation.
- [x] shell/error integration package fixtures pass the common lifecycle contract (`h-shell-001`); independent/main Gate remains pending and does not promote this row.

## L3 (C4)

- hashline/apply_patch-grade path;
- hunk accept/reject;
- post-edit project verification;
- multi-file atomic/partial-success policy.

## Non-goals for H

- Full AST edit engine
- IDE/TUI diff rendering
