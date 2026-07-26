---
status: active
scope: CLI interaction and signal lifecycle
---

# CLI interaction contract

This module owns plain CLI and REPL behavior. Machine output remains defined by
[headless-contract.md](./headless-contract.md); Agent cancellation semantics
remain defined by [sdk-contract.md](./sdk-contract.md).

## Ownership boundary

- `zag-cli` owns terminal input, prompts, signal-handler installation, and process exit behavior.
- `zag-agent-core` supplies an atomic cancellation flag; it does not decide terminal UX.
- The Zig SDK does not install process signal handlers merely because an `Agent` is constructed.
- A CLI-installed handler restores the previous process handler when its scope ends.
- A handler performs only async-signal-safe atomic state changes and self-pipe wake-up.
  It performs no allocation, logging, formatting, or buffered I/O.

## Ctrl+C contract

### Idle REPL

- **First Ctrl+C:** wake the blocking read and exit cleanly with code `0`, without a Zig runtime stack.
- **Second Ctrl+C:** not normally reachable after the clean exit.

### Active interactive reply or permission input

- **First Ctrl+C:** request cooperative cancellation. If observed, report `cancelled` and return to a usable prompt.
- **Second pending Ctrl+C:** hard process exit with conventional status `130`.

### Default one-shot reply

- **First Ctrl+C:** request cooperative cancellation and preserve existing human-mode result behavior when observed.
- **Second pending Ctrl+C:** hard process exit `130`.

### `--json` and `--json-stream`

- **First Ctrl+C:** follow `headless-v1`; observed cancellation exits `11` with one terminal envelope/event.
- **Second pending Ctrl+C:** explicit hard abort; no protocol terminal is promised.

The second interrupt is an abandonment path. It may bypass session/trace flush and is not evidence of a normal
truthful run terminal.

## Signal safety and lifecycle

```text
disabled --install--> idle --first SIGINT--> pending --second SIGINT--> escaped (exit 130)
                              └--run acknowledges cancel--> idle
```

- The handler owns a process-lifetime state machine: `disabled` → `idle` → `pending` → `escaped`.
  Its unacknowledged `pending` state, not the Agent cancel flag, identifies a second Ctrl+C. A programmatic cancel
  therefore cannot masquerade as a second interrupt.
- A singleton self-pipe is created with NONBLOCK and CLOEXEC on both ends. It remains open for the process lifetime,
  so a stale handler cannot write to a recycled fd. The OS reclaims the fixed two-fd allocation at exit.
- The bound flag is stored as a lock-free atomic address; the pipe fd is immutable after creation. During teardown,
  `deinit` disables the state, atomically unbinds the flag, restores the previous `sigaction`, and waits for all
  in-flight handler entries to finish.
- Guard installation is one-shot per process. `deinit` restores the prior disposition, but a later installation is
  rejected. Concurrent and nested installation are also rejected. This removes teardown/reinstall ABA exposure from
  a delayed old signal delivery.
- The handler performs only lock-free atomics, an optional atomic `CancelFlag.request`, a raw one-byte `write(2)`,
  and a raw hard exit. It performs no locks, allocation, logging, formatting, or buffered I/O.
- The run loop acknowledges a consumed interrupt (`pending` → `idle`) after the run finishes, allowing the next
  interaction to use Ctrl+C again. `escaped` is terminal.
- A SIGINT delivered after Guard installation but before a run starts applies to that run. The Agent clears the cancel
  flag when the run exits, including run-start failure paths, rather than erasing it at run start.

## Backend truth

The first interrupt does not create a new active-preemption claim:

- curl may observe active provider cancellation through its existing control contract;
- std HTTP may remain blocked in DNS/connect/TLS/response-head operations and is cooperative only at documented
  boundaries;
- already-running Tool/shell handlers remain outside mid-flight preemption.

The second interrupt guarantees an escape path without claiming graceful cancellation.

## Build runner boundary

The public exit-code contract applies to the direct `zag` process. On current macOS tooling, `zig build run` shares a
foreground process group with Zig's build runner. Ctrl+C may terminate that parent runner with shell status `130`
before Zag completes its graceful path.

That parent status is not a Zag contract violation. The direct child must not emit a Zig runtime error or stack such
as `ReadFailed`. Tests spawn the built binary directly. `README` and chapters may show `zig build run` for convenience,
but `./zig-out/bin/zag` is the exit-code authority.

## Verification

- The process fixture starts the real direct binary in an isolated cwd with a synthetic environment. It reads no
  `.env` file or real key.
- Idle prompt readiness is detected from output before SIGINT; no blind sleep decides the injection point.
- For active requests, the slow mock writes `ready` after consuming the full HTTP request and before stalling the
  response head. The fixture waits for that marker before sending SIGINT.
- All waits are bounded; failure paths kill and reap children; child output is checked for secrets and absolute paths.
- std active hard escape exits `130`. curl active cancellation exits `11` with exactly one cancelled result envelope.
- Direct-child stderr contains no runtime `error:`, stack trace, or `ReadFailed`.
- Existing REPL delimiter, default-mode, SDK cancel, and headless terminal tests remain green.

## Non-goals

- normalizing Zig build-runner process-group behavior;
- OS process-tree supervision;
- mid-flight Tool/shell preemption;
- changing `headless-v1` exit codes;
- TUI keybinding design.
