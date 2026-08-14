# TUI vaxis backend (binding)

> Binding spec for `tui-vaxis-001`
> ([task](../plan/tasks/tui-vaxis-001.md)). vaxis as the **quarantined
> terminal library** inside zag-tui — the contract-sanctioned form
> (tui-minimal.md:118 "Terminal library: implementation detail, not
> contract-visible API. Must be quarantined inside `zag-tui`,
> lazy/optional"; boundary: "**No wholesale vaxis port**").

## 1. Principles

1. **Quarantine**: vaxis is visible only to terminal.zig/keys.zig/
   render.zig + build wiring. Product state and logic (app.zig state
   machine, cards ring, editor, layout geometry, streaming, permission
   modal, wake pipe, SignalHost) are unchanged in behavior.
2. **No wholesale port**: vxfw/widgets/Image/Mouse/kitty-keyboard never
   enter the product. vaxis is a rendering + input-parsing backend.
3. **Contract markers survive**: PTY fixtures grep `state:{s}`,
   `\x1b[?1049h/l`, geometry diagnostics, and raw termios incl. ISIG —
   all byte-identical.
4. **Guard path intact**: ISIG stays ON (Ctrl+C → SIGINT → host wake fd →
   two-phase escape) exactly as today.

## 2. Vendoring

`packages/third_party/vaxis/` = MIT-licensed vendored copy (source:
pi-mono-zig `zig/vendor/vaxis`; provenance note with the source checkout
recorded) **with documented vendored patches**, quarantined in
`packages/third_party/vaxis`:

1. stdin-tty init + `owned_fd` (do not close borrowed stdin; `/dev/tty`
   fallback only). vaxis hard-codes `/dev/tty`, which breaks zag's PTY
   fixture spawn (fork+dup2 slave→0/1/2, deliberately no controlling
   tty, macOS NOTTY).
2. `PosixTty.deinit`: `error.ProcessOrphaned` on `tcsetattr` is retried
   with `TCSANOW` and not logged (Ctrl+C under `zig build run` can race
   the parent off the FG pgroup; EIO is not a leftover-raw failure).

`zigimg` + `uucode` resolve from the local zig cache (already present —
offline resolution).

## 3. Backend (packages/zag-tui/src/terminal.zig)

Keeps its filename and outward shape; internals become a vaxis wrapper
over the **patched fd-based Tty** (STDIN/STDOUT, as today):

- `Terminal.open()` → Tty fd-init → `vaxis.init` → alt screen → **ISIG
  re-enable shim** → **initial `vx.resize(term.size())`** (screen starts
  0x0; first paint must render into real dims) → queries (best-effort) →
  bridge thread start;
- **size gate ordering**: app.run checks the below-minimum size (vaxis-free
  `windowSize`) BEFORE `open()` — a fail-closed exit must never leave raw
  mode/alt screen/a thread behind (gate30);
- `Size`/`isBelowMinimum`/`isConstrained`/`windowSize` live in a
  **vaxis-free module** (zag-cli's tui_entry.zig:172 imports them without
  pulling vaxis);
- `restore()` pinned protocol: quit flag → `loop.postEvent(sentinel)` (wake
  the blocked `nextEvent`; sentinel never maps to a key) → join bridge
  thread → `vx.deinit` → `tty.deinit` (original termios restored; fixture
  asserts ISIG restored equal) → hand the TTY FG pgroup back — completes
  before `App.destroy`. `loop.stop()` is still not called (PTY hang).
  `open()` claims a private FG pgroup when already the FG job so Ctrl+C
  does not also signal `zig build run`; PTY / background jobs skip;
- wake-pipe family unchanged; `windowSize` kept for tui_entry.zig.

## 4. Input (packages/zag-tui/src/keys.zig → mapKey)

Hand-rolled decode is deleted; `mapKey(vaxis.Key) -> AppKey`:

- enter/escape/backspace/delete/up/down/left/right (vaxis codepoints);
- alt+enter (multiline newline), alt+s, alt+f (mods);
- ctrl+j; ctrl_c/ctrl_d from codepoint (defensive — ISIG normally routes
  ctrl_c to SIGINT);
- printable input prefers `key.text` (IME commit / multi-codepoint
  graphemes) and otherwise UTF-8-encodes the codepoint before
  `editor.insert` (one codepoint, not byte-by-byte);
- editor backspace / delete / left / right step by UTF-8 codepoint so
  CJK stays valid;
- kitty-keyboard is **not** left enabled after `queryTerminal` (CSI u
  `report_all_as_ctl_seqs` swallows IME composition on Kitty / Ghostty /
  WezTerm / iTerm2).

## 5. Rendering (packages/zag-tui/src/render.zig)

`renderFrame` keeps its signature; emit layer becomes vaxis cells:

1. `const root = vx.window();`
2. `layout.compute(...)` (unchanged authority) → per region
   `root.child(.{ .x_off, .y_off, .width, .height })`;
3. modal region gets `border` (rounded) + style; header/status get
   style/color (the visual upgrade — but NO layout change, geometry is
   layout.zig's);
4. card list: title/body rows via `printSegment` with the tui-layout-001
   truncation rules (utf8Prefix min-caps);
5. editor region: first line + cursor cell (byte→cell via UTF-8 width);
6. `state:{s}` text present in header cells (PTY grep contract);
7. `vx.render(tty.writer())` — double-buffered diff (replaces full-frame
   ANSI; also replaces the dirty-flag optimization at the byte level —
   vaxis diff only emits changed cells).

## 6. Event loop (packages/zag-tui/src/app.zig)

- poll set: `[wake_r, host.wakeFd()]` (stdin removed — vaxis's internal
  thread owns the tty);
- wake_r branch: drain the bridge ring → mapKey/handle events → dirty;
- winsize events: `vx.resize` + dirty; **paint's size-recheck RECONCILES**
  (re-read size differs from vx screen dims → call `vx.resize` — belt-and-
  braces against a dropped/late winsize event);
- poll_timeout_ms=250 unchanged; worker/host wake paths unchanged;
- handleKey: switch on `mapKey` results (existing actions unchanged).

## 7. Tests

- Offscreen `vaxis.Screen` render fixtures: cell snapshots assert the
  full/constrained frames' content (rows equal the pre-vaxis ANSI layout;
  `state:{s}` cell text; modal border cells; truncation min-caps);
- RecordingTerm/RecTerm byte-drain → cell-diff assertions;
- Event-ring fixtures (order, wake per event, quit);
- mapKey fixtures incl. UTF-8 multibyte;
- winsize fixture (resize → repaint);
- PTY process fixture unchanged (markers + ISIG);
- Regression: all existing TUI gates + default/curl matrices + SDK
  fixture.

## 8. Diagnostics & budgets

- No new config; no new diagnostics; vaxis queries are best-effort
  (failures degrade to defaults).
- Frame memory: vaxis Screen owns the cell buffer (no 16KB stack frame);
  render budget = screen cells.
