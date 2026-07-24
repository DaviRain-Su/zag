# Security — Zag

Zag is a local coding agent. It can read, write, and execute shell commands when policy permits. Treat it like a junior engineer running with the credentials and OS access of the current user.

## Maturity

Teaching Phase 3 demonstrates lexical path checks, a shell denylist, and JSONL trace. Phase H is **not complete**. Current P0/P1 blockers are tracked in the [production-floor assessment](./docs/plan/analysis/2026-07-24-production-floor-assessment.md) and [maturity matrix](./docs/maturity.md).

Do not describe the current build as an OS sandbox, production-ready, or safe for untrusted autonomous execution.

## Current controls

| Control | Default/current behavior | Important limitation |
|---------|--------------------------|----------------------|
| Human permission | `ask`; write/execute risk from validated `ToolDescriptor` (custom tools included) | symlink escape and OS sandbox are still open (workspace L1) |
| Permission remember | enabled for an approved built-in write path; `--no-remember` disables | path identity must be aligned with real containment before L2 |
| Plan session | blocks general built-in write/shell, even under yolo | product UX is still a stub |
| Workspace path check | rejects absolute, `..`, drive/UNC, empty/NUL paths | **lexical only**; workspace symlinks can currently escape the root |
| Shell policy | `protect`; blocks selected catastrophic command patterns | denylist only; shell is not contained by file-path jail or OS sandbox |
| Trace | optional local JSONL events | schema/terminal truth/I/O propagation are not L2 yet |

Even with `--yolo`, the current lexical jail and shell policy remain active unless shell policy is explicitly disabled. This does **not** make yolo safe against symlink escape, arbitrary shell access, malicious repositories, or secrets in tool output.

## Known release blockers

### Workspace symlink escape

A relative path can pass lexical validation and then resolve through a workspace symlink to a file outside the workspace. Until [h-workspace-001](./docs/plan/tasks/h-workspace-001.md) lands:

- do not treat the workspace jail as real filesystem containment;
- avoid running Zag on untrusted repositories containing symlinks;
- keep permission mode `ask` and review every shell/write action.

### Custom Tool fail-open classification

Built-ins have a name-based read/write/execute matrix, but custom Tool names do not carry mandatory runtime capabilities yet. A mutating custom Tool may be treated as read. Do not expose third-party/MCP/plugin Tools through the current registry as a trusted permission boundary. Contract: [D-007](./docs/decisions/active/D-007-tool-runtime-descriptor.md).

### Session and audit reliability

Current resume may fall back from invalid/unsupported/I/O failure to a fresh transcript on the same path; save truncates the target and failure can be hidden. A provider failure can also leave an open trace that is finalized as successful completion. Until the P0 session/trace tasks land, back up important `.zag/sessions/` data and do not treat trace as authoritative evidence of success.

## Secrets

- Prefer environment variables (`DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ZAG_API_KEY`, …).
- Never paste keys into prompts, source files, Tool arguments, or shell commands deliberately.
- Systematic redaction is not implemented yet; verbose output, trace, session, file content, and command output may contain secrets.
- Treat all `.zag/` files as sensitive local state and keep them out of version control.

P1 redaction must run before verbose logging, trace serialization, and session persistence. Redaction will reduce known-key leakage; it will not prove arbitrary file/Tool output secret-free.

## Audit limitations

Trace event order can help debug a run, but current trace has no schema version and does not yet guarantee exactly one truthful terminal state. The L2 contract is defined in [trace-observability](./docs/modules/trace-observability.md).

After H7 closes, a strict reader must be able to reconstruct permission, containment, shell policy, provider retry/usage, compaction, and terminal outcome. Explicit trace write failure must be observable.

## OS sandbox boundary

Phase H targets one user on a trusted host and does **not** require an OS sandbox. C7 adds platform enforcement/process supervision for higher autonomy.

A product mode that requires sandbox enforcement must fail closed when the platform/profile cannot enforce it. Warn-and-continue is not sufficient for high-autonomy, background, or untrusted executable-extension modes.

## Missing capabilities

| Missing | Gate/track |
|---------|------------|
| symlink-aware file containment | Phase H P0 |
| explicit Tool capabilities/fail-closed custom policy | Phase H P0 |
| safe session open/save/concurrency | Phase H P0 |
| truthful/versioned trace lifecycle | Phase H P0/P1 |
| systematic secret redaction | Phase H P1 |
| enforced deadline/in-flight cancellation | Phase H P1 |
| OS sandbox/network/process-tree enforcement | C7 |
| multi-tenant isolation | Out of scope |

## Reporting and fixes

A security/correctness fix must:

1. update the owning module contract;
2. add a deterministic failure fixture to [quality/evals](./docs/quality/evals.md);
3. implement the fix without weakening the default `ask` policy;
4. update [maturity](./docs/maturity.md) and the relevant teaching chapter in the same delivery.
