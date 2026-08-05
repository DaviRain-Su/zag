---
id: tui-vaxis-001
scope: tui/vaxis-backend
status: contract-draft
priority: P1
depends-on:
  - tui-minimal-001
  - tui-streaming-001
  - tui-layout-001
---

# objective

Replace zag-tui's hand-rolled terminal backend with **vaxis as a
quarantined terminal library** (the contract-sanctioned form:
tui-minimal.md:118 "Terminal library: implementation detail, not
contract-visible API. Must be quarantined inside `zag-tui`, lazy/optional"
— and its explicit boundary "**No wholesale vaxis port**"). Concretely:
raw termios/alt-screen/size → vaxis `Tty`/`Vaxis`; ANSI string frames →
vaxis `Screen`/`Window` cell rendering (double-buffered diff, borders,
styles, colors); hand-rolled key decoding → vaxis `Key` parsing. All
product state and logic stays: app.zig state machine, card ring,
editor.zig + history, layout.zig geometry, streaming slice, permission
modal, wake-pipe mechanism, SignalHost port. vxfw/widgets/Image/Mouse are
OUT of scope (wholesale-port boundary).

**Binding specification:** [tui-vaxis.md](../../modules/tui-vaxis.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent architecture + safety re-reviews |
| Implementation | not started |
| Maturity | **unchanged** — no row add/raise |
| tui-minimal-001 / tui-streaming-001 / tui-layout-001 behavioral contracts | **unchanged** — PTY fixture markers, state machine, Guard Ctrl+C path, streaming, geometry all survive |
| Session v1 / Trace v1 / headless-v1 / Core / coding-agent | **unchanged** by contract law (zag-tui-only slice) |

# context

- zag-tui today: terminal.zig (raw termios + ANSI alt-screen, wake pipe),
  keys.zig (hand-rolled decoder, no UTF-8 assembly), render.zig (ANSI
  string frames, 16KB buffer), layout.zig (pure geometry, just landed),
  app.zig (3-fd poll loop: STDIN/wake_r/host, dirty-flag presenter).
- vaxis 0.6.0 (MIT, vendored at pi-mono-zig/zig/vendor/vaxis): std.Io-era,
  zig 0.16-verified by a real consumer (pi-mono-zig builds TUIs with it);
  Window/Screen/Cell (child windows with borders, printSegment with
  grapheme wrap, Cell.Style fg/bg/attributes), Vaxis.render diff
  double-buffer, Loop with custom Event unions + thread-safe
  postEvent/nextEvent, Key with codepoint/mods/matches. Deps zigimg +
  uucode are hard imports but already in the local zig cache (offline
  resolution); vaxis LICENSE is MIT.
- Key recon facts: vaxis `Loop` owns only its tty fd (no pollable event
  fd) → the app's poll set must shrink to [wake_r, host] with a bridge
  thread draining `loop.nextEvent()` into a ring + `wakeWrite(wake_w)`;
  vaxis `makeRaw` clears ISIG (tty.zig:161) while zag-tui deliberately
  keeps ISIG ON for the Guard Ctrl+C path (terminal.zig:46) → ISIG must be
  re-enabled after `Tty.init`; PTY fixtures grep for `state:{s}`,
  `\x1b[?1049h/l`, geometry diagnostics, and raw termios incl. ISIG
  (tui_process_fixture.zig:37-42,674-695).

# path

| Path | Role |
|------|------|
| `packages/third_party/vaxis/` | vendored vaxis 0.6.0 (MIT, source = pi-mono-zig vendored copy, provenance note) |
| `packages/zag-tui/src/terminal.zig` | slim backend: Tty+Vaxis init, alt screen, size(), ISIG re-enable shim, restore, wake-pipe fns (kept), `windowSize` for tui_entry.zig |
| `packages/zag-tui/src/keys.zig` | replaced by vaxis Key + a small `mapKey` translation (file may be deleted; gate2 list updated) |
| `packages/zag-tui/src/render.zig` | vaxis cell renderer: layout.zig geometry → `root.child()` windows; borders/colors; `state:{s}` text preserved; `vx.render()` diff |
| `packages/zag-tui/src/app.zig` | poll set [wake_r, host]; bridge-thread event ring drained in the wake_r branch; handleKey remap; winsize → `vx.resize` + dirty |
| `packages/zag-tui/build.zig` + `build.zig.zon` + root `build.zig.zon` | vaxis dep wiring (path dep; zigimg/uucode resolve from cache) |
| `packages/zag-tui/src/tests_gate.zig` | gate2 import scan updated; terminal Size keeps `isBelowMinimum`/`isConstrained` (relocated if needed) |
| Forbidden | zag-agent-core, zag-coding-agent, zag-cli production logic, Session v1, Trace v1, chapters |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Quarantine boundary | vaxis touches ONLY terminal.zig/keys.zig/render.zig + build wiring; app.zig state machine, cards.zig, editor.zig, layout.zig, present.zig, permission.zig, signal_host.zig, streaming, wake pipe, dirty presenter ALL unchanged in behavior; **no vxfw/widgets/Image/Mouse/kitty-keyboard in v1** |
| Vendoring | `packages/third_party/vaxis` = MIT vendored copy (exact source: pi-mono-zig zig/vendor/vaxis @ its checkout, provenance note in THIRD-PARTY style) **with ONE documented vendored patch**: a fd-based `Tty` init path (`makeRaw` on the provided in_fd, writer over out_fd) — vaxis hard-codes `/dev/tty` (tty.zig:57-59) which breaks the PTY fixture's fork+dup2(slave→0/1/2) spawn (no controlling tty by design, macOS NOTTY); the patch is quarantined inside `packages/third_party/vaxis` and recorded in the Vendoring row; Screen/Loop/Key stay stock vaxis |
| fd adapter | the backend uses the patched fd-based Tty (open over STDIN/STDOUT as today); PTY fixture spawn unchanged (dup2 slave→0/1/2); gate32 termios assertions stay on the pty slave device |
| ISIG shim | after Tty init, re-enable ISIG via tcsetattr (Guard Ctrl+C → SIGINT → host wake fd path MUST be byte-identical; tui_process_fixture.zig:692 asserts ISIG restored equal) |
| Size gate ordering | the below-minimum size check (vaxis-free `windowSize`) runs BEFORE `Terminal.open()` in app.run (gate30 "exit 1 before raw/alt/thread" — app.zig:427-440 order flipped); open()'s internal makeRaw is a side effect that must not precede a fail-closed exit |
| Size placement | `Size`/`isBelowMinimum`/`isConstrained`/`windowSize` live in a **vaxis-free module** (new `size.zig` or constants.zig) so zag-cli (tui_entry.zig:172) and app.zig import them WITHOUT pulling vaxis (quarantine boundary) |
| Initial resize | `Terminal.open()` performs an initial `vx.resize(term.size())` (the vaxis screen starts 0x0; first paint must render into real dims — idempotent with the loop's initial winsize event) |
| paint reconciliation | paint's size-recheck RECONCILES: when the re-read size differs from vx screen dims, call `vx.resize` (detect-only would strand rendering on a stale screen after a dropped/late winsize event) |
| Bridge thread teardown | pinned restore() protocol: (1) set quit flag → (2) `loop.postEvent(quit_sentinel)` to wake the blocked `nextEvent` (sentinel dropped in the app ring drain, never mapped to a key) → (3) join bridge thread → (4) `loop.stop()` (internal read thread) → (5) `vx.deinit` → (6) `tty.deinit`; this order completes BEFORE `App.destroy` frees the ring |
| Event loop | app poll set becomes `[wake_r, host.wakeFd()]` (stdin removed — vaxis's internal thread owns the tty); a bridge thread in the backend runs `loop.nextEvent()` → pushes into a small ring → `wakeWrite(wake_w)`; app's wake_r branch drains the ring and marks dirty; poll_timeout_ms=250 unchanged |
| Key mapping | `mapKey(vaxis.Key) -> AppKey` covering: enter/escape/backspace/delete/arrows (vaxis codepoints), alt+enter (multiline), alt+s/alt+f (mods), ctrl+j; UTF-8 codepoints → multi-byte insert into editor (fixes today's byte-by-byte UTF-8 insert); ctrl_c/ctrl_d mapped from codepoint (defensive — ISIG on means SIGINT normally handles ctrl_c) |
| Rendering | layout.zig `Region` → `root.child(.{ .x_off = x, .y_off = y, .width = w, .height = h })`; modal gets `border` (rounded) + style; header/status get style/color; truncation rules from tui-layout-001 (utf8Prefix min-caps) preserved; `state:{s}` string present in the header cells (PTY grep contract); `vx.render()` diff replaces full-frame ANSI |
| Size | `term.size()` thin wrapper over vaxis dims; `Size`/`isBelowMinimum`/`isConstrained` survive (tui_entry.zig:172 + app.zig gate depend on them); winsize events → `vx.resize` + dirty (size-recheck in paint kept as belt-and-braces) |
| Tests | render fixtures move to offscreen `vaxis.Screen` cell snapshots (pi-mono-zig pattern); RecordingTerm/RecTerm byte-drain → cell-diff assertions; PTY process fixture markers unchanged; gate2 import list updated |
| Divergence from reference | no vxfw component tree, no widgets (TextInput is single-line, unsuitable — editor.zig stays), no images/mouse in v1, no kitty-keyboard mode in v1 |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| ISIG | after backend init, termios ISIG == true; restore returns original termios (fixture via pipe/fake? — PTY fixture covers e2e; unit: tcgetattr check if a tty is available, else skip-marked) |
| fd adapter | PTY fixture spawn unchanged (fork+dup2, no controlling tty); backend opens over STDIN/STDOUT fds via the patched Tty; gate32 termios assertions on the pty slave device pass |
| Size gate | below-minimum check (vaxis-free) before Terminal.open: fixture asserts exit 1 BEFORE any raw/alt-screen/thread (1049h absent) |
| Initial resize | first paint renders into real dims (open() pre-resizes); belt-and-braces: paint reconciles (re-read size ≠ screen dims → vx.resize) |
| Bridge teardown | restore() protocol: quit → postEvent(sentinel) → join bridge → loop.stop() → vx.deinit → tty.deinit, before App.destroy; no hang on exit (gate32 waitExit), no use-after-free |
| Event ring | bridge thread pushes events; app drains in order; wake fires per event; quit sentinel never mapped to a key |
| Key mapping | vaxis Key → AppKey table: enter/escape/arrows/alt-enter/alt-s/alt-f/ctrl-j/backspace/delete; UTF-8 multibyte (e.g. "你") inserts as one codepoint not byte-by-byte |
| winsize | resize event → vx.resize + dirty + repaint with new geometry (layout recompute) |
| Render parity | offscreen Screen snapshot: full-mode frame cells match the pre-vaxis ANSI layout (same rows/columns content, same `state:{s}` cell text); constrained-mode equivalent; modal border cells present; truncation min-caps hold |
| PTY markers | tui_process_fixture green unchanged: `state:idle/busy/closing`, `\x1b[?1049h/l`, geometry diag, ISIG restored, `stop=completed` absence |
| Streaming | delta accumulation still paints (bridge ring + dirty); card identity rules intact |
| Regression | existing TUI matrix green (gates 3/4/6/7/8/11/12/13/15/16/19/21/26/27/31 untouched); default + curl matrices; SDK fixture |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (default +
  TUI matrices, std + curl); **no** maturity raise; **no** remote `-Dtui`
  claim.

# non-goals

- vxfw widget tree / component system adoption
- vaxis widgets (TextInput etc.) as product components
- Images (kitty), mouse support, kitty-keyboard protocol, clipboard
- Changing the Guard Ctrl+C / ISIG semantics
- Changing app.zig state machine, cards, editor, layout, streaming behavior
- Session v1 / Trace v1 / headless-v1 changes
- Maturity raise

# related

- [tui-vaxis.md](../../modules/tui-vaxis.md) (binding)
- [tui-minimal-001](./tui-minimal-001.md) (frozen contract + :118 authorization)
- [tui-streaming-001](./tui-streaming-001.md) · [tui-layout-001](./tui-layout-001.md)
- [C9-product-shell.md](../../phases/C9-product-shell.md) (:162 wholesale-port non-goal)
- Reference consumer: pi-mono-zig zig/src/tui/terminal.zig:309-404 (proven vaxis 0.6.0 pattern)
