# C9 — Minimal Product Shell

| Item | Content |
|------|---------|
| Prerequisite | Headless/Process L2 ✅; minimal TUI additionally needs stable lifecycle events/control |
| Near-term slice | M2 `tui-minimal-001` |
| Failure mode | plain CLI is too weak for daily use, or UI duplicates Kernel business logic |
| Reference | Current Pi + historical `pi-mono-zig` terminal behavior (design only) |
| Feature map | [Pi feature correspondence](../plan/analysis/2026-07-26-pi-feature-correspondence.md) |

## Product/programmatic entrances

These are different contracts, not aliases:

| Entrance | Current / target |
|----------|------------------|
| Zig SDK | same-process source composition; L2 closed |
| plain CLI | human one-shot / REPL |
| `headless-v1` | output-only `--json` / `--json-stream`; L2 closed |
| future `rpc-v1` | long-lived bidirectional correlated commands/responses/events; separate Gate |
| TUI | host interactive shell over public events/control |

`rpc-v1` does not modify or inflate the closed `headless-v1` contract and does not promise Pi command/schema parity.

## Existing machine shell

Headless is already an independent closed Gate:

- `--json` single terminal envelope;
- `--json-stream` NDJSON with one terminal;
- `headless-v1` versioned errors/exit codes;
- real-process fixtures under both HTTP backends.

Contract: [headless](../modules/headless-contract.md).

## Scheduled minimal TUI

Only after `harness-events-001` and `harness-steering-001` (both now closed; a TUI still requires its own task and Gate):

1. streaming assistant text;
2. multiline input/history;
3. Tool call/result cards;
4. permission/cancel/error state;
5. basic session identity/resume indication.

This task establishes the host component/render/input boundary. It does not include a theme platform, arbitrary extension UI, package manager, or dashboard.

## Extension UI host

Runtime extension UI belongs to both C8 and C9:

- C8 owns request/view/action schemas, capabilities, quotas, and binding behavior;
- C9 owns rendering, terminal input, focus, layout, redaction, accessibility, and availability.

### Initial host-rendered surface

- notify/status/progress;
- select/confirm/input;
- markdown/diff/list/table/tree Tool or message views;
- deterministic plain/headless fallback.

### Later stateful views

A separate Gate may let E2/E3 code maintain private UI state, receive sanitized action IDs, and return a new bounded view tree. The host still owns raw terminal input and rendering.

### Never across E2/E3

- raw stdin/terminal bytes;
- arbitrary ANSI/escape sequences;
- renderer/widget/allocator pointers;
- untrusted native component factories;
- replacement of permission/session/trace truth.

E0 trusted static Zig product code may add native host components at compile time. This corresponds to Pi user scenarios without copying its in-process TypeScript component factory.

## Theme boundary

Theme data is passive. ANSI generation, terminal capability/background detection, hot reload, and UI invalidation are host-shell behavior. `theme-001` follows `tui-minimal-001`; no theme renderer crosses E2/E3.

## Invariants

- product shell only assembles public Kernel/coding-agent APIs;
- plain/headless/TUI expose the same permission/error/session truth;
- UI close/drop cannot invent completed success;
- headless stdout remains uncontaminated;
- TUI can be disabled without changing Kernel builds/tests;
- unavailable extension UI has deterministic fallback;
- focus/action IDs cannot capture raw input or bypass redaction.

## Deferred

- `rpc-v1` implementation and full command vocabulary;
- ACP/editor host;
- dashboard/cost explorer;
- themes, images, stateful extension views, full overlay framework;
- package configuration UI;
- cloud collaboration/i18n breadth.

## Acceptance for `tui-minimal-001`

- [ ] core prompt→Tool→result flow works without losing permission/error/session semantics;
- [ ] Ctrl+C behavior follows [CLI interaction](../modules/cli-interaction.md);
- [ ] lifecycle rendering comes from events, not private Agent memory;
- [ ] plain/headless dual-backend Gates remain green;
- [ ] Kernel packages do not import TUI.

## Acceptance for later extension UI host

- [ ] malformed/oversized view trees fail closed;
- [ ] actions/focus cannot expose raw input;
- [ ] all rendered extension content passes redaction;
- [ ] plain/JSON/RPC fallbacks are deterministic;
- [ ] extension UI failure cannot replace Tool/run terminal truth.

## Non-goals

- copying the old vaxis product wholesale;
- Loop/session/permission implementation in UI;
- dynamic Zig plugin ABI;
- Pi TUI component API or raw-terminal parity.
