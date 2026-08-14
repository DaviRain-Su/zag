# Zag-native long-lived `rpc-v1`

> Binding draft for [rpc-v1-001](../plan/tasks/rpc-v1-001.md) (D-012 item 4 —
> long-lived bidirectional process control between a host client and a running
> zag agent). Architecture law from
> [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md):
> RPC stays **outside** `zag-agent-core`; one-way package graph; Core loop
> unchanged.
> Reference (semantic only, **not** parity — D-009): hyper-grok-build's RPC is
> Claude-Code-SDK-compatible (JSON-RPC over stdio, client-mode). Zag borrows
> the *shapes* that matter — bidirectional messages, sessions, cancellation, a
> resume/continue hook — over a **Zag-native** NDJSON wire in the headless-v1
> envelope family.
>
> **Status:** **implemented** @ `0eeef5d` ([rpc-v1-001](../plan/tasks/rpc-v1-001.md)).
> Wave 2 closeout 2026-08-14: [architecture](../plan/reviews/rpc-v1-001-01-architecture.md)
> PASS · [safety](../plan/reviews/rpc-v1-001-02-safety.md) PASS; process
> fixture **26/26**. Zig 0.16 (`std.Io` era) APIs assumed throughout.

## 1. Principles

1. **One server process = one agent conversation.** `zag --rpc` is the REPL's
   long-lived sibling: the same Agent + Session assembly the TUI host builds,
   with the terminal UI replaced by a pipe protocol. Session selection happens
   at startup via the existing flags (`-s` create / `-c` resume / none =
   ephemeral); `resume` re-binds the configured session idle-only.
2. **Consume existing public surfaces, change nothing.** Agent / Session /
   LifecycleObserver / Observer / permission Gate / control queues /
   `sigint.Guard` are the entire backend. No Core ports, no coding-agent
   changes, no new package.
3. **Local pipes only.** The server speaks over the inherited stdin/stdout of
   its own process. No sockets, no listening ports, no network, no auth
   tokens: the wire adds no privilege beyond what the same-user host already
   has. The API key lives in the server's environment and never crosses the
   wire.
4. **Headless-family envelope, JSON-RPC-shaped correlation.** Every frame is
   one NDJSON object carrying `protocol_version` + `type` (`request` /
   `response` / `notification`) like headless-v1, with request/response `id`
   correlation borrowed from JSON-RPC. Not a parity port: no Claude-Code-SDK
   message names, no command vocabulary replication (D-009).
5. **One in-flight prompt.** Busy → `session_busy` error. No prompt queueing.
   steer / follow_up / cancel remain available while busy through the existing
   bounded Session control queues and the cancel flag — the same honesty as
   the TUI: cancellation applies at loop boundaries, never mid-handler.
6. **Bounded everything.** Frame, prompt, control-text, permission-argument,
   and result caps (checked arithmetic, §10). Overflow is an explicit error or
   an explicit truncation marker — never silent RAM growth.
7. **Truthful terminal.** Exactly one exit path per shutdown trigger, with a
   documented exit code. A run that cannot finish reports its real
   `stop_reason`; the server never invents success (headless rule).
8. **Redaction on every field.** All strings pass the Session redactor
   (headless rules §11): no keys, no session/trace paths, no absolute paths.

## 2. Ownership (package decision, frozen)

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-cli`** | `--rpc` mode; NDJSON framing; protocol types; server host (read loop, dispatcher, worker thread, permission gate bridge, writer mutex, shutdown state machine); `rpc_process_fixture.zig` | Core/coding-agent changes; TUI imports; sockets/network; new package without ownership pressure |
| `zag-coding-agent` | unchanged — consumed public surfaces only | rpc types; wire vocabulary |
| `zag-agent-core` | unchanged (D-011/D-012) | process/pipe/protocol ports |
| `zag-tui` | unchanged | — |
| Future | if a **second** embedder of the server appears (API frozen + release channel + self-contained tests), split `zag-rpc` out of zag-cli per [packaging.md](../packaging.md) §3 | premature split |

**No new package in v1** (packaging law): the server has exactly one consumer
(the `zag` binary), no frozen public API, and no independent release channel.
The TUI earned its unique package through vaxis quarantine; rpc carries no
heavy dependency and is always compiled (like headless, unlike `-Dtui`).

### 2.1 Future implementation paths

| Path | Role |
|------|------|
| `packages/zag-cli/src/rpc/framing.zig` | line reader/writer: caps, resync, escape; no protocol semantics |
| `packages/zag-cli/src/rpc/protocol.zig` | pure message types: parse/serialize, error codes, event groups (unit-testable without IO) |
| `packages/zag-cli/src/rpc/server.zig` | dual-thread host: read loop, dispatch, worker, gate bridge, writer mutex, shutdown |
| `packages/zag-cli/src/rpc_entry.zig` | `--rpc` CLI wiring (mode matrix, Agent/Session init, Guard) — mirrors `tui_entry.zig` |
| `packages/zag-cli/src/cli.zig` | `--rpc` flag + mutual-exclusion matrix |
| `packages/zag-cli/src/rpc_process_fixture.zig` | process fixture (real binary, pipes/PTY, mock provider) |
| root `build.zig` | `rpc-process-fixture` step wired into `test` under std **and** curl |

No `SignalHost` needed: that port exists to keep `zag-tui` free of zag-cli
imports; rpc lives **inside** zag-cli and uses `sigint.Guard` directly.

## 3. Transport and trust (frozen)

- **Framing:** NDJSON — exactly one JSON object per line, `\n` (0x0A)
  terminated. UTF-8. String values are JSON-escaped by the writer; a literal
  `\n` inside a value would split the frame and is a client parse error.
  No `\r\n` tolerance: `\r` is ordinary data (a trailing `\r` makes the line
  invalid JSON → error response).
- **Direction:** client writes stdin, server writes stdout. stderr carries
  human diagnostics only. **stdout is protocol-only in rpc mode** (same rule
  as headless): no logs, prompts, or banner bytes.
- **Cap:** inbound line ≤ **4 MiB**. Overflow → error response
  `invalid_arguments` + resync at the next newline (bounded drain). The
  server never buffers past the cap.
- **Pipelining:** the read loop processes one frame at a time, in order;
  responses are written in request order. Clients MAY pipeline; a second
  `prompt` while one is in flight receives `session_busy`.
- **Versioning:** `protocol_version: "rpc-v1"` is required on **every**
  inbound frame. Unknown value → response error `unsupported_protocol`
  (server continues). Breaking changes require a new protocol string
  (`rpc-v2`); additive params fields are ignored (forward-compatible).
- **Trust:** inherited stdio only; same-user, same-host process boundary.
  The client is trusted as the user's own shell (it can already read/write
  the user's files); the protocol grants nothing beyond the CLI's existing
  permission/jail/policy/redaction enforcement, which stays in the agent
  process. No network auth, no tokens, no ambient-credential forwarding.

## 4. Envelope

Every frame:

```json
{ "protocol_version": "rpc-v1", "type": "request", "id": 1, "method": "prompt", "params": { } }
{ "protocol_version": "rpc-v1", "type": "response", "id": 1, "result": { }, "error": null }
{ "protocol_version": "rpc-v1", "type": "notification", "method": "ready", "params": { } }
```

| Field | Rule |
|-------|------|
| `protocol_version` | exact `"rpc-v1"` in every frame |
| `type` | `request` \| `response` \| `notification`; anything else → error response `id: null` |
| `id` | request/response only; positive integer chosen by the client, echoed verbatim; no uniqueness enforcement (the server is sequential) |
| `method` | request/notification only; frozen sets in §5–§6 |
| `params` | object; unknown extra fields ignored |
| `result` / `error` | response only; exactly one non-null; `error` is the §9 error object |

## 5. Requests (client → server, frozen v1 set)

| Method | Params | Response result | Errors |
|--------|--------|-----------------|--------|
| `prompt` | `{ "text": string (≤ 1 MiB, non-empty), "stream": bool = true }` | `{ "ok": bool, "stop_reason": string, "turns": int, "final_text": string (≤ 1 MiB, truncation marker), "usage": { prompt_tokens, completion_tokens, total_tokens } }` | `session_busy` (in-flight), `invalid_arguments` (empty/oversized text), run-level outcomes are **results** (§9.2), never response errors |
| `cancel` | `{}` | `{ "ok": true }` | — (idle cancel is a no-op `ok`; the flag is **not** set when idle, so the next prompt starts clean) |
| `steer` | `{ "text": string (1..4096 B) }` | `{ "ok": true }` | `invalid_arguments` (empty), `message_too_long` (> 4096 B), `queue_full` (cap 4) |
| `follow_up` | same as `steer` | `{ "ok": true }` | same as `steer` |
| `subscribe` | `{ "events": [string] (≤ 32, §7 groups) }` | `{ "ok": true, "subscribed": [string] }` | `unknown_event` (strict; **no** partial apply) |
| `permission_decision` | `{ "request_id": int, "allowed": bool, "remember": bool = false }` | `{ "ok": true }` | `permission_unknown` (no pending gate with that `request_id`) |
| `resume` | `{ "path": string? }` (optional; omitted → configured path) | `{ "ok": true, "resumed": bool, "path": string, "turns": int }` | `session_busy` (busy), `session_not_configured` (no path and none configured), store codes `session_not_found` / `session_invalid` / `session_unsupported_schema` / `session_io_failed` |
| `exit` | `{}` | `{ "ok": true }` (then graceful shutdown §8.3, exit 0) | — |
| anything else | — | — | `unknown_method` |

`prompt` semantics: the server spawns the reply worker (§8.2); the response
is emitted **after** `Agent.reply` returns and carries the headless result
shape (`ok` from `resultOk`, `stop_reason` from the Core vocabulary — §9.2).
`stream: false` suppresses `assistant_delta`/`thinking_delta` notifications
for that run (the terminal response is identical).

## 6. Notifications (server → client, frozen v1 set)

### 6.1 Always delivered (not subscribable)

| Method | When | Params |
|--------|------|--------|
| `ready` | **first frame**, after Agent.init + Session.start succeed | `{ "protocol_version": "rpc-v1", "zag_version": string, "permission": "ask" \| "yolo", "shell_policy": "protect" \| "off", "session": { "configured": bool, "path": string?, "turns": int, "resumed": bool } }` — no provider, trace-path, or secret fields |
| `permission_request` | ask mode, each gate decision needed (unconditional; the run blocks on it, §8.4) | `{ "request_id": int (server counter), "tool_name": string (redacted), "risk": string, "arguments_json": string (redacted, ≤ 64 KiB + marker) }` |
| `error` | fatal only (startup failure, unrecoverable internal); followed by process exit with the mapped code | `{ "error": { "code", "message", "retryable", "category" } }` — headless error schema |

### 6.2 Subscribable groups (default: all ON)

| Group | Notifications | Internal source |
|-------|---------------|-----------------|
| `delta` | `assistant_delta` `{ "text" }` · `assistant_delta_clear` `{}` | lifecycle `assistant_delta` / `assistant_delta_clear` (stream only; UI-visible, never persisted) |
| `thinking` | `thinking_delta` `{ "text" }` | lifecycle `thinking_delta` |
| `tools` | `tool_start` `{ "turn", "call_index", "id", "name", "arguments" }` · `tool_end` `{ "turn", "call_index", "id", "name", "body" }` | lifecycle `tool_start` / `tool_end` — **single source**; the observer `tool_call`/`tool_result` pair is **not** duplicated on the wire (turn context is strictly richer); pending-cancel between tools emits `tool_end` only (no fabricated `tool_start`) |
| `permission` | `permission` `{ "tool_name", "allowed", "remembered", "risk" }` | observer `permission` (decisions; distinct from `permission_request`) |
| `usage` | `usage` `{ "prompt_tokens", "completion_tokens", "total_tokens" }` | observer `usage` (cumulative per run) |
| `lifecycle` | `run_start` `{ "session_configured" }` · `assistant_message` `{ "turn", "text", "has_tools", "reasoning"? }` · `control_applied` `{ "kind": "steering" \| "follow_up", "next_turn", "text" }` | lifecycle `run_start` / `assistant_message` / `control_applied` |
| `session` | `session` `{ "path", "turns", "resumed" }` | server state (after successful `resume`) |

`subscribe` **replaces** the whole filter (idempotent); `[]` unsubscribes all
subscribable groups. No `run_end` notification: the `prompt` response **is**
the terminal result (single client ⇒ every run is correlated by its request
id). Notification order = program order (callbacks are synchronous in
`Agent.reply`); the `prompt` response is always the last frame of its run.

## 7. Session model (frozen)

- **One server process = one Agent + one Session.** Startup parity with the
  REPL: `--rpc -s PATH` → `create_new`; `--rpc -c` → `resume_existing`
  (default `.zag/sessions/default.jsonl`); bare `--rpc` → ephemeral. The same
  host options resolve once at startup (skills/templates roots, redactor,
  project instructions, permission mode, shell policy, trace path) and are
  reused for every session the process opens.
- **`resume` request**: idle-only re-bind with `open_or_create` semantics
  (resume if present, create only on `SessionNotFound`). Sequence: save the
  current session if durable → `Session.start(.open_or_create)` on the target
  path → deinit + destroy the old Session → emit `session` notification →
  respond. Target = explicit `path` (same `validateSessionPath` rules as the
  CLI) or the process-configured path. Busy → `session_busy` (mirrors the TUI
  swap lock).
- **Resume-path reuse across restarts** (the borrowed continue hook): a host
  crash is recovered by restarting `zag --rpc -c` on the same workspace; the
  durable session (writer lease, schema v1) is picked up exactly as
  `--continue` does today. No new session schema fields.
- Control queues are **not** cleared between runs (TUI rule): steers queued
  during a run that survive cancel/error are applied to the next prompt.

## 8. Host architecture and lifecycle

### 8.1 Dual-thread host (TUI pattern)

```text
main thread:  read stdin frames → dispatch → responses (writer mutex)
worker thread: Agent.reply(session, prompt)   ← one at a time
lifecycle/observer callbacks: fire ON THE WORKER THREAD; serialize each
  notification under the writer mutex and emit immediately (in order)
permission gate: worker blocks on a condvar; main thread delivers
  permission_decision / cancel / shutdown as deny-or-allow (§8.4)
```

- Frames from worker callbacks and main-thread responses share **one writer
  mutex**; ordering is deterministic: all notifications of a run precede its
  `prompt` response.
- `worker_active` (atomic) guards the single-in-flight invariant.
- `Agent.requestCancel()` is called **only** when `worker_active` (idle
  cancel is a no-op, so the next prompt starts with a clean flag — the flag
  is already cleared at the reply-completion boundary).

### 8.2 Run lifecycle

```text
prompt request
  → worker_active = true; spawn worker thread
  → (lifecycle/observer notifications flow)
  → reply returns → response (result with stop_reason)
  → join worker; worker_active = false; state idle
```

### 8.3 Shutdown (exactly one exit path)

Triggers: `exit` request · stdin EOF (client disconnect) · first SIGINT /
SIGTERM. All share one graceful sequence:

```text
set shutting_down (stop reading stdin)
resolve pending permission gate as DENY (never allow on shutdown)
if worker_active → Agent.requestCancel (cooperative)
join worker, bounded wait 30 s
  → worker joined: save session (best effort; durable only), deinit,
    exit 0
  → join bound expired: exit 70 (truthful — mid-handler preemption is
    not claimed; the loop saves at turn boundaries)
```

Second SIGINT/SIGTERM while shutting down → immediate exit **130** (cli-sigint
semantics). **No idle timeout in v1** (the client owns process lifetime; an
editor host must not be surprised by an LSP-style idle kill).

### 8.4 Permission gate bridge

- ask mode: `permissions.Gate.ask(rpcAskFn, server)`. The callback blocks the
  worker; the server emits `permission_request` (unconditional). The client
  answers with `permission_decision`; the server resolves the condvar.
  `remember: true` → `Gate` records the write path (existing remember store).
- `cancel` or shutdown while a gate is pending → resolve **deny** (never
  allow on cancel); the run then ends `cancelled` at the next boundary.
- yolo mode: no `permission_request` frames at all.
- **No gate deadline in v1** (mirrors the TUI's human-at-keyboard model;
  cancel/EOF are the unblock paths — see §12 open questions).

### 8.5 Exit code matrix (rpc mode)

The headless numeric matrix applies to rpc-mode **process exits**; run-level
outcomes never exit the process (they are `prompt` responses).

| Scenario | Exit | Notes |
|----------|:----:|-------|
| Clean shutdown (`exit`, EOF, first signal, graceful join) | 0 | |
| Usage / mode-matrix violation | 2 | empty stdout |
| Run-level outcomes (`completed`/`max_turns`/`cancelled`/`timeout`/…) | — | response result, **no process exit** (rows 10/11/20/21/22 reserved for headless parity, unused in rpc mode) |
| Startup `provider_configuration` / `provider_error` | 30 / 31 | `error` notification first |
| Startup `invalid_toolset` / `invalid_context` | 32 / 33 | |
| `out_of_memory` | 40 | best-effort response, then exit |
| Session startup/resume store failures | 50–55 | `session_not_found` 50, `session_already_exists` 51, `session_invalid` 52, `session_unsupported_schema` 53, `session_busy` 54, `session_io_failed` 55 |
| `trace_error` | 60 | |
| Internal / join-bound expiry | 70 | |
| Second signal | 130 | |

## 9. Error model

### 9.1 Request error object (response `error`)

```json
{ "code": "session_busy", "message": "a run is already in flight", "retryable": false, "category": "session" }
```

Frozen codes: `invalid_arguments` · `unknown_method` · `unknown_event` ·
`unsupported_protocol` · `session_busy` · `queue_full` · `message_too_long` ·
`prompt_too_large` · `session_not_configured` · `session_not_found` ·
`session_already_exists` · `session_invalid` · `session_unsupported_schema` ·
`session_io_failed` · `permission_unknown` · `out_of_memory` (then exit 40) ·
`internal_error` (then exit 70). Unparseable frames get `id: null` and the
server continues (bounded, §3). `retryable` is `true` only for
`session_io_failed` in v1; `category` mirrors headless (`auth` / `provider` /
`session` / `runtime` / `argument`).

### 9.2 Run outcomes (response `result`)

Run-level failures are **results**, not response errors (headless rule):
`stop_reason` ∈ `completed` · `max_turns` · `cancelled` · `timeout` ·
`unsupported_control` · `provider_error` · `session_error` · `trace_error` ·
`out_of_memory` · `invalid_toolset` · `invalid_context`; `ok` = headless
`resultOk` (true for completed/max_turns/cancelled).

## 10. Budgets (checked arithmetic)

| Item | Cap |
|------|----:|
| Inbound frame (line) | **4 MiB** (overflow → error + resync) |
| `prompt.text` | **1 MiB** (`prompt_too_large`) |
| `steer` / `follow_up` text | **4096 B** (= `control_queue.message_max_bytes`, wire-enforced before the queue) |
| `subscribe.events` | **32 entries** (7 valid groups) |
| `permission_request.arguments_json` | **64 KiB** + `...[truncated]` |
| `tool_end.body` | 64 KiB (existing `tool.max_result_bytes` — loop-capped, passed through) |
| `final_text` (result) | **1 MiB** + `...[truncated]` |
| Shutdown join bound | **30 s** (expiry → exit 70) |

No server-side run deadline in v1: the end-to-end provider deadline is the
existing config-driven `provider_timeout_ms` (CLI `--timeout` passthrough),
identical to every other mode.

## 11. Redaction (frozen rules)

1. Every string field in every frame passes the Session redactor
   (`session.activeRedactor()`), exactly like headless-v1.
2. Error and notification messages never contain API keys, session paths,
   trace paths, or absolute file system paths.
3. `tool_start.arguments` / `tool_end.body` / `permission_request.arguments_json`
   are redacted as raw strings (marker may appear).
4. The API key is never transmitted: it stays in the server process
   environment; the client configures the provider via the same flags/config
   the CLI already uses before the process starts.

## 12. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| [headless-contract.md](./headless-contract.md) | **separate** protocol; rpc-v1 neither modifies nor extends headless-v1 (headless reserves it); both modes coexist in one binary, mutually exclusive on the CLI |
| Session v1 / Trace v1 | **unchanged**; `Session.start`/`OpenMode`/writer lease reused; trace stays a file flag |
| [harness-steering.md](./harness-steering.md) | queue caps (4 × 4096 B) are binding on the wire; no new control surface |
| [harness-events.md](./harness-events.md) | LifecycleObserver mapped 1:1 onto §6 notifications; no Core channel |
| [permissions.md](./permissions.md) | `Gate.ask` bridge (§8.4); never allow on cancel/shutdown |
| [cli-interaction.md](./cli-interaction.md) | mode matrix + first-signal-graceful/second-130 semantics |
| [process-supervisor.md](./process-supervisor.md) | **no dependency** (frozen, lsp-001-style): supervisor v1 is foreground-bounded and hosts agent-spawned children; the rpc server is a top-level host spawning nothing; `run_shell` inherits supervisor migration automatically with zero wire change |
| [sdk-contract.md](./sdk-contract.md) | no in-process API change; rpc is a process entrance, not an SDK surface |
| [extensions.md](./extensions.md) / D-010 | rpc is a product entrance (like JSON/TUI), not an extension tier; E2 `zag-ext-process-v1` stays separate |
| Maturity | **no row raise**; no OS sandbox; no process-tree ownership claims |

## 13. Fixtures (implementation track — when ready)

`packages/zag-cli/src/rpc_process_fixture.zig`, same style as
`tui_process_fixture.zig`: real `zag --rpc` binary, isolated tmp cwd, empty
env + `ZAG_API_KEY`/`ZAG_BASE_URL`, mock provider over localhost
(`headless_mock_server.zig` for full responses; `sigint_slow_mock.zig` for
stalled-provider busy/cancel timing — both already wired). Runs under std
**and** curl backends; PTY gates via openpty on macOS/Linux (SkipZigTest
elsewhere), libc on the test artifact only. ~20 classes (§fixtures of
rpc-v1-001).

## 14. Non-goals (v1)

- ACP / editor protocol parity (separately gated adapter later)
- Network transport, sockets, auth, multi-client
- Multi-session per process; session browser/switch UI
- Prompt queueing; background jobs; idle timeout; server-side run deadlines
- In-flight Tool/shell preemption claims
- TUI integration; headless-v1 / Session v1 / Trace v1 changes; Core/coding-agent ports
- New Zig package; maturity raise; OS sandbox; process-tree ownership
- stdout logs or human banners in rpc mode (stderr only)

## 15. Open questions for dual review

1. **Gate deadline**: none in v1 (cancel/EOF unblock; mirrors the TUI
   human-at-keyboard model). Confirm, or add a bounded gate timeout.
2. **Tool events single source**: lifecycle `tool_start`/`tool_end` only;
   observer `tool_call`/`tool_result` not duplicated. Confirm.
3. **`resume` explicit path** vs configured-path-only (contract allows any
   valid workspace-relative path, open_or_create).
4. **First SIGINT = graceful exit** (not cancel-only) in rpc mode — the
   protocol owns cancel; signals own operator shutdown. Confirm.
5. **`--verbose` forbidden** in rpc mode (TUI parity). Confirm.
6. Cap values: frame 4 MiB / prompt 1 MiB / final_text 1 MiB / permission
   args 64 KiB.
7. `stream` param vs pure subscription-driven deltas (contract has both;
   `stream` defaults true).

## Related

- [rpc-v1-001](../plan/tasks/rpc-v1-001.md)
- [process-supervisor.md](./process-supervisor.md) · [headless-contract.md](./headless-contract.md)
- [harness-events.md](./harness-events.md) · [harness-steering.md](./harness-steering.md) · [permissions.md](./permissions.md) · [cli-interaction.md](./cli-interaction.md)
- [lsp.md](./lsp.md) (sibling design slice)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md) · [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) · [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) · [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md)
- Hyper: Claude-Code-SDK RPC (client-mode JSON-RPC over stdio) — shape reference only (D-009)
