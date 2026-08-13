---
id: tui-scrollback-001
scope: tui/row-scrollback
status: implemented
priority: P1
depends-on:
  - tui-vaxis-001
  - tui-markdown-001
---

# objective

Replace the **card-level transcript window** (shows the last N cards; tall
multi-line markdown bodies get clipped — after the screen fills, older
turns are unreachable) with a **row-level virtualized scrollback** ported
from hyper-grok-build (Grok Build TUI): per-card rendered-row cache keyed by
`(width, body_generation)`, cumulative `virtual_y`, `usize` scroll offset +
follow mode, the paint-window algorithm (binary search + straddle
back-off), lazy measurement (estimate-all → measure-visible-window-exactly),
negative-`y_off` window drawing (vaxis `Window.y_off: i17`), a scrollbar
with follow-dimmed thumb, and follow re-engagement on overscroll. This is
the user's blocking complaint: 内容占满后无滚动、旧回合不可达.

**Binding:** this task. Algorithm reference (exact port):
hyper-grok-build `scrollback/state/layout.rs` (compute_paint_window
:1648-1690, rebuild_layout_cache :1300-1373, settle_visible_measurements
:699-731) + `state/mod.rs` (prepare_layout 3 cases :1563-1694) +
`scrollback/render.rs` paint loop + `state/nav.rs` follow semantics.

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented as written** |
| Implementation | **done** @ `c631752` — row-level virtualized transcript scrollback |
| Maturity | **unchanged** — no row add/raise |
| PTY marker contract | `state:{s}` contiguous, ISIG, 1049h/l, geometry exit — unchanged |
| Session v1 / Trace v1 / headless-v1 / Core | unchanged |

# context

- Current transcript: `cards_window {start,count}` is CARD-counted
  (layout.zig); drawCards renders the last N cards, tall assistant bodies
  clip at the region height — a 20-row markdown turn is only partially
  visible and PgUp/Dn page by cards, not rows.
- vaxis: `Window.child` supports **negative `y_off: i17`** (content above
  the window is clipped) — the direct-clip render primitive.
- md_render returns rendered row counts (`md_rows`) — the exact-measure
  primitive. Cards carry `ui_seq` (monotonic, bumped per publish/replace)
  — the body-generation key.
- Card ring is bounded (125 ordinary + 3 reserves) — the cache array can
  be ring-sized.

# path

| Path | Role |
|------|------|
| `packages/zag-tui/src/scrollback.zig` | NEW: visible-card list + height cache + virtual_y + paintWindow + lazy measurement + follow (pure, testable) |
| `packages/zag-tui/src/md_render.zig` | `measure` mode (Ctx flag: skip overflow stop, row keeps counting) |
| `packages/zag-tui/src/render.zig` | drawCards → row-level paint window + negative-y_off drawing + scrollbar |
| `packages/zag-tui/src/app.zig` | scroll state (usize offset, follow), PgUp/Dn → row scroll, follow re-engagement on new content |
| `packages/zag-tui/src/layout.zig` | scrollbar column reservation (always 1 col in full mode) |
| Forbidden | zag-agent-core, zag-coding-agent, zag-cli production, Session v1, Trace v1 |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Height cache | per-card cache keyed **(slot_index, slot.ui_seq, occupied)** (review #9: ring wrap vacancy + drop-note seq reuse → include slot_index; ui_seq bumps on every publish/replace — cards.zig:134/159/174) → `{h: u16, measured: bool}`; width change → all `measured=false` (heights become estimates, geometry recalculated); card change → that card `measured=false` |
| **No rendered-line cache in v1** (review #6 resolved by design): paint re-renders visible cards each frame (md 4KB≈1ms benchmark); the cache holds HEIGHTS ONLY — no cell grapheme ownership, no eviction of text. Rendered-line caching is a documented later optimization |
| Measurement primitive | **md_render gains a `measure` mode** (review #1 blocker): Ctx flag that skips the `fits()` overflow stop — write ops still run but `writeCell` bounds-drops out-of-window rows safely; `row` keeps counting → unclipped row count. Exact height = measure render (still O(body), but no cell writes land) |
| Hidden cards (review #2 blocker) | terminal/`kind==.terminal` cards and unoccupied slots have **no height and no row** — the scrollback keeps a **visible-card index list** (compressed; skips terminal + unoccupied); gaps are 1 between adjacent VISIBLE cards (trailing visible card also 1 — matches current transcript spacing; no dense grouping in v1) |
| virtual_y | cumulative rows over the **visible-card list**: `vy[i+1] = vy[i] + h[i] + gap` (gap = 1 constant); rebuilt on width change / visibility change; delta-patched on card height change from the earliest changed index (O(n−k)) |
| Lazy measurement | rebuild (width change / first frame): estimate every visible card (per-source-line char-ceil over byte lengths — NO markdown render), then settle: measure EXACTLY the visible window ± 8 entries below (measure-mode render), re-pin offset, repeat until stable (monotonic: measured grows; cap = visible count + 2); new/streaming cards measured exactly at first settle after publish (O(1) append + delta patch) |
| Per-frame order (review #7) | **settle → re-pin (follow clamp) → compute_paint_window → draw** — exact sequence, every frame |
| paintWindow | exact port of compute_paint_window (binary search + ONE-entry straddle back-off, strict `vy >= vp_start` / `vy >= vp_end` partition points — review #8: exact-boundary landing does NOT back off; a gap landing yields a blank top row; empty range and zero-viewport return empty); no group-header extension; returns (visible-card range, content_y0) |
| Drawing | render only the paint window; top-clipped card rendered into `win.child(.{ .y_off = -(offset) + card_y, .height = h })` — vaxis `writeCell` bounds-drops negative rows (Window.zig:177-187), so the tail shows; bottom-clipped head shows via `height` clamp; `scroll_offset` clamped to **65535** at draw (i17 `y_off` range −65536..65535; invariant skip < h ≤ 65535 < |i17 min| — review #5, debug-assert the cast; no split needed) |
| Scroll | `scroll_offset: usize` (u16 strands long sessions); `scrollUp/Down` (saturating / clamp to max = total − viewport); overscroll at bottom re-engages follow; `gotoBottom` sets follow; ANY manual upward scroll leaves follow; new content while following → offset = max (auto-follow, applied in settle) |
| Follow | follow_mode bool; preserve-scroll not in v1 (no page-flip pinning); follow while new delta arrives → stay at bottom; PgDn beyond bottom = re-engage |
| Scrollbar | **column always reserved in full mode** (review #3 — conditional reservation is a width↔total feedback loop): cards region width is `cards.w − 1`; track drawn at the last column only when total > viewport; thumb = division-first arithmetic (review #11: `thumb_y = offset * H / total` with u128 intermediate or width-first division); thumb dimmed while follow_mode; hidden when total ≤ viewport |
| Input | PgUp/PgDn page by `max(viewport_height − 1, 1)` rows; **Home/End stay editor-cursor bindings** (review #4: existing bindings + pinned tests app.zig:778-785,1528-1537 — transcript top/bottom via PgUp overscroll / PgDn overscroll; Ctrl+Home/End scroll variants are a later option); wheel/mouse out of scope v1 |
| Streaming | delta accumulation unchanged; each paint re-measures the running card exactly (ui_seq bumped per replace) — O(1) delta patch |
| Constrained mode | unchanged (3-line form) |
| Divergence from reference | no turns/groups/folds/sticky headers/text selection/page-flip pin; no mouse wheel (v1); scrollbar click reserved (no mouse) |

# verification

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| virtual_y | cumulative rows with gaps; append O(1); delta patch after a mid-history card changes (later cards shift) |
| paintWindow | empty range; scroll 0; scroll mid-history (straddle back-off: partial top card included); scroll at bottom; viewport larger than content; exact row counts |
| Lazy measurement | estimate vs exact: only visible ±8 measured; settle loop terminates; scrolling up measures the newly revealed cards |
| Row cache | (slot_index, ui_seq, occupied) keyed; width change → all unmeasured; card change → one unmeasured; ring wrap → earliest-changed = 0 → full rebuild (O(n)) |
| paintWindow edges (review #8) | exact-boundary landing → no back-off; gap landing → blank top row; zero-viewport → empty range |
| Drawing | negative-y_off rendering: top-clipped card shows its tail; bottom-clipped card shows its head; scroll offset row-exact |
| Measurement (review #1) | 30-row card in 14-row viewport measures h=30 (unclipped) |
| Follow | new content while following → bottom; manual scroll up leaves follow; PgUp then PgDn to bottom re-engages on overscroll |
| Scrollbar | thumb position/size math (division-first, no overflow); dimmed in follow; hidden when total ≤ viewport; track column always reserved |
| PTY (review #10) | 80x24 fixture with >viewport rows: track column present, `state:{s}` markers byte-identical |
| Regression | all existing TUI gates + PTY markers + default/curl matrices green |

### Gate

- task Gate + merged-main Gate (default + TUI matrices, std + curl); no
  maturity raise.

# non-goals

- Turns/groups/folds/sticky headers/text selection
- Mouse wheel / scrollbar dragging (v1 keyboard + visual only)
- Page-flip pinning (follow_preserve_scroll)
- Changes outside packages/zag-tui
- Maturity raise

# related

- [tui-markdown-001](./tui-markdown-001.md) · [tui-vaxis-001](./tui-vaxis-001.md)
- Reference: hyper `scrollback/state/layout.rs` + `render.rs` + `nav.rs`
  (exact algorithm port)
