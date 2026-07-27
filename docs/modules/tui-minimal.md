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

**Review state:** round-1 independent architecture and safety reviews were
**BLOCKED**. This revision closes those blockers as unique freezes. Re-review
is **pending** (do not treat as PASS until re-review records say so).
Implementation remains **BLOCKED** until architecture/ownership +
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

### 1.1 Layer law (unique package owner)

```text
terminal / renderer / input / focus / history / card ring
        │  host shell only
        ▼
packages/zag-tui/   module name: zag-tui   (ONLY later product package)
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
| **`zag-tui` only** | terminal channel, layout, focus/layering, editor buffer, in-process history, card ring, permission modal UI, host-owned preallocated buffers, reply-worker rendezvous | Agent private fields, Loop, Transcript mutation, Trace schema, permission risk classification, session schema, headless envelopes, process SIGINT install |
| `zag-cli` | flag parse, mode mutex, SIGINT Guard install, process exit, plain/headless paths; **assembles/imports `zag-tui` only when `-Dtui=true`** | inventing lifecycle facts; silent mode fallback; owning TUI widgets under `zag-cli/src/tui` |
| `zag-coding-agent` | product policy, Session, Trace, lifecycle adapter, edit/review, Gate | terminal widgets, focus, raw TUI input, any TUI import |
| `zag-agent-core` | thin loop + ports | any TUI / CLI / terminal import |

**Forbidden shape (removed):** `packages/zag-cli/src/tui/**` as an alternate
TUI owner. Product TUI code lives **only** under `packages/zag-tui/`.

### 1.2 Build wiring (unique freeze)

| Rule | Binding |
|------|---------|
| Package path | **`packages/zag-tui/`** only; Zig module name **`zag-tui`** |
| `-Dtui` default | **false** |
| Root `build.zig` | declares `-Dtui`; passes the bool into `zag-cli` dependency options |
| When `-Dtui=false` | **must not** resolve, fetch, or build `zag-tui` or any terminal library; default `zig build` / `zig build test` unchanged |
| When `-Dtui=true` | root may resolve optional/lazy `zag-tui` + terminal library; `zag-cli` may `@import("zag-tui")` and call its public entry |
| `zag-cli` role | owns flags/mode/SIGINT/exit; **only** wires TUI entry when built with `-Dtui=true` |
| Kernel / coding-agent ban | must not `@import("zag-tui")`, `@import("tui")`, or reference `zag_tui` (existing headless Kernel scan remains) |
| Terminal library | **implementation detail**, not contract-visible API. Must be **quarantined inside `zag-tui`**, lazy/optional, must not alter this behavioral contract. **No wholesale vaxis port** |
| This contract node | **no** new package, **no** new dependency, **no** product implementation file |

### 1.3 Public-API-only assembly

TUI may call only public roots / documented product APIs, including:

- `Agent.init` / `Agent.reply` / `Agent.deinit` with `Options.lifecycle`,
  `Options.observer`, `Options.permission_mode`, `Options.permission_gate`,
  `Options.hunk_reviewer`
- `Session.start` / `Session.deinit` with product-TUI open modes only
  (§5: `create_new` / `resume_existing`)
- `Session.enqueueSteering` / `enqueueFollowUp` / `steeringPending` /
  `followUpPending` / `clearControlQueues` (idle-only clear)
- `Session.activeRedactor` (must be non-null before first worker; §7.5)
- `LifecycleObserver` + `LifecycleEvent` (`lifecycle.zig`)
- `Observer` + `Event` (`observer.zig`) — optional progressive text only
- `permissions.Gate` / `AskFn` / `Mode` / `SessionKind` / remember policy
- Existing CLI SIGINT `Guard` from [cli-interaction](./cli-interaction.md)

**Forbidden:** reading `Agent` private fields, Core private loop state,
`Transcript` internals for UI cards, Trace file as live UI truth, or any
private memory peek that is not a public callback or public method.

## 2. Dual-thread host concurrency (unique freeze)

Busy steering + synchronous `AskFn` **require** two threads with fixed roles.
No alternate concurrency model is allowed for product TUI v1.

### 2.1 Threads and ownership

| Thread | Owns exclusively | Must not |
|--------|------------------|----------|
| **UI thread** (main) | stdin key decode, stdout/raw/alt-screen, render, editor buffer, history navigation, card **snapshot** display, permission **decision** input, `Session.enqueue*` / `*Pending` calls | execute `Agent.reply`; read raw lifecycle slices after callback return |
| **Reply worker** (exactly one when busy) | one synchronous `Agent.reply` (single-flight); runs Lifecycle/Observer callbacks and Gate/`AskFn` on this thread | touch stdin/stdout/raw/alt-screen; call render; re-enter `reply`; `clearControlQueues` / `Session.deinit` / `Agent.deinit` |

Rules:

1. **Single-flight:** at most one reply worker exists. While `state=busy`,
   root prompt submit is **ignored** (status `busy_locked`).
2. `Agent`, `Session`, `TuiPermissionAdapter`, and all shared host slots are
   allocated and **address-stable** before the worker starts.
3. Until the UI thread **joins** the worker, no thread may move/deinit/clear
   `Agent` / `Session` / adapter / preallocated rings.
4. After join only: idle `clearControlQueues`, session teardown, adapter
   reset for the next run.
5. `Session.enqueueSteering` / `enqueueFollowUp` / pending counts are called
   **from the UI thread** while the worker may be inside `reply`, using the
   already-frozen foreign-thread queue safety
   ([harness-steering](./harness-steering.md)). Clear remains **idle-only**.

### 2.2 Lifecycle / Observer callbacks (worker thread)

Callbacks run **synchronously on the reply worker**. Inside a callback the
host **must**:

1. **Not** perform TTY I/O, render, or stdin reads.
2. **Not** re-enter `Agent.reply`, `clearControlQueues`, `Session.deinit`,
   or `Agent.deinit`.
3. **Not** hold a host lock while calling back into user/host code outside
   the fixed publish path.
4. Redact full source bytes with Session-owned non-null
   `Redactor.redactAlloc` (**§8**), then UTF-8-validate / truncate / copy
   into a **preallocated** host card slot.
5. Under a **short** card-publish lock: write slot + advance a monotonic
   `ui_seq`, then **release the lock**.
6. Signal a **bounded non-blocking** UI wake (self-pipe / eventfd / equivalent
   with drop-on-full). Never block the worker forever on a full wake queue.

UI thread: drain wake → snapshot cards under the same short lock → render
outside the lock.

**Lock order (unique):**

```text
1. permission_slot_mutex   (AskFn rendezvous only)
2. card_ring_mutex         (publish/snapshot only)
```

Never acquire `permission_slot_mutex` while holding `card_ring_mutex`.
**Never wait for a permission decision while holding `card_ring_mutex`.**

### 2.3 Permission rendezvous (worker `AskFn`, UI decides)

Product TUI ask mode uses **one preallocated permission slot** (capacity **1**
outstanding request) + mutex + condition variable (or equivalent single-slot
rendezvous).

```text
worker AskFn:
  if ask_ctx == null OR redactor missing OR slot already pending:
      return deny
  redact/copy bounded modal facts into slot   // no raw args body shown
  publish request + wake UI
  wait on condition until decision OR host closing
  return allow|deny

UI thread (only decider):
  on wake / poll: if permission pending, steal focus to modal
  a/A → allow; d/D/n/N/Esc/Enter/EOF/render-fail/read-fail → deny
  signal condition; clear slot
```

| Failure | Decision |
|---------|----------|
| close / host fatal while waiting | **deny** + wake worker |
| EOF on input | **deny** + if busy enter closing (§9) |
| render / read failure | **deny** |
| cancel observed before decision | **deny** (cooperative cancel continues) |
| null `ask_ctx` / missing redactor | **deny** (no modal) |
| second concurrent AskFn | **deny** (slot full) |

**Worker must not** read stdin or render. **UI must not** call `Gate.check`
directly.

### 2.4 Shutdown and host fatal

| Step | Binding |
|------|---------|
| TUI entry | **must successfully install** the existing CLI SIGINT `Guard` before raw mode / worker; install failure → fixed stderr, exit **1**, no TUI |
| Busy close / host fatal | set `closing=true`; **deny** any pending permission slot and signal; request cooperative cancel via Guard-bound flag; enter **visible waiting** state (status `closing`); keep two-phase Ctrl+C escape |
| Wait honesty | UI waits for worker join. **std HTTP backend may block** in DNS/connect/TLS/response-head; there is **no** automatic graceful host timeout. Documented as **user-visible wait** + second Ctrl+C hard escape `130`. **Forbidden:** “silent unbounded wait” without visible closing chrome |
| After worker ends | join → restore tty/raw/alt-screen when possible (§9.4) → deinit order: worker resources, then Session/Agent only when idle |
| Success invent | **forbidden** — no completed chrome on close/fatal |

## 3. Data-source matrix

| UI surface | Source of truth | Not allowed |
|------------|-----------------|-------------|
| Run open | `LifecycleEvent.run_start` | fabricating start without facade emit |
| Assistant complete card | `LifecycleEvent.assistant_message` | inventing turns / partial lifecycle kinds |
| Tool cards | `tool_start` / `tool_end` per [harness-events](./harness-events.md) | inventing `tool_update`; assuming every start has end |
| Control applied card | `LifecycleEvent.control_applied` | treating enqueue as applied |
| Run terminal card | `LifecycleEvent.run_terminal` | UI drop/close inventing `completed` success |
| Progressive assistant text (optional) | existing `Observer.Event.assistant_text` only | inventing `message_delta` / token-stream lifecycle |
| Permission modal | host `AskFn` via `Gate.ask` (ask mode) | missing seam ⇒ allow / yolo; `StdinPrompter` |
| Cancel / SIGINT UX | [cli-interaction](./cli-interaction.md) + cooperative cancel + `run_terminal` | second Ctrl+C as graceful terminal |
| Session identity strip | §5 host facts only | inventing UUID / false resumed |
| Errors | reply/`ReplyError` + `run_terminal` when started | quiet success after failed render |

### 3.1 Progressive text fact

There is **no** public `message_delta`. Optional progressive display uses
`Observer.Event.assistant_text` only.

**Current source fact:** coding-agent emits `assistant_text` with the
**complete validated assistant message body** at the same moment as
lifecycle `assistant_message` — **not** a provider token delta stream.

Host rules:

1. Treat each emission as a full message body snapshot (replace open
   assistant card body, or open one if none). No token-stream claim.
2. Redact + copy into preallocated host buffers **inside** the callback (§8).
3. Prefer lifecycle `assistant_message` for card identity (`turn`, `has_tools`).
4. Real token deltas require a **separate** source-owning task.

### 3.2 Terminal truth precedence

For every started run (`run_start` emitted):

1. Exactly one `run_terminal` is the public lifecycle terminal.
2. UI close, card drop, render failure, resize failure, or allocation failure
   **must not** invent `stop_reason=completed` / success chrome.
3. Process exit without lifecycle terminal (e.g. second SIGINT `130`) is
   process-abandoned — not completed.
4. Reply-level errors after start map to product failed terminal truth; TUI
   only displays them.
5. Preflight failure before `run_start` produces no lifecycle terminal;
   fixed host error only.

Tool patterns:

| Pattern | UI must |
|---------|---------|
| `tool_start` → `tool_end` | show running then finished |
| end-only `tool_end` (`cancelled` / `steered`) | end-only card; **no** fabricated start |
| `tool_start` then hard fail, no `tool_end` | leave open/interrupted; close via `run_terminal` only |

## 4. Minimal UI layout

### 4.1 ASCII layout (default ≥ 80×24)

```text
┌─ zag  tui ──────────────────────────────────────────────────────────┐
│ id: <path|ephemeral>  open:<create_new|resume_existing|n/a> cfg:y/n │
│ perm:ask|yolo  shell:protect|off  state:idle|busy|error|closed      │
├─────────────────────────────────────────────────────────────────────┤
│ CARD VIEWPORT (scrollable ring; newest at bottom)                   │
│  · run_start …                                                      │
│  · assistant turn=N …                                               │
│  · tool  start|end  name id …                                       │
│  · control kind=steering|follow_up next_turn=N …                    │
│  · run_terminal ok=… stop=… turns=…                                 │
│  · host_error / host_note …                                         │
├─────────────────────────────────────────────────────────────────────┤
│ EDITOR (multiline; focus default when no modal)                     │
│  > line1                                                            │
│  . line2                                                            │
│  [bytes used/max]  [history i/n]  [submit:Enter · nl:Alt+Enter]     │
└─────────────────────────────────────────────────────────────────────┘
```

**Permission modal** (focus-stealing):

```text
┌─ permission (modal) ────────────────────────────────────────┐
│ risk:<read|write|shell>  args_len:<n>  tool:<redacted|—>    │
│ [a]=allow   [d]=deny   Esc/Enter/EOF/fail=deny              │
└─────────────────────────────────────────────────────────────┘
```

**Constrained** (`cols < 40` or `rows < 10`, but ≥ 20×5):

```text
[zag tui · constrained]
state=… id=…
(cards truncated to 1-line summaries)
> editor single-line display (buffer still multiline-capable)
```

**Below 20×5:** refuse before raw mode — fixed stderr, exit **1** (§9).
Never silent headless/plain fallback under `--tui`.

### 4.2 Component tree

```text
TuiApp
├─ StatusStrip
├─ CardViewport          preallocated ring (§6)
│   └─ CardSlot[]
├─ EditorPane            preallocated buffer + history
├─ PermissionModal?      single-slot rendezvous view
└─ HostServices          redactor borrow · wake · SIGINT Guard hooks
```

### 4.3 Focus and layering

| Priority (high → low) | Layer | Input owner |
|----------------------:|-------|-------------|
| 1 | `PermissionModal` when pending | modal keys only |
| 2 | `EditorPane` | editor keys / Alt+S|F when busy |
| 3 | `CardViewport` scroll | scroll only |

1. Modal steals focus; editor does not append while modal open.
2. Modal close returns focus to editor.
3. Busy: root Enter submit **ignored**; **Alt+S** / **Alt+F** enqueue control
   from editor buffer via public Session methods (UI thread).
4. Card viewport never decides permissions.

### 4.4 State variants

| `state` | When | Editor | Cards |
|---------|------|--------|-------|
| `idle` | no worker; ready | root submit enabled | prior ring retained |
| `busy` | worker live (from accepted dispatch until join) | root submit locked; Alt+S/F allowed | live publishes |
| `closing` | host close/fatal/EOF-busy; waiting join | locked | frozen + visible wait |
| `error` | host render fault or failed terminal displayed | enabled after join | error + last terminal |
| `closed` | process exiting TUI | disabled | frozen |
| empty | no cards | enabled | exact `(no events yet)` |
| loading | after dispatch before first lifecycle event | locked | status `(starting…)` only — not success |

## 5. Session identity, open mode, resume truth

### 5.1 Product TUI CLI open modes (unique)

Product TUI CLI uses **only**:

| Flag path | `OpenMode` | Display `open:` |
|-----------|------------|-----------------|
| `-c` / `--continue` | `resume_existing` | `resume_existing` |
| `-s PATH` without continue | `create_new` | `create_new` |
| no session flags | ephemeral (`path=null`) | `n/a` |

Implementation **must** reuse CLI `selectOpenMode` semantics
([session-store](./session-store.md)): continue → `resume_existing`, else
`create_new`. **Product TUI v1 must not call `open_or_create`.**

### 5.2 Resumed / configured facts

| Fact | When true |
|------|-----------|
| `resumed` chrome | **only** `open_mode == resume_existing` **and** `Session.start` succeeded |
| `session_configured` | lifecycle `run_start.session_configured` after start (display `cfg:y/n`) |
| configured path display | host-validated relative path bytes present **and** lifecycle/host path fact; **never** infer configured from path string alone without start |
| ephemeral | no durable path configured → display exact `ephemeral` |

### 5.3 SDK hosts and `open_or_create`

Product TUI v1 **excludes** `open_or_create`. If a non-product SDK host
still starts a Session with `open_or_create` under a custom shell, it **must**
display `open:open_or_create/unknown` and **must not** claim `resumed`
(public API does not expose the actual create vs resume branch). Prefer not
using that mode with this contract at all.

### 5.4 Forbidden identity inventions

- UUID / random session ids
- `resumed` on `create_new` success
- `resumed` for any `open_or_create` path
- configured session when lifecycle says `session_configured=false`
- absolute canonicalized paths (keep lexical relative path; redact for display §8)
- Trace headers as identity

## 6. Preallocation and card ring (unique capacity)

### 6.1 Startup preallocation

**Before** entering raw/alt-screen mode, **before** `Session.start` success
path that leads to interactive loop, and **before** any reply worker:

Preallocate **once** (fail-closed):

- editor buffer (`editor_max_bytes`)
- history ring (`history_capacity` × `history_entry_max_bytes` backing)
- full card ring slots (§6.2)
- permission single-slot storage
- wake pipe / event primitives

**OOM at preallocate:** fixed stderr diagnostic (no secrets), exit **1**,
**never** start a run / never enter raw mode.

### 6.2 Card capacity = 128 slots (exact split)

| Class | Count | Role |
|------:|------:|------|
| Ordinary FIFO | **125** | lifecycle/observer/control/host_note drop-eligible |
| Terminal reserve | **1** | allocation-free current-run `run_terminal` summary |
| Host-error reserve | **1** | allocation-free host error summary |
| Drop-note / virtual | **1** | virtual or fixed slot for `cards_dropped=<n>` |
| **Total** | **128** | |

Each ordinary/terminal/host-error slot has **fixed** title and body arrays:

| Field | Cap |
|-------|----:|
| `card_title_max_bytes` | **128** |
| `card_body_max_bytes` | **4096** |

### 6.3 Drop / terminal / OOM rules

| Rule | Binding |
|------|---------|
| Ordinary full | drop **oldest ordinary** slot first (FIFO) |
| Drop count | saturating `u32`; never wraps to zero |
| Drop note | single virtual/host_note update with exact ASCII `cards_dropped=<n>`; **does not** consume ordinary FIFO in a way that recursively triggers further drops of itself |
| Terminal event | format with **numeric/enum fixed fields only** into terminal reserve (`ok`, `stop_reason` tag, `turns`, usage numbers). **Always** writable without redaction heap; **must not** lose current-run terminal summary to redaction/card OOM |
| Prior-run terminal | when a **new** run starts, previous terminal may demote into ordinary FIFO (then droppable) |
| Current-run terminal reserve | always available while that run is open |
| Host-error reserve | always available for fixed host fault codes |
| “if possible” language | **forbidden** — reserves are mandatory |

## 7. Composition bind matrix (unique)

### 7.1 Permission mode

| Mode | Bind |
|------|------|
| **ask** (default) | **must** set `permission_mode=.ask` and `permission_gate = Gate.ask(TuiPermissionAdapter.ask, adapter_ptr)` with non-null stable `ask_ctx`. **Forbidden:** falling through to `StdinPrompter` / stdin y/N |
| **yolo** | only when user passed explicit `--yolo` / `--permission yolo`; bind `Gate.yolo()`. Jail + shell protect/off still enforce |
| plan | `session_kind=.plan` still blocks general write/execute per [permissions](./permissions.md) before ask |

Missing AskFn / null ctx in ask mode → Gate deny path; host must still not
treat that as allow/yolo.

### 7.2 Hunk reviewer (TUI v1)

| Mode | `Options.hunk_reviewer` |
|------|-------------------------|
| TUI **ask** | **fixed null** → `apply_hunk` soft `review_unavailable` if reached; **never** `InteractiveHunkReviewer`; **never** stdin/stderr hunk UI |
| TUI **yolo** | existing explicit **AutoAccept** bind (same product yolo rule as CLI B2); no interactive review |
| plan / permission deny | no review path (deny before execute) |

No hunk modal in TUI v1. Remember never skips hunk review (product law).

### 7.3 Adapter init order (unique)

```text
1. Preallocate TUI host state (editor/history/cards/permission/wake) — OOM→exit 1
2. Install SIGINT Guard successfully — fail→exit 1
3. Construct address-stable TuiPermissionAdapter + card host (ptrs fixed)
4. Agent.init(..., .{
     .permission_mode = ask|yolo,
     .permission_gate = Gate.ask(...) | Gate.yolo(),
     .hunk_reviewer = null | AutoAccept,   // §7.2
     .lifecycle = ...,
     .observer = ...,                      // optional
   })
5. Session.start with create_new|resume_existing|ephemeral only
6. Require Session.activeRedactor() non-null; bind adapter.redactor =
   that pointer (Session-owned). If null → fixed error, exit 1, no worker
7. Enter raw/alt-screen only after 1–6 succeed
8. On root submit: history push + start single reply worker
```

Any missing bind / null ctx → deny (permissions) or drop-marker
(`redaction_unavailable`) for presentation — **never** call
`redactOptional(null)`.

### 7.4 Control enqueue (UI thread)

| Action | API | UI on error |
|--------|-----|-------------|
| Steering | `Session.enqueueSteering` | typed status: `control_empty` / `control_too_long` / `control_queue_full` / `invalid_utf8` |
| Follow-up | `Session.enqueueFollowUp` | same |
| Pending | `steeringPending` / `followUpPending` | optional `S:n F:m` |
| Clear | `clearControlQueues` | **idle-only**, after worker join |

Control text max remains **4096** bytes
([harness-steering](./harness-steering.md)). Oversize → `MessageTooLong` →
status `control_too_long` (keep buffer; no truncate-enqueue).

### 7.5 Cancel

| Path | Binding |
|------|---------|
| First Ctrl+C busy | cooperative cancel via Guard → Agent flag |
| Observed cancel | show truthful `run_terminal` / `cancelled` |
| Second pending Ctrl+C | hard exit **130**; no promised lifecycle terminal; **tty restore not guaranteed** (§9.4) |
| Idle first Ctrl+C | clean exit **0** per cli-interaction |

TUI must **not** install a second SIGINT handler.

## 8. Redaction and trust (all outward arbitrary bytes)

### 8.1 Mandatory redact-before-publish

For **every** outward presentation of arbitrary bytes, including:

- assistant text (lifecycle + observer)
- tool id / name / arguments / body
- control_applied text
- session path display
- any host_error / title / note that embeds user or model content

**Pipeline (unique order):**

```text
full source slice
  → Redactor.redactAlloc(gpa, full_input)   // Session-owned, non-null
  → on success: UTF-8 validate → truncate to cap with marker (§8.2)
  → copy into preallocated host slot
  → free temporary redactAlloc buffer
```

| Condition | Published bytes (exact) |
|-----------|-------------------------|
| redaction OOM / `redactAlloc` error | ASCII `redaction_failed` |
| redactor pointer missing / null bind | ASCII `redaction_unavailable` |
| after redaction, invalid UTF-8 | ASCII `invalid_utf8` |
| success | redacted, UTF-8-safe truncated body |

**Forbidden:**

- raw fallback of unredacted source
- `redactOptional(null)` (null redactor is **not** a pass-through path for TUI)
- retaining borrowed callback pointers past callback return
- writing secrets to stdout/stderr or durable new schemas

**Exempt from redaction** (enum / numeric / fixed codes only):
`ok`, `stop_reason` tag, turn counters, usage integers, risk label enum,
`args_len`, fixed status codes like `cards_dropped=<n>`, `busy_locked`.

Permission modal: risk + args_len are numeric/enum; optional tool name uses
the same redactAlloc pipeline into ≤ **64** byte title-class buffer.
Arguments **body is never shown** in v1 modal.

### 8.2 Truncation marker (exact)

| Constant | Value |
|----------|-------|
| Truncation marker | exact 14-byte ASCII `...[truncated]` |
| Body cap | `card_body_max_bytes` = 4096 |
| Title cap | `card_title_max_bytes` = 128 |

Truncated output length **≤ cap**, composed as:

```text
valid_utf8_prefix(redacted, cap - 14)  ++  "...[truncated]"
```

Do **not** call U+2026 / Unicode ellipsis “ASCII”. Marker is the 14-byte
ASCII sequence above. Empty prefix after redaction → publish marker only if
cap ≥ 14, else publish empty and treat as drop-marker fault
(`redaction_failed` preferred for zero-capacity edge — should not occur with
frozen caps).

### 8.3 Channel isolation

| Mode | stdout | stderr | TUI tty |
|------|--------|--------|---------|
| plain CLI | final text | logs/prompts | unused |
| headless | `headless-v1` only | diagnostics | unused |
| **TUI** | **renderer exclusive**; **must not** emit headless envelopes or plain final-text protocol | **fixed diagnostics only**; during normal alt-screen **must not** print raw user/model content | exclusive interactive channel |

## 9. Flags, modes, exit, and tty matrix

### 9.1 Build

| Item | Binding |
|------|---------|
| `-Dtui` | default **false** |
| default tests | no TUI resolve/build; Kernel scan green |
| `-Dtui=true` | may build `zag-tui` + lazy terminal dep |

### 9.2 Runtime flag matrix (product TUI v1)

Product TUI v1 is an **interactive shell only**: **no positional prompt**.

| Combination | Exit | stdout | stderr |
|-------------|-----:|--------|--------|
| `--json` + `--json-stream` | 2 | empty protocol rules as today | fixed |
| `--tui` + `--json` | **2** | empty | mutual exclusion |
| `--tui` + `--json-stream` | **2** | empty | mutual exclusion |
| `--tui` + `--doctor` | **2** | empty | mutual exclusion |
| `--tui` + positional prompt | **2** | empty | mutual exclusion |
| `--tui` + `--verbose` / `-v` | **2** | empty | reject (keeps stderr free of verbose raw dumps) |
| `--tui` on `-Dtui=false` binary | **2** | empty | TUI unavailable — **no** REPL fallback |
| `--tui` and **either** stdin or stdout is not a TTY | **2** | **empty** | fixed non-tty diagnostic |
| `--help` with `--tui` (no json) | **0** | normal help text path as CLI help | help may use stderr per existing help rules; **must not** init TUI / raw mode |
| `--help` with `--tui` and json flags | **2** | follow existing parse/mutex with headless | — |
| default without `--tui` | existing | existing | existing |

**Allowed with `--tui`** (still subject to validation):

- `--ask` / `--yolo` / `--permission`
- `--plan`
- `--shell-policy`
- `-s` / `--session`, `-c` / `--continue`
- `--trace` / resource / model / provider flags that plain interactive allows
- `--stream` (provider SSE request; orthogonal; no headless envelopes)
- `--no-remember`, `--no-project`, skills/templates trust flags

### 9.3 Exit code table (TUI mode)

| Scenario | Exit |
|----------|-----:|
| Idle EOF (Ctrl+D empty buffer) / clean interactive quit | **0** |
| Idle first Ctrl+C | **0** |
| Arg / mode / build-unavailable / non-TTY | **2** |
| Preallocate OOM, Guard install fail, Session.start fail (before raw), terminal &lt; 20×5 | **1** |
| Runtime init / unrecoverable host after start (non-signal) | **1** |
| Second pending SIGINT | **130** |

Session.start failure: **before** raw mode — fixed redacted/generic stderr
(no absolute secret paths), exit **1**. **Not** “idle with error card”.

Terminal geometry &lt; 20×5: **before** raw mode — fixed stderr, exit **1**.

### 9.4 Tty restore honesty

| Path | Restore raw/alt-screen |
|------|------------------------|
| Clean idle exit, cooperative cancel completed + join, host closing after join | **must** restore tty |
| Second SIGINT `_exit(130)` / kill / panic | **not guaranteed**; **must not** claim scrollback wipe or secret zeroization |
| Busy renderer fatal | leave alt-screen if possible → fixed stderr explaining cancel/wait/Ctrl+C escape → wait worker join → no fake success |

## 10. Bounded multiline editor and in-process history

### 10.1 Limits

| Constant | Value |
|----------|------:|
| `editor_max_bytes` | **65536** |
| `editor_max_lines` | **512** |
| `history_capacity` | **64** |
| `history_entry_max_bytes` | **8192** |

### 10.2 UTF-8 and oversize

| Condition | Behavior |
|-----------|----------|
| Incomplete UTF-8 while typing | allowed until submit/enqueue |
| Submit / Alt+S / Alt+F invalid UTF-8 | reject; status `invalid_utf8`; no dispatch/enqueue |
| Insert exceeds byte/line cap | reject that insert/paste chunk entirely |
| History entry &gt; 8192 | store valid UTF-8 prefix ≤ 8192; empty prefix → skip push |

### 10.3 Keys

| Key | Idle | Busy (no modal) | Permission modal |
|-----|------|-----------------|------------------|
| **Enter** | root submit if len&gt;0 (no trim); empty ignored | ignored (`busy_locked`) | **deny** |
| **Alt+Enter** / **Ctrl+J** | insert `\n` | insert `\n` | ignored |
| **Esc** | clear status notes only | clear draft selection only | **deny** |
| **Ctrl+C** | cli-interaction | cli-interaction | cli-interaction |
| **Ctrl+D** | empty buffer → idle EOF exit **0**; non-empty ignored | enter **closing** (deny pending modal, cooperative cancel, wait join) | **deny** then if still busy enter **closing** |
| **Up/Down** | history walk | disabled | ignored |
| **a/A** | insert | insert | **allow** |
| **d/D/n/N** | insert | insert | **deny** |
| **Alt+S** | enqueue steering if valid; keep buffer; status queued/error | same | ignored |
| **Alt+F** | enqueue follow-up | same | ignored |

### 10.4 History dispatch point (unique)

History push occurs **only** when root submit is **accepted for worker
dispatch** (buffer valid UTF-8, non-empty, pre-busy, worker start begins).

- Not on failed UTF-8
- Not on Alt+S/F control-only
- Not on busy_locked ignored Enter
- If worker **fails to start** after push, entry may remain (acceptable);
  must not call `Agent.reply` without the push already recorded for that
  accepted dispatch attempt

History is **process-only** — never Session JSONL / Trace / new schema.
Do not reload from durable Session on resume.

## 11. Implementation Gate matrix (later node)

Fixtures below are **implementation-track** (not this docs node). Fault
injection is required where noted.

| # | Fixture | Expect |
|---|---------|--------|
| 1 | `-Dtui=false` default build/test | no TUI resolve; plain/headless green |
| 2 | `-Dtui=true` compile + import scan | `zag-tui` links; core/coding-agent have no TUI import |
| 3 | Editor byte/line caps | reject oversize; valid UTF-8 submit |
| 4 | History 64×8 KiB | ring behavior; no durable file; push only on accepted dispatch |
| 5 | Lifecycle ordering | `run_start`→…→one `run_terminal` |
| 6 | End-only tool_end cancelled/steered | no fake `tool_start` card |
| 7 | Hard mid-call gap | start without end + truthful terminal |
| 8 | Permission fail-closed | EOF/render/read/null ctx → deny; missing AskFn ≠ allow |
| 9 | Permission rendezvous concurrency | single slot; worker wait; UI decide; no worker stdin |
| 10 | Worker busy controls | Alt+S/F from UI thread; root submit locked; single-flight |
| 11 | Callback/UI concurrency | no TTY I/O in callback; short lock publish; wake; no deadlock |
| 12 | Host close + blocked provider | closing chrome; deny modal; cancel; wait; **no** silent unbounded wait; SIGINT escape |
| 13 | Join/deinit order | no clear/deinit before join; after join idle clear ok |
| 14 | Session create/resume only | `create_new`/`resume_existing`; **no** product `open_or_create`; no false resumed |
| 15 | Configured secret in **every** lifecycle/observer arbitrary field | rendered output contains marker / redacted form; **never** raw secret |
| 16 | Redaction OOM | fixed `redaction_failed`; no raw fallback |
| 17 | Missing redactor / null ask_ctx | `redaction_unavailable` / deny; no `redactOptional(null)` path |
| 18 | Exact trunc cap | body/title ≤ cap; ends with exact `...[truncated]` when truncated |
| 19 | Full ring + simultaneous terminal + OOM/drop | terminal reserve retained; drop note non-recursive; saturating count |
| 20 | TUI ask hunk null | `review_unavailable`; never InteractiveHunkReviewer/stdin |
| 21 | TUI yolo AutoAccept | no interactive review; jail/shell still apply |
| 22 | Non-TTY stdin or stdout | exit **2**, stdout empty, fixed stderr |
| 23 | Mode matrix | tui+json/stream/doctor/prompt/verbose → exit **2**; help+tui → 0 no TUI init |
| 24 | Geometry &lt; 20×5 | exit **1** before raw |
| 25 | Session.start fail | exit **1** before raw; generic/redacted stderr |
| 26 | Ctrl+C | idle 0; active cancel; second 130; hard path **no false restore claim** |
| 27 | Cooperative restore | clean/closing-after-join restores tty |
| 28 | plain + headless std **and** curl | unchanged green |
| 29 | Docs/diff | contract consistency |

## 12. Non-goals

- Theme platform, dashboard, images, cost explorer
- Plugin / extension UI host (E2/E3 view trees)
- RPC / ACP / editor protocol
- OS sandbox / process-tree preemption
- Multi-file edit transactions; Core/session-v1/Trace-v1/headless-v1 schema edits
- Maturity raises (any row), including Tools write/edit L3 and Runtime Extensions &gt; L0
- Pi TUI API parity or **wholesale vaxis port**
- Persisting editor history or new UI schema
- Token-delta lifecycle invention
- `open_or_create` product chrome / host-tracked branch lies
- `zag-cli/src/tui` alternate package owner
- This contract node adding packages, deps, or product code

## 13. Contract-node acceptance (docs only)

- [x] Binding module authored (`docs/modules/tui-minimal.md`)
- [x] Task file authored (`docs/plan/tasks/tui-minimal-001.md`)
- [x] Round-1 architecture + safety **BLOCKED** findings addressed in this freeze
- [ ] Independent architecture/ownership **re-review** PASS
- [ ] Independent safety/fail-closed **re-review** PASS
- [ ] Docs lint + score + `git diff --check` green on candidate
- [ ] **No** C9 product implementation acceptance checked off as done
- [ ] **No** maturity row raise; **no** “TUI implemented” claim

## Related

- [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
- [C9 product shell](../phases/C9-product-shell.md)
- [harness-events](./harness-events.md) · [harness-steering](./harness-steering.md)
- [cli-interaction](./cli-interaction.md) · [headless-contract](./headless-contract.md)
- [permissions](./permissions.md) · [sdk-contract](./sdk-contract.md)
