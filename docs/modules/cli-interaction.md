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

## Backend truth

The first interrupt does not create a new active-preemption claim:

- curl may observe active provider cancellation through its existing control contract;
- std HTTP can remain blocked in DNS/connect/TLS/response-head operations and is only cooperative at documented boundaries;
- already-running Tool/shell handlers remain outside mid-flight preemption.

The second interrupt guarantees that the user still has an escape path without claiming graceful cancellation.

## Build runner boundary

The public contract applies to the direct `zag` process. `zig build run` shares a foreground process group with Zig’s build runner on current macOS tooling; Ctrl+C may terminate the parent runner with status `130` before Zag completes its graceful path. Tests therefore spawn the built `zag` binary directly.

## Verification

- Process fixture starts the real direct binary with isolated cwd and an empty/synthetic environment; no `.env` or real key is read.
- Idle prompt readiness is detected from output before SIGINT; no blind sleep decides the injection point.
- A deterministic mock-provider handshake marks an active request before SIGINT.
- Tests bound exit time and fail on hangs.
- std and curl expectations remain capability-specific.
- Existing REPL delimiter, default-mode, SDK cancel, and headless terminal tests remain green.

## Non-goals

- normalizing Zig build-runner process-group behavior;
- OS process-tree supervision;
- mid-flight Tool/shell preemption;
- changing `headless-v1` exit codes;
- TUI keybinding design.
