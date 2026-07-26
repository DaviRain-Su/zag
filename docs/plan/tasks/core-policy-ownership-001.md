---
id: core-policy-ownership-001
scope: coding-agent/tool-policy-ownership
status: ready
priority: P0
depends-on:
  - core-observation-ownership-001
---

# objective

Move concrete permission/HITL, workspace containment, and shell-protection implementations to `zag-coding-agent` while
Core retains the required ports, Tool metadata validation, one-time path extraction, fixed gate order, and generic soft
Tool-result behavior.

# context

- `docs/decisions/active/D-007-tool-runtime-descriptor.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/tool-runtime.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/tools-shell.md`

# path

- `packages/zag-agent-core/src/permissions.zig`
- `packages/zag-agent-core/src/workspace.zig`
- `packages/zag-agent-core/src/shell_policy.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/tool.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- `packages/zag-coding-agent/src/doctor.zig`
- `packages/zag-coding-agent/src/runtime/`
- destination coding-agent policy/workspace modules
- `packages/zag-cli/src/cli.zig`
- policy/workspace/shell/doctor/SDK fixtures
- `docs/modules/core-boundary.md`
- `docs/modules/tool-runtime.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/tasks/core-policy-ownership-001.md`
- generated quality reports

# contract

1. Core keeps mandatory ToolDescriptor/Capabilities validation and one-time argument/path extraction.
2. Core invokes required ToolPolicy → Jail → ShellPolicy ports before execute; none has an implicit allow/yolo default.
3. Coding-agent provides ask/yolo/plan semantics, remember state, workspace Guard, shell protect/disabled modes, and
   product deny bodies/events.
4. Product default remains ask + workspace jail + shell protect. Yolo bypasses confirmation only.
5. Built-in file handlers retain their defense-in-depth containment checks; custom Tool contracts remain D-007 truthful.
6. Denials are stable soft Tool results and execute no handler; host/OOM failures stay typed.
7. CLI stdin prompting and doctor/readiness remain product/CLI concerns.

# verification

- custom write/execute Tool fixtures prove descriptor-derived policy and handler count zero on deny.
- missing/invalid capabilities still fail before provider call.
- same extracted path reaches permission and jail; alias remember never bypasses Guard.
- escaping/dangling paths, contained symlinks, defaulted paths, dangerous shell patterns, plan mode, yolo, and doctor
  matrices remain green.
- direct low-level permissive composition is explicit in source; product defaults never select it silently.
- Core source/root scan exposes only generic ports and Tool runtime, not concrete policy/workspace/shell implementations.
- package tests, SDK fixture, root std/curl suites, headless fixture, docs lint, and quality checks pass.

# non-goals

- OS sandbox, process supervisor, command-domain policy, canonical remember identity, or mid-flight Tool cancellation;
- changing D-007 metadata or current user-visible defaults;
- creating `zag-workspace` solely for this move.
