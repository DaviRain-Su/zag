# TUI layout + presenter (binding)

> Binding spec for `tui-layout-001`
> ([task](../plan/tasks/tui-layout-001.md)). Pure layout computation and a
> dirty-flag presenter for the minimal host TUI — the first slice of the
> TUI improvement line (reference: hyper's `AgentViewLayout::compute` +
> `Presenter`; architecture direction only, not parity).

## 1. Principles

1. **Layout is pure data**: `compute()` takes numbers, returns rectangles.
   No IO, no allocator, no app state — fully unit-testable.
2. **Renderer is a thin shell**: draw functions consume the computed layout;
   they never re-derive geometry.
3. **No repaint without change**: the presenter skips painting when nothing
   (input, state, size) changed.
4. **Visual parity**: full-mode and constrained-mode frames are
   byte-identical to today's output for the same inputs.

## 2. Pure layout module (packages/zag-tui/src/layout.zig)

```zig
pub const Region = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Mode = enum { full, constrained };

pub const Layout = struct {
    mode: Mode,
    header: Region,       // status band at top (2 rows, +1 when note)
    cards: Region,        // scrollable card list band
    editor: Region,       // editor band (fixed rows at bottom)
    status: Region,       // footer hint line
    modal: ?Region,       // permission modal overlay region (when pending)
    cards_window: struct { start: usize, count: usize },
};

pub fn compute(size: Size, card_count: usize, modal_pending: bool, note_present: bool) Layout
```

Geometry rules (mirror today's render.zig exactly):

- **constrained** (`size.isConstrained()`): 3-line form — status line, up to
  3 card titles (newest first), editor line; **modal is never drawn
  (modal = null)**; regions sized to content.
- **full**: header rows **3** (+1 when `note_present`) — top border, id line,
  perm/shell/state line (render.zig:68-82); the `├─ cards ─` separator is
  the first row of the cards region and `├─ editor ─` the first row of the
  editor region; `max_cards = rows > 12 ? rows - 10 : 3`; cards window =
  last `min(card_count, max_cards)` cards; **editor band fixed height 3**
  (separator + ONE content row, multi-line editor content clipped + hint
  line); modal.y computed bottom-up from the fixed editor band.
- All regions clamped: `w` shrinks to ≥ 1, `h` shrinks to available,
  `h == 0` → region absent (draw skips), `y+h <= size.rows`.

## 3. Renderer (packages/zag-tui/src/render.zig)

`renderFrame` keeps its signature; internally:

1. `const layout = layout_mod.compute(size, snap.len, modal.pending, note_present)`;
2. per-region draw fns (`drawHeader/drawCards/drawEditor/drawStatus/drawModal`)
   write only within their region bounds;
3. truncation rules (min-capped so frames never exceed today's bytes):
   `body_preview = utf8Prefix(body, min(120, region.w - 3))` (body prefix
   `│   `), `title = utf8Prefix(title, min(128, region.w - 2))`, header
   strings min-capped to their region width;
4. multi-line editor content clipped to the fixed content row;
5. ANSI output via the existing `term.writeAll` path; clear+home emitted once
   per frame (full repaint semantics retained in v1).

## 4. Presenter (packages/zag-tui/src/app.zig)

`App` gains:

- `dirty: bool` — set explicitly by every mutation block (key action,
  worker join, host wake drain, interrupt check, permission modal change,
  note update);
- `last_painted_size: ?terminal.Size`;

Event loop: **paint() is ALWAYS called**; inside, it re-reads
`term.size()` and early-returns ONLY when `!dirty` AND size equals
`last_painted_size` (idle-terminal resizes still repaint — the size check
cannot be skipped). First paint always runs. No 16ms throttle in v1.

## 5. Tests

- `layout.zig`: geometry fixtures (full/constrained/edges/window/modal/note),
  allocation-free, inline `std.testing` tests.
- `render.zig`: golden inline strings for a fixed full-mode and constrained
  frame (byte-identical to pre-slice output); region truncation fixtures
  (UTF-8 boundary, height clip).
- `app.zig`: presenter fixtures — no-change poll skips write (0 bytes
  written), key/worker/size changes paint exactly once; first paint always
  happens.

## 6. Diagnostics & budgets

- No new diagnostics; no new config; no CLI surface change.
- Stack budget: renderFrame's 16KB buffer is retained (region-based drawing
  keeps total output ≤ today's frame size; oversized regions truncate).
