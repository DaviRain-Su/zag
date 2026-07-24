---
id: h-shell-001
scope: phase-h/shell-runtime-observability
status: in-progress
priority: P1
depends-on: [h-tool-runtime-001, h-trace-001]
---

# objective

Close the missed Phase H shell blocker without introducing a process supervisor: implement the stable synchronous [`shell-v1` contract](../../modules/tools-shell.md), prove Zig 0.16 `std.process.run` direct-child timeout/output-limit cleanup, and compose shell policy/runtime results through Agent → transcript/session/trace → one truthful terminal.

This task does **not** implement or claim mid-flight user cancellation of an already running Tool, process-group/tree ownership, background jobs, PTY, network/OS sandboxing, or detached-command supervision. Those remain post-H process-supervisor work.

`h-integration-001` retains its independently verified and main-merged composition evidence but cannot close Phase H until this task lands and the full integration/main Gate runs again.

# develop state

Independent review 01 **blocked** the first package commit on three scoped gaps: policy denial echoed the command, invalid UTF-8 could fail trace/session recovery, and real-runner exactly-N/N+1 capture behavior lacked evidence. The docs-first fix is now implemented with a fixed generic policy body, whole-stream utf8/base64 representation, scoped capture/body-encoding limits, direct bounded final-body encoding, exact boundary fixtures, and real invalid-UTF-8 Agent composition. Core error codes and trace schema remain unchanged.

The task remains **in-progress** through independent re-review/main Gate. `h-integration-001` remains **blocked**, and Phase H remains below L2.

Review-fix isolated evidence passes: default backend `30/30` steps and `384/384` tests; curl backend `32/32` steps and `383/383` tests; focused coding-agent `104/104`. On the supported macOS host every real shell, signal, PID, N/N+1, and invalid-UTF-8 Agent fixture ran with **zero skips**. Docs lint/score remain `91/100` readability and `64/100` security.

# contract source

The owning contract is [docs/modules/tools-shell.md](../../modules/tools-shell.md). In particular:

- first-line handler codes are `shell_success`, `shell_nonzero`, `shell_signal`, `shell_timeout`, `shell_output_limit`, and `shell_process_failure` under `format=shell-v1`;
- policy denial keeps core `shell_deny` and uses one exact generic Tool body with no command preview;
- production converts one 30,000 ms monotonic capture timeout to an absolute deadline before `std.process.run`, caps each stream at 30 KiB, limits the formatted envelope to 4 KiB, and proves the 64 KiB total Tool-body ceiling with checked arithmetic;
- valid UTF-8 streams stay byte-exact; an invalid whole stream is represented directly in the bounded final body as padded standard base64, while `*_bytes` retains the raw captured count;
- every first line declares both stream encodings when streams are available, is within the trace Tool-result body cap (currently 500 bytes), and survives prefix truncation;
- capture `StreamTooLong` returns `shell_output_limit limit_scope=capture` with no fabricated partial output;
- base64 expansion beyond the body budget returns `shell_output_limit limit_scope=body_encoding` with raw counts/encodings and no partial representation or generic failure;
- post-spawn timeout/capture-output cleanup is direct-child kill/reap through Zig std unwind; body-encoding limit is computed only after normal wait/reap;
- `OutOfMemory` remains a hard host error and raw command/path/`@errorName` diagnostics are forbidden.

Handler-local codes stay in `edit_tools.zig`; do not expand core `tool_error.Code`.

# implementation constraints

- Production continues to call `std.process.run`; do not copy its spawn/MultiReader/wait internals or add a watchdog thread.
- A private `builtin.is_test` configuration may set shell path, timeout milliseconds, and stdout/stderr limits only. It must not widen Tool JSON, `Agent.Options`, `Tool.Context`, CLI, provider ABI, session schema, or the production descriptor.
- A shell timeout is a recoverable Tool result, not Agent/provider `stop_reason=timeout`.
- Runtime shell outcomes never emit `shell_deny`; policy denial never invokes the handler.

# deterministic verification matrix

## Module fixtures

- success: stdout + stderr, `shell_success`, exit 0, exact raw byte counts/sections and `encoding=utf8`;
- nonzero exit 7: `shell_nonzero`, exact exit code;
- POSIX signal: `shell_signal`, exact signal;
- valid UTF-8 is byte-exact; invalid-only and mixed valid/invalid streams encode the entire invalid stream as padded standard base64;
- base64 represented-length overflow returns bounded `shell_output_limit limit_scope=body_encoding` with no sections/partial/generic failure;
- short absolute capture deadline: deterministically reaches `shell_timeout`, reports no partial output, and the recorded direct PID is absent after return; no end-to-end wall-clock product bound is claimed;
- real `/bin/sh` stdout exactly N, stderr exactly N, and both exactly N succeed; stdout N+1 and stderr N+1 return `shell_output_limit limit_scope=capture` with no sections; macOS/Linux cannot skip;
- invalid test shell path: `shell_process_failure stage=run`, no command/path/error-name echo;
- direct stopped/unknown term formatter cases: fixed `stage=term`, fixed term value, exact signal/status, raw stream counts, and encodings;
- maximum formatter uses checked represented lengths and direct final-body encoding;
- longest realizable first line is `<= trace.cap_tool_result_body` and remains complete in parsed trace;
- OOM remains typed and never becomes a soft shell result.

## Agent composition fixtures

Exercise real permission → descriptor-selected shell policy → handler → transcript/session → trace:

- default/protect policy denial: handler invocation zero, one `shell_deny`, an exact fixed generic matching Tool-result body that lacks a command sentinel, original call ID persisted/resumed, and one recovered `completed` terminal; Tool-call/audit fields may legitimately retain the command;
- at least success, nonzero, timeout, capture output-limit, process-failure, and real invalid-UTF-8/base64 shell-v1 headers appear in the matching transcript/session Tool result and trace header; provider recovery ends with one `completed` terminal, not provider timeout/error;
- runtime outcomes do not emit `shell_deny`;
- trace JSON is parsed: expected permission/shell/tool events and exactly one same-object `run_end` (`ok=true`, `stop_reason=completed`); single-call result correlation uses exact-one event counts because trace `tool_result` has no call ID, while transcript/session own exact ID pairing;
- pending/mid-flight cancellation claims remain absent.

Tests use no network. POSIX `/bin/sh`/signal fixtures may skip on unsupported platforms, but supported macOS/Linux Gate hosts must prove the real path ran.

# context

- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/modules/tools-shell.md`
- `docs/modules/trace-observability.md`
- `docs/quality/evals.md`
- Zig 0.16 local `std/process.zig` (`run`) and `std/process/Child.zig` (`kill`/`wait`)

# path

- `packages/zag-coding-agent/src/runtime/edit_tools.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `README.md`
- `SECURITY.md`
- `docs/architecture.md`
- `docs/maturity.md`
- `docs/packaging.md`
- `docs/roadmap.md`
- `docs/modules/tools-edit.md`
- `docs/modules/tools-shell.md`
- `docs/modules/trace-observability.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/plan/README.md`
- `docs/plan/tasks/h-shell-001.md`
- `docs/plan/tasks/h-integration-001.md`
- `docs/gaps/00-loop.md`
- `docs/gaps/01-edit.md`
- `docs/gaps/03-safety.md`
- `chapters/01-edit-permissions/README.md`
- `chapters/H-harden/README.md`

# verification

- all module and Agent shell-v1 matrix fixtures pass deterministically, including utf8/base64, encoding overflow, exact capture boundaries, and fixed-deny negative assertions;
- checked represented-length arithmetic keeps every Tool result within the shared 64 KiB budget, and the longest realizable first-line classification remains within the 500-byte trace cap;
- timeout/capture-output-limit fixtures prove the recorded direct PID is absent after return; pinned Zig 0.16 source establishes the unwind kill/reap mechanism. The fixture may have a CI anti-hang guard but exposes no product wall-clock cleanup SLA;
- docs state descendants/process trees, mid-flight cancel, detached jobs, and OS sandbox remain unsupported;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- independent worktree review + main std/curl Gate pass;
- only after this task is done may `h-integration-001` return to ready for the final Phase H exit audit.
