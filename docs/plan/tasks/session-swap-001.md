---
id: session-swap-001
scope: tui/session-swap
status: implemented
priority: P1
depends-on:
  - session-resume-tui-001
---

# objective

Make a `/resume`-selected session the ACTIVE session: after replay the
user can send a message and it appends to the replayed session (real
"continue"), not the original one. Currently the active Session is bound
at TUI start and cannot be swapped (session-resume-tui-001 v1 was
read-only replay browsing for exactly this reason).

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented** — reviews absorbed; contract text is authoritative |
| Implementation | **done** — see commit line at the bottom |
| Session v1 schema | unchanged (read + append only; no schema change) |
| Trace v1 / headless / CLI `-c` | unchanged |

# implementation log

- `agent.zig`: `SessionStartOptions.cwd` (defaults to `Io.Dir.cwd()`;
  backward compatible) — the swap resolves the newly selected session
  against the same root the resume overlay listed (tests point it at a
  tmp dir). All five `Session.start` session-store/project callsites use
  it.
- `cards.zig`: `CardRing.clear()` — resets every slot (ordinary FIFO +
  terminal/host-error/drop-note reserves) and all counters so a swapped-in
  session's replay never concatenates with the previous session's cards +
  fixture.
- `app.zig`: `BindSessionOpts` captured at `bind` (base_system /
  load_project / Agent redactor / skills+template flags); `swapSession(path)`
  idle-only guard (`!worker_active and state == .idle`; busy → note
  `resume_busy` + no-op), sequence: old.save() → Session.start(new,
  resume_existing, bind-captured opts) → heap-move (fail-closed on start
  errors; old untouched) → old.deinit()+gpa.destroy(old) → session/redactor
  re-point → setIdentity refresh + session_configured_ui reset → card-ring
  clear → replay the new session's live transcript → swap-specific note
  (`resume_swapped`; `resume_swapped_ephemeral` surfaces the lost
  conversation for writer==null sources). `/resume` selection wiring:
  non-active → swap + replay; active → replay only (no-op swap).
  `App.destroy` deinits + destroys the CURRENT session exactly once (after
  Agent.deinit; session state is session-owned). 10 app-level fixtures:
  swap sequence + lock release + new-lock-held + round-trip append, busy
  guard, external-lock fail-closed (old usable), save-failure abort,
  swap-back ownership, redactor re-point + replay redaction, config-parity,
  active-selection replay-only, ephemeral note. Existing resume fixtures
  converted to the swap world (bound heap sessions; byte-preservation test
  re-scoped to the swap's replay-not-write property).
- `tui_entry.zig`: the INITIAL session is heap-allocated and handed to App
  (bind owns it); stack slot + teardown deinit removed; early-error paths
  deinit+destroy exactly once; `RunResult.session_deinited` now false
  (App.destroy owns session teardown) + doc comment; cli.zig teardown-order
  comments updated.
- `tui_process_fixture.zig`: `gate33_pty_resume_swap_continue_appends_to_
  selected_session` — real binary: /resume → select the only listed session
  → swap+replay marker → send → reply appends to the SELECTED session file
  (bounded file poll proves both halves + mock reply). Uses the headless
  mock (the slow mock's full-response path was never exercised by any test;
  it fails pre-existing with the std client — noted, not in scope).
  build.zig passes `headless_mock_bin` to the fixture opts.
- Verified: all 4 matrices green — `zig build test` 805/805;
  `-Dhttp_backend=curl` 804/804; `-Dtui=true` 1024/1025 (1 skip) incl.
  PTY 14/14; `-Dtui=true -Dhttp_backend=curl` 1023/1024 (1 skip) incl.
  PTY 14/14. PTY markers (`state:{s}` contiguous, 1049h/l, ISIG)
  unchanged.

commit: 89ffda6 "zag-tui: /resume selection swaps the active session (real continue) (session-swap-001)"

# context

Recon facts (all verified):
- `Agent.reply(self, session: *Session, user_text)` takes the session
  PER CALL — Agent has no session field, so swapping is App-layer only
  (agent.zig:154,1597).
- `Session.start(gpa, io, opts)` (agent.zig:190) — non-blocking exclusive
  lock on `{path}.lock`; `WouldBlock` → `error.SessionBusy`; lock is
  released ONLY by `Session.deinit` (agent.zig:428-437); no separate
  close API.
- App binds `agent/session/redactor/host` (app.zig:83-86, bind 330-342);
  `dispatchReply` captures `self.session` at dispatch (1465-1466) and
  spawns `workerMain(self, agent, session)` → `agent.reply(session, ...)`
  (1517,1535). Swap must happen with `worker_active == false`.
- Session owns a CLONED redactor (agent.zig:174,229-237;
  `activeRedactor()` 469-472); App.redactor must re-point on swap.
- tui_entry.zig:113-154 creates a stack-local Session and deinits it at
  teardown (171) — swap ownership must be reworked.

# path

| Path | Role |
|------|------|
| `packages/zag-tui/src/app.zig` | `swapSession(path)` (idle-only); `/resume` selection gains "continue" semantics (Enter on a listed session = swap + replay); session_configured_ui + setIdentity refresh; teardown deinits the CURRENT session (ownership moved from tui_entry) |
| `packages/zag-cli/src/tui_entry.zig` | session ownership moves into App: create via App (or hand off); teardown stops deiniting the session it created |
| Forbidden | Session schema, session_store write-path changes, Trace/headless, worker-active swap |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Trigger | `/resume` overlay selection of a NON-active session → swap + replay; selecting the ACTIVE session → replay only (no-op swap); after swap, sending appends to the new session; post-swap note uses a swap-specific label (not resume_active) |
| Guard | swap allowed only when `!worker_active and state == .idle`; busy → note "resume_busy" + no-op (never mid-run) |
| Swap sequence | (1) `old.save()` (save error → abort, stay on old); (2) `Session.start(gpa, io, opts)` on the NEW path FIRST — `SessionBusy`/missing/OOM → abort with old untouched (fail-closed reachable; the two leases briefly coexist — per-path locks, agent.zig:268); (3) heap-allocate + move the new Session (errdefer deinit+destroy on later failure); (4) `old.deinit()` + `gpa.destroy(old)` (lock released; pairing per ownership row); (5) `app.session = new`; `app.redactor = new.activeRedactor()` (Agent.activeRedactor source, agent.zig:1317-1319); (6) `setIdentity` refresh + `session_configured_ui` reset; (7) **card-ring reset** (new clear API) then replay the new session's transcript (from-active live branch) |
| Ownership | App owns the CURRENT session from bind time — the INITIAL session is heap-allocated too (gpa.create; Session.start returns by value, movable while idle); `App.destroy` deinits AND `gpa.destroy`s `self.session` exactly once when non-null (after Agent.deinit; session state is session-owned); tui_entry's stack slot + teardown deinit REMOVED (early-error paths 137/159 deinit+destroy; bind failure leaves app.session null); swap deinits AND destroys the old exactly once; RunResult.session_deinited semantics updated in cli.zig:585 + comment |
| Redaction | redactor re-pointed to the new session's cloned redactor BEFORE any replay publish; the new session's redactor comes from Agent.activeRedactor (may be null → empty policy → replay bodies carry the redaction-unavailable marker until the first reply binds one — same as initial bind; documented, fixture: config-parity incl. base_system/redactor/skills flags captured at bind and forwarded to the new Session.start opts) |
| Multi-session | two sessions briefly coexist during the swap (old + new, distinct path locks); after the swap only the new one is open |
| Fail-closed | save/start errors abort the swap BEFORE the old session is touched; old stays active and the next turn works; start succeeds but a later step fails → new session deinit+destroy, old already destroyed is the documented boundary (sequence order makes this unreachable except OOM after start); notes surfaced; never crash. Fixture: start-failure → old usable (next turn appends to old) |
| Non-goals | session tree/fork, deletion, partial swap, swap while busy, multi-session tabs, control-queue migration (queued steering/follow-up are process-memory and dropped on swap — surfaced by note), ephemeral-source swap (writer==null loses the conversation — note surfaced) |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Swap sequence | save → deinit (lock released) → start(resume_existing) → active; the selected path is now writable (a new turn appends to it; round-trip save/load preserves both halves) |
| Guard | worker_active → swap rejected; idle → OK |
| Lock | old lock released (a second Session.start on the old path succeeds); new lock held; SessionBusy on an externally-locked path → fail-closed |
| Ownership | no double-deinit at teardown after a swap (testing.allocator clean); swap-then-swap-back works |
| Redaction | new session's redactor applied to subsequent cards (secrets marker differs by redactor instance — assert via a secret pattern present in one session, absent in the other) |
| PTY | real binary: /resume → select another session → send → reply appends to it (marker in the session file) |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Session tree/navigation, fork, deletion
- Parallel sessions
- Schema changes

# related

- [session-resume-tui-001](./session-resume-tui-001.md)
