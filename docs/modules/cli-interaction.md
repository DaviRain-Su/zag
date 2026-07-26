---
status: active
scope: CLI interaction and signal lifecycle
---

# CLI interaction contract

This module owns plain CLI and REPL behavior. Machine output remains defined by [headless-contract.md](./headless-contract.md); Agent cancellation semantics remain defined by [sdk-contract.md](./sdk-contract.md).

## Ownership boundary

- `zag-cli` owns terminal input, prompts, signal-handler installation, and process exit behavior.
- `zag-agent-core` supplies an atomic cancellation flag; it does not decide terminal UX.
- The Zig SDK does not install process signal handlers merely because an `Agent` is constructed.
- A CLI-installed handler restores the previous process handler when its scope ends.
- A signal handler performs only async-signal-safe work: atomic state and a wake-up mechanism; no allocation, logging, formatting, or normal buffered I/O.

## Ctrl+C contract

| State | First Ctrl+C | Second Ctrl+C while cancellation is pending |
|-------|--------------|---------------------------------------------|
| Idle REPL waiting for input | Wake the blocking read and exit cleanly with code `0`; no Zig runtime error/stack | Not normally reachable after clean exit |
| Active interactive reply or permission input | Request cooperative cancellation; if it lands, report `cancelled` and return to a usable prompt | Hard process exit with conventional status `130` |
| Default one-shot reply | Request cooperative cancellation; preserve the existing human-mode stop/result behavior when observed | Hard process exit `130` |
| `--json` / `--json-stream` | Follow `headless-v1`; observed cancellation exits `11` with a terminal envelope/event | Hard exit is an explicit user abort and cannot promise a protocol terminal |

The second interrupt is an explicit abandonment path. It may bypass session/trace flush and therefore is not evidence of a normal truthful run terminal.

## Signal-safety & lifecycle

- The handler maintains its own process-lifetime interrupt state (`disabled` → `idle` → `pending` → `escaped`), NOT the Agent's cancel flag. The second-interrupt predicate is the handler's unacknowledged `pending` state, so a programmatic cancel (a test or SDK caller setting the flag) is never misread as a "second Ctrl+C".
- A process-lifetime singleton self-pipe (NONBLOCK + CLOEXEC on both ends) is created once and never closed while the process runs. `Guard.deinit` only restores the previous SIGINT disposition; the pipe is reclaimed by the OS at exit (at most 2 leaked fds, bounded and safe — no close/fd-reuse window under a stale handler).
- The bound flag is a lock-free atomic address; the write fd is a process-lifetime immutable value. `deinit` atomically unbinds the flag, restores the previous `sigaction`, then waits for all in-flight handler entries to drain (the handler does only lock-free atomics + a nonblocking one-byte write, so an entry is bounded and cannot deadlock the drain).
- `Guard` installation is ONE-SHOT per process: the first successful `install` latches permanently; `deinit` restores the previous disposition but a later `install` is rejected. This removes the teardown→reinstall ABA (POSIX does not guarantee an old-generation handler committed but not yet executing cannot enter after `sigaction(restore)` returns, and a userspace generation counter cannot distinguish it from a new-generation entry). The CLI has exactly one Guard for the process lifetime and never reinstalls. Concurrent/nested installation is also rejected.
- The previous `sigaction` is captured on install and restored on teardown; the bound flag/state stay live until teardown so a signal delivered mid-restore observes a consistent disposition.
- The handler performs only: a `fetchAdd` on an in-flight counter, a `cmpxchg` on a seq_cst atomic state word, an atomic load of the bound flag, an optional `CancelFlag.request`, a raw `write(2)` of one byte, and a raw exit. No locks, allocation, logging, formatting, or buffered I/O.
- The run loop acknowledges a consumed interrupt (`pending` → `idle`) at the run-completion boundary so the next interaction can use Ctrl+C again; `escaped` is terminal (the process is exiting).
- A pre-run pending interrupt (a SIGINT that arrives after the guard is installed but before a run begins) applies to the current run, not a silent drop. The cancel flag is cleared at the run-completion boundary (not at run start) so the pending cancel is not erased.

## Backend truth

The first interrupt does not create a new active-preemption claim:

- curl may observe active provider cancellation through its existing control contract;
- std HTTP can remain blocked in DNS/connect/TLS/response-head operations and is only cooperative at documented boundaries;
- already-running Tool/shell handlers remain outside mid-flight preemption.

The second interrupt guarantees that the user still has an escape path without claiming graceful cancellation.

## Build runner boundary

The public contract applies to the direct `zag` process. `zig build run` shares a foreground process group with Zig’s build runner on current macOS tooling; Ctrl+C may terminate the parent runner with status `130` before Zag completes its graceful path. The parent runner's `130` is not a Zag contract violation; the contract is that the direct `zag` child must not emit a Zig runtime `error`/stack (e.g. `ReadFailed`) on Ctrl+C. Tests therefore spawn the built `zag` binary directly. `README`/chapters may still show `zig build run` for convenience, but the exit-code authority is `./zig-out/bin/zag`.

## Verification

- Process fixture starts the real direct binary with isolated cwd and an empty/synthetic environment; no `.env` or real key is read.
- Idle prompt readiness is detected from output before SIGINT; no blind sleep decides the injection point.
- A deterministic mock-provider handshake marks an active request before SIGINT: the slow mock writes a `ready` marker after consuming the full HTTP request and before the response-head stall; the fixture waits on that marker, then sends the first SIGINT.
- Tests bound exit time, reap/kill children on failure, and assert no secret/absolute-path leak in child output.
- std active second-signal expects exit `130`; curl active first-signal expects exit `11` with exactly one headless terminal envelope (`"type":"result"`, `stop_reason="cancelled"`).
- The direct child's stderr must not contain a Zig runtime `error:`/stack trace / `ReadFailed`.
- Existing REPL delimiter, default-mode, SDK cancel, and headless terminal tests remain green.

## Non-goals

- normalizing Zig build-runner process-group behavior;
- OS process-tree supervision;
- mid-flight Tool/shell preemption;
- changing `headless-v1` exit codes;
- TUI keybinding design.
