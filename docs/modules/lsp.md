# LSP-backed code intelligence (`code_intel`)

> Binding draft for [lsp-001](../plan/tasks/lsp-001.md) (D-012 item 2 —
> repository navigation and LSP-backed code intelligence). Architecture
> direction from [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md):
> LSP stays **outside** `zag-agent-core` (one-way package graph).
> Semantic references: hyper-grok-build tower-lsp clients (hover/definitions/
> diagnostics surfaced as tool results), zls protocol model — **not** API or
> source parity (D-009).
>
> **Status:** implementation **landed** @ `75f213b` ([lsp-001](../plan/tasks/lsp-001.md)
> `implemented`). Dual review / Gate closeout still **pending**. Zig 0.16
> (`std.Io` era) APIs assumed throughout.
>
> **Update (2026-08-07):** implemented per this binding by lsp-001
> (status: implemented) — see the task's implementation log. The
> documented deviations are (1) the §5.1 env allow-list is deferred
> (v1 inherits the parent env; §12 Q2 stays open) and (2) Zig 0.16 has
> no `Child.terminate` — teardown sends SIGTERM via `std.posix.kill`.
> §10 fixture classes 1–15, 17–20 are green; class 16 (real zls smoke)
> remains deferred (zls not installed on this host).

## 1. Principles

1. **Tool results, not overlays**: LSP answers are plain text tool bodies the
   model reads. No UI overlays, hover popups, or editor integration in v1.
2. **Kernel law**: the LSP client, server table, session lifecycle, and tool
   handler live in `zag-coding-agent`. `zag-agent-core` gains no LSP/process/
   pipe symbols (D-011 / D-012).
3. **Persistent session, lazy start**: one server child per workspace root,
   started on first tool call, killed on `Agent.deinit` and on idle timeout.
   Cold-start cost is paid once, not per call.
4. **Bounded everything**: file reads, response messages, result bodies,
   caches, and stderr capture are capped (checked arithmetic, §7). No unbounded
   RAM growth and no unbounded handler blocking: every op has a deadline.
5. **Honest absence**: a missing server, an unresolved workspace root, or an
   op with no answer returns the exact body `null` — the model falls back to
   grep/read patterns. `null` is a designed outcome, not an error.
6. **Direct-child only**: v1 owns the spawned server child (stdio pipes);
   terminate → bounded wait → kill → wait on teardown. **No** process-tree
   ownership, **no** OS-sandbox claim. When the process supervisor gains
   long-lived slots, this child migrates to a supervised slot
   ([process-supervisor.md §2](./process-supervisor.md)) — only the
   spawn/kill surfaces change.
7. **Single-threaded ownership**: the client is not thread-safe; it is owned
   by one `Agent` and serialized by the Tool loop (Tool handlers run
   synchronously, one at a time).

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-coding-agent`** | Tool `code_intel`; JSON-RPC framing; LSP message subset; server table + discovery; session lifecycle (spawn/pump/kill); open-file + diagnostics caches; result formatting | Core ports; Session/Trace/headless schema fields; UI |
| `zag-agent-core` | Existing `tool.zig` / `loop.zig` / `tool_error` / `tool_args` only | LSP types, process/pipe ports, server state |
| `zag-cli` / `zag-tui` | — (v1: no surface; tool results flow through the existing loop) | LSP UI; bypassing the tool handler |
| Future supervisor | LSP child as a supervised slot (post-supervisor-v2) | — |

## 3. Model-visible surface

### 3.1 Tool: `code_intel`

One tool, subcommand-style `op`. Closed JSON (`additionalProperties: false`):

```json
{
  "type": "object",
  "properties": {
    "op": {
      "type": "string",
      "enum": ["hover", "definition", "references", "diagnostics"]
    },
    "path": { "type": "string" },
    "line": { "type": "integer", "minimum": 0 },
    "col": { "type": "integer", "minimum": 0 }
  },
  "required": ["op", "path"],
  "additionalProperties": false
}
```

| Item | Binding |
|------|---------|
| Name | `code_intel` (exact) |
| `op` | `hover` \| `definition` \| `references` \| `diagnostics` (exact strings) |
| `path` | workspace-relative file path (same lexical rules as file tools; product-jailed, §3.2) |
| `line` / `col` | **0-based** LSP positions; required for hover/definition/references; **ignored** for diagnostics; negative → `invalid_arguments` |
| Missing file | op returns `null` (server answers are only defined for existing files) |
| File read budget | 4 MiB; over → `error: code=too_large message=file exceeds LSP read budget` |

### 3.2 Descriptor and jail

| Field | Binding |
|-------|---------|
| `risk` | `read` |
| `workspace` | `.path_field = "path"` (Core path probe applies) |
| `cancellation` | `none` (handler blocks on a **bounded** deadline; no mid-flight cancel claim) |
| `shell` | `none` |

The handler **MUST** run the product workspace `Guard` containment check on
`path` before any server interaction (same law as file tools): resolve
realpath containment; failure → `jail_deny`, **no** spawn, **no** URI
construction from an uncontained path. Absolute/`..`/NUL paths are rejected
lexically by `tool_args.checkToolPath` at the Core boundary and again by the
Guard.

### 3.3 Result format

| Case | Tool body |
|------|-----------|
| No result (server missing, spawn failure, unresolved workspace root, op answered empty) | **`null`** (exactly 4 bytes, no first line) |
| Success | first line `intel-v1: op=<op> status=ok` + blank line + content (§3.4) |
| Hard error | `error: code=<code> message=<human>` (core codes: `invalid_arguments`, `jail_deny`, `tool_failed`; local: `too_large`) |

The first line fits the trace Tool-result cap (500 B). Result body ≤ 64 KiB
(`tool.max_result_bytes`). Content is plain text; LSP markdown (hover) is
passed through verbatim — no rendering, no stripping.

### 3.4 Per-op content

| op | Content |
|----|---------|
| `hover` | Hover contents joined by newline (MarkupContent `value`, or each `MarkedString`), markdown preserved; cap **32 KiB** + `...[truncated]` |
| `definition` | For each returned `Location` (usually 1): `<path>:<line+1>:<col+1>` then an indented source-line copy **only when the target URI is inside the workspace**; external targets print the URI only. Cap 16 locations |
| `references` | Same line format per hit, in-workspace source lines only; cap **50 hits** + `...[truncated N more]` |
| `diagnostics` | Per diagnostic: `<severity>: <path>:<line+1>:<col+1>: <message>` (severity from LSP `DiagnosticSeverity`: `error`/`warning`/`info`/`hint`); cap **200 entries / 32 KiB** per URI + truncation marker. Source = the client's publishDiagnostics cache (§5.3); empty cache after the wait budget → `null` |

Positions are displayed 1-based (human convention); the wire stays 0-based.
All `path` displays are workspace-relative when inside the root, else the
server-supplied URI.

## 4. Server table and discovery

| lang | v1 server | argv | env |
|------|-----------|------|-----|
| `zig` | `zls` | `["zls"]` | allow-list (§5.1) |

- Discovery: resolve the binary via `PATH` at spawn time (Zig 0.16
  `std.process.spawnPath`/PATH lookup); not found → `null`, **no** retry storm
  (one attempt per session start).
- The table is a static `{ lang, binary, argv }` array; **only the `zig` row
  ships in v1**. Later rows (e.g. `rust → rust-analyzer`) are out of scope —
  the table shape is the extension point.
- `workspace_root_real == null` (custom hosts) → session cannot start → `null`.

## 5. Session lifecycle (normative)

### 5.1 Spawn

```text
first tool call for this root
  → resolve server binary in PATH            (missing → null)
  → spawn: argv ["zls"], cwd = workspace root, stdio = {stdin: pipe, stdout: pipe, stderr: pipe},
    env = allow-list {PATH, HOME, LANG, LC_ALL, LC_CTYPE, ZLS_*}
  → initialize (rootUri = workspace root URI, client caps §6.3)
  → initialized notification
  → ready (session state = .ready)
```

Startup deadline **20 s** for the initialize handshake; failure → teardown →
`null` (or `tool_failed` when the server responded with a protocol error).

### 5.2 Teardown and restart

- **On `Agent.deinit`** (covers app exit): always. Sequence: best-effort
  `shutdown` request (≤1 s) → `exit` notification → `terminate(io)` → wait
  ≤ **2 s** → `kill(io)` → `wait(io)`. Direct child only.
- **Idle timeout**: **10 min** without a tool call; checked at the start of
  each call (monotonic clock). Teardown runs, session state = `.idle_dead`;
  the current call restarts the session.
- **Server crash / exit**: detected on the next read (EOF/pipe closed or wait
  shows a term). Session state = `.dead`; the tool call returns a bounded
  `tool_failed` (with stderr ring tail §7); the **next** call restarts.
- **Restart**: caches (open files, diagnostics) are cleared on restart; one
  restart per tool call, no infinite retry loop.

### 5.3 Document sync and diagnostics cache

- Per-URI open state: `{ uri, content_bytes, version }`. On any op for a URI:
  read the file (≤4 MiB). Not open → `textDocument/didOpen` (full text,
  `version` 1). Content changed vs cache → `textDocument/didChange`
  (`contentChanges` = one full-text change, `version`+1). Unchanged → no sync.
- **publishDiagnostics** (server → client notification): stored per URI,
  replacing the previous entry; **no** forwarding to the model (diagnostics
  are pulled by the `diagnostics` op, not pushed).
- `diagnostics` op: ensure sync (didOpen/didChange) → if no cached entry for
  the URI, wait up to **10 s** for the first publish → return cache or `null`.
  Subsequent calls return the cache immediately.
- Cache bounds: ≤ **64 URIs** (evict oldest; no `didClose` sent in v1 — the
  server may keep the doc; our cache simply drops it), ≤ **32 KiB** text per
  URI. Content cache per URI ≤ 4 MiB (the same read budget).

## 6. Wire protocol

### 6.1 JSON-RPC framing (LSP base protocol)

```text
Content-Length: <N>\r\n
\r\n
<body: N bytes>
```

- Write: stringify request via `std.json` → header + body.
- Read: header line-by-line (cap 4 KiB) → read N bytes (cap **8 MiB**).
  Header parse error or message over cap → protocol error → session killed →
  `tool_failed`.
- No `\n`-only tolerance; no pipelining (one outstanding request at a time,
  ids are strictly increasing integers starting at 1).

### 6.2 Message subset (frozen)

| Direction | Method | Notes |
|-----------|--------|-------|
| client → server | `initialize` | id 1; params: `processId` (parent PID), `rootUri`, `capabilities` (§6.3) |
| client → server | `initialized` | notification |
| client → server | `textDocument/didOpen` / `didChange` | full-text sync, §5.3 |
| client → server | `textDocument/hover` | position from args |
| client → server | `textDocument/definition` | position from args |
| client → server | `textDocument/references` | params: position, `context: {includeDeclaration: true}` |
| client → server | `shutdown` / `exit` | teardown only |
| server → client | `publishDiagnostics` | notification → cache (§5.3) |
| server → client | `window/showMessage`, `window/logMessage`, `telemetry/event`, `$/progress` | notifications: **ignored** (drained) |
| server → client | unknown **requests** | reply JSON-RPC error `-32601 MethodNotFound`, then continue |

Request/response matching by `id`; a response whose `id` matches no pending
request is drained and ignored.

### 6.3 Client capabilities (initialize)

```json
{
  "textDocument": {
    "synchronization": { "dynamicRegistration": false, "willSave": false, "willSaveWaitUntil": false, "didSave": false },
    "hover": { "contentFormat": ["plaintext", "markdown"] },
    "definition": {},
    "references": {}
  }
}
```

- `positionEncodings: ["utf-8"]` in initialize params. Server selects via
  `ServerCapabilities.positionEncoding` in the initialize result; if absent or
  `utf-16`, positions are interpreted as **UTF-16 code units**. The tool
  description tells the model positions are 0-based in the negotiated encoding
  (utf-8 for zls on modern versions; ASCII-only positions are always safe).

### 6.4 Polling read loop

POSIX v1: child stdout pipe set **non-blocking**; per-op pump loops:
read available frame bytes → parse complete messages → dispatch by id
(response) or method (notification → cache/ignore) → `std.Io.sleep(io, 20 ms,
.monotonic)` until the op deadline. Stderr pipe drained the same way into the
ring buffer (§7) so the child never blocks on a full stderr pipe.

## 7. Budgets and deadlines (checked arithmetic)

| Item | Cap |
|------|----:|
| File read (per op, per URI) | **4 MiB** |
| JSON-RPC message (read) | **8 MiB** |
| Header line | **4 KiB** |
| Hover content | **32 KiB** |
| Definition locations | **16** |
| References hits | **50** |
| Diagnostics entries / text per URI | **200** / **32 KiB** |
| Open-file cache | **64 URIs** |
| stderr ring buffer | **8 KiB** (tail surfaced in `tool_failed` diagnostics) |
| Result body | **64 KiB** (`tool.max_result_bytes`) |
| Startup (initialize) deadline | **20 s** |
| Per-op request deadline | **15 s** |
| Diagnostics first-publish wait | **10 s** |
| Idle timeout | **10 min** |
| Teardown graceful wait | **2 s** |

Truncation is explicit (`...[truncated]` / `...[truncated N more]`), never a
silent cut. `OutOfMemory` remains a hard typed host error; all other
post-spawn failures are soft results.

## 8. Failure vocabulary

| code | Meaning |
|------|---------|
| `null` (body) | server not found; spawn failure; unresolved root; op answered empty; diagnostics cache empty after wait |
| `invalid_arguments` | bad JSON, unknown op, missing `path`, negative/non-integer `line`/`col` |
| `jail_deny` | path escapes the workspace Guard |
| `too_large` | file read > 4 MiB |
| `tool_failed` | protocol error, message over cap, server crash, response timeout (stderr ring tail may follow) |

`tool_failed` bodies carry **no** raw OS error strings, no absolute paths on
the first line, no command lines. Server stderr content only appears inside
the bounded ring tail.

## 9. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| [tool-runtime.md](./tool-runtime.md) | `code_intel` is a normal Core `Tool`: `buildTool`-compatible descriptor; handler signature; loop policy/jail boundaries |
| [tools-edit.md](./tools-edit.md) | additive tool; `apply_hunk`/`apply_transaction`/`search_replace` unchanged; LSP does **not** write files |
| [tools-shell.md](./tools-shell.md) | no shell execution surface; the server child is product-owned, not `run_shell` |
| [process-supervisor.md](./process-supervisor.md) | sibling draft; **no** dependency in v1 (supervisor v1 is foreground-bounded); migration path documented in §1.6 / lsp-001 |
| [workspace-sandbox.md](./workspace-sandbox.md) | Guard containment reused; no OS sandbox claim |
| Trace / redaction | tool bodies flow through existing trace Tool-result redaction/truncation unchanged; no schema change |
| Session v1 / headless-v1 | **unchanged** (no PID/URI fields) |
| Core / D-011 / D-012 | **no** Core ports; LSP lives in `zag-coding-agent` |
| Maturity | **no row raise**; new capability at L2 discipline (bounded, direct-child, no sandbox) |

## 10. Fixtures (implementation track — when ready)

Mock LSP server: a **Python 3 stdlib-only script** (deterministic, no
dependencies; model: pi-mono-zig's MCP stdio fixture) speaking LSP JSON-RPC
over real pipes. A private `builtin.is_test` seam configures: server binary
path (fixture), argv, deadlines, idle timeout — mirroring the shell-v1 test
seam (never in Tool JSON, `Agent.Options`, CLI, or session schema).

| # | Class | Expect |
|---|-------|--------|
| 1 | Happy hover | markdown contents; `intel-v1` first line + text |
| 2 | Definition | location rendered `<path>:<line+1>:<col+1>` + in-workspace source line |
| 3 | References | 2 hits; cap/truncation beyond 50 |
| 4 | Diagnostics | publish after didOpen; pulled by `diagnostics` op within wait budget; second call instant (cache) |
| 5 | Server not found | PATH miss → body exactly `null` |
| 6 | Server crash mid-request | bounded `tool_failed` + stderr tail; next call restarts (new PID) |
| 7 | Response timeout | fixture sleeps > deadline; no hang; `tool_failed`; session torn down |
| 8 | Idle timeout | short test idle → child killed; next call restarts (PID changes) |
| 9 | Jail escape | `../` / absolute path → `jail_deny`; no spawn, no URI |
| 10 | Invalid args | unknown op, missing path, negative line → `invalid_arguments` |
| 11 | File > 4 MiB | `too_large`; no didOpen |
| 12 | Message > 8 MiB / hover > 32 KiB / refs > 50 / diags > 200 | capped with marker; finite memory |
| 13 | Empty answers | hover/definition/references empty result → `null` |
| 14 | Ownership | no `zag-agent-core` symbols (grep); all sources under `zag-coding-agent` |
| 15 | Toolset regression | Phase1Storage test updated ([10]→[11]); coding-agent suite green |
| 16 | Real zls smoke (later, host with zls) | hover/definition/diagnostics on the zag repo itself |

## 11. Non-goals (v1)

- UI overlays, hover popups, editor integration; inlay hints; semantic tokens
- Multi-root workspaces; multi-language server rows
- rename / codeAction / completion / signatureHelp / documentSymbol /
  documentLink
- Background indexing service; project-wide diagnostics broadcast
- didClose / incremental sync; workspace folder management
- Process-tree ownership; OS sandbox; PTY; Windows (POSIX v1)
- Thread-safety guarantees; concurrent requests
- Session/Trace/headless schema changes; Core ports; maturity raise

## 12. Open questions for dual review

1. `null` as an exact bare body vs a structured `intel-null` first line —
   frozen to `null` per lsp-001; confirm the model-facing ergonomics.
2. Env allow-list (PATH/HOME/LANG/LC_*/ZLS_*) vs full parent environment for
   server spawn.
3. Position encoding: utf-8-only v1 vs negotiated fallback (frozen: negotiated).
4. Whether the diagnostics wait (10 s) should be a product-visible budget or a
   test-only knob (frozen: product budget, configurable via test seam only).
5. Idle timeout value (frozen: 10 min) and whether a max session lifetime is
   needed for long-running agents.

## Related

- [lsp-001](../plan/tasks/lsp-001.md) · [process-supervisor.md](./process-supervisor.md)
- [tool-runtime.md](./tool-runtime.md) · [tools-edit.md](./tools-edit.md) · [tools-shell.md](./tools-shell.md) · [workspace-sandbox.md](./workspace-sandbox.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md) · [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) · [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md)
- hyper-grok-build tower-lsp usage (semantic reference, not parity)
- zls generated `src/lsp.zig` (MIT) — optional future vendor for a wider model
