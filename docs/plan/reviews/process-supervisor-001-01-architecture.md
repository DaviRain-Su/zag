# Review: process-supervisor-001 — architecture / ownership

- Task: [process-supervisor-001](../tasks/process-supervisor-001.md)
- Binding: [process-supervisor.md](../../modules/process-supervisor.md)
- Code: `packages/zag-coding-agent/src/runtime/process_supervisor.zig`
  + `run_shell` → `runForeground` in `runtime/edit_tools.zig`
- Track: architecture / ownership (Wave 1a)
- Result: **PASS** (zero blockers; §8 four freezes accepted; P3 nits below)

## Scope

Does the landed supervisor stay inside `zag-coding-agent`, avoid Core
process ports, avoid Session PID fields, and match the §8 v1 freeze?

## §8 freeze — accepted

| # | Proposed freeze | Evidence |
|---|-----------------|----------|
| 1 | Single file, no new package | `runtime/process_supervisor.zig`; `root.zig` re-exports |
| 2 | Atomic `run_shell` migration, no dual flag | `edit_tools.zig` calls `supervisor.runForeground` only |
| 3 | Portable direct-child PID | `std.process.spawn` / `std.process.run`; no `setpgid` |
| 4 | Reuse shell-v1 atoms; add supervisor codes | `Code` enum includes `spawn_failed` / `timed_out` / `cancelled`; `run_shell` still emits shell-v1 first-lines via `shellRunError` |

## What holds

- **D-011.** No `std.process` in `zag-agent-core` (repo grep). Core keeps
  Cancel / ShellPolicy ports only.
- **No Session PID fields.** Supervisor state is process-memory `Handle`.
- **zag-live exception.** [zag-live.md](../../modules/zag-live.md) §2 owns
  its Chez child; this review does not require zag-live to import Supervisor.
- **CLI/TUI.** No direct `kill` of `run_shell` children; signals still go
  through existing Cancel / `sigint.Guard`.
- **Two backends, one owner.** `runForeground` preserves shell-v1
  pump/timeout/limit. `spawn` / `cancel` / `wait` / `collect` exist for
  cancel fixtures and later long-lived slots. Both live in this file.

## Non-blocking notes

- **N1 (P3).** `collect` does not pump pipes on the `spawn` path. v1
  `run_shell` does not use `collect`; long-lived slots must not pretend
  this API already streams stdio.
- **N2 (P3).** Fixture 7 was policy-lookup only. Closeout adds
  `rejectDeniedShell` as the supervisor-side fail-closed seam. Core
  ShellPolicy remains the product gate before the handler.
- **N3 (P3).** Ambient child env is inherited on `spawn` / `runForeground`.
  Explicit allow-list is a later slot/MCP concern, not a v1 shell regression
  (shell-v1 already inherited).

## Decision

**PASS** — architecture/ownership freeze is implementable and already
matches HEAD. Does not raise Shell/Workspace maturity. Does not authorize
OS sandbox, process-group reaper, or MCP/LSP protocol work.
