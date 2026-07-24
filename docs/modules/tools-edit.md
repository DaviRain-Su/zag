# Module: tools-edit

| Item | Content |
|------|---------|
| Code | `packages/zag-coding-agent/src/runtime/{edit_tools,fs_tools}.zig`; `toolset.zig` |
| Current maturity | **L1+** — search/anchor edit landed; real containment/failure matrix open |
| Target | L2 H correctness → L3 C4 sharpness |
| Reference | Hyper hashline; omp; Codex apply_patch |

## Invariants

1. Every file/search Tool declares a D-007 runtime descriptor and uses real workspace containment.
2. Default editing is not limited to whole-file overwrite.
3. Anchor failure is machine-readable and non-mutating.
4. Results/output have byte budgets and truncation markers.
5. A denied/failed operation does not partially mutate without an explicit partial-success contract.

## Current Tool surface

| Tool | Role |
|------|------|
| `search_replace` | preferred unique-content-anchor edit |
| `write_file` | create or explicit full replacement |
| `read_file` / `list_dir` | file exploration |
| `grep` / `glob` | bounded content/path search |

`search_replace` requires exactly one `old_string`; zero → `anchor_not_found`, multiple → `ambiguous_anchor`, oversize → `too_large`.

## Current gap

The Tools call lexical path validation, so a workspace symlink may resolve outside the root. Existing absolute/`..` tests do not prove containment. Tool descriptors and symlink fixtures are P0 prerequisites for L2.

## L2 acceptance

- [x] default descriptions prefer `search_replace` over large overwrite.
- [x] zero/multiple anchor failures do not mutate and are tested.
- [x] grep/glob/output budgets exist.
- [ ] all file/search Tools declare descriptors and use symlink-aware containment.
- [ ] contained-path identity is shared with permission remember.
- [ ] write/edit failure fixtures prove no unintended partial mutation.
- [ ] shell/error integration uses the common lifecycle contract.

## L3 (C4)

- hashline/apply_patch-grade path;
- hunk accept/reject;
- post-edit project verification;
- multi-file atomic/partial-success policy.

## Non-goals for H

- Full AST edit engine
- IDE/TUI diff rendering
