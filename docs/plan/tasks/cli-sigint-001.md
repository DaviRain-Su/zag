---
id: cli-sigint-001
scope: product/cli-interaction
status: in-progress
priority: P1
depends-on: []
---

# objective

Make Ctrl+C predictable and non-hanging in the direct Zag CLI without claiming unsupported mid-flight process or std-HTTP cancellation.

The binding behavior is [CLI interaction contract](../../modules/cli-interaction.md). Empirical reproduction on macOS found:

- direct idle REPL swallows SIGINT and remains blocked;
- current `zig build run` exits with its parent foreground process group (status 130), which is outside Zag’s direct-binary contract;
- an active std-backend request can remain blocked after the cancellation flag is set.

# context

- `docs/modules/cli-interaction.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/headless-contract.md`
- `docs/modules/zag-ai-provider.md`
- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/plan/tasks/cli-repl-001.md`

Historical design reference only (no source dependency): `DaviRain-Su/pi-mono-zig@9d1f78c`, especially its scoped signal guards and terminal tests. Any copied code/fixture requires explicit MIT provenance; default is an independent implementation.

# path

- `packages/zag-agent-core/src/cancel.zig`
- `packages/zag-cli/src/cli.zig`
- `packages/zag-cli/src/*sigint*fixture*.zig` (new if needed)
- `packages/zag-cli/build.zig`
- `build.zig`
- `docs/modules/cli-interaction.md`
- `README.md` and/or `chapters/` when user-visible behavior changes
- `docs/plan/tasks/cli-sigint-001.md`

`packages/zag-ai/src/http_std.zig` is out of scope unless investigation proves a small correctness defect. This task must not redesign std HTTP into an actively cancellable backend.

# verification

1. **Idle direct REPL:** after the real `zag` process reaches `you>`, first SIGINT exits within a bounded interval with status 0; no runtime `error:`/stack output, and no `ReadFailed`/stack on stderr.
2. **Active cooperative path:** first SIGINT requests cancellation; where the backend can observe it, normal mode reports cancelled and interactive mode remains usable; headless remains exit 11 with exactly one terminal.
3. **Hard escape:** second SIGINT while cancellation remains pending exits within a bound with conventional status 130; docs state this may bypass terminal persistence. The second-interrupt predicate is the handler's own unacknowledged `pending` state, NOT the Agent cancel flag.
4. **No stale cancellation:** a prior idle/finished signal cannot be silently cleared into an unintended next reply. A pre-run pending interrupt (SIGINT after guard install but before the run starts) applies to the current run; the cancel flag is cleared at the run-completion boundary, not at run start.
5. **Handler ownership:** CLI restores the previous SIGINT disposition; constructing/using the SDK alone does not install a handler. Concurrent/nested Guard install is rejected; sequential reinstall is supported.
6. **Capability truth:** std backend is not advertised as bounded active interruption; Tool/shell preemption remains unclaimed.
7. **Process fixture:** uses the real direct binary, deterministic readiness/request handshake (slow mock writes a `ready` marker after consuming the request, before the response-head stall; the fixture waits on that marker — no blind sleep is the correctness oracle), isolated cwd, and no real credentials. Bounded waits, child reap on failure, no secret/absolute-path leak.
8. **REPL input integrity:** same-batch stdin bytes after the first newline are retained for the next call (e.g. `first\nsecond\n` yields `first` then `second`); EINTR loops, no recursion; the poll/self-pipe path returns `interrupted`, never `ReadFailed`/stack.
9. **Linux non-libc:** the product `sigint.zig` module carries no libc dependency on Linux (raw `std.posix.system`/`std.os.linux` syscalls); `zig build -Dtarget=x86_64-linux` compiles. The fixture test artifact may use libc (scoped `link_libc = true`) since it only runs host-native.
10. **Direct-binary exit-code authority:** `README`/chapters may show `zig build run`, but the exit-code contract is `./zig-out/bin/zag`; `zig build run`'s parent runner may exit 130, but the Zag child must not emit `ReadFailed`/stack.
11. Existing focused REPL/cancel/headless fixtures pass, then merged-main `zig build test --summary all` and curl equivalent pass before `done`. Task stays `in-progress` until the merged-main Gate passes.

# non-goals

- fixing or wrapping `zig build run` parent process-group behavior;
- OS process supervisor/process-tree ownership;
- changing headless-v1 schema or exit matrix;
- TUI implementation;
- graceful persistence after the explicit second-interrupt hard exit.
