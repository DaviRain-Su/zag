# Security — Zag

Zag is a local coding agent. It can read, write, and execute shell commands when policy permits. Treat it like a junior engineer running with the credentials and OS access of the current user.

## Maturity

Teaching Phase 3 demonstrates lexical path checks, a shell denylist, and JSONL trace. Phase H is **not complete**. Current P0/P1 blockers are tracked in the [production-floor assessment](./docs/plan/analysis/2026-07-24-production-floor-assessment.md) and [maturity matrix](./docs/maturity.md).

Do not describe the current build as an OS sandbox, production-ready, or safe for untrusted autonomous execution.

## Current controls

| Control | Default/current behavior | Important limitation |
|---------|--------------------------|----------------------|
| Human permission | `ask`; write/execute risk from validated `ToolDescriptor` (custom tools included) | not an OS sandbox; shell still broad |
| Permission remember | enabled for an approved built-in write path; `--no-remember` disables | path identity follows real containment for file tools |
| Plan session | blocks general built-in write/shell, even under yolo | product UX is still a stub |
| Workspace path check | lexical deny of absolute/`..`/drive/UNC **plus** realpath containment for file tools | **software check-time** only; residual TOCTOU under concurrent FS races; not an OS sandbox |
| Shell policy | `protect`; blocks selected catastrophic command patterns | denylist only; shell is **not** contained by the file-path jail or OS sandbox |
| Trace | optional local JSONL events | schema/terminal truth/I/O propagation are not L2 yet |

Even with `--yolo`, the file-path jail and shell policy remain active unless shell policy is explicitly disabled. This does **not** make yolo safe against arbitrary shell access, malicious repositories that abuse shell, or secrets in tool output.

## Workspace file containment (h-workspace-001)

Built-in file tools (`read_file`, `list_dir`, `grep`, `glob`, `write_file`, `search_replace`) enforce **symlink-aware** containment:

- workspace root is resolved once per loop run (handlers lazy-resolve if needed);
- existing targets must realpath inside the root (component-boundary safe);
- create/write walks existing ancestors and denies escaping or dangling intermediate/final symlinks;
- contained symlinks (target still inside the root) continue to work;
- containment denials use stable soft `code=jail_deny`; ordinary missing files are not mislabeled as jail denials;
- handlers re-check so raw registry dispatch of built-ins cannot skip the jail.

**Trust boundary:** the host OS account is trusted; **workspace contents (including pre-seeded symlinks) are not**. This is check-time software enforcement, **not** an OS sandbox. A concurrent process under the same account can still race paths between check and use (TOCTOU residual). Shell is a separate boundary.

## Known release blockers

### Custom Tool fail-open classification

Built-ins declare capabilities; custom Tool names require mandatory runtime capabilities at registration (D-007). A mutating custom Tool without write/execute risk fails closed at registration. Custom tools that touch the filesystem without `workspace.path_field` (or without their own containment) are outside the loop path gate — do not treat the registry as a full multi-tenant security boundary. Contract: [D-007](./docs/decisions/active/D-007-tool-runtime-descriptor.md).

### Session and audit reliability

Session durability is L2 (h-session-001). Trace lifecycle is L2 for schema/terminal/persistence (h-trace-001): every started run has one truthful terminal; explicit path I/O is fail-closed (`TraceIoFailed`). Secret redaction before write is still P1 — do not treat unredacted traces as secret-safe.

## Secrets

- Prefer environment variables (`DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ZAG_API_KEY`, …).
- Never paste keys into prompts, source files, Tool arguments, or shell commands deliberately.
- Systematic redaction is not implemented yet; verbose output, trace, session, file content, and command output may contain secrets.
- Treat all `.zag/` files as sensitive local state and keep them out of version control.

P1 redaction must run before verbose logging, trace serialization, and session persistence. Redaction will reduce known-key leakage; it will not prove arbitrary file/Tool output secret-free.

## Audit limitations

Trace is versioned (`schema_version` on `run_start`, currently `1`). Each `Agent.reply` is one run; the explicit path atomically stores the **latest completed reply**. The facade commits exactly one truthful `run_end` for ordinary post-start failures and Results. Contract: [trace-observability](./docs/modules/trace-observability.md).

Preflight is non-destructive (atomic temp discarded without replace) and **symlink-aware** (`Guard.checkCreate` before preflight, at persist entry, and immediately before replace). Parent symlink escape and dangling links fail closed as `InvalidPath` before provider work. Fixed-writer / event-too-large / invalid UTF-8 string failures are `TraceSerializationFailed`, not OOM. Non-finite `estimated_usd` is omitted. Terminal commit is transactional: a failed intended terminal still yields exactly one minimal `trace_error` (or `out_of_memory`) terminal when capacity allows. Final write uses atomic replace; prior destination bytes are preserved on fault; persist errors keep their typed category. Residual TOCTOU after the last Guard check is trusted-host only — not an OS sandbox. Secret redaction remains P1.

## Provider deadline / cancel (h-provider-001)

- **curl** (`-Dhttp_backend=curl`): configured `timeout_ms` and active cancel (libcurl TIMEOUT_MS + xferinfo) are enforced; setopt failure fails closed before perform.
- **std** (D-005 default): ordinary no-timeout HTTP remains usable. A **configured deadline** or required active cancel returns typed `UnsupportedControl` / terminal `unsupported_control` **before** network work — no unsafe cross-thread socket shutdown, no silent ineffective timeout.
- Default remains **no** timeout when unset. Loop is the sole retry owner for agent chat. Partial streamed tool-call arguments are discarded. Terminals: `cancelled` (ok=true), `timeout` / `unsupported_control` (ok=false), auth/transport `provider_error`. Trusted-host only — not an OS sandbox.

## OS sandbox boundary

Phase H targets one user on a trusted host and does **not** require an OS sandbox. C7 adds platform enforcement/process supervision for higher autonomy.

A product mode that requires sandbox enforcement must fail closed when the platform/profile cannot enforce it. Warn-and-continue is not sufficient for high-autonomy, background, or untrusted executable-extension modes.

## Missing capabilities

| Missing | Gate/track |
|---------|------------|
| ~~symlink-aware file containment~~ | **done** Phase H P0 h-workspace-001 |
| ~~explicit Tool capabilities/fail-closed custom policy~~ | **done** Phase H P0 h-tool-runtime-001 |
| ~~safe session open/save/concurrency~~ | **done** Phase H P0 h-session-001 |
| ~~truthful/versioned trace lifecycle~~ | **done** Phase H P0 h-trace-001 (redaction still P1) |
| systematic secret redaction | Phase H P1 |
| ~~enforced deadline/in-flight provider cancellation~~ | **done** Phase H P1 h-provider-001 (tool/shell mid-flight cancel still open) |
| OS sandbox/network/process-tree enforcement | C7 |
| multi-tenant isolation | Out of scope |

## Reporting and fixes

A security/correctness fix must:

1. update the owning module contract;
2. add a deterministic failure fixture to [quality/evals](./docs/quality/evals.md);
3. implement the fix without weakening the default `ask` policy;
4. update [maturity](./docs/maturity.md) and the relevant teaching chapter in the same delivery.
