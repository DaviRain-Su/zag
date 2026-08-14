# Review: process-supervisor-001 — safety / lifecycle

- Task: [process-supervisor-001](../tasks/process-supervisor-001.md)
- Binding: [process-supervisor.md](../../modules/process-supervisor.md)
- Code: `packages/zag-coding-agent/src/runtime/process_supervisor.zig`
- Track: safety / lifecycle (Wave 1a)
- Result: **PASS** after closeout fix F1 (reap after cancel). P3 residuals below.

## Scope

One Terminal per started child; bounded output; cooperative then hard
kill; no silent zombies under the test harness; jail/policy fail-closed
before spawn.

## What holds

- **Pre-spawn fail-closed.** `validateSpec` rejects empty argv and
  lexical jail escapes (`/etc`, `../escape`) with `SpawnFailed` and no
  child. Fixture 8 covers this.
- **Foreground timeout.** Fixture 3: `runForeground` returns
  `error.Timeout`; written PID is gone (`ProcessNotFound` on signal 0).
- **Hard kill.** Fixture 5: `trap '' TERM` + `cancel(.hard)` →
  `cancelled`; PID gone.
- **Output cap.** Fixture 6: over-limit → `error.StreamTooLong` (finite;
  mapped by `run_shell` to shell-v1 `shell_output_limit`).
- **shell-v1 regression path.** `runForeground` is the same
  `std.process.run` pump shell-v1 already used (timeout as deadline,
  30 KiB stream caps).
- **Ownership.** Fixture 10: module may import Core types; Core has no
  process symbols.

## Closeout fix (blocking until applied)

### F1 — cancel stored a Terminal without reaping

`cancel` set `handle.terminal = cancelled` and `wait` returned that
value without `child.wait`. A killed-but-unreaped child is a zombie
until `deinit`. Binding §1.2 / §4 require reap on every started child.

**Fix:** `wait` reaps if `child.id != null` even when a Terminal is
already stored. Fixtures 4 and 5 already assert the PID is gone; they
now also exercise the reap path.

## Non-blocking notes

- **N1 (P3).** Cooperative cancel sleeps `cancel_grace_ms` on the caller
  thread. Acceptable for v1 tests; a long-lived slot must not block the
  Agent loop this way.
- **N2 (P3).** `runForeground` maps timeout/cap to `error.Timeout` /
  `error.StreamTooLong`, not `Code.timed_out` / `Code.output_truncated`.
  The Tool path translates via `shellRunError`. Do not document
  `Code.timed_out` as the `run_shell` first-line atom.
- **N3 (P3).** `Handle.deinit` kills if `id != null`. After a successful
  `wait` reap this is a no-op. Keep that order in callers (`wait` then
  `deinit`).

## Decision

**PASS** once F1 is in the tree. No OS-sandbox claim. No mid-flight
preemption claim for non-process Tools. Shell/Workspace stay **L2**.
