---
id: cli-sigint-001
scope: product/cli-interaction
status: done
priority: P1
depends-on: []
---

# objective

Make Ctrl+C predictable and non-hanging in the direct Zag CLI without claiming unsupported mid-flight process or
std-HTTP cancellation.

The binding behavior is [CLI interaction contract](../../modules/cli-interaction.md). Empirical reproduction on
macOS found:

- direct idle REPL swallowed SIGINT and remained blocked;
- `zig build run` shared its parent foreground process group, outside Zag's direct-binary exit-code contract;
- an active std-backend request could remain blocked after the cancellation flag was set.

# context

- `docs/modules/cli-interaction.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/headless-contract.md`
- `docs/modules/zag-ai-provider.md`
- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/plan/tasks/cli-repl-001.md`

Historical design reference only, with no source dependency: `DaviRain-Su/pi-mono-zig@9d1f78c`. Any copied code or
fixture requires explicit MIT provenance; this task used an independent implementation.

# path

- `packages/zag-agent-core/src/cancel.zig`
- `packages/zag-cli/src/cli.zig`
- `packages/zag-cli/src/sigint.zig`
- `packages/zag-cli/src/sigint_process_fixture.zig`
- `packages/zag-cli/src/sigint_slow_mock.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `build.zig`
- `docs/modules/cli-interaction.md`
- `README.md`
- `chapters/00-loop/README.md`

`packages/zag-ai/src/http_std.zig` remained out of scope. The task did not redesign std HTTP into an actively
cancellable backend.

# verification

1. **Idle direct REPL:** after the real `zag` process reaches `you>`, first SIGINT exits within a bound with status `0`;
   stderr contains no runtime `error:`, stack, or `ReadFailed`.
2. **Active cooperative path:** first SIGINT requests cancellation. curl observes it actively; interactive mode can
   return to a usable prompt; observed headless cancellation exits `11` with exactly one terminal.
3. **Hard escape:** a second unacknowledged SIGINT exits `130`. It is explicitly allowed to bypass persistence.
4. **No stale cancellation:** pre-run SIGINT applies to the current run; all reply exits, including run-start failure,
   clear the Agent flag before a later reply.
5. **Handler ownership:** only the CLI installs the handler and restores the prior disposition. Installation is
   one-shot per process; concurrent, nested, and teardown/reinstall attempts are rejected.
6. **Capability truth:** std active interruption and Tool/shell mid-flight preemption remain unclaimed.
7. **Process fixture:** uses the direct binary, request-ready handshake, isolated cwd, synthetic credentials, bounded
   waits, child reaping, and output leak checks.
8. **Input integrity:** retained bytes preserve `first\nsecond\n` across two reads; EINTR uses loops; pending SIGINT wins
   over queued input.
9. **Linux non-libc:** the product signal module uses native Linux syscalls; only the host-native process fixture links
   libc explicitly.
10. **Build-runner boundary:** `zig build run` may end through its parent group as shell status `130`, but the Zag child
    emits no `ReadFailed` stack. The direct binary remains authoritative.
11. **Regression Gate:** focused fixtures, std/curl full suites, docs, SDK/headless fixtures, and Linux cross-build pass.

# closeout

Closed on merged local `main` at `d542332` after independent `VERDICT: PASS` and ff-only integration.

Evidence:

- std merged-main Gate: **465/465** tests, 40/40 steps;
- curl merged-main Gate: **464/464** tests, 42/42 steps;
- SIGINT process fixture: **2/2** on each backend;
- Linux `x86_64-linux` product build: success, no undeclared libc dependency;
- real PTY `zig build run -- --no-project`: Ctrl+C at `you>` ended through SIGINT with clean child output and no
  `ReadFailed`/stack;
- OpenAPI coverage **287/287**, model catalog **40**, docs lint passed;
- final generated docs scores are recorded in `docs/quality/`.

The direct process contract does not normalize build-runner exit behavior, claim process-tree ownership, make std HTTP
actively cancellable, preempt running Tool/shell handlers, alter `headless-v1`, or promise graceful persistence after
the explicit hard escape.
