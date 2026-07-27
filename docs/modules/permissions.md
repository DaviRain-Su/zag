# Module: permissions

| Item | Content |
|------|---------|
| Current code | `packages/zag-coding-agent/src/permissions.zig` (moved from Core by core-policy-ownership-001) |
| D-011 target | required `ToolPolicy` port + `deniedBody` renderer in Core; concrete Gate/remember/prompt policy in coding-agent |
| Current maturity | **L2** — descriptor-derived risk; custom tools share the same gate |
| Target | L3 fine-grained rules + product Plan UX |
| Decision | [D-007](../decisions/active/D-007-tool-runtime-descriptor.md) |
| CLI | `--ask` / `--yolo` · `--plan` · `--no-remember` |

## Purpose

Permission policy decides whether an otherwise valid Tool invocation may proceed. Tool registration and capabilities are defined in [tool-runtime](./tool-runtime.md); workspace containment and shell policy remain independent gates after permission.

```text
ToolDescriptor → permission → workspace containment → shell policy → execute
```

## Invariants

1. Product default is `ask`; production documentation never defaults to yolo.
2. Write/execute cannot become read because a tool name is unknown.
3. Every registered Tool has explicit runtime risk metadata; missing/invalid metadata fails closed at `buildTool` / `validateTools` / `loop.run` (before provider).
4. Denial is a machine-readable soft Tool result so the model may adapt.
5. yolo bypasses confirmation only; it does not bypass workspace or shell/sandbox enforcement.
6. `SessionKind.plan` blocks general write/execute even under yolo.
7. Unknown model-requested tools soft-fail as `unknown_tool` without name-based risk inference.

## Risk matrix

| Risk | Typical built-ins | ask | yolo | plan |
|------|-------------------|-----|------|------|
| `read` | list/read/grep/glob | allow | allow | allow |
| `write` | search_replace/write_file | confirm | allow | only reserved plan files |
| `execute` | run_shell | confirm | allow | deny |

The examples do not define classification. `ToolDescriptor.capabilities.risk` does.

## Gate API

A caller may inject a `permission_gate`. The Gate receives the complete `ToolDescriptor` plus arguments and the single extracted path context when the descriptor declares one. Required paths stay required and present-empty required paths fail before the Gate; explicit defaulted paths (for example grep/glob missing or empty `path` → `.`) are passed to the Gate and then jail-checked. The Gate must not call a name-based risk fallback.

```text
Gate.check(descriptor, arguments_json, path?) → Outcome
AskFn(ctx, descriptor, arguments_json) → Decision
```

A missing ask callback in ask mode denies dangerous operations. A caller-supplied policy may be stricter than the product matrix but may not relabel missing capability metadata as read.

## Remember

- After approval of a write to a validated path, the same Agent lifetime may skip a second prompt for that exact lexical request-path string.
- Default on; `--no-remember` disables it. Maximum 64 paths.
- H intentionally treats the key as request spelling, not canonical filesystem-object identity: aliases such as `a.txt` and `./a.txt` re-prompt.
- Remembered approval never bypasses the execution-time workspace Guard. An escaping/dangling alias is still denied, and a denied alias does not create an executable authorization.
- Same-string filesystem retargeting remains inside the documented trusted-host/check-time TOCTOU boundary. Canonical object/path-domain authorization is L3 work.
- Trace permission events include `risk`, `allowed`, and `remembered=true|false`.

## Plan mode

Plan mode permits read and reserved plan-file writes (`plan.md`, `.zag/plan.md`, normalized equivalent) and denies general writes/execute. Product switching UX remains C6; the enforcement semantics belong here.

## L2 acceptance

- [x] built-in read/write/execute matrix and remember behavior have tests.
- [x] Plan stub blocks shell and non-plan writes (by descriptor risk).
- [x] all Tool risk comes from a validated descriptor.
- [x] custom write/execute Tools are confirmed/denied like built-ins.
- [x] missing descriptor/risk fails registration rather than defaulting to read.
- [x] exact lexical remember keys re-prompt for aliases and never bypass Guard/jail (`h-edit-integrity-001` independent/main Gate passed).
- [x] canonical filesystem-object/path-domain authorization is explicitly L3 rather than an H claim.
- [x] trace records descriptor-derived risk and decision.

## L3

- path/command/domain rules;
- persisted policy backend;
- full Plan UX and ACP mode mapping.

## C4 note — hunk review is not permission prompt

`edit-sharpness-001` (contract PASS @ `07b8dab`; first-slice on branch, task in-progress/L2;
[tools-edit](./tools-edit.md)) freezes a coding-agent-owned **`HunkReviewer`**
separate from this Gate:

- `StdinPrompter` / `formatPermissionPrompt` remain **risk + args_len only** and must
  **not** be extended or labeled as hunk review.
- Permission allow does **not** satisfy `apply_hunk` review; missing/null reviewer is
  fail-closed (`review_unavailable`), never implicit accept.
- Lexical path **remember** continues to apply only to write permission; first-slice
  review decisions are **never** remembered and never skip review.
- Gate order stays **ToolPolicy → Jail → ShellPolicy → execute**; review runs **inside**
  the coding-agent `apply_hunk` handler after execute is entered.
- Product reviewer bind precedence (B2 first-match): plan/permission deny → no review
  path; else CLI `--yolo` → AutoAccept (incl. headless JSON); else interactive
  non-headless ask → InteractiveHunkReviewer; else null. SDK host injects; explicit
  AutoAccept-equivalent is bound, not missing.

## Non-goals

- Effort/model modes
- OS sandbox enforcement
- Dynamic plugin loading in H
