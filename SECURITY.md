# Security — Zag

Zag is a local coding agent. **It can read, write, and run shell commands** in the
working directory when permitted. Treat it like a junior engineer with your
credentials on the machine.

## Maturity note

Teaching Phase 3 demonstrates jail + shell denylist + JSONL trace. That is
**tutorial-grade**, not a full production floor. Production-floor targets
(redact, policy test matrix, versioned trace, doctor, …) are **Phase H** —
see [docs/maturity.md](./docs/maturity.md) and
[docs/modules/workspace-sandbox.md](./docs/modules/workspace-sandbox.md).

## Default denials

| Gate | Default | Blocks |
|------|---------|--------|
| Human permission | `ask` | `write_file` / `run_shell` until you type `y` |
| Workspace jail | always on | Absolute paths, `..` escapes, drive/UNC paths |
| Shell policy | `protect` | Catastrophic patterns (`rm -rf /`, `curl … \| bash`, `mkfs`, …) |

Even with **`--yolo`**, jail + shell policy still apply unless you also set
`--shell-policy off` (not recommended).

## API keys

- Prefer env vars (`DEEPSEEK_API_KEY`, `ZAG_API_KEY`, …).
- Do **not** paste keys into transcripts or `--verbose` logs deliberately.
- Trace/session files may contain file contents and command output — treat
  `.zag/` as sensitive local state (gitignored).
- **Phase H** adds systematic secret redaction in verbose/trace/session; until
  then, assume leakage is possible and keep `.zag/` private.

## Audit

```bash
zag --yolo --trace -v "…"
# → .zag/traces/latest.jsonl  (tool sequence, jail/shell denies)
```

Replay: open the JSONL and follow `kind` fields in order
(`run_start` → `tool_call` → `tool_result` → `run_end`).

Schema versioning and `usage` / `stop_reason` fields are Phase H (H7) goals —
see [docs/modules/trace-observability.md](./docs/modules/trace-observability.md).

## What Zag is not (yet)

| Missing | Track |
|---------|--------|
| Full OS sandbox / containers / network allowlists | Capability **C7** |
| Systematic secret redaction | Phase **H5** |
| Permission remember / category matrix | Phase **H3** |
| Security eval suite in CI | Phase **H** / [docs/quality/evals.md](./docs/quality/evals.md) |
| Multi-tenant isolation | Out of scope (vision) |

Phase H is the **minimum production bar** for single-user, trusted-host use.
OS sandbox remains a later Capability.

## Reporting

If you find a jail bypass or policy hole, fix it in `agent/workspace.zig` /
`agent/shell_policy.zig`, add a unit test (policy matrix), and update
[docs/maturity.md](./docs/maturity.md) if the security row level changes.
