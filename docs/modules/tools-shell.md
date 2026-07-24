# Module: tools-shell

| Item | Content |
|------|---------|
| Code | coding-agent `runtime/edit_tools.zig` (`run_shell`) + core `shell_policy` |
| Current maturity | **L1** — synchronous bounded basics; lifecycle/sandbox gaps open |
| Target | L2 H correctness → L3 background/process supervisor |
| Reference | Hyper background tasks; Codex sandbox shell |

## Invariants

1. Execute Tool declares `risk=execute` and passes permission then shell/process policy.
2. Shell is not made workspace-contained by the file Tool jail.
3. stdout/stderr are bounded and truncation is explicit.
4. exit, timeout, cancellation, policy denial, spawn failure, and output truncation are distinguishable.
5. A timeout/cancel owns and reaps the documented process scope; it does not leave an untracked child.

## L2 synchronous contract

- non-interactive command execution;
- structured/machine-readable `exit_code`, timeout/cancel and bounded output semantics;
- configured timeout actually executes;
- cancel integrates with run terminal state;
- fixed shell-policy matrix;
- docs state that TTY/background/process-tree sandbox are absent.

## Current gaps

- run cancellation does not preempt an in-flight Tool handler;
- shell/process ownership and result shape need failure fixtures;
- denylist is accident reduction, not OS isolation.

## L2 acceptance

- [ ] exit/timeout/cancel/policy/spawn failure matrix is stable.
- [ ] timeout/cancel has a bounded cleanup contract.
- [ ] output truncation preserves useful diagnostics and marks omitted bytes.
- [ ] required policy/security events appear in truthful trace.
- [ ] docs and behavior agree that no PTY/background/OS sandbox is present.

## L3

Background jobs require C7 process supervisor first: task IDs, monitor/output retrieval, cancel/kill, process-group ownership, bounded retained logs, and required sandbox policy for autonomous execution.

## Non-goals for H

- PTY/TUI terminal emulation
- Detached background jobs
- OS sandbox implementation
