---
status: active
scope: CLI interaction and signal lifecycle
task: ci-hang-sigint-linux-errno-001 (done @ bc737025)
---

# CLI interaction contract

This module owns plain CLI and REPL behavior. Machine output remains defined by
[headless-contract.md](./headless-contract.md); Agent cancellation semantics
remain defined by [sdk-contract.md](./sdk-contract.md).

**Lifecycle status:** M0 Ctrl+C contract closed by `cli-sigint-001` at `d542332`.
**Errno follow-on:** `ci-hang-sigint-linux-errno-001` (**done** at `bc737025`;
contract `b56b238`) binds raw-Linux errno decoding via `linuxRawErrno` /
`std.os.linux.errno` so self-pipe drains terminate under curl-linked
`link_libc` without switching product Linux paths to libc or raising maturity.
Independent review-fix PASS (zero blockers); candidate + merged-main local
macOS dual-backend Gates green (std **611/611**, curl **610/610**). Pure
raw-Linux decoder regression ran in both std and curl-linked test artifacts.
**Broader Linux reliability is not closed:** no fresh post-fix remote Linux
runner in the closeout session; planned process-idle fixture work (task file
not yet authored) and a final merged-path Linux dual-backend Gate remain
required before prompt-templates work. [CI fuses](../plan/tasks/ci-hang-ci-fuses-001.md)
are **done** as host rails only (binding [quality/README](../quality/README.md);
concurrency + 30m job timeout; timeout/cancel ≠ product hang proof).

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

## Linux raw syscall errno decoding (`ci-hang-sigint-linux-errno-001`)

### Problem class

On Linux the product signal module uses **raw** `std.os.linux` syscalls so the product binary is not forced to
`link_libc` by signal ownership. Curl-linked builds and some test artifacts set `link_libc = true` via `attachCurl`
(and the host-native process fixture links libc for `waitpid`/`kill` only).

In Zig 0.16, `std.posix.errno` aliases `system.errno`, and `system` is `std.c` whenever `builtin.link_libc` is true.
`std.c.errno` is libc-shaped: only `rc == -1` is an error. Kernel raw returns encode errors as **negative errno** in a
`usize` (values in approximately `(-4096, 0)` as signed), which is **not** `-1`. Passing a raw `-EAGAIN` through
`std.posix.errno` under `link_libc` can yield `.SUCCESS`; a subsequent `@intCast` of that huge `usize` makes
`sys.read` appear to return a massive success length. `drainWake` then spins until `got == 0` and never terminates.

### Binding rule

| Call convention | Decode with | When |
|-----------------|-------------|------|
| Raw `std.os.linux.*` returning kernel `usize` | **`std.os.linux.errno(rc)`** (kernel signed-window semantics) | **Always** on those sites, **independent of `link_libc`** |
| Libc / macOS / BSD (`std.c.*`, `-1` + thread errno) | libc return / `std.c.errno` / existing platform patterns | Non-Linux product paths; never mixed onto raw Linux results |

**Forbidden:** documenting or implementing “`std.posix.errno` normalises both raw Linux and libc” for product Linux
raw sites. That statement is false when `link_libc` is true.

### Audited product sites (`packages/zag-cli/src/sigint.zig` `sys` block)

Every raw Linux result that is classified by errno today must use kernel decode:

1. `pipe2` — success → fds; else `PipeFailed`.
2. `read` — `.SUCCESS` → return byte count **only after SUCCESS**; `.INTR` → retry; `.AGAIN` → return `0`; else
   `ReadFailed`.
3. `fcntl` GETFD / SETFD (CLOEXEC path) — non-SUCCESS → failure.
4. `fcntl` GETFL / SETFL (NONBLOCK path) — non-SUCCESS → failure.

`write` wake, `close`, and `exit_group` remain intentionally unchecked or noreturn as today.

### Drain and idle wake

- Self-pipe ends stay NONBLOCK + CLOEXEC for the process lifetime.
- `drainWake` reads until `sys.read` returns `0` (empty would-block or EOF class) or a typed read failure aborts the
  drain; it must **not** spin on misdecoded `EAGAIN`.
- Idle first SIGINT still exits `0` without a runtime `ReadFailed` stack for the expected wake path.
- Second unacknowledged SIGINT still hard-exits `130`.

### API / lifetimes / defaults

- Public Guard / line-read API and one-shot install lifecycle are unchanged from `cli-sigint-001`.
- Product Linux path stays raw syscalls (do **not** “fix” the hang by switching product Linux signal I/O to libc).
- Process fixture may keep host-native libc linkage for process control only; that does not authorize product decode
  mistakes.
- Permission default **ask**, workspace jail, and shell protect remain unchanged and out of this module’s errno path.

### Errors

| Condition | Binding result |
|-----------|----------------|
| Nonblocking empty read (`E.AGAIN`) | `0` bytes from `sys.read`; drain terminates |
| `E.INTR` | retry inside `sys.read` |
| Unexpected read errno | `error.ReadFailed` |
| pipe2 / fcntl failure | existing init failure paths (`SigintInitFailed` / pipe fail) |

### Safety and budgets

- Handler remains async-signal-safe; no allocation or buffered I/O on the signal path.
- Drain uses a small fixed stack buffer; no new unbounded heap on the wake path.
- No weakening of ask / jail / shell protect; no secret or absolute-path leakage in fixtures.

### Compatibility

- std vs curl provider-control truth unchanged.
- headless observed cancel exit `11` and hard escape `130` unchanged.
- Linux product non-libc claim preserved: signal module does not force `link_libc`.
- No maturity raise from this fix alone.

### Non-goals (errno node)

- Softening, skipping, or claiming fixed a separately tracked idle process-fixture timeout without evidence.
- `.github` workflow timeout/concurrency changes.
- std HTTP active cancellation redesign; Tool/shell mid-flight preemption.
- Build-runner process-group normalization.
- Prompt Templates, TUI, schema/Trace/headless field changes.

### Verification (errno node)

`ci-hang-sigint-linux-errno-001` closeout evidence (done at `bc737025`):

1. **Pure raw-Linux errno regression** — kernel-encoded `-EAGAIN` (synthetic `usize`) decodes as would-block /
   non-SUCCESS through the product decode path under both std and curl-linked test artifacts (`link_libc` false and
   true), without relying on thread `errno` state. **Proven** in both std and curl-linked test artifacts.
2. **Empty nonblocking drain** — wake-pipe drain terminates promptly when the pipe has no data. **Proven** (F2).
3. **Pending-interrupt suite retained** — first wake + idle interrupted path; second-signal predicate remains handler
   state; focused zag-cli SIGINT unit tests stay green.
4. **Dual-backend full Gate (local host)** — candidate std **611/611**, curl **610/610**; merged-main local macOS
   again std **40/40 · 611/611**, curl **42/42 · 610/610**. Idle process-fixture reliability remains separately
   planned (not claimed fixed by this node).
5. **Docs** — docs lint + score readability **91** / security **72**; committed-range `git diff --check` clean; no
   maturity inflation.
6. **Not claimed** — fresh post-fix remote Linux runner; process-idle fixture;
   broader Linux reliability. CI fuses (`ci-hang-ci-fuses-001`) are separate host
   rails and do not prove product SIGINT/errno/idle correctness.

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
- Additional errno regressions in the Linux raw-decode section above are required for
  `ci-hang-sigint-linux-errno-001` closeout.

## Non-goals

- normalizing Zig build-runner process-group behavior;
- OS process-tree supervision;
- mid-flight Tool/shell preemption;
- changing `headless-v1` exit codes;
- TUI keybinding design;
- CI workflow timeout/concurrency knobs as a substitute for correct errno decode;
- switching Linux product signal syscalls to libc to avoid kernel errno handling.
