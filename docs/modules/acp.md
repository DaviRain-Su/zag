# Zag ACP adapter (`acp-v1`)

> Binding draft for [acp-001](../plan/tasks/acp-001.md) (D-012 item 4 second
> half — "a separately gated ACP adapter"). ACP = the **Agent Client
> Protocol** (agentclientprotocol.com), the editor↔agent JSON-RPC protocol
> from the Claude-Code-SDK ecosystem (Zed, Claude Code, the ACP registry).
> Zag speaks the **editor's** protocol directly over stdio, assembled from the
> same public host surfaces rpc-v1 assembled — **no Core changes, no
> coding-agent changes, no new package**.
>
> Reference (semantic, **not** parity — D-009): the official ACP v1 spec
> (agentclientprotocol.com/protocol/v1) and the `agent-client-protocol` Rust
> SDK 0.10.4 / schema 0.11.4 (the crate hyper-grok-build builds against), plus
> the Claude-Code-ecosystem custom methods pinned in §6. Method names,
> capability gates, and wire shapes are quoted from that surface; nothing is
> ported.
>
> **Status:** **implemented** @ `8d2ba64` ([acp-001](../plan/tasks/acp-001.md);
> 32/33 process-fixture gates). Wave 2 closeout 2026-08-14:
> [architecture](../plan/reviews/acp-001-01-architecture.md) PASS ·
> [safety](../plan/reviews/acp-001-02-safety.md) PASS. gate15 residual:
> [acp-gate15-001](../plan/tasks/acp-gate15-001.md). Zig 0.16 (`std.Io` era)
> APIs assumed throughout.

## 1. Principles

1. **Speak the editor's protocol, assemble the host like the TUI.** `zag
   --acp` is a third long-lived host mode (after TUI and `--rpc`): the same
   Agent + Session assembly, with the terminal UI replaced by JSON-RPC 2.0
   over stdio. ACP's method vocabulary, capability negotiation, and session
   correlation are honored as the protocol defines them; zag semantics
   (cooperative cancel, bounded control queues, permission gate, redaction)
   are unchanged.
2. **Consume existing public surfaces, change nothing.** Agent / Session /
   LifecycleObserver / Observer / permission Gate / control queues /
   `sigint.Guard` are the entire backend. No Core ports, no coding-agent
   changes, no rpc-v1 changes, no new package.
3. **Framing is newline-delimited JSON-RPC 2.0 — not LSP framing.** The ACP
   transports spec fixes stdio as one JSON-RPC message per `\n`-terminated
   line (UTF-8, no embedded newlines). There is **no Content-Length
   framing** in ACP: the transport shape is the same NDJSON shape rpc-v1
   uses. The adapter therefore reuses `rpc/framing.zig` read-only (4 MiB cap,
   resync at next newline); what differs from rpc-v1 is the *envelope*
   (`jsonrpc: "2.0"`, §5), the *method vocabulary* (§6), and the *error
   model* (§11) — not the line discipline.
4. **One server process = one Agent + one Session** (rpc-v1 §7 parity:
   `-s PATH` create / `-c` resume / none = ephemeral, decided at startup).
   ACP's `sessionId`-correlated surface is served by a one-row session
   table; `session/new` maps onto the startup session (§7). A second
   `session/prompt` while one is in flight → application error `busy`
   (§11). No prompt queueing.
5. **Bounded everything.** Frame, prompt-text, steer-text, permission-field,
   and tool-body caps (checked arithmetic, §12). Overflow is an explicit
   JSON-RPC error or an explicit truncation marker — never silent RAM growth.
6. **Truthful terminal.** Exactly one exit path per shutdown trigger with a
   documented exit code (§10). A run that cannot finish reports its real
   outcome: stop reasons where ACP has vocabulary, a JSON-RPC run error
   where it does not (§11.3). The server never invents success.
7. **Redaction on every field** (§13) — except `cwd`, which ACP *mandates*
   absolute and which is echoed from the client's own request (zero new
   disclosure).
8. **No parity claims.** ACP is a moving spec (v2 draft exists). The adapter
   pins the v1 subset in §6 and answers everything else with standard
   JSON-RPC errors; the full SDK surface (fs/terminal/elicitation/session
   management methods) is out of scope (D-009, §16).

## 2. Relationship to rpc-v1 (frozen decision)

Two options were evaluated; **(b) is frozen**.

| Dimension | (a) Translation layer on top of the rpc server | (b) Separate adapter (chosen) |
|-----------|------------------------------------------------|-------------------------------|
| Framing | Same NDJSON transport — but that is the *only* shared layer; rpc-v1's envelope (`protocol_version` + `type`, integer-id, string error codes) is not JSON-RPC 2.0 (`jsonrpc`, string-or-number ids, numeric codes) | `rpc/framing.zig` reused read-only (same package); own protocol types for the JSON-RPC 2.0 envelope |
| Error model | rpc string codes (`session_busy`, `queue_full`, …) have no JSON-RPC equivalents; every mapping is a lossy re-interpretation | Native JSON-RPC errors; rpc codes stay rpc-only |
| Session model | rpc-v1 is one-process-one-session bound at startup; ACP `session/new` carries `cwd` and expects per-editor session creation — inexpressible without an rpc wire extension (frozen) or per-session child spawns (process-supervisor territory, explicitly out of scope) | `session/new` maps onto the startup session with cwd validation in the adapter (§7) |
| Permission | Adapter relays `permission_request` → `session/request_permission` and answers `permission_decision`; workable, but adds a hop and a second correlation layer on top of rpc's request-id counter | Direct `Gate.ask` bridge emitting ACP's own agent→client request (§9) |
| Host shape | Would have to be a **second process** (both protocols own stdin/stdout): adapter spawns `zag --rpc` as a child — contradicts rpc-v1's "top-level host, spawns nothing" decision and D-012's supervisor ordering. In-process variant requires refactoring the just-landed, frozen rpc server | Third host assembly (TUI / rpc precedent): one process, direct surfaces, zero rpc churn |
| Test reuse | Fixture drives a proxy through rpc frames — indirect, double-binary, and it would test the translator, not the protocol | Same fixture style, same mocks (`headless_mock_server.zig`, `sigint_slow_mock.zig`), direct JSON-RPC client in the fixture |
| Maintenance | Every ACP change touches the translator and risks pressure to change the frozen rpc wire | rpc-v1 stays frozen; ACP tracks its spec independently |

**Decision:** **(b)** — a separate adapter inside `zag-cli`, reusing
`rpc/framing.zig` (import, unchanged), the dual-thread host *pattern* from
`rpc/server.zig`, and the fixture/mock infrastructure. It is the cheaper
correct option: the protocol mismatch is at the envelope/semantics level, not
the transport; option (a) would either violate the frozen rpc-v1 contract or
drag in process ownership that D-012 explicitly defers.

**Shared principles with rpc-v1** (adopted, not imported): dual-thread host
(worker runs `Agent.reply`, main thread reads stdin + dispatches), one writer
mutex, gate condvar bridge, bounded shutdown join, truthful exit codes,
first-signal-graceful/second-130, no idle timeout, stdout protocol-only.

## 3. Ownership and paths

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-cli`** | `--acp` mode; JSON-RPC 2.0 wire types; ACP server host (read loop, dispatcher, session table, worker thread, permission request bridge, writer mutex, shutdown); `acp_process_fixture.zig` | Core/coding-agent changes; rpc-v1 changes; TUI imports; sockets/network; new package without ownership pressure |
| `zag-coding-agent` | unchanged — consumed public surfaces only | ACP types; wire vocabulary |
| `zag-agent-core` | unchanged (D-011/D-012) | process/pipe/protocol ports |
| `rpc/*` (zag-cli) | unchanged — `rpc/framing.zig` is imported read-only by the ACP adapter (same package, protocol-agnostic line I/O) | — |
| `zag-tui` | unchanged | — |

**No new package in v1** (packaging law, rpc-v1 §2): one consumer (the `zag`
binary), no frozen public API, no release channel, no heavy dependency.

### 3.1 Future implementation paths

| Path | Role |
|------|------|
| `packages/zag-cli/src/acp/protocol.zig` | JSON-RPC 2.0 + ACP wire types: envelope parse/serialize, frozen method subset (§6), error codes (§11), budgets (§12), capability constants (unit-testable without IO) |
| `packages/zag-cli/src/acp/server.zig` | dual-thread host (rpc/server.zig pattern): read loop, dispatch, worker, one-row session table, permission request bridge, writer mutex, shutdown; imports `rpc/framing.zig` |
| `packages/zag-cli/src/acp_entry.zig` | `--acp` CLI wiring (mode matrix, Agent/Session init, Guard) — mirrors `rpc_entry.zig` |
| `packages/zag-cli/src/cli.zig` | `--acp` flag + mutual-exclusion matrix (§10.2) |
| `packages/zag-cli/src/acp_process_fixture.zig` | process fixture: fake editor over pipes/PTY (real `zag --acp` binary, mock provider) |
| root `build.zig` | `acp-process-fixture` step wired into `test` under std **and** curl |
| `docs/modules/README.md` · `docs/plan/tasks/README.md` | add `acp.md` / `acp-001` rows at contract freeze (not this slice) |

`acp/framing.zig` is **not** created: ACP's line discipline is identical to
rpc-v1's and `rpc/framing.zig` carries no protocol semantics — it is imported
as-is. No `SignalHost` (rpc-v1 §2.1 rationale applies).

## 4. Transport and trust (frozen)

- **Framing:** NDJSON — exactly one JSON object per `\n` (0x0A)-terminated
  line, UTF-8, **no embedded newlines** (ACP transports spec; a literal `\n`
  inside a string value splits the frame → parse error). Same line
  discipline as rpc-v1 §3; implemented by `rpc/framing.zig` (reused).
- **Direction:** client (editor) writes stdin, agent writes stdout. stderr
  carries human diagnostics only. **stdout is protocol-only in acp mode**
  (same rule as headless/rpc): no logs, prompts, or banner bytes.
- **Cap:** inbound line ≤ **4 MiB** (`rpc/framing.zig` `frame_cap`).
  Overflow → JSON-RPC parse error (`-32700`, id `null`) + resync at the next
  newline (bounded drain). The server never buffers past the cap.
- **Pipelining:** the read loop processes one frame at a time, in order;
  responses are written in request order. A second `session/prompt` while one
  is in flight receives the `busy` application error (§11.2).
- **Versioning:** ACP negotiates a single **integer** protocol version in
  `initialize` (`protocolVersion: 1` — no per-frame version field). The
  adapter answers `1` and rejects nothing on the envelope; breaking changes
  would require a new major version, out of v1.
- **Trust:** inherited stdio only; same-user, same-host process boundary
  (rpc-v1 §3 rationale). The client is trusted as the user's own shell; the
  protocol grants nothing beyond the CLI's existing permission/jail/policy/
  redaction enforcement. No network auth, no tokens, no credential
  forwarding; the API key lives in the server environment and never crosses
  the wire.

## 5. Envelope (JSON-RPC 2.0, frozen)

Every message is one JSON-RPC 2.0 object:

```json
{ "jsonrpc": "2.0", "id": 1, "method": "session/prompt", "params": { } }
{ "jsonrpc": "2.0", "id": 1, "result": { "stopReason": "end_turn" } }
{ "jsonrpc": "2.0", "method": "session/update", "params": { } }
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32601, "message": "Method not found" } }
```

| Field | Rule |
|-------|------|
| `jsonrpc` | `"2.0"` required; missing/wrong → `-32600` (id `null`) |
| `id` | requests/responses only; string or integer, echoed verbatim; **absent id = notification** (no response, ever); id `null` treated as a notification (JSON-RPC discourages it) |
| `method` | requests/notifications; frozen set §6; unknown request → `-32601`; unknown **notification → silently ignored** (JSON-RPC rule — this is also how `initialized`/unknown extensions are tolerated) |
| `params` | object; unknown extra fields ignored (forward compat); `_meta` ignored |
| `result` / `error` | response only; exactly one present; `error` is the §11 object |

## 6. Method subset (frozen v1)

### 6.1 Client → agent requests

| Method | Status | Params (v1-relevant) | Result | Errors |
|--------|--------|----------------------|--------|--------|
| `initialize` | **required** (baseline; first method) | `{ "protocolVersion": int, "clientCapabilities"?: {}, "clientInfo"?: {} }` | `{ "protocolVersion": 1, "agentCapabilities": { "sessionCapabilities": { "list": {} } }, "agentInfo": { "name": "zag", "title": "Zag", "version": <zag_version> }, "authMethods": [] }` — **no** `loadSession`, **no** `mcpCapabilities`, **no** prompt/image/audio extras | `-32600` (called after the process already initialized once, or malformed) |
| `session/new` | **required** (baseline) | `{ "cwd": string (absolute), "mcpServers"?: [], "prompt"?: [], "additionalDirectories"?: [] }` | `{ "sessionId": "sess_1" }` — maps onto the startup session (§7); **idempotent**: repeated calls return the same id | `-32602`: cwd ≠ process cwd; non-empty `mcpServers` / `additionalDirectories`; `prompt` present (initial prompt unsupported in v1) |
| `session/prompt` | **required** (baseline) | `{ "sessionId": string, "prompt": ContentBlock[], "allowInterruptions"?: bool, "maxTurns"?: int, "canUseMcp"?: bool }` | `{ "stopReason": "end_turn" \| "max_turn_requests" \| "cancelled" }` — run-level failures are JSON-RPC errors (§11.3) | `-32602` (unknown sessionId, empty/oversized prompt, unsupported content block), `-32001` busy |
| `session/cancel` | **required** (baseline) | `{ "sessionId": string }` — **notification**, no response | — | — (unknown sessionId or idle → ignored; a cancel notification while a run is in flight → `Agent.requestCancel()` + pending gate resolved **deny**, §9) |
| `session/list` | **optional** (advertised: `sessionCapabilities.list`) | `{}` | `{ "sessions": [ { "sessionId": "sess_1", "cwd": <process cwd> } ] }` — the current session only (§7) | — |
| `session/steer` | **optional extension** (see below) | `{ "sessionId": string, "text": string (1..4096 B), "interjectionId"?: string }` | `{ "status": "queued" }` | `-32602` (empty text / unknown sessionId), `-32003` (> 4096 B), `-32002` (queue full, cap 4) |
| `authentication/getUser` | **optional extension stub** | `{}` | `{ "userId": null, "userName": null }` — zag has no user concept | — |
| `ping` | **optional compat** | `{}` | `{}` | — |
| anything else | — | — | — | `-32601` |

**`session/steer` provenance:** steer is **not** part of official ACP v1
(no such method in the spec or the SDK — the SDK's interruption surface is
`allowInterruptions` + `session/cancel`, and ecosystem steer lives in
extension methods such as grok's `x.ai/interject`). The name `session/steer`
is pinned here because it is the Claude-Code-ecosystem name editors expect
(batch context; same convention as `authentication/getUser` — see §17
question 6). It is documented as a **zag extension method**, not an ACP
spec method.

**`initialized` / `ping` provenance:** neither is in official ACP v1 (the
initialization flow is `initialize` → response; there is no `initialized`
notification and no keepalive method in the spec or SDK). Both are accepted
for Claude-Code-client compatibility: `initialized` as an ignored
notification (unknown-notification rule), `ping` as a trivial request
(`{}` result) or ignored notification.

**`authentication/getUser` provenance:** not in official ACP. The official
auth surface is `authenticate` (baseline) — which the adapter does **not**
advertise (`authMethods: []`), so compliant clients never call it; if called
anyway → `-32602` "zag does not require authentication". `getUser` is an
ecosystem extension stub (batch scope: "authentication flows beyond getUser
stub" is a non-goal, so the stub itself is in).

### 6.2 Agent → client (server → editor)

| Method | Status | Params | When |
|--------|--------|--------|------|
| `session/update` | **required** (baseline) | `{ "sessionId": string, "update": { §8 variants } }` | streaming during a run (§8); notification, no response |
| `session/request_permission` | **required when permission mode = ask** (baseline) | `{ "sessionId": string, "toolCall": { "toolCallId": string, "title": string, "kind": "other", "fields": <redacted raw args, ≤ 64 KiB> }, "options": [ { "id": "allow_once", "kind": "allow_once" }, { "id": "allow_always", "kind": "allow_always" }, { "id": "reject_once", "kind": "reject_once" }, { "id": "reject_always", "kind": "reject_always" } ] }` | ask mode, each gate decision needed; the run blocks on the response (§9). yolo mode: never emitted |

The client answers `session/request_permission` with a JSON-RPC response to
the adapter's id: `{ "result": { "outcome": { "optionId": "allow_once" } } }`
or `{ "result": { "outcome": "cancelled" } }` (SDK `RequestPermissionOutcome`
shapes). A **notification** in response to the permission request is not
valid (it has an id) — a missing response blocks the run until `session/
cancel` / shutdown resolves it as deny (no gate deadline, §9).

## 7. Session mapping (frozen)

- **One server process = one Agent + one Session** (rpc-v1 §7 parity).
  Session selection happens at startup via the existing flags (`-s` create /
  `-c` resume / none = ephemeral); the process cwd is the workspace.
- **Session table:** exactly one row. The adapter assigns the opaque id
  **`sess_1`** at startup (never a path — redaction §13) and keeps the
  session path internally.
- **`session/new`** maps onto the startup session: the session already
  exists (created when the process launched — the editor's "create" moment
  moved to launch time), so the call validates and returns it:
  - `cwd` must equal the process cwd (canonicalized comparison) → else
    `-32602` "cwd does not match the process working directory". Fail
    closed: the agent runs in the workspace the host launched it in.
  - non-empty `mcpServers` / `additionalDirectories` → `-32602` (no MCP,
    no extra roots — not advertised, so compliant clients do not send them).
  - `prompt` present → `-32602` "initial prompt unsupported; use
    session/prompt" (v1; the response-timing semantics of prompt-in-new are
    underspecified in ACP and the editor can prompt immediately after).
  - Repeated `session/new` is **idempotent** (same id; no second session).
    Concurrent-second-session semantics are out of v1 (§16).
- **`session/prompt`** with an unknown `sessionId` → `-32602`. `session/
  cancel` with an unknown `sessionId` → ignored (notification).
- **`session/list`** returns the single current row
  `{ "sessionId": "sess_1", "cwd": <process cwd> }` — no session-store scan
  in v1 (that would leak paths and needs store plumbing; §16).
- **No `session/load` / `session/resume` / `session/close` / `session/
  delete` / `session/set_mode` / `session/set_config_option` / `session/
  fork`:** not advertised, `-32601` if called. The rpc-v1-style continue
  hook (`--acp -c` on the same workspace after a crash) is the resume
  story for v1, exactly as in rpc-v1 §7.
- Control queues are **not** cleared between runs (TUI/rpc rule): steers
  queued during a run that survive cancel/error apply to the next prompt.
- `maxTurns` on `session/prompt` is **accepted and ignored** (the agent's
  host-configured max_turns applies; per-run override has no public surface
  — documented limitation, §17 question 4).

## 8. Run streaming (`session/update`, frozen v1 variants)

Notifications fire on the worker thread, serialized under one writer mutex
in program order; the `session/prompt` response is always the last frame of
its run (rpc-v1 §8.1 pattern).

| zag event (source) | ACP `session/update` variant |
|--------------------|------------------------------|
| lifecycle `assistant_delta` | `{ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": … } }` |
| lifecycle `assistant_delta_clear` | *(none — ACP has no clear; chunks accumulate)* |
| lifecycle `thinking_delta` | `{ "sessionUpdate": "agent_thought_chunk", "content": { "type": "text", "text": … } }` |
| lifecycle `tool_start` | `{ "sessionUpdate": "tool_call", "toolCallId": <tool call id>, "title": <tool name>, "kind": "other", "status": "pending" }` |
| lifecycle `tool_end` | `{ "sessionUpdate": "tool_call_update", "toolCallId": <id>, "status": "completed" \| "failed", "content": [ { "type": "content", "content": { "type": "text", "text": <body, ≤ 64 KiB> } } ] }` (content omitted when body empty) |
| lifecycle `run_start` / `control_applied` | *(none — ACP has no run/control events)* |
| observer `usage` | *(none in v1 — ACP `usage_update` is context-window used/size, not run tokens; emitting it would fabricate data; §17 question 5)* |
| observer `permission` | *(none — decisions surface through the §9 flow only)* |

- Pending-cancel between tools: no fabricated `tool_call`/`tool_call_update`
  pair; the client marks non-finished calls `cancelled` itself (ACP
  cancellation rule: "the Client SHOULD preemptively mark all non-finished
  tool calls… as cancelled").
- `messageId` is omitted on chunks in v1 (optional per spec; §17 question 7).
- `rawInput` / `rawOutput` are omitted on tool frames in v1 (redaction-vs-
  absolute-path tension; title/status/content suffice for editors;
  §17 question 8).

## 9. Permission bridge (frozen)

- ask mode: `permissions.Gate.ask(acpAskFn, server)`. The callback runs on
  the worker thread; the adapter emits `session/request_permission` as a
  JSON-RPC **request with the adapter's own id** (separate id counter from
  client ids — namespaces are per-direction, no collision possible) and
  blocks on a condvar, exactly like rpc-v1 §8.4.
- Client outcome mapping (frozen):
  | outcome | gate decision |
  |---------|---------------|
  | `{ "outcome": { "optionId": "allow_once" } }` | **allow** (no remember) |
  | `{ "outcome": { "optionId": "allow_always" } }` | **allow** + remember the write path (existing remember store) |
  | `{ "outcome": { "optionId": "reject_once" } }` | **deny** |
  | `{ "outcome": { "optionId": "reject_always" } }` | **deny** (zag has no deny-remember store; §17 question 9) |
  | `{ "outcome": "cancelled" }` | **deny** |
- `session/cancel`, stdin EOF, or shutdown while a gate is pending →
  resolve **deny** (never allow on cancel); the run then ends `cancelled`
  at the next boundary.
- yolo mode: no `session/request_permission` frames at all.
- **No gate deadline in v1** (rpc-v1 §8.4 rationale; cancel/EOF are the
  unblock paths).

## 10. Host architecture, lifecycle, exit codes

### 10.1 Dual-thread host (rpc-v1 §8.1 pattern)

```text
main thread:  poll stdin + Guard self-pipe (250 ms) → read frames → dispatch
              → responses (writer mutex); owns shutdown
worker thread: Agent.reply(session, flattened_prompt)   ← one at a time
lifecycle/observer callbacks: fire ON THE WORKER THREAD; each session/update
  notification serialized under the writer mutex, emitted immediately
permission gate: worker blocks on a condvar; main thread delivers the client's
  outcome / cancel / shutdown as deny-or-allow (§9)
```

### 10.2 CLI surface and mode matrix

- Flag: **`--acp`** (long-lived server mode, stdin/stdout pipes).
- Mutually exclusive with `--rpc`, `--json`, `--json-stream`, `--tui`,
  `--doctor`, `--verbose`, and a positional prompt → exit **2**, empty
  stdout. `--acp --help` → stderr help, exit **0**, empty stdout.
- Session flags `-s PATH` / `-c` / none behave exactly as every other mode.
- Always compiled (like headless/rpc; no `-Dtui` gate) — the flag is the
  separate gate D-012 requires.

### 10.3 Shutdown (exactly one exit path)

Triggers: **stdin EOF** (editor closed the process / client disconnect) ·
**first SIGINT/SIGTERM**. There is **no `exit` request** in ACP — the client
owns process lifetime (editors kill or close stdin). All triggers share one
graceful sequence:

```text
set shutting_down (stop reading stdin)
resolve pending permission gate as DENY
if worker active → Agent.requestCancel (cooperative)
join worker, bounded wait 30 s
  → joined: save session (best effort; durable only), deinit, exit 0
  → join bound expired: exit 70 (truthful — no mid-handler preemption claim)
```

Second SIGINT/SIGTERM while shutting down → immediate exit **130**
(cli-sigint semantics). **No idle timeout in v1** (rpc-v1 §8.3 rationale).

### 10.4 Exit code matrix (acp mode)

The headless numeric matrix applies to acp-mode **process exits**; run-level
outcomes never exit the process (they are `session/prompt` results or run
errors, §11.3).

| Scenario | Exit | Notes |
|----------|:----:|-------|
| Clean shutdown (EOF, first signal, graceful join) | 0 | |
| Usage / mode-matrix violation | 2 | empty stdout |
| Run-level outcomes | — | response result / run error, **no process exit** |
| Startup `provider_configuration` / `provider_error` | 30 / 31 | stderr diagnostic only (see below) |
| Startup `invalid_toolset` / `invalid_context` | 32 / 33 | |
| `out_of_memory` (mid-run) | 40 | best-effort `-32603` error, then exit |
| Session startup/resume store failures | 50–55 | rpc-v1 §8.5 codes |
| `trace_error` | 60 | |
| Internal / join-bound expiry | 70 | |
| Second signal | 130 | |

**Startup failures emit no stdout bytes** (unlike rpc-v1's `error`
notification — JSON-RPC has no notification channel for a failure that
happens before any request id exists): the adapter writes a human diagnostic
to stderr and exits with the mapped code. The editor observes EOF + exit
code; that is the protocol-honest surface.

## 11. Error model

### 11.1 JSON-RPC codes (frozen)

| Code | Name | When |
|-----:|------|------|
| `-32700` | Parse error | malformed JSON; frame > 4 MiB (id `null`, then resync at newline) |
| `-32600` | Invalid request | missing/wrong `jsonrpc`; malformed envelope; request before `initialize` ("not initialized"); invalid id shape |
| `-32601` | Method not found | unknown request method (incl. all non-advertised ACP methods) |
| `-32602` | Invalid params | §6 param rules (cwd mismatch, unknown sessionId, empty/oversized prompt, unsupported content block, mcpServers, initial prompt, oversized steer, authenticate-without-advertisement) |
| `-32603` | Internal error | internal failure (then exit 70) / out-of-memory (best effort, then exit 40) |

### 11.2 Application codes (implementation-defined range)

| Code | Name | When |
|-----:|------|------|
| `-32000` | Run error | `session/prompt` run-level failure (§11.3) — message carries the redacted failure reason |
| `-32001` | Busy | `session/prompt` while a run is in flight |
| `-32002` | Queue full | `session/steer` beyond the 4-slot control queue |
| `-32003` | Message too long | `session/steer` text > 4096 B (wire-enforced before the queue) |

### 11.3 Run outcomes (frozen mapping)

Run-level failures are **never** invented successes. zag `stop_reason` →
ACP surface:

| zag `stop_reason` | ACP surface |
|-------------------|-------------|
| `completed` | result `{ "stopReason": "end_turn" }` |
| `max_turns` | result `{ "stopReason": "max_turn_requests" }` |
| `cancelled` | result `{ "stopReason": "cancelled" }` (cooperative; **must** be returned when a `session/cancel` was received, per ACP cancellation rule) |
| `timeout` · `provider_error` · `session_error` · `trace_error` · `out_of_memory` · `invalid_toolset` · `invalid_context` · `unsupported_control` | error `-32000`, message = redacted failure text (ACP has no stop reason vocabulary for these; the prompt request is answered with an error, which editors display) |

## 12. Budgets (checked arithmetic)

| Item | Cap |
|------|----:|
| Inbound frame (line) | **4 MiB** (`rpc/framing.zig`; overflow → `-32700` + resync) |
| Flattened prompt text | **1 MiB** (`-32602`) |
| `session/steer` text | **4096 B** (= `control_queue.message_max_bytes`, wire-enforced) |
| `session/request_permission.fields` | **64 KiB** + `...[truncated]` |
| `tool_call_update` content text | 64 KiB (existing `tool.max_result_bytes`) |
| Shutdown join bound | **30 s** (expiry → exit 70) |

No server-side run deadline in v1: the end-to-end provider deadline is the
existing config-driven `provider_timeout_ms`, identical to every other mode.

## 13. Redaction (frozen rules)

1. Every string field in every frame passes the Session redactor
   (`session.activeRedactor()`), like rpc-v1 §11.
2. Error and notification messages never contain API keys, session paths,
   trace paths, or absolute file system paths.
3. `session/request_permission.toolCall.fields` is redacted as a raw string
   (marker may appear); tool titles and bodies pass the redactor.
4. **Exceptions (explicit):** `cwd` — ACP mandates absolute paths, and the
   only `cwd` values on the wire are (a) echoed from the client's own
   `session/new` request and (b) the process cwd in `session/list`, which
   the client already knows (it launched the process). Zero new disclosure.
   `sessionId` is an opaque adapter-generated token, never a path.
5. The API key is never transmitted: it stays in the server process
   environment; the client configures the provider via the same flags/config
   the CLI already uses before the process starts.

## 14. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| [rpc-v1.md](./rpc-v1.md) | **separate adapter** (§2): no rpc-v1 code changes; `rpc/framing.zig` imported read-only; rpc's string error codes and envelope are not reused |
| [headless-contract.md](./headless-contract.md) | separate protocol; headless-v1 untouched; mode matrix extends (not modifies) |
| [process-supervisor.md](./process-supervisor.md) | **no dependency** (frozen, rpc-v1-style): the ACP server is a top-level host spawning nothing (no `terminal/*`, no MCP servers); `run_shell` inherits supervisor migration automatically |
| [harness-steering.md](./harness-steering.md) | control queue caps (4 × 4096 B) binding on `session/steer`; no new control surface |
| [harness-events.md](./harness-events.md) | LifecycleObserver projected onto §8 variants; no Core channel |
| [permissions.md](./permissions.md) | `Gate.ask` bridge (§9); never allow on cancel/shutdown |
| [cli-interaction.md](./cli-interaction.md) | mode matrix + first-signal-graceful/second-130 semantics |
| [sdk-contract.md](./sdk-contract.md) | no in-process API change; ACP is a process entrance, not an SDK surface |
| [extensions.md](./extensions.md) / D-010 | ACP is a product entrance (like JSON/TUI/rpc), not an extension tier |
| Maturity | **no row raise**; no OS sandbox; no process-tree ownership claims |

## 15. Fixtures (implementation track — when ready)

`packages/zag-cli/src/acp_process_fixture.zig`, same style as
`rpc_process_fixture.zig`: real `zag --acp` binary, isolated tmp cwd, empty
env + `ZAG_API_KEY`/`ZAG_BASE_URL`, mock provider over localhost
(`headless_mock_server.zig`: `--echo` / `--tool-call` / `--stall-ms` /
`--ready-file`; `sigint_slow_mock.zig` for stalled-provider timing). The
fixture is a **fake editor** speaking JSON-RPC 2.0 over pipes/PTY. Runs under
std **and** curl backends; PTY gates via openpty on macOS/Linux
(SkipZigTest elsewhere), libc on the test artifact only. ~25 classes
(§verification of acp-001).

## 16. Non-goals (v1)

- Full ACP/SDK compatibility and parity (D-009); ACP v2 draft; ACP registry
  advertisement
- `session/load` · `session/resume` · `session/close` · `session/delete` ·
  `session/fork` · `session/set_mode` · `session/set_config_option` ·
  `session/set_model` · `logout` · `authenticate` flow (not advertised)
- Client-side surfaces: `fs/*` · `terminal/*` · elicitation · `usage_update`
  · plan/state updates · `user_message_chunk` replay
- Initial prompt in `session/new`; per-run `maxTurns` override;
  `allowInterruptions` enforcement (advisory in v1, §17 q.3)
- Multi-session concurrency (single session; `session/new` idempotent;
  busy → error); session-store scanning in `session/list`
- Multi-client; network transports (streamable HTTP / WebSocket); MCP
  servers; additional workspace roots
- Authentication flows beyond the `authentication/getUser` stub
- TUI integration; rpc-v1 / headless-v1 / Session v1 / Trace v1 changes;
  Core or coding-agent ports; new Zig package; maturity raise; OS sandbox;
  process-tree ownership

## 17. Open questions for dual review

1. **Pre-initialize requests**: `-32600` "not initialized" (pinned). Confirm.
2. **`session/new` idempotence**: repeated calls return the startup session's
   id. Confirm the single-session mapping is acceptable for v1.
3. **`allowInterruptions`**: accepted but **ignored** — `session/cancel` and
   `session/steer` always apply (zag's cancel is cooperative/boundary-based,
   identical to every other mode). Confirm, or honor `false` by ignoring
   cancel/steer for that run (risk: unkillable runaway turn).
4. **`maxTurns`**: accepted and ignored (host-configured max_turns applies).
   Confirm, or reject with `-32602` when present.
5. **No `usage_update`**: ACP's variant is context-window used/size, which
   zag does not track per run; emitting it would fabricate data. Confirm.
6. **Extension naming**: `session/steer` / `authentication/getUser` use bare
   ecosystem names (not the spec's `_`-prefix convention). Confirm keeping
   the ecosystem names, or switch to `_session/steer` / `_authentication/
   getUser` (spec-conformant but unknown to today's editors).
7. **`messageId` on chunks**: omitted in v1 (optional per spec). Confirm, or
   emit a per-message counter.
8. **Tool frames**: `kind: "other"` + title only; `rawInput`/`rawOutput`
   omitted (redaction-vs-absolute-path tension). Confirm.
9. **`reject_always`**: maps to plain deny (zag has no deny-remember store).
   Confirm.
10. **Startup failure surface**: stderr + exit code, no stdout bytes (no
    JSON-RPC error channel pre-initialize). Confirm.
11. Cap values: frame 4 MiB / prompt 1 MiB / steer 4096 B / permission
    fields 64 KiB.

## Related

- [acp-001](../plan/tasks/acp-001.md)
- [rpc-v1.md](./rpc-v1.md) · [rpc-v1-001](../plan/tasks/rpc-v1-001.md)
- [process-supervisor.md](./process-supervisor.md) · [headless-contract.md](./headless-contract.md)
- [harness-events.md](./harness-events.md) · [harness-steering.md](./harness-steering.md) · [permissions.md](./permissions.md) · [cli-interaction.md](./cli-interaction.md)
- [lsp.md](./lsp.md) (sibling design slice)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md) · [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) · [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) · [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md)
- ACP spec: agentclientprotocol.com/protocol/v1 (transports · initialization · session-setup · prompt-turn · tool-calls · extensibility) · `agent-client-protocol` SDK 0.10.4 / schema 0.11.4 (method constants, request/response shapes, `StopReason`, `PermissionOptionKind`, `ToolKind`, `ToolCallStatus`) · hyper-grok-build `x.ai/interject` steer extension (semantic reference)
