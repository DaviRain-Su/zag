# Module: permissions

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/permissions.zig` |
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

A caller may inject a `permission_gate`. The Gate receives the complete `ToolDescriptor` plus arguments and any validated path context; it must not call a name-based risk fallback.

```text
Gate.check(descriptor, arguments_json, path?) → Outcome
AskFn(ctx, descriptor, arguments_json) → Decision
```

A missing ask callback in ask mode denies dangerous operations. A caller-supplied policy may be stricter than the product matrix but may not relabel missing capability metadata as read.

## Remember

- After approval of a write to a validated path, the same Agent lifetime may skip a second prompt for that path.
- Default on; `--no-remember` disables it.
- Maximum 64 paths.
- Remember keys currently use the path string extracted for the gate (same field as workspace metadata). Canonical/contained identity improvements track workspace containment work.
- Trace permission events include `risk`, `allowed`, and `remembered=true|false`.

## Plan mode

Plan mode permits read and reserved plan-file writes (`plan.md`, `.zag/plan.md`, normalized equivalent) and denies general writes/execute. Product switching UX remains C6; the enforcement semantics belong here.

## L2 acceptance

- [x] built-in read/write/execute matrix and remember behavior have tests.
- [x] Plan stub blocks shell and non-plan writes (by descriptor risk).
- [x] all Tool risk comes from a validated descriptor.
- [x] custom write/execute Tools are confirmed/denied like built-ins.
- [x] missing descriptor/risk fails registration rather than defaulting to read.
- [ ] remember keys use contained canonical path identity (workspace-001 / follow-up).
- [x] trace records descriptor-derived risk and decision.

## L3

- path/command/domain rules;
- persisted policy backend;
- full Plan UX and ACP mode mapping.

## Non-goals

- Effort/model modes
- OS sandbox enforcement
- Dynamic plugin loading in H
