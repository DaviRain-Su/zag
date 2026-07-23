# Security — Zag

Zag is a local coding agent. **It can read, write, and run shell commands** in the
working directory when permitted. Treat it like a junior engineer with your
credentials on the machine.

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

## Audit

```bash
zag --yolo --trace -v "…"
# → .zag/traces/latest.jsonl  (tool sequence, jail/shell denies)
```

Replay: open the JSONL and follow `kind` fields in order
(`run_start` → `tool_call` → `tool_result` → `run_end`).

## What Zag is not (yet)

- Full OS sandbox / containers  
- Network allowlists  
- Secret redaction in logs  
- Multi-tenant isolation  

Phase 3 is a **minimum production bar** for single-user, trusted-host use.

## Reporting

If you find a jail bypass or policy hole, fix it in `agent/workspace.zig` /
`agent/shell_policy.zig` and add a unit test.
