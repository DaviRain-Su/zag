# Module: tools-shell

| Item | Content |
|------|---------|
| Code | coding-agent `runtime/edit_tools.zig` (`run_shell`) + core `shell_policy` |
| Current maturity | **L1** — review-fix package implementation/evidence landed; independent re-review/main Gate and final Phase H audit remain open |
| Target | L2 H synchronous correctness → L3 background/process supervisor |
| Reference | Hyper background tasks; Codex sandbox shell; Zig 0.16 `std.process.run` |

## Boundary

Phase H supports a **foreground, synchronous, direct-child** shell runner on a trusted host. The file Tool jail does not contain shell commands, and the `protect` denylist is accident reduction rather than an OS sandbox.

The H contract does not own process groups or descendants. It does not support PTY, detached/background jobs, network isolation, or cancellation of a shell handler that is already running. Those require the post-H C7 process supervisor.

## Invariants

1. The execute Tool declares `risk=execute` and passes permission, then descriptor-selected shell policy, before the handler runs.
2. Shell is not made workspace-contained by the file Tool jail.
3. Success, nonzero exit, signal, timeout, output limit, and process failure have distinct stable machine headers.
4. stdout/stderr and the complete Tool body are bounded; valid UTF-8 remains byte-exact, an invalid whole stream is represented as padded standard base64, and an unavailable/over-budget representation is never fabricated partially.
5. Capture timeout/output-limit returns only after Zig's runner error-unwinds and synchronously kills/reaps the spawned **direct child**; body-encoding limit is evaluated only after `run` has normally waited/reaped that direct child.
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
| `shell_success` | `.exited == 0` | `exit_code=0`, raw stdout/stderr byte counts, `stdout_encoding=utf8|base64`, `stderr_encoding=utf8|base64`, both `*_truncated=false` |
| `shell_nonzero` | `.exited != 0` | exact `exit_code`, raw byte counts, both encodings, both `*_truncated=false` |
| `shell_signal` | `.signal` | exact `signal`, raw byte counts, both encodings, both `*_truncated=false` |
| `shell_timeout` | `error.Timeout` | `timeout_ms`, `partial_output_available=false`, `cleanup_scope=direct_child` |
| `shell_output_limit` | capture `error.StreamTooLong` | `limit_scope=capture`, both per-stream limits, `exceeded_stream=unknown`, `partial_output_available=false`, `cleanup_scope=direct_child` |
| `shell_output_limit` | encoded body would exceed 64 KiB | `limit_scope=body_encoding`, original byte counts and selected encodings, `body_limit_bytes=65536`, `partial_output_available=false`, `cleanup_scope=direct_child` |
| `shell_process_failure` | other `std.process.run` error | `stage=run`, `partial_output_available=false` |
| `shell_process_failure` | `.stopped` term | `stage=term`, `term=stopped`, exact `signal`, raw byte counts, both encodings, both `*_truncated=false` |
| `shell_process_failure` | `.unknown` term | `stage=term`, `term=unknown`, exact `status`, raw byte counts, both encodings, both `*_truncated=false` |

`std.process.run` does not expose a reliable phase tag for every overlapping spawn/capture/wait error, so H intentionally uses one non-sensitive `stage=run` value rather than guessing. Stopped/unknown terms are formatter outcomes with captured streams, not `run` errors.

`ShellResultCode` is handler-local in `edit_tools.zig`; these values do not expand core `tool_error.Code`. Policy denial retains the existing core header:

```text
error: code=shell_deny message=shell command blocked by policy; use a safer command or ask the user to adjust policy
```

The matching Tool-result body is this fixed generic string. It never contains a command preview. The separate audit `shell_deny.command` field and Tool-call arguments may contain the redacted/capped command by their existing trace contract; tests therefore scope command-sentinel rejection to the matching Tool-result body rather than the whole trace/session.

`OutOfMemory` remains a hard host error. Nonzero, signal, timeout, output-limit, and process failures are Tool soft results so the model can recover.

## Capture and body budget

- Production capture timeout: **30,000 ms**, converted once before `std.process.run` to an absolute monotonic (`.awake`) deadline rather than passing a duration that may reset per read.
- stdout cap: **30 KiB** (30,720 bytes).
- stderr cap: **30 KiB** (30,720 bytes).
- Formatted envelope (first line, section labels, separators, newlines): **at most 4 KiB** (4,096 bytes).
- Each captured stream is classified before allocation. Valid UTF-8 uses `encoding=utf8` and remains byte-exact. If any byte makes the stream invalid UTF-8, the **entire stream** uses `encoding=base64` with RFC 4648 standard alphabet and `=` padding; `*_bytes` always remains the original captured byte count.
- Represented lengths are computed first with checked arithmetic (`utf8 = raw length`; `base64 = 4 * ceil(raw length / 3)`). Before allocating/writing the final body, checked addition proves:

  `stdout_represented_len + stderr_represented_len + formatted_envelope_len <= tool.max_result_bytes` (**64 KiB**, 65,536 bytes).

- UTF-8 bytes are copied and base64 is encoded directly into the single already-bounded final body. No hidden represented-stream allocation or partial encoded prefix exists.
- Output within both capture caps and the body cap is preserved in separate stdout/stderr sections and marked `truncated=false`.
- Zig 0.16 `std.process.run` does not return captured prefixes with `StreamTooLong`. Capture overflow therefore returns `shell_output_limit limit_scope=capture` with no sections, omitted-byte count, or fake `truncated=true` prefix; it reports `exceeded_stream=unknown` and `partial_output_available=false`.
- If base64 expansion would exceed the body budget, formatting returns `shell_output_limit limit_scope=body_encoding` with the original stream byte counts/selected encodings and `body_limit_bytes=65536`. It has no stream sections or partial representation and never falls through to generic `tool_failed`.

## Timeout and cleanup scope

Production continues to use Zig 0.16 `std.process.run`; Zag does not copy its spawn/MultiReader/wait implementation and does not add a watchdog thread for H.

After a successful spawn, Zig 0.16 `std.process.run` installs `defer child.kill(io)`. Timeout, capture output-limit, and other post-spawn error unwinds synchronously kill/reap that **direct child** before returning. A body-encoding limit happens later, after successful `child.wait` and returned capture, so the direct child is already reaped. This is the maximum H claim.

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

Module fixtures cover success with both streams, exit 7, POSIX signal, short capture timeout, invalid test shell path, stopped/unknown terms, valid/invalid UTF-8 representation, body-encoding overflow, the longest realizable first-line trace preservation, OOM, and real `/bin/sh` capture boundaries at stdout/stderr/both exactly N plus each N+1 control. Timeout/capture-output-limit fixtures record the direct-child PID and prove only that this PID is absent after handler return; the pinned Zig 0.16 source separately establishes the `defer child.kill(io)` kill/reap mechanism. They do not inspect or claim descendants. Agent fixtures compose policy/runtime results through permission → handler → transcript/session/resume → trace → exactly one recovered `completed` terminal. Since trace `tool_result` has no call ID, each single-call trace fixture correlates by exact-one tool-call/result counts; exact ID pairing is asserted only in transcript/session.

Tests use no network. POSIX shell/signal fixtures may skip on unsupported platforms, but supported macOS/Linux Gate hosts must prove that the real path ran.

## Current delivery state

Independent review 01 blocked the prior package evidence on command leakage in the policy Tool body, invalid UTF-8 representation, and unproved real-runner N/N+1 capture boundaries. The docs-first review fix is now implemented with a generic policy body, utf8/base64 encoding fields, `limit_scope=capture|body_encoding`, exact boundary fixtures, direct final-body encoding, and single-call exact-one trace correlation. The task remains in-progress through independent re-review/main Gate; this does not introduce a broader process supervisor.

Task: [h-shell-001](../plan/tasks/h-shell-001.md) (**in-progress**). `h-integration-001` closeout and Phase H exit remain blocked until this task is `done`; package-local green tests do not promote maturity by themselves.

## L2 acceptance

- [x] package success/nonzero/signal/timeout/output-limit/process-failure/policy matrix uses the stable contract above, including stopped/unknown term fields and fixed generic policy denial.
- [x] valid UTF-8 remains exact; invalid whole streams use padded standard base64; body-encoding overflow is a bounded scoped soft result.
- [x] real `/bin/sh` capture fixtures prove stdout/stderr/both exactly N succeed and each N+1 control returns scoped capture overflow on macOS/Linux.
- [x] package timeout/output-limit fixtures prove recorded direct PID absence after return; pinned Zig source supplies the kill/reap mechanism, with no wall bound or process-tree claim.
- [x] checked formatter arithmetic keeps every represented Tool body within 64 KiB; unavailable partial output is reported honestly.
- [x] the longest realizable shell-v1 first line fits the trace Tool-result cap and survives parsed trace truncation.
- [x] package shell policy and runtime results are reconstructable from transcript/session/trace with one truthful terminal; single-call trace correlation uses exact-one counts, not a result call ID.
- [x] docs and behavior agree that mid-flight Tool cancellation, PTY, background jobs, process-tree ownership, and OS sandbox are absent.
- [ ] independent re-review, main std/curl Gate, and final integration/Phase H audit pass.

## L3

Background jobs require C7 process supervisor first: task IDs, monitor/output retrieval, cancel/kill, process-group ownership, bounded retained logs, and required sandbox policy for autonomous execution.

## Non-goals for H

- PTY/TUI terminal emulation
- Detached/background jobs
- Process-group or descendant cleanup
- Mid-flight user cancellation of an already running shell handler
- OS/network sandbox implementation
