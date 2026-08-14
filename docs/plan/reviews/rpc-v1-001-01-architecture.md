# Review: rpc-v1-001 — architecture / ownership (closeout)

- Task: [rpc-v1-001](../tasks/rpc-v1-001.md)
- Binding: [rpc-v1.md](../../modules/rpc-v1.md)
- Code: `packages/zag-cli/src/rpc/` + `rpc_entry.zig` + `--rpc` in `cli.zig`
- Track: Wave 2 closeout (architecture)
- Result: **PASS**

## Scope

Does `--rpc` assemble existing public coding-agent surfaces without Core
ports, without changing `headless-v1`, and without a new package?

## What holds

- Owner is `zag-cli` only. No `@import("zag-agent-core")` in rpc files
  (fixture gate19).
- Same host assembly as TUI: Agent / Session / LifecycleObserver /
  Observer / permission Gate / control queues / `sigint.Guard`.
- Local stdin/stdout NDJSON. Does not extend `headless-v1`.
- Mutually exclusive with `--tui` / `--json` / `--acp` / `--doctor` / `-v`.
- Process fixture **26/26** recorded on the impl tip (`0eeef5d` closeout
  notes in the task).

## Non-blocking

- **N1 (P3).** Module header still said “draft” in places; closeout marks
  status `implemented`.
- Does not sit on Supervisor. Wave 3 if a child process is ever owned here.

## Decision

**PASS** — closeout. No maturity row. ACP remains a sibling, not a child.
