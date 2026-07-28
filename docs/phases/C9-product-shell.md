# C9 — Minimal Product Shell

| Item | Content |
|------|---------|
| Prerequisite | Headless/Process L2 ✅; minimal TUI additionally needs stable lifecycle events/control |
| Near-term slice | M2 `tui-minimal-001` **done** @ `f8f7f55`; Theme contract **PASS** @ `9e1b9f9` (`theme-001` **ready**; no implementation) |
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

## Minimal TUI (implemented / closed slice)

Prerequisites `harness-events-001` and `harness-steering-001` are closed. The
**binding contract** is [tui-minimal.md](../modules/tui-minimal.md)
([task](../plan/tasks/tui-minimal-001.md) — **contract PASS** @ `c7a8f3a`;
**implementation done** @ `f8f7f55`). Package `packages/zag-tui/` (lazy `-Dtui`,
CLI wire, §11 fixtures) closed after dual independent final reviews (**PASS**,
zero blockers), local ff-only merge, and local macOS task/main Gates. **No**
maturity row raise; **no** current-tip Linux/remote Gate. Local remote-tracking
reflog records an external/other push of `f8f7f55` to `origin/main`; this
closeout did not execute or authorize that push. Docs closeout remains local;
remote branch presence is not a Linux/remote Gate. This is the **minimal**
host-shell slice only — not Theme implementation/RPC/ACP/extension UI.
Theme binding is separate: [theme.md](../modules/theme.md)
([theme-001](../plan/tasks/theme-001.md) **contract PASS** @ `9e1b9f9`;
`status: ready`; dual re-reviews zero blockers; **no** implementation;
**orthogonal** to post-TUI remote Gate).

Contract freezes (detail in the module — do not fork):

1. unique later package **`packages/zag-tui/`** only; CLI wires when `-Dtui=true`;
2. dual-thread host (UI + single reply worker) + permission single-slot rendezvous;
3. progressive text only via `Observer.assistant_text` (complete body today);
4. product open modes `create_new`/`resume_existing` only; no false resumed;
5. ask `Gate.ask(TuiPermissionAdapter)` never `StdinPrompter`; TUI ask hunk null;
6. full outward redaction via Session-owned `redactAlloc` before publish.

Host owns all UI state; Kernel/coding-agent must not import TUI. `-Dtui` default
false. Permission default remains **ask** (fail-closed; missing ask seam is
deny, never yolo). Workspace jail + shell protect stay mandatory. Outward UI
bytes are redacted before render; secrets must not hit stdout. No theme
platform, extension UI host, package manager, or dashboard.

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

Theme data is passive. ANSI generation, terminal capability/background detection, hot reload, and UI invalidation are host-shell behavior. Binding: [theme.md](../modules/theme.md) (`theme-001` **contract PASS** @ `9e1b9f9`; `status: ready`; dual re-reviews zero blockers; **no** implementation; **no** maturity raise). Owner is **`packages/zag-tui` only**; Core/coding-agent gain no Theme types. Fail closed to built-in host Theme; no raw ANSI in Theme data; no theme renderer crosses E2/E3. Orthogonal to [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) (TARGET `f352b60…`; Phase A; no Phase B grant/run/green).

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
- Theme **implementation** (contract PASS @ `9e1b9f9` / ready; still deferred until a fresh Goal — see [theme.md](../modules/theme.md)), images, stateful extension views, full overlay framework;
- package configuration UI;
- cloud collaboration/i18n breadth.

## Acceptance for `tui-minimal-001`

### Contract track (docs; PASS @ `c7a8f3a`)

- [x] binding module [tui-minimal.md](../modules/tui-minimal.md) authored
- [x] task [tui-minimal-001](../plan/tasks/tui-minimal-001.md) authored (now `status: done`)
- [x] round-1 BLOCKED findings closed (`a38f0ec` → `6c73e46` → `c7a8f3a`)
- [x] independent architecture/ownership contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] independent safety/fail-closed contract **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] docs lint / score / diff green on contract docs path; no product code in contract node

### Product implementation track (closed @ `f8f7f55`; local macOS evidence only)

- [x] core prompt→Tool→result flow works without losing permission/error/session semantics;
- [x] Ctrl+C behavior follows [CLI interaction](../modules/cli-interaction.md) (PTY fixtures: idle / busy first / second SIGINT; termios restore);
- [x] lifecycle rendering comes from events, not private Agent memory;
- [x] plain/headless dual-backend Gates remain green (default std **656/656**, curl **655/655**);
- [x] Kernel packages do not import TUI;
- [x] fixture matrix in tui-minimal.md §11 green on the implementation tip (TUI std **711/711**, TUI curl **710/710**).

## Acceptance for `theme-001` (contract track; docs only)

- [x] binding module [theme.md](../modules/theme.md) authored
- [x] task [theme-001](../plan/tasks/theme-001.md) authored (now `status: ready`)
- [x] round-1 dual **BLOCKED** findings closed in docs (structural vs Theme SGR; host options; containment; diagnostics; ownership Gates)
- [x] independent architecture/ownership contract **re-review** PASS @ reviewed tip `9e1b9f9` (zero blockers)
- [x] independent safety/fail-closed contract **re-review** PASS @ reviewed tip `9e1b9f9` (zero blockers)
- [x] docs lint / score / diff green on contract docs path; no product code
- [x] PASS-record tip records prior-tip PASS only; does not claim self dual re-review
- [ ] **no** product implementation until a separate fresh Goal (contract PASS alone is not product authz)
- [x] **no** maturity raise; **no** post-TUI Phase B grant/run/green claim

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
