# C9 — Minimal Product Shell

| Item | Content |
|------|---------|
| Prerequisite | Headless/Process L2 ✅；minimal TUI additionally needs stable lifecycle events/control |
| Near-term slice | M2 `tui-minimal-001` |
| Failure mode | plain CLI is too weak for daily use, or UI duplicates Kernel business logic |
| Reference | Current Pi + historical `pi-mono-zig` terminal behavior (design only) |

## Existing machine shell

Headless is already an independent closed Gate:

- `--json` single terminal envelope;
- `--json-stream` NDJSON with one terminal;
- `headless-v1` versioned errors/exit codes;
- real-process fixtures under both HTTP backends。

Contract: [headless](../modules/headless-contract.md).

## Scheduled minimal TUI

Only after `harness-events-001` and `harness-steering-001`:

1. streaming assistant text;
2. multiline input/history;
3. Tool call/result cards;
4. permission/cancel/error state;
5. basic session identity/resume indication。

## Invariants

- product shell only assembles public Kernel/coding-agent APIs;
- plain/headless/TUI expose the same permission/error/session truth;
- UI close/drop cannot invent completed success;
- headless stdout remains uncontaminated;
- TUI can be disabled without changing Kernel builds/tests。

## Deferred

- ACP/editor host;
- dashboard/cost explorer;
- themes, images, custom widgets, full overlay framework;
- package manager/extension UI;
- cloud collaboration/i18n breadth。

## Acceptance for `tui-minimal-001`

- [ ] core prompt→Tool→result flow works without losing permission/error/session semantics;
- [ ] Ctrl+C behavior follows [CLI interaction](../modules/cli-interaction.md);
- [ ] lifecycle rendering comes from events, not private Agent memory;
- [ ] plain/headless dual-backend Gates remain green;
- [ ] Kernel packages do not import TUI。

## Non-goals

- copying the old vaxis product wholesale;
- Loop/session/permission implementation in UI;
- dynamic Zig plugin ABI。
