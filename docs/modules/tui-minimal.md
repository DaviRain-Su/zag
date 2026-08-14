---
status: done
scope: minimal host TUI binding contract (PASS) + implementation closed
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
`zag-cli` surfaces. The behavioral freezes below are **stable contract text**
and are not weakened by delivery. Closing the minimal slice does **not** raise
any maturity row and does **not** imply Theme implementation/RPC/ACP/extension-UI/dashboard
or Pi TUI parity. Theme has a separate docs candidate:
[theme.md](./theme.md) / [theme-001](../plan/tasks/theme-001.md)
(**contract PASS** @ `9e1b9f9`; `status: ready`; dual re-reviews zero blockers;
**no** implementation).

**Contract freeze PASS** at tip
`c7a8f3a23eb2b66febdd24a891ba55ee7fd09a11` after independent
**architecture/ownership** and **safety/fail-closed** final re-reviews
(**zero blockers**; A1–A11 and B-S1–B-S10 closed). Lineage: initial freeze
`d01d70b` → blocker close `a38f0ec` → signal-host order `6c73e46` → teardown
order `c7a8f3a` (contract PASS tip).

**Implementation closed** at tip
`f8f7f55014a01ce4d6cf3ad7b751c8f6f0aa30b5` (`packages/zag-tui/`, lazy `-Dtui`
CLI wire, §11 unit/integration/PTY fixtures). Two independent final code
reviews **PASS** (**zero blockers**). Local ff-only merge to canonical main at
the same tip; task-worktree and merged-main Gates green on **local macOS only**.
Local remote-tracking reflog records an external/other push of implementation
tip `f8f7f55` to `origin/main`; this closeout did not execute or authorize that
push. The TUI docs closeout chain through historical tip
`b1513073190089bd2dc2473a466373c8a1702f1f` (now **OLD_TARGET** on the post-TUI
remote Gate) was **local-only at TUI closeout time** and is a later ancestor of
supplied Class C / observed TARGET `f352b60` (historical lineage only — **not**
Phase B live remote evidence; **not** a claim this closeout pushed). Remote
branch presence is not a Linux/remote Gate. Post-TUI **default-path** remote
dual-backend evidence is owned by
[post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md)
(**in-progress**, Phase A; TARGET `f352b60`; Class C rebind review PASS @
`7f9cfa4`; **no** run id; **no** push; **no** Phase B grant; Gate green **No**;
**no** remote `-Dtui` claim — current CI has no TUI step; PTY remains local
macOS only). Defaults remain ask + workspace jail + shell protect; `-Dtui`
default **false**/lazy. See [task](../plan/tasks/tui-minimal-001.md).

Merged C9 follow-ons preserve this contract: [TUI streaming](./tui-streaming.md)
landed at `2d57e84` (default provider streaming into progressive assistant
cards) and [TUI layout](./tui-layout.md) landed at `189de9e` (pure layout plus
dirty-flag presenter). Neither changes Session/Trace/headless wire contracts or
raises maturity. The Vaxis backend remains separate uncommitted work and is
not claimed by this module. Theme implementation candidate `ff509a6` is also
unmerged; its standalone audit does not change `main` status and it must be
adapted and re-gated after the Vaxis backend stabilizes.

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
| **`zag-tui` only** | terminal channel, layout, focus/layering, editor buffer, in-process history, card ring, permission modal UI, host-owned preallocated buffers, reply-worker rendezvous, **defines** product-internal `SignalHost` port type | Agent private fields, Loop, Transcript mutation, Trace schema, permission risk classification, session schema, headless envelopes, process SIGINT install, **import of `zag-cli` / `sigint.zig` / CLI Guard type** |
| `zag-cli` | flag parse, mode mutex, **installs** CLI `sigint.Guard`, **implements** `SignalHost` wrapping Guard, process exit, plain/headless; **assembles/imports `zag-tui` only when `-Dtui=true`** | inventing lifecycle facts; silent mode fallback; owning TUI widgets under `zag-cli/src/tui` |
| `zag-coding-agent` | product policy, Session, Trace, lifecycle adapter, edit/review, Gate | terminal widgets, focus, raw TUI input, any TUI import, SignalHost |
| `zag-agent-core` | thin loop + ports | any TUI / CLI / terminal / SignalHost import |

**Forbidden shape (removed):** `packages/zag-cli/src/tui/**` as an alternate
TUI owner. Product TUI code lives **only** under `packages/zag-tui/`.

**Dependency direction (unique):**

```text
zag-cli  ──imports──►  zag-tui
zag-cli  ──implements SignalHost callbacks wrapping sigint.Guard──►  zag-tui App
zag-tui  ──must not──►  zag-cli / packages/zag-cli/src/sigint.zig
```

`SignalHost` is product-internal (CLI ↔ TUI only). It must **not** enter
Core or coding-agent.

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
- `Session.activeRedactor` (must be non-null before first worker; §7.3)
- `LifecycleObserver` + `LifecycleEvent` (`lifecycle.zig`)
- `Observer` + `Event` (`observer.zig`) — optional progressive text only
- `permissions.Gate` / `AskFn` / `Mode` / `SessionKind` / remember policy
- Product-internal **`SignalHost`** port **defined by `zag-tui`**,
  **constructed/implemented by `zag-cli`** over the existing `sigint.Guard`
  ([cli-interaction](./cli-interaction.md)) — see §1.4

**Forbidden:** reading `Agent` private fields, Core private loop state,
`Transcript` internals for UI cards, Trace file as live UI truth, any private
memory peek that is not a public callback or public method, or
`@import("zag-cli")` / `@import` of `sigint.zig` from `zag-tui`.

### 1.4 `SignalHost` port (product-internal; CLI implements)

`zag-tui` **defines** a narrow host port. Exact Zig shape is implementation
detail as long as it is a **borrowed `ptr` + vtable** (or equivalent concrete
struct of function pointers) with at least:

| Method | Role |
|--------|------|
| `wake_readiness` / poll integration | expose the CLI Guard **self-pipe read end** (or equivalent readiness) so the UI thread can poll it **with** the app callback-wake pipe; TUI **drains** via host adapter; **does not** install a second SIGINT handler |
| `pending_interrupt` (optional but required if UI shows pending chrome) | query whether Guard state is `pending` (maps to `Guard.pendingInterrupt`) |
| `acknowledge_cancel` | maps to `Guard.acknowledgeCancel` — reset Guard `pending` → `idle` after a run consumed the interrupt |

Rules:

1. **CLI constructs** the port wrapping the live `sigint.Guard` after
   `Guard.install(&agent.cancel)` succeeds (§7.3).
2. Port, Guard, and `Agent` lifetimes last until worker join and TUI exit;
   address-stable while TUI is entered.
3. Port callbacks: **no allocation**, **no render**, **no read of user/model
   content**, async-signal-safe where they touch Guard state.
4. TUI may request cooperative cancel by setting the **Agent cancel flag**
   already bound into Guard at install (programmatic close). TUI **must not**
   forge Guard `pending` / second-interrupt / `escaped` state.
5. **Missing `SignalHost`:** TUI **must not start** — fixed stderr, exit **1**.
   Not a silent degrade to unprotected input.
6. `SignalHost` is **not** a Core/coding-agent seam and is **not** public SDK.

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
2. `Agent`, `Session`, `TuiPermissionAdapter`, `SignalHost`, and all shared
   host slots are allocated and **address-stable** before the worker starts
   (full order §7.3).
3. Until the UI thread **joins** the worker, no thread may move/deinit/clear
   `Agent` / `Session` / adapter / Guard / SignalHost / preallocated rings.
4. After every worker join (success **or** error), before returning to
   `idle` / next root submit: UI/CLI **must** call
   `SignalHost.acknowledge_cancel` once (§2.5). Then idle-only
   `clearControlQueues` if needed.
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
   with **drop-on-full**). Never block the worker forever on a full wake
   queue. Drop is allowed because the pipe remains **readable** if any byte
   was written earlier, and the UI loop also uses a **bounded poll timeout**
   (§2.2.1).

#### 2.2.1 UI thread event loop (wake + timeout)

UI thread poll set includes at least: stdin, **app callback-wake** fd, and
**SignalHost** Guard self-pipe readiness (via port; not a second handler).

| Rule | Binding |
|------|---------|
| Callback wake write full | **drop** the write; do not block worker; do not allocate |
| Poll timeout | **≤ 250 ms** (same order as existing CLI interruptible-read polling) so lost/coalesced wakes cannot leave terminal cards or permission modals unrendered for unbounded time |
| After wake or timeout | drain wake (and SignalHost drain adapter if needed) → snapshot cards under short lock → render outside lock; if permission slot pending, show modal even when wake was dropped |
| Permission pending + wake pipe full | still observed via **readable residual** and/or **timeout** path |

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
| TUI entry | CLI must successfully `Guard.install(&agent.cancel)` **after** `Agent.init` and **before** raw mode / worker (§7.3); install failure → fixed stderr, exit **1**, no TUI. One-shot Guard: **no** reinstall attempt on later Session fail |
| Missing SignalHost | exit **1** before raw; no degrade |
| Busy close / host fatal | set `closing=true`; **deny** any pending permission slot and signal; request cooperative cancel via **Agent cancel flag** (already Guard-bound); enter **visible waiting** (`closing`); keep two-phase Ctrl+C escape via Guard state (not forged by TUI) |
| Wait honesty | UI waits for worker join. **std HTTP backend may block** in DNS/connect/TLS/response-head; there is **no** automatic graceful host timeout. Documented as **user-visible wait** + second Ctrl+C hard escape `130`. **Forbidden:** “silent unbounded wait” without visible closing chrome |
| After worker ends (multi-run) | join → §2.5 ack → `idle` (App/Agent/Session/Guard stay live for next run) |
| Final TUI exit / installed-Guard failure | **only** §2.6 teardown order — never free Agent before Guard unbind/drain |
| Success invent | **forbidden** — no completed chrome on close/fatal |

### 2.5 Guard acknowledge after every worker join

After **each** reply worker finishes (lifecycle success **or** reply error)
and the UI thread has **joined** it, **before** `state=idle` and before the
next root submit / next run:

1. Call **`SignalHost.acknowledge_cancel`** exactly once (CLI maps to
   `Guard.acknowledgeCancel`).
2. This resets Guard **`pending` → `idle`** so the **next** first Ctrl+C is
   cooperative again, not a mistaken second-interrupt hard `130`.
3. Also required after reply-error paths that never emit a pretty terminal.
4. **Do not confuse** with Agent cancel-flag cleanup: the Agent clears its
   own cancel flag on reply completion (existing product behavior). Guard
   pending state is **independent** and **must** be acknowledged via
   SignalHost. Programmatic cancel must not forge Guard pending.

### 2.6 Final / failure teardown order (unique; A11 / B-S10)

Applies only when **no reply worker is running** (joined or never started)
and **no** Lifecycle/Observer/`AskFn` callback can re-enter. Source-aligned
with `sigint.Guard.deinit`: disable → atomic unbind `agent.cancel` → restore
prior `sigaction` → drain in-flight → then release Agent storage.

#### 2.6.1 Final cooperative / normal TUI exit (Guard was installed)

Exact order — **no OR**, **no** “App/Session/Agent then Guard”:

```text
1. SignalHost.acknowledge_cancel          // success and error workers already did this
                                            // on multi-run; still once more if pending
                                            // on final exit before Guard.deinit
2. Restore tty / leave raw / alt-screen     // MUST on cooperative/normal paths after join
3. App → quiesced / detach                  // forbid further SignalHost calls, workers,
                                            // callbacks; DO NOT free App storage yet
                                            // (Agent.Options still holds adapter/lifecycle
                                            //  ptrs into App until Agent.deinit)
4. Guard.deinit + CLI SignalHost adapter teardown
     - disable handler state
     - atomic unbind agent.cancel flag pointer
     - restore prior sigaction
     - drain in-flight handler entries to 0
     - release Guard ownership (one-shot latch stays set — no reinstall)
5. Session.deinit                           // idle-only; ONLY after Guard.deinit
6. Agent.deinit                             // frees cancel flag storage AFTER unbind+drain
7. App.deinit / free last                   // adapter storage last
```

**Why Session after Guard (unique):** Guard may still be draining handlers that
loaded the bound `agent.cancel` address. Session does not own that flag, but
teardown must keep **all** Agent-owned storage (including cancel) alive until
step 4 completes. Freeing Session first is allowed **only** after step 4;
the frozen order places Session at step 5 so no alternate “Session before
Guard” path exists.

#### 2.6.2 Failure paths after Guard.install succeeded

Same Guard-before-Agent rule. Examples:

| Failure | Order |
|---------|-------|
| `Session.start` fails after Guard install | no worker → (skip ack if never pending) → **no** raw enter → `Guard.deinit` → `Agent.deinit` → free App if allocated → exit **1** |
| Missing redactor / SignalHost bind after Session.start | `Session.deinit` **only after** `Guard.deinit`: `Guard.deinit` → `Session.deinit` → `Agent.deinit` → App free → exit **1** |
| Reply error then host exit | join → ack (§2.5) → §2.6.1 full order |
| Success then host exit | join → ack → §2.6.1 full order |

If **Guard.install never succeeded**, omit all Guard/SignalHost steps; deinit
only what was constructed (e.g. Agent then App).

#### 2.6.3 Hard paths (honest)

Second SIGINT `_exit(130)` / kill / panic: **no** promised restore or ordered
deinit (unchanged). Do not claim scrollback wipe or secret zeroization.

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
└─ HostServices          redactor borrow · app wake · SignalHost port (CLI-impl)
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
| empty | no cards | enabled | welcome canvas: title `zag`, optional model/cwd, hint `Ask anything, or type / for commands` |
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

### 7.3 Adapter / signal init order (unique; source-aligned)

`sigint.Guard.install` requires a stable `*CancelFlag` from a live `Agent`.
Order is therefore **Agent before Guard** (not Guard-before-Agent).

```text
1. Preallocate address-stable zag_tui.App + adapters + callback/card/permission
   / app-wake state  — OOM → fixed stderr, exit 1  (no raw mode)
2. CLI Agent.init(gpa, io, provider, .{
     .permission_mode / .permission_gate = Gate.ask(TuiAdapter) | Gate.yolo(),
     .hunk_reviewer = null | AutoAccept,   // §7.2
     .lifecycle / .observer = App callbacks (stable ptrs from step 1),
     ...
   })
3. CLI Guard.install(&agent.cancel)
     - failure → fixed stderr, exit 1; Agent.deinit; App free if needed;
       **no** Guard step (never installed); **no** reinstall attempt
       (one-shot latch — [cli-interaction](./cli-interaction.md))
4. CLI Session.start (create_new | resume_existing | ephemeral only)
     - failure → §2.6.2: Guard.deinit **then** Agent.deinit; exit 1;
       **no** one-shot Guard reinstall
5. Bind into App (still before raw mode):
     - Session-owned non-null activeRedactor() into adapter
     - Agent* / Session* (borrowed for TUI session lifetime)
     - SignalHost port wrapping the live Guard (CLI-implemented)
     - missing redactor or missing SignalHost → §2.6.2:
       Guard.deinit → Session.deinit → Agent.deinit → App free; exit 1
6. Enter raw / alt-screen only after 1–5 succeed
7. On accepted root submit: history push + start single reply worker
8. After every worker join: SignalHost.acknowledge_cancel (§2.5) then idle
9. Final exit: §2.6.1 full teardown (Guard.deinit before Agent.deinit;
   App free last)
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
| First Ctrl+C busy | Guard handler → pending + Agent cancel flag (install-bound) |
| Observed cancel | show truthful `run_terminal` / `cancelled` |
| After join | `SignalHost.acknowledge_cancel` so next first Ctrl+C is not second |
| Second **unacknowledged** Ctrl+C | hard exit **130**; no promised lifecycle terminal; **tty restore not guaranteed** (§9.4) |
| Idle first Ctrl+C | clean exit **0** per cli-interaction |
| Programmatic close cancel | set Agent cancel flag only; **never** forge Guard pending |

TUI must **not** install a second SIGINT handler and must **not** import
CLI Guard types. All Guard ops go through **SignalHost** (§1.4).

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
| Preallocate OOM, Agent init fail, Guard install fail, Session.start fail, missing SignalHost/redactor (before raw), terminal &lt; 20×5 | **1** |
| Runtime init / unrecoverable host after start (non-signal) | **1** |
| Second pending SIGINT | **130** |

Session.start failure: **before** raw mode — fixed redacted/generic stderr
(no absolute secret paths), exit **1**. **Not** “idle with error card”.

Terminal geometry &lt; 20×5: **before** raw mode — fixed stderr, exit **1**.

### 9.4 Tty restore honesty

| Path | Restore raw/alt-screen |
|------|------------------------|
| Clean idle exit, cooperative cancel completed + join, host closing after join | **must** restore tty **after join**, as §2.6.1 step 2 (before Guard/Agent free) |
| Second SIGINT `_exit(130)` / kill / panic | **not guaranteed**; **must not** claim scrollback wipe or secret zeroization |
| Busy renderer fatal | **must** leave alt-screen / restore on recoverable path after join (or best-effort before wait if needed for stderr), fixed stderr explaining cancel/wait/Ctrl+C escape → wait worker join → §2.6.1 → no fake success |

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
| 2 | `-Dtui=true` compile + import scan | `zag-tui` links; core/coding-agent have no TUI import; **`zag-tui` has no `zag-cli` / `sigint` import** |
| 3 | Init order | App prealloc → Agent.init → Guard.install(&agent.cancel) → Session.start → bind redactor/SignalHost → raw; Guard never before Agent |
| 4 | Missing SignalHost | exit **1** before raw; no TUI degrade |
| 5 | Session.start fail after Guard | exit **1**; **Guard.deinit before Agent.deinit**; **no** Guard reinstall |
| 6 | Worker join success **and** error | each path calls `SignalHost.acknowledge_cancel` before idle |
| 7 | Two successive runs | each run’s **first** Ctrl+C is cooperative cancel, not accidental hard **130** (ack between runs) |
| 8 | Wake coalescing / pipe full | drop write ok; ≤250 ms poll timeout still surfaces terminal card + permission modal |
| 8a | Final teardown order (inject/observe) | after join: ack → restore tty → App quiesce (storage kept) → **Guard.deinit unbind+in-flight drain completes** → Session.deinit → Agent.deinit → App free last; prove Agent.cancel storage lives until after Guard drain |
| 8b | Teardown after reply error exit | same §2.6.1 order; App adapter ptrs valid until Agent.deinit |
| 8c | Teardown Session.start / missing SignalHost | Guard.deinit before Session/Agent free; no raw mode |
| 9 | Editor byte/line caps | reject oversize; valid UTF-8 submit |
| 10 | History 64×8 KiB | ring behavior; no durable file; push only on accepted dispatch |
| 11 | Lifecycle ordering | `run_start`→…→one `run_terminal` |
| 12 | End-only tool_end cancelled/steered | no fake `tool_start` card |
| 13 | Hard mid-call gap | start without end + truthful terminal |
| 14 | Permission fail-closed | EOF/render/read/null ctx → deny; missing AskFn ≠ allow |
| 15 | Permission rendezvous concurrency | single slot; worker wait; UI decide; no worker stdin |
| 16 | Worker busy controls | Alt+S/F from UI thread; root submit locked; single-flight |
| 17 | Callback/UI concurrency | no TTY I/O in callback; short lock publish; wake; no deadlock |
| 18 | Host close + blocked provider | closing chrome; deny modal; cancel; wait; **no** silent unbounded wait; SIGINT escape |
| 19 | Join/deinit order | no clear/deinit before join; ack then idle; final §2.6.1 Guard before Agent |
| 20 | Session create/resume only | `create_new`/`resume_existing`; **no** product `open_or_create`; no false resumed |
| 21 | Configured secret in **every** lifecycle/observer arbitrary field | rendered output contains marker / redacted form; **never** raw secret |
| 22 | Redaction OOM | fixed `redaction_failed`; no raw fallback |
| 23 | Missing redactor / null ask_ctx | `redaction_unavailable` / deny; no `redactOptional(null)` path |
| 24 | Exact trunc cap | body/title ≤ cap; ends with exact `...[truncated]` when truncated |
| 25 | Full ring + simultaneous terminal + OOM/drop | terminal reserve retained; drop note non-recursive; saturating count |
| 26 | TUI ask hunk null | `review_unavailable`; never InteractiveHunkReviewer/stdin |
| 27 | TUI yolo AutoAccept | no interactive review; jail/shell still apply |
| 28 | Non-TTY stdin or stdout | exit **2**, stdout empty, fixed stderr |
| 29 | Mode matrix | tui+json/stream/doctor/prompt/verbose → exit **2**; help+tui → 0 no TUI init |
| 30 | Geometry &lt; 20×5 | exit **1** before raw |
| 31 | Ctrl+C | idle 0; active cancel; second unacked 130; hard path **no false restore claim** |
| 32 | Cooperative restore | clean/closing-after-join restores tty |
| 33 | plain + headless std **and** curl | unchanged green |
| 34 | Docs/diff | contract consistency |

## 12. Non-goals

- Theme **implementation** inside this minimal slice (Theme binding is separate:
  [theme.md](./theme.md) / [theme-001](../plan/tasks/theme-001.md) —
  **contract PASS** @ `9e1b9f9`, `status: ready`; no product Theme code claimed here)
- Dashboard, images, cost explorer
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

## 13. Contract-node acceptance (docs only; historical)

- [x] Binding module authored (`docs/modules/tui-minimal.md`)
- [x] Task file authored (`docs/plan/tasks/tui-minimal-001.md`)
- [x] Round-1 architecture + safety **BLOCKED** findings addressed (`a38f0ec`+)
- [x] Independent architecture/ownership **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] Independent safety/fail-closed **re-review** PASS @ `c7a8f3a` (zero blockers)
- [x] Docs lint + score + `git diff --check` green on contract docs path
- [x] Contract freeze did **not** invent product acceptance by itself
- [x] **No** maturity row raise from contract freeze

## 14. Implementation closeout evidence (minimal slice)

Authoritative delivery checklist: [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
and [C9 product acceptance](../phases/C9-product-shell.md#acceptance-for-tui-minimal-001).
Summary only — do not fork Gate numbers elsewhere.

| Fact | Value |
|------|--------|
| Contract PASS tip | `c7a8f3a` |
| Implementation + dual final review tip | `f8f7f55` (zero blockers) |
| Local macOS default std / curl | **42/42 · 656/656** · **44/44 · 655/655** |
| Local macOS TUI std / curl | **47/47 · 711/711** · **49/49 · 710/710** |
| OpenAPI / catalog / docs | **287/287** · **40** · readability **92** / security **74** (55 files) |
| PTY (macOS product path) | geometry; idle Ctrl+C; busy first/second SIGINT; Ctrl+D/termios restore |
| Pollution fix | run-unique exclusive owned workspace for gate21 @ `f8f7f55` |
| Schemas / defaults | Core · session-v1 · Trace-v1 · headless-v1 unchanged; ask + jail + shell protect; `-Dtui` default false |
| Not claimed by TUI closeout | Remote dual-backend Gate for tip `f8f7f55`/docs tips; maturity raise; remote `-Dtui` |
| Theme follow-on | [theme.md](./theme.md) / [theme-001](../plan/tasks/theme-001.md) — **done** (canvas); contract PASS @ `9e1b9f9` was the freeze; **orthogonal** to post-TUI remote Gate |
| `origin/main` | Local reflog: external/other push of `f8f7f55`; TUI docs closeout tips local-only at closeout time through historical `b151307` (OLD_TARGET), later ancestors of observed TARGET `f352b60` (historical Class C lineage only; not Phase B live evidence); this closeout did not push |
| Post-TUI remote Gate | [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) — **in-progress** Phase A; TARGET `f352b60`; Class C rebind review PASS @ `7f9cfa4`; no Phase B grant / run / Gate green; default non-TUI matrix only |

## Related

- [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
- [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) (Phase A in-progress; no remote TUI claim)
- [theme.md](./theme.md) · [theme-001](../plan/tasks/theme-001.md) (**done**; contract PASS @ `9e1b9f9` was the freeze)
- [C9 product shell](../phases/C9-product-shell.md)
- [harness-events](./harness-events.md) · [harness-steering](./harness-steering.md)
- [cli-interaction](./cli-interaction.md) · [headless-contract](./headless-contract.md)
- [permissions](./permissions.md) · [sdk-contract](./sdk-contract.md)
