---
id: tui-layout-001
scope: tui/layout-presenter
status: implementation-complete
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
| Contract | **PASS** — close-out re-review (4 blockers + 2 suggestions closed; zero blockers) |
| Implementation | **complete** — std 764/764, curl 763/763, TUI std 853/853, TUI curl 852/852 (+28 TUI tests); pre-slice byte-identical goldens (full 439B / constrained 96B) |
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
| compute() | `compute(size: Size, card_count: usize, modal_pending: bool, note_present: bool) Layout` — pure, allocation-free, unit-testable; **full-mode header.h = 3 (+1 when note)** (top border + id line + perm/shell/state line — render.zig:68-82); `├─ cards ─` separator is the first row of the cards region, `├─ editor ─` the first row of the editor region; **editor band fixed height 3** (separator row + one content row, multi-line editor content clipped, + hint line); constrained mode: 3-line form, modal is NEVER drawn (modal = null); `max_cards = rows > 12 ? rows - 10 : 3`; cards window = last `min(card_count, max_cards)`; modal.y depends on the fixed editor band (bottom-up layout) |
| Clamp semantics | `w` shrinks to available (≥ 1); `h` shrinks to available; `h == 0` → region absent (draw skips empty regions); `y+h <= size.rows` always |
| Renderer | `renderFrame` consumes the computed `Layout`; per-region draw functions write only within their region; **truncation rules: `body_preview = utf8Prefix(body, min(120, region.w - 3))` (body prefix `│   ` = 3); titles `utf8Prefix(title, min(128, region.w - 2))` (prefix `│ · ` — cap 2 keeps parity with today's 128 title cap); header strings (id/note/perm) min-capped to region width** — byte-identical at cols ≥ 123, strictly shorter below, frames never exceed today's byte count (16KB buffer safe); constrained mode output byte-identical to today |
| Presenter | **paint() is ALWAYS called** by the event loop; it re-reads `term.size()` and early-returns ONLY when `!dirty` AND size == `last_painted_size` (resize detection lives in paint, so idle-terminal resizes still repaint); `dirty` is set explicitly in every mutation block: key action, worker join, host wake drain, interrupt check, permission modal change, note update; first paint always runs (last_painted_size == null) |
| Size change | `App` stores last painted size; paint re-reads `term.size()` every call; different → recompute layout + full repaint + update last_painted_size |
| Output | unchanged ANSI writer path (`term.writeAll`); no cell model in v1 (deferred slice) |
| Divergence from reference | no throttle/tick-demand (v1), no scrollback paint-window (v1), no cell diff (v1) — this slice is layout math + dirty flag only |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| compute() geometry | full mode: header 3 rows (+1 with note); cards region rows = rows-10 (>12); editor band fixed height 3 (separator + clipped content + hint); constrained mode: 3-line form, modal null; modal_pending affects only the modal region presence |
| compute() edge cases | rows ≤ 12 (cards cap 3), rows = 0/1 (no overflow), rows = 10 + note + modal (clamps), tiny width (w = 1), card_count 0 (empty cards region), card_count < window |
| cards window | window = last `count` cards, start = card_count - count when overflowing; count respects constrained (≤3) |
| Region truncation | body preview = utf8Prefix(body, min(120, w-3)); title = utf8Prefix(title, min(128, w-2)); multi-line editor content clipped to the fixed content row; header strings min-capped to region width |
| Renderer parity | full-mode frame rows/lines byte-identical to pre-slice output at cols ≥ 123 (golden inline string); strictly shorter below; constrained-mode byte-identical |
| Presenter dirty | no change + same size → paint early-returns (write count 0); key input → painted; worker join → painted; **idle-terminal resize → painted (size re-read in paint)**; first paint always happens |
| Presenter regression | poll-timeout iterations still CALL paint (early-return inside); no path skips the size check |
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
