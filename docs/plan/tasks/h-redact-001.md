---
id: h-redact-001
scope: phase-h/security-redaction
status: in-progress
priority: P1
depends-on: [h-session-001, h-trace-001]
---

# objective

Introduce one shared redaction boundary for configured secrets and common API-key patterns before verbose logs, traces, and session persistence.

> Implementation landed in worktree (shared `redact.Redactor`, wired through Agent/CLI/trace/session/observer + zag-ai `redact_log`). Task status stays **in-progress** for orchestrator closeout; do not mark done here.

# context

- `docs/modules/workspace-sandbox.md`
- `docs/modules/trace-observability.md`
- `docs/modules/session-store.md`
- `docs/quality/evals.md`
- `SECURITY.md`

# path

- `packages/zag-agent-core/src/`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-ai/src/`
- `packages/zag-cli/src/cli.zig`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/trace-observability.md`
- `docs/quality/evals.md`
- `docs/maturity.md`
- `SECURITY.md`

# verification

- fake configured keys and representative key patterns do not appear in verbose output, trace, or session fixtures;
- ordinary code-like strings are not over-redacted by the documented policy;
- redaction occurs before persistence, not only in display code;
- `.zag/` remains documented as sensitive because arbitrary tool/file content cannot be proven secret-free;
- `zig build test --summary all`.
