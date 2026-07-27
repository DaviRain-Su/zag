---
status: active
scope: minimal host TUI binding contract (docs candidate)
task: tui-minimal-001
prerequisite:
  - harness-events-001
  - harness-steering-001
  - cli-sigint-001
  - headless-001
  - edit-sharpness-001
---

# Minimal host TUI binding contract

This module is the **single authoritative binding** for `tui-minimal-001`.
It freezes how a host TUI may assemble public `zag-coding-agent` /
`zag-cli` surfaces. It is a **contract candidate**: it does **not** ship a
product TUI, does **not** mark C9 implementation acceptance complete, and
does **not** raise any maturity row.

Implementation is **BLOCKED** until independent architecture/ownership and
safety/fail-closed contract reviews **PASS** and this contract merges.
See [task](../plan/tasks/tui-minimal-001.md).

Related truth (do not fork):

| Concern | Authority |
|---------|-----------|
| Lifecycle vocabulary / ordering | [harness-events](./harness-events.md) |
| Steering / follow-up queues | [harness-steering](./harness-steering.md) |
| Ctrl+C / process signals | [cli-interaction](./cli-interaction.md) |
| Headless JSON / stdout purity | [headless-contract](./headless-contract.md) |
| Permission Gate / ask / yolo / plan | [permissions](./permissions.md) |
| Session open modes / durability | [session-store](./session-store.md) |
| In-process SDK surface | [sdk-contract](./sdk-contract.md) |
| C9 phase goals | [C9-product-shell](../phases/C9-product-shell.md) |
| Package layers | [packaging](../packaging.md) · [architecture](../architecture.md) |

## 1. Ownership and dependency direction

### 1.1 Layer law

```text
terminal / renderer / input / focus / history / card ring
        │  host shell only
        ▼
zag-tui  (later product package; optional build)
   or  zag-cli tui module compiled only when -Dtui=true
        │  assembles public APIs only
        ▼
zag-coding-agent   Agent / Session / LifecycleObserver /
                   Observer / Gate·AskFn / control queues
        │
        ▼
zag-agent-core     thin generic model→tool→model loop
                   (no UI, no product policy, no TUI import)
```

| Layer | Owns | Must not own |
|-------|------|--------------|
| Host TUI (`zag-tui` or `zag-cli` TUI module) | terminal channel, layout, focus/layering, editor buffer, in-process input history, card ring, permission modal UI, host-owned copy buffers | Agent private fields, Loop, Transcript mutation, Trace schema, permission risk classification, session schema, headless envelopes |
| `zag-cli` | flag parse, mode mutex, SIGINT Guard install, process exit, plain/headless paths, wiring TUI when built | inventing lifecycle facts; silent mode fallback |
| `zag-coding-agent` | product policy, Session, Trace, lifecycle adapter, edit/review, Gate | terminal widgets, focus, raw TUI input |
| `zag-agent-core` | thin loop + ports | any TUI / CLI / terminal import |

### 1.2 Later package / build wiring (implementation track)

**Freeze (implementation may choose one of two shapes, not both in default builds):**

1. **Preferred:** new optional package `packages/zag-tui/` with module name
   `zag-tui`, depending only downward on `zag-coding-agent` (+ chosen
   terminal library). Root `build.zig` wires it **only** when
   `-Dtui=true`.
2. **Acceptable interim:** `packages/zag-cli/src/tui/*.zig` compiled into
   `zag-cli` **only** when `-Dtui=true`, still never imported by Kernel
   packages.

**Hard rules (both shapes):**

| Rule | Binding |
|------|---------|
| `-Dtui` default | **false** |
| Default `zig build` / `zig build test` | **no** TUI dependency, **no** change to plain or headless behavior |
| Kernel import ban | `zag-agent-core` and `zag-coding-agent` must not `@import("zag-tui")`, `@import("tui")`, or reference `zag_tui` (existing headless Kernel scan remains) |
| Terminal library | may be added as **lazy/optional** dep only under `-Dtui=true`; not a default monorepo dep |
| This contract node | **no** new package, **no** new dependency, **no** product implementation file |

### 1.3 Public-API-only assembly

TUI may call only public roots / documented product APIs, including:

- `Agent.init` / `Agent.reply` / `Agent.deinit` with `Options.lifecycle`,
  `Options.observer`, `Options.permission_mode`, `Options.permission_gate`
- `Session.start` / `Session.deinit` with `OpenMode` and validated path
- `Session.enqueueSteering` / `enqueueFollowUp` / `steeringPending` /
  `followUpPending` / `clearControlQueues` (idle-only clear)
- `LifecycleObserver` + `LifecycleEvent` (`lifecycle.zig`)
- `Observer` + `Event` (`observer.zig`) — optional progressive text only
- `permissions.Gate` / `AskFn` / `Mode` / `SessionKind` / remember policy
- Existing CLI SIGINT `Guard` and mode/exit rules from
  [cli-interaction](./cli-interaction.md)

**Forbidden:** reading `Agent` private fields, Core private loop state,
`Transcript` internals for UI cards, Trace file as live UI truth, or any
private memory “peek” that is not a public callback or public method.

## 2. Data-source matrix

| UI surface | Source of truth | Not allowed |
|------------|-----------------|-------------|
| Run open | `LifecycleEvent.run_start` | fabricating start without facade emit |
| Assistant complete card | `LifecycleEvent.assistant_message` | inventing turns / partial lifecycle kinds |
| Tool cards | `tool_start` / `tool_end` with end-only and hard mid-call gaps per [harness-events](./harness-events.md) | inventing `tool_update`; pairing every start with end |
| Control applied card | `LifecycleEvent.control_applied` | treating enqueue as applied |
| Run terminal card | `LifecycleEvent.run_terminal` | UI drop/close inventing `completed` success |
| Progressive assistant text (optional) | existing `Observer.Event.assistant_text` only | inventing `message_delta` / token-stream lifecycle |
| Permission modal | host `AskFn` bound into `Gate.ask` during ask mode | missing seam ⇒ allow / yolo |
| Cancel / SIGINT UX | [cli-interaction](./cli-interaction.md) + cooperative cancel + `run_terminal` / reply errors | second Ctrl+C as graceful terminal |
| Session identity strip | CLI validated path + open mode + `Session.path` + `run_start.session_configured` | inventing UUID / “resumed” without host fact |
| Errors | reply/`ReplyError` mapping + `run_terminal` when started | quiet success after failed render |

### 2.1 Progressive text fact (explicit)

There is **no** public `message_delta` lifecycle event. If the host wants
near-live assistant text, it may bind `Options.observer` and handle
`Observer.Event.assistant_text`.

**Current source fact (implementation evidence in coding-agent):**
`assistant_text` is emitted with the **complete validated assistant message
body** at the same moment as lifecycle `assistant_message` — it is **not**
a provider token delta stream today. Headless `assistant_delta` may also
map that complete body as one chunk.

**Host binding rules:**

1. Treat each `assistant_text` payload as a full message body snapshot for
   that emission (replace the open assistant card body, or open a new card
   if none). Do **not** claim token-streaming fidelity.
2. Copy borrowed bytes into a host-owned bounded buffer inside the
   callback (see §7).
3. Prefer lifecycle `assistant_message` for durable card identity
   (`turn`, `has_tools`); observer text is presentation-only.
4. A future real token-delta source requires a **separate** source-owning
   task; this contract forbids inventing one.

### 2.2 Terminal truth precedence

For every started run (`run_start` emitted):

1. Exactly one `run_terminal` is the public lifecycle terminal.
2. UI close, card drop, render failure, resize failure, or editor OOM
   **must not** invent `stop_reason=completed` / success chrome.
3. If the process exits without a lifecycle terminal (e.g. second SIGINT
   hard escape `130`), show process-abandoned state — not completed.
4. Reply-level errors after start map to failed terminal truth already
   owned by coding-agent; the TUI only displays them.
5. Preflight failure before `run_start` produces no lifecycle terminal;
   show host error, not a fake run card.

Tool correlation follows harness-events end-only / hard mid-call rules:

| Pattern | UI must |
|---------|---------|
| `tool_start` → `tool_end` | show running then finished |
| end-only `tool_end` (`cancelled` / `steered`) | show end-only card; **no** fabricated start |
| `tool_start` then hard fail, no `tool_end` | leave card “open/interrupted”; close run via `run_terminal` only |

## 3. Minimal UI layout

### 3.1 ASCII layout (default ≥ 80×24)

```text
┌─ zag  tui ──────────────────────────────────────────────────────────┐
│ id: <session_path|ephemeral>  open:<create|resume|n/a>  cfg:<y/n>   │
│ perm:ask|yolo  shell:protect|off  state:idle|busy|error|closed      │
├─────────────────────────────────────────────────────────────────────┤
│ CARD VIEWPORT (scrollable ring; newest at bottom)                   │
│  · run_start …                                                      │
│  · assistant turn=N …                                               │
│  · tool  start|end  name id …                                       │
│  · control kind=steering|follow_up next_turn=N …                    │
│  · run_terminal ok=… stop=… turns=…                                 │
│  · host_error …                                                     │
├─────────────────────────────────────────────────────────────────────┤
│ EDITOR (multiline; focus default when no modal)                     │
│  > line1                                                            │
│  . line2                                                            │
│  [bytes used/max]  [history i/n]  [submit:Enter · nl:Alt+Enter]     │
└─────────────────────────────────────────────────────────────────────┘
```

**Permission modal layer** (focus-stealing; see §3.3):

```text
┌─ permission (modal) ────────────────────────────────────────┐
│ risk:<read|write|shell>  args_len:<n>  tool:<redacted|—>    │
│ [a]/allow   [d]/deny   Esc=deny   EOF/fail=deny           │
└─────────────────────────────────────────────────────────────┘
```

**Constrained / tiny terminal** (`cols < 40` or `rows < 10`):

```text
[zag tui · constrained]
state=… id=…
(cards truncated to 1-line summaries)
> editor single-line mode (still bounded multiline buffer)
```

If both dimensions fall below **20×5**, enter **closed-error** host state:
do not run Agent; print one stderr diagnostic; exit non-zero for one-shot
launch, or refuse interactive entry. Never silently run headless/plain
semantics under a TUI flag.

### 3.2 Component tree

```text
TuiApp
├─ StatusStrip        session identity · perm · shell · run state
├─ CardViewport       bounded ring of CardView
│   └─ CardView[]     kind-specific rows (run/tool/control/terminal/error)
├─ EditorPane         buffer · cursor · history index · byte meter
├─ PermissionModal?   optional focus layer
└─ HostServices       copy buffers · redactor borrow · SIGINT drain hooks
```

### 3.3 Focus and layering

| Priority (high → low) | Layer | Input owner |
|----------------------:|-------|-------------|
| 1 | `PermissionModal` when open | modal keys only |
| 2 | `EditorPane` when idle or waiting for user submit | editor keys |
| 3 | `CardViewport` scroll (optional keys) | scroll only; never submit |
| — | background run | no text entry into Agent except control queues / cancel |

Rules:

1. Opening a permission modal **steals** focus; editor keystrokes do not
   append while modal is open.
2. Closing modal (allow/deny/fail-closed) returns focus to editor.
3. While `state=busy` without modal, editor may still accept keystrokes for
   **steering/follow-up draft** only if the host freezes a visible draft
   mode; v1 **minimal** freeze: editor is locked for submit of a new root
   prompt, but **Alt+S** queues steering and **Alt+F** queues follow-up
   from the current editor buffer via public Session methods (see §6).
4. Card viewport never owns permission decisions.

### 3.4 Card retention / backpressure / drop

| Constant | Value | Meaning |
|----------|------:|---------|
| `card_ring_capacity` | **128** | max retained host cards |
| `card_body_max_bytes` | **4096** | max copied body/preview per card |
| `card_title_max_bytes` | **128** | max title/name/id display slice |
| `drop_policy` | oldest first | when ring full, drop **oldest** non-terminal card |
| `terminal_card_pin` | last `run_terminal` | never drop the latest terminal card of the open run |
| `drop_marker` | insert synthetic `host_note` card | text exactly `cards_dropped=<n>` (ASCII) when ≥1 card dropped since last note |

Drop / failure semantics:

| Failure | Behavior |
|---------|----------|
| Card copy OOM | do not retain raw borrowed slice; emit `host_error` card if possible; keep run truth from lifecycle |
| Body oversize | copy first `card_body_max_bytes` bytes of **valid UTF-8 prefix**; append ASCII `…` if truncated |
| Invalid UTF-8 in source | replace card body with exact ASCII `invalid_utf8` (no raw bytes to terminal) |
| Render failure mid-frame | keep previous frame if any; set `state=error` strip; **never** rewrite terminal to success |
| UI closed during busy run | cooperative cancel request if Guard bound; await run end or process escape; no success chrome |

### 3.5 Terminal resize

| Event | Binding |
|-------|---------|
| SIGWINCH / size poll | recompute layout; clamp editor visible rows ≥ 1 when not constrained-closed |
| Width shrink | wrap card lines; do not reflow by re-querying Agent private state |
| Height shrink | keep newest cards visible; scroll offset may clamp |

### 3.6 State variants

| `state` | When | Editor | Cards |
|---------|------|--------|-------|
| `idle` | no open run; ready for submit | enabled | show history of prior cards in ring |
| `busy` | after `run_start` until `run_terminal` | root-submit locked; Alt+S/F control allowed | append live cards |
| `error` | host render/input/OOM or displayed failed terminal | enabled after run closes | show error + last terminal |
| `closed` | TUI exit / constrained refuse / fatal host | disabled | frozen |
| empty viewport | no cards yet | enabled | show exact placeholder line `(no events yet)` |
| loading | between submit and first lifecycle event | locked | show exact `(starting…)` status only — not a success terminal |

## 4. Bounded multiline editor and in-process history

### 4.1 Limits

| Constant | Value | Binding |
|----------|------:|---------|
| `editor_max_bytes` | **65536** (64 KiB) | hard cap of editor buffer size in UTF-8 **bytes** |
| `editor_max_lines` | **512** | hard cap of `\n`-separated lines in buffer |
| `history_capacity` | **64** | max prior **submitted** prompts retained in-process |
| `history_entry_max_bytes` | **8192** | max bytes stored per history entry |

### 4.2 UTF-8 and oversize

| Condition | Behavior |
|-----------|----------|
| Typing produces incomplete UTF-8 sequence | allow in buffer until submit; cursor may sit on incomplete tail |
| Submit / Alt+S / Alt+F with invalid UTF-8 | **reject**; keep buffer; status `invalid_utf8`; no Agent call / no enqueue |
| Insert would exceed `editor_max_bytes` | **reject insert** of that keystroke/paste chunk; no truncation of existing buffer |
| Insert would exceed `editor_max_lines` | **reject** newline that would create line 513 |
| Paste larger than remaining capacity | reject whole paste chunk (no partial silent fill) |
| History push of entry > `history_entry_max_bytes` | store only first valid UTF-8 prefix ≤ 8192; if prefix empty, skip push |

### 4.3 Key behavior (v1 freeze)

| Key | Idle editor | Busy (no modal) | Permission modal |
|-----|-------------|-----------------|------------------|
| **Enter** | submit root prompt if buffer non-empty after **no trim** of interior; empty buffer (len 0) ignored; leading/trailing spaces kept | ignored for root submit | treated as **deny** only if focus is on deny default — freeze: Enter = **deny** |
| **Alt+Enter** | insert `\n` (subject to line/byte caps) | insert `\n` into control draft buffer | ignored |
| **Ctrl+J** | same as Alt+Enter | same | ignored |
| **Esc** | clear status notes only; does **not** exit process | cancel draft selection only | **deny** |
| **Ctrl+C** | fully obey [cli-interaction](./cli-interaction.md) | same | same — first = cooperative cancel path when active; second pending = hard `130` |
| **Ctrl+D** | if buffer empty → EOF exit path (clean interactive exit `0` when idle); if buffer non-empty → ignored | ignored | **deny** (fail-closed) |
| **Up / Down** | walk in-process history (see §4.4) | disabled | ignored |
| **a / A** | normal insert | normal insert | **allow** |
| **d / D** / **n / N** | normal insert | normal insert | **deny** |
| **Alt+S** | if non-empty valid UTF-8: `Session.enqueueSteering`; on success clear buffer optional **no** (freeze: **keep** buffer, show `steering_queued` or error) | same if Session live | ignored |
| **Alt+F** | `Session.enqueueFollowUp` with same rules | same | ignored |

Empty message enqueue returns `ControlError.EmptyMessage` — show `control_empty`; do not crash.

### 4.4 History is not Session transcript

| Store | Lifetime | Persistence |
|-------|----------|-------------|
| Editor history ring | process memory only | **never** written to session JSONL / Trace / new schema |
| Session transcript | product Session | existing session-store contract only |
| Control queues | Session process memory | not schema v1 (already frozen) |

History rules:

1. Push **only** on successful root submit that actually calls `Agent.reply`
   (not on failed UTF-8, not on control-only Alt+S/F).
2. Duplicate consecutive identical bytes still push (no dedup requirement).
3. Up moves to older entries; Down toward newer / live buffer.
4. Editing after Up detaches from history index (standard shell-like).
5. **Do not** reload history from durable Session on resume.
6. **Do not** invent a `.zag/tui-history` file in this contract.

## 5. Session identity, open mode, resume truth

### 5.1 Allowed identity facts

| Fact | Source |
|------|--------|
| Path string | CLI-validated relative workspace path (`session_store.validateSessionPath`) or host-configured SDK path; display max 128 bytes with truncation marker |
| Open mode | CLI: `-c`/`--continue` → `resume_existing`; else `create_new` for `-s` / default create; SDK may use `open_or_create` |
| `session_configured` | `LifecycleEvent.run_start.session_configured` only after start |
| Ephemeral | `Session.path == null` and no durable path configured → display exact `ephemeral` |
| Resumed chrome | **only** when open mode is `resume_existing` **and** `Session.start` succeeded, or SDK `open_or_create` path that actually resumed (host must track the branch). **Never** infer “resumed” from path string alone |

### 5.2 Forbidden identity inventions

- UUID / random session ids
- Claiming `resumed` on `create_new` success
- Claiming configured session when `run_start.session_configured=false`
- Showing absolute canonicalized paths (keep lexical relative path bytes)
- Reading Trace headers for identity

`create_new` / `resume_existing` semantics stay exactly as
[session-store](./session-store.md). TUI does not add open modes.

## 6. Run / tool / control / cancel / error binding

### 6.1 Run lifecycle cards

Map 1:1 from public lifecycle events (§2). Ordering must match program
order of callbacks. Host may coalesce display rows but must not reorder
kinds relative to each other for the same run.

### 6.2 Control

| Action | API | Errors shown |
|--------|-----|--------------|
| Steering | `Session.enqueueSteering(text)` | `QueueFull`, `MessageTooLong` (4096), `EmptyMessage`, `InvalidUtf8` |
| Follow-up | `Session.enqueueFollowUp(text)` | same |
| Pending counts | `steeringPending` / `followUpPending` | display optional `S:n F:m` in status strip |
| Clear | `clearControlQueues` **idle-only** | never call during `reply` |

Applied control appears only via `LifecycleEvent.control_applied`. Queue
capacity remains **4 + 4** slots × **4096** bytes
([harness-steering](./harness-steering.md)).

### 6.3 Cancel

| Path | Binding |
|------|---------|
| First Ctrl+C while busy | cooperative cancel via existing SIGINT Guard → Agent cancel flag |
| Observed cancel terminal | show `run_terminal` / stop `cancelled` |
| Second pending Ctrl+C | hard exit `130`; no promised lifecycle terminal |
| Idle first Ctrl+C | clean exit `0` per cli-interaction |

TUI must **not** install a second competing SIGINT handler. Reuse CLI Guard
lifecycle.

### 6.4 Errors

| Class | Display |
|-------|---------|
| Session start failure | host_error; exit/non-zero or return to idle without run cards |
| Reply error after start | failed terminal truth from product; show stop reason |
| Control enqueue error | status line only; no fake `control_applied` |
| Permission deny | Tool soft result via normal tool_end path; modal closes |

## 7. Permission ask adapter (fail-closed)

### 7.1 Defaults (unchanged)

- Default permission mode: **ask**
- Workspace jail: unchanged
- Shell policy default: **protect**
- `--yolo` only when **explicitly** selected; never implied by TUI build
- yolo does **not** bypass jail or shell policy
- Plan mode still blocks general write/execute per [permissions](./permissions.md)
- Hunk review remains separate (`HunkReviewer`); TUI v1 does **not** implement
  hunk-review UI (interactive hunk review stays CLI stderr path unless a later
  task binds it). Missing hunk reviewer stays fail-closed
  (`review_unavailable`), never allow

### 7.2 Ask binding

```text
TuiPermissionAdapter implements AskFn
  → Gate.ask(adapter.ask, adapter_ptr)
  → Agent.Options.permission_gate = gate   (ask mode)
  → Agent.Options.permission_mode = .ask
```

When `permission_mode=ask` and `ask_fn` is missing, Gate already **denies**
dangerous ops. TUI **must** install an AskFn in interactive ask mode.
**Missing seam must never be treated as allow or yolo.**

### 7.3 Modal presentation (bounded / redacted)

| Field | Source | Bound |
|-------|--------|------:|
| `risk` | `descriptor.capabilities.risk.label()` | enum label only |
| `args_len` | `arguments_json.len` | decimal length only |
| `tool` | optional: redacted `descriptor.definition.name` | ≤ **64** bytes host buffer |
| arguments body | **not shown** in v1 modal | — |

Redaction: run tool name through the same product `Redactor` the Agent/Session
owns (`activeRedactor`) into a host buffer **inside AskFn before any render**.
On redaction OOM / failure → show tool as `—` and **still** require explicit
allow/deny (fail-closed default remains deny on EOF).

### 7.4 Modal decisions

| Input / failure | Decision |
|-----------------|----------|
| `a` / `A` | allow |
| `d`/`D`/`n`/`N` / Esc / Enter | deny |
| EOF on input | deny |
| render failure before decision | deny |
| read failure | deny |
| cancel observed before decision | deny (and cooperative cancel continues) |
| adapter panic | process failure; no false allow |

Remember: still exact lexical request-path remember owned by Gate; TUI must
not implement a parallel remember store. Remember never skips hunk review.

## 8. Redaction and trust

### 8.1 Borrowed callback bytes

Lifecycle and Observer payloads are **borrowed only for the callback**.
Host rules:

1. Copy needed bytes into **host-owned** buffers before returning.
2. Copy size ≤ card/editor constants above.
3. On OOM: drop that presentation copy; never retain raw pointer; never
   write secrets to plain stdout.
4. On oversize: UTF-8-safe truncate + `…`.
5. On invalid UTF-8: display `invalid_utf8` marker, not raw bytes.
6. Never persist raw preview into Session schema, Trace, or new files.

### 8.2 Channel isolation

| Mode | stdout | stderr | TUI terminal |
|------|--------|--------|--------------|
| plain CLI | final text | logs/prompts | unused |
| headless | `headless-v1` only | diagnostics | unused |
| TUI | **must not** emit headless envelopes; avoid plain final-text protocol on stdout while alt-screen/TUI owns the tty | diagnostics allowed | exclusive interactive channel |

TUI must not pollute headless stdout purity tests. Enabling TUI is a distinct
mode (see §9).

## 9. Flags, modes, and `-Dtui`

### 9.1 Build

| Item | Binding |
|------|---------|
| `-Dtui` | optional bool, **default false** (already declared in root `build.zig`) |
| default tests | no TUI link; Kernel no-TUI scan remains |
| `-Dtui=true` | may compile TUI package/module + optional terminal dep |

### 9.2 Runtime mode mutex

| Combination | Result |
|-------------|--------|
| `--json` + `--json-stream` | exit **2** (existing) |
| headless + REPL (no prompt) | exit **2** (existing) |
| `--tui` + `--json` | exit **2**, message requires mutual exclusion |
| `--tui` + `--json-stream` | exit **2** |
| `--tui` on binary built with `-Dtui=false` | exit **2**, exact class: TUI unavailable — **no** silent REPL fallback |
| `--tui` without TTY | exit **2** or host_error — **no** silent headless conversion |
| default (no `--tui`) | existing plain/REPL/headless unchanged |

**No silent fallback** that changes semantics (TUI request must not become
yolo, headless, or plain without user-visible error).

### 9.3 Dual-backend and terminal truth

std and curl HTTP backends remain orthogonal. TUI does not alter provider
control claims. Plain/headless exit matrices remain authoritative for those
modes.

## 10. Implementation Gate matrix (later node)

Executable fixtures for the **implementation** track (not this docs node):

| # | Fixture | Expect |
|---|---------|--------|
| 1 | Default `-Dtui=false` build/test | green; no TUI dep |
| 2 | `-Dtui=true` compile | links TUI; Kernel still clean |
| 3 | Editor byte/line caps | reject oversize insert; valid UTF-8 submit |
| 4 | History capacity 64 / entry 8 KiB | ring drop oldest; no durable file |
| 5 | Lifecycle ordering | run_start → … → one run_terminal |
| 6 | End-only tool_end cancelled/steered | no fake tool_start card |
| 7 | Hard mid-call gap | tool_start without tool_end + failed/non-success terminal |
| 8 | Permission fail-closed | EOF/render/read fail → deny; missing AskFn ≠ allow |
| 9 | Session create/resume identity | no forged resumed; path validated |
| 10 | Ctrl+C | idle 0; active cancel; second 130 per cli-interaction |
| 11 | Render/input/OOM/drop | no success invent; drop markers |
| 12 | plain + headless std/curl | unchanged green |
| 13 | Kernel import scan | no TUI imports in core/coding-agent |
| 14 | Mode mutex | `--tui`+json exit 2; `--tui` without build exit 2 |
| 15 | Docs/diff | contract remains consistent |

## 11. Non-goals

- Theme platform, dashboard, images, cost explorer
- Plugin / extension UI host (E2/E3 view trees)
- RPC / ACP / editor protocol
- OS sandbox / process-tree preemption
- Multi-file edit transactions; Core/session-v1/Trace-v1/headless-v1 schema edits
- Maturity raises (any row), including Tools write/edit L3 and Runtime Extensions > L0
- Pi TUI API parity or wholesale vaxis port
- Persisting editor history or new UI schema
- Token-delta lifecycle invention
- This contract node adding packages, deps, or product code

## 12. Contract-node acceptance (docs only)

- [x] Binding module authored (`docs/modules/tui-minimal.md`)
- [x] Task file authored (`docs/plan/tasks/tui-minimal-001.md`)
- [ ] Independent architecture/ownership contract review **PASS**
- [ ] Independent safety/fail-closed contract review **PASS**
- [ ] Docs lint + score + `git diff --check` green on candidate
- [ ] **No** C9 product implementation acceptance checked off as done
- [ ] **No** maturity row raise; **no** “TUI implemented” claim

## Related

- [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
- [C9 product shell](../phases/C9-product-shell.md)
- [harness-events](./harness-events.md) · [harness-steering](./harness-steering.md)
- [cli-interaction](./cli-interaction.md) · [headless-contract](./headless-contract.md)
- [permissions](./permissions.md) · [sdk-contract](./sdk-contract.md)
