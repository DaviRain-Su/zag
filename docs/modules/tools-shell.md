# Module: tools-shell

| Item | Content |
|------|---------|
| Code | coding-agent `runtime/edit_tools.zig` (`run_shell`) + core `shell_policy` |
| Current maturity | **L1** — synchronous execution exists; stable outcome/budget/trace evidence is open in `h-shell-001` |
| Target | L2 H synchronous correctness → L3 background/process supervisor |
| Reference | Hyper background tasks; Codex sandbox shell; Zig 0.16 `std.process.run` |

## Boundary

Phase H supports a **foreground, synchronous, direct-child** shell runner on a trusted host. The file Tool jail does not contain shell commands, and the `protect` denylist is accident reduction rather than an OS sandbox.

The H contract does not own process groups or descendants. It does not support PTY, detached/background jobs, network isolation, or cancellation of a shell handler that is already running. Those require the post-H C7 process supervisor.

## Invariants

1. The execute Tool declares `risk=execute` and passes permission, then descriptor-selected shell policy, before the handler runs.
2. Shell is not made workspace-contained by the file Tool jail.
3. Success, nonzero exit, signal, timeout, output limit, and process failure have distinct stable machine headers.
4. stdout/stderr and the complete Tool body are bounded; an unavailable partial stream is never fabricated.
5. Timeout/output-limit returns only after Zig's runner unwinds and synchronously kills/reaps the spawned **direct child**.
6. Policy denial stays distinct from runtime outcomes. A shell timeout is a recoverable Tool result, not an Agent/provider timeout terminal.
7. Full command text, configured shell path, and raw `@errorName` values never appear in result diagnostics.

## `shell-v1` result contract

The first line is the stable machine contract. It must be `<= trace.cap_tool_result_body` (currently **500 bytes**), and trace truncation retains this byte-zero prefix when it caps the rest of `tool_result.body`:

```text
ok: code=shell_success format=shell-v1 ...
error: code=<shell-code> format=shell-v1 ...
```

Stable values contain no whitespace; numeric values are decimal. `stage` is restricted to `run|term`; `term` is restricted to `stopped|unknown`.

| Code | Source | Required first-line fields |
|------|--------|----------------------------|
| `shell_success` | `.exited == 0` | `exit_code=0`, stdout/stderr byte counts, both `*_truncated=false` |
| `shell_nonzero` | `.exited != 0` | exact `exit_code`, byte counts, both `*_truncated=false` |
| `shell_signal` | `.signal` | exact `signal`, byte counts, both `*_truncated=false` |
| `shell_timeout` | `error.Timeout` | `timeout_ms`, `partial_output_available=false`, `cleanup_scope=direct_child` |
| `shell_output_limit` | `error.StreamTooLong` | both per-stream limits, `exceeded_stream=unknown`, `partial_output_available=false`, `cleanup_scope=direct_child` |
| `shell_process_failure` | other `std.process.run` error | `stage=run`, `partial_output_available=false` |
| `shell_process_failure` | `.stopped` term | `stage=term`, `term=stopped`, exact `signal`, byte counts, both `*_truncated=false` |
| `shell_process_failure` | `.unknown` term | `stage=term`, `term=unknown`, exact `status`, byte counts, both `*_truncated=false` |

`std.process.run` does not expose a reliable phase tag for every overlapping spawn/capture/wait error, so H intentionally uses one non-sensitive `stage=run` value rather than guessing. Stopped/unknown terms are formatter outcomes with captured streams, not `run` errors.

`ShellResultCode` is handler-local in `edit_tools.zig`; these values do not expand core `tool_error.Code`. Policy denial retains the existing core header:

```text
error: code=shell_deny ...
```

`OutOfMemory` remains a hard host error. Nonzero, signal, timeout, output-limit, and process failures are Tool soft results so the model can recover.

## Capture and body budget

- Production capture timeout: **30,000 ms**, converted once before `std.process.run` to an absolute monotonic (`.awake`) deadline rather than passing a duration that may reset per read.
- stdout cap: **30 KiB** (30,720 bytes).
- stderr cap: **30 KiB** (30,720 bytes).
- Formatted envelope (first line, section labels, separators, newlines): **at most 4 KiB** (4,096 bytes).
- Before allocating/writing the final body, formatter arithmetic uses checked addition and proves:

  `stdout.len + stderr.len + formatted_envelope_len <= tool.max_result_bytes` (**64 KiB**, 65,536 bytes).

- Output within both caps is preserved in separate stdout/stderr sections and marked `truncated=false`.
- Zig 0.16 `std.process.run` does not return captured prefixes with `StreamTooLong`. `shell_output_limit` therefore returns no stdout/stderr section, omitted-byte count, or fake `truncated=true` prefix; it reports `exceeded_stream=unknown` and `partial_output_available=false`.

## Timeout and cleanup scope

Production continues to use Zig 0.16 `std.process.run`; Zag does not copy its spawn/MultiReader/wait implementation and does not add a watchdog thread for H.

After a successful spawn, Zig 0.16 `std.process.run` installs `defer child.kill(io)`. Timeout, output-limit, and other post-spawn error unwinds synchronously kill/reap that **direct child** before returning. This is the maximum H claim.

It is **not** process-tree cleanup: descendants may survive, detached/background commands are unsupported, and a command that closes captured pipes before continuing may reach an untimed wait. `child.wait` and the unwind `child.kill` have no additional numeric cleanup deadline.

Therefore H claims an absolute **capture** deadline and return-after-cleanup ordering, not an end-to-end wall-clock upper bound for `runShell`. Tests may use a generous outer anti-hang guard for CI hygiene, but that guard is not a product cleanup SLA.

## Cancellation boundary

- Cancellation before a Tool invocation, or between accepted Tool calls, is owned by the core loop and produces the existing `cancelled` Tool body without invoking pending handlers.
- H does not preempt a `run_shell` handler already inside `std.process.run`.
- Runtime `shell_timeout` does not emit Agent `stop_reason=timeout`; provider timeout/cancel semantics remain owned by `h-provider-001`.

## Private test seam

A private `builtin.is_test` namespace may configure only:

- shell path (production `/bin/sh`);
- timeout milliseconds;
- stdout limit bytes;
- stderr limit bytes.

These controls do not enter Tool JSON, `Agent.Options`, `Tool.Context`, CLI flags, provider ABI, session schema, or the production Tool descriptor.

## Required deterministic evidence

Module fixtures cover success with both streams, exit 7, POSIX signal, short capture timeout, tiny output cap, invalid test shell path, direct formatter coverage for stopped/unknown terms, maximum formatter budget, maximum first-line trace preservation, and OOM. Timeout/output-limit fixtures record the direct-child PID without relying on partial stdout and prove that PID is gone after the handler returns; they do not inspect or claim descendants. Agent fixtures compose policy/runtime results through permission → handler → transcript/session/resume → trace → exactly one recovered `completed` terminal.

Tests use no network. POSIX shell/signal fixtures may skip on unsupported platforms, but supported macOS/Linux Gate hosts must prove that the real path ran.

## Current gaps

- `error.Timeout`, `error.StreamTooLong`, and process failures still collapse to generic `tool_failed` diagnostics.
- stdout and stderr currently each receive the old 64 KiB capture limit, so the formatted Tool body is not proven to fit the shared 64 KiB result budget.
- Stable shell runtime headers and their Agent/session/trace composition matrix are not yet permanent fixtures.

Task: [h-shell-001](../plan/tasks/h-shell-001.md) (**ready**). `h-integration-001` closeout and Phase H exit remain blocked until this contract lands and passes independent plus main-branch Gates.

## L2 acceptance

- [ ] success/nonzero/signal/timeout/output-limit/process-failure/policy matrix uses the stable contract above, including stopped/unknown term fields.
- [ ] timeout/output-limit prove synchronous direct-child cleanup without an end-to-end wall bound or process-tree claim.
- [ ] checked formatter arithmetic keeps every Tool body within 64 KiB; unavailable partial output is reported honestly.
- [ ] every shell-v1 first line fits the trace Tool-result cap and survives parsed trace truncation.
- [ ] shell policy and runtime results are reconstructable from transcript/session/trace with one truthful terminal.
- [ ] docs and behavior agree that mid-flight Tool cancellation, PTY, background jobs, process-tree ownership, and OS sandbox are absent.

## L3

Background jobs require C7 process supervisor first: task IDs, monitor/output retrieval, cancel/kill, process-group ownership, bounded retained logs, and required sandbox policy for autonomous execution.

## Non-goals for H

- PTY/TUI terminal emulation
- Detached/background jobs
- Process-group or descendant cleanup
- Mid-flight user cancellation of an already running shell handler
- OS/network sandbox implementation
