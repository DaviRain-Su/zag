---
id: tui-layout-001
scope: tui/layout-presenter
status: contract-draft
priority: P1
depends-on:
  - tui-minimal-001
---

# objective

Introduce **pure layout computation + a dirty-flag presenter** to the minimal
host TUI, following the Rust reference architecture (hyper-grok-build
`AgentViewLayout::compute` — pure data layout math, unit-tested, rendering is
a thin shell over computed geometry; `Presenter` — dirty flag, no repaint
when nothing changed). `packages/zag-tui` currently hard-codes ANSI layout
paragraphs in `render.zig` and repaints every poll iteration in `app.zig`
regardless of whether anything changed.

**Binding specification:** [tui-layout.md](../../modules/tui-layout.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent architecture + safety re-reviews |
| Implementation | not started |
| Maturity | **unchanged** — no row add/raise (host-shell enrichment, per C9 precedent) |
| Core / coding-agent / headless-v1 / Session v1 / Trace v1 | **unchanged** by contract law (zag-tui-only slice) |
| tui-minimal-001 | closed at `f8f7f55` — this slice builds on it |

# context

- `packages/zag-tui/src/render.zig` (5.2KB): `renderFrame` builds one ANSI
  frame in a 16KB stack buffer; layout is hard-coded paragraphs
  (header/cards/editor/status/modal; constrained mode for small terminals);
  card body preview truncated at 120 chars; full repaint every call.
- `packages/zag-tui/src/app.zig` (27.4KB): event loop polls
  (stdin + wake pipe + host wake) and calls `paint()` once per iteration —
  including iterations where only `poll_timeout_ms` elapsed and nothing
  changed.
- `tests_gate.zig` asserts constants only; no byte-level render snapshot.
- Reference (hyper): `AgentViewLayout::compute` (views/agent.rs) — pure
  layout struct + vertical bands; `Presenter` (event_loop.rs) — dirty flag +
  in-flight gating + throttle; scrollback paint-window (deferred slice).

# path

| Path | Role |
|------|------|
| `packages/zag-tui/src/layout.zig` | NEW pure module: `Region`/`Layout` types + `compute()` (no IO, no allocator) |
| `packages/zag-tui/src/render.zig` | consume `Layout`; per-region draw fns; region-width truncation |
| `packages/zag-tui/src/app.zig` | dirty-flag presenter (skip paint when nothing changed; repaint on any state/input/size change) |
| Forbidden | zag-agent-core, zag-coding-agent, zag-cli, chapters, docs, Session v1, Trace v1 |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Layout types | `Region { x: u16, y: u16, w: u16, h: u16 }`; `Layout` = header/cards/editor/status/modal regions + `cards_window { start: usize, count: usize }` + `mode: enum{ full, constrained }`; pure data, no pointers into app state |
| compute() | `compute(size: Size, card_count: usize, modal_pending: bool, note_present: bool) Layout` — pure, allocation-free, unit-testable; rules EXACTLY mirror today's render.zig paragraph layout (same row counts and card window math: `max_cards = rows > 12 ? rows - 10 : 3`, constrained window ≤ 3) |
| Renderer | `renderFrame` consumes the computed `Layout`; per-region draw functions write only within their region; card body truncated to region width (today: fixed 120) via UTF-8-safe boundary cut; constrained mode output byte-identical to today |
| Presenter | dirty flag in `App`: `paint()` runs only when (a) any input/state change occurred this iteration (key action, worker join, host wake, interrupt, pending-modal change), or (b) terminal size changed since last paint, or (c) first paint. Poll-timeout-only iterations skip paint. No 16ms throttle in v1 (timing-sensitive tests; batching per iteration is the improvement) |
| Size change | `App` stores last painted size; `paint()` re-reads `term.size()`; different → recompute layout + full repaint |
| Output | unchanged ANSI writer path (`term.writeAll`); no cell model in v1 (deferred slice) |
| Divergence from reference | no throttle/tick-demand (v1), no scrollback paint-window (v1), no cell diff (v1) — this slice is layout math + dirty flag only |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| compute() geometry | full mode: header 2 rows (+1 with note), cards region rows = rows-10 (>12), editor + status rows at bottom; constrained mode: 3-line form; modal_pending affects layout only via its region presence |
| compute() edge cases | rows ≤ 12 (cards cap 3), rows = 0/1 (no overflow), tiny width (region w ≥ 1), card_count 0 (empty cards region), card_count < window |
| cards window | window = last `count` cards, start = card_count - count when overflowing; count respects constrained (≤3) |
| Region truncation | card body cut at region width on UTF-8 boundary; multi-line body rows clipped to region height |
| Renderer parity | full-mode frame rows/lines byte-identical to pre-slice output for a fixed input (golden via inline expected string), constrained-mode byte-identical |
| Presenter dirty | no change → paint skipped (write count 0); key input → painted; worker join → painted; size change → painted; poll timeout alone → skipped |
| Presenter first paint | first paint always happens |
| Regression | existing TUI matrix (tui Gate) green; default + curl matrices green; `-Dtui=false` default unchanged |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (default +
  TUI matrices, std + curl); **no** maturity raise; **no** remote `-Dtui`
  claim.

# non-goals

- Cell model / differential cell rendering
- Scrollback paint-window virtualization
- Throttle / tick-demand scheduling
- Overlay/animation compositing
- Theme integration (separate ready task `theme-001`)
- Changes outside `packages/zag-tui`
- Maturity raise

# related

- [tui-layout.md](../../modules/tui-layout.md) (binding)
- [tui-minimal-001](./tui-minimal-001.md) · [tui-minimal.md](../../modules/tui-minimal.md)
- [theme-001](./theme-001.md) (orthogonal, ready)
- [C9-product-shell.md](../../phases/C9-product-shell.md)
- Reference: hyper `AgentViewLayout::compute` (views/agent.rs) + `Presenter`
  (event_loop.rs) — architecture direction only, not parity
