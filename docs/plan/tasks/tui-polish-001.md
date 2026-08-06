---
id: tui-polish-001
scope: tui/visual-polish
status: contract-draft
priority: P1
depends-on:
  - tui-vaxis-001
---

# objective

Fix the three user-visible TUI complaints (audited, file:line evidence in
`2026-08-06-tui-canvas-grok-gap.md` + this task): (1) **bare panels** — the
main frame has NO right/bottom border closures (only left-edge glyphs
`┌─`/`│`/`├─`, no `┐`/`│`/`┤`/`└─┘`); (2) **inconsistent styles** — `card_fg`
is fetched then discarded (cards render unstyled), 6 of 13 theme roles are
dead, bg roles are mis-parsed as fg, `card.kind` is ignored, theme roles
drift from the frozen contract (`card_border`/`modal_border` vs
`card_bg`/`modal_bg`); (3) **log flood** — every lifecycle event publishes a
card (a tool-heavy turn = ~9 cards ≈ 18 rows, filling the transcript at
80×24). Plus input completeness (Home/End/Ctrl+A/E/W/U/K editing keys,
page-sized scrolling).

Target reference (documented): full bordered frame per panel, transcript as
assistant/tool/user blocks, theme ramp — per
`docs/plan/analysis/2026-08-06-tui-canvas-grok-gap.md:21-47`.

**Binding:** this task + the audit findings in [tui-canvas-grok-gap.md](../../plan/analysis/2026-08-06-tui-canvas-grok-gap.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent review |
| Implementation | not started |
| Maturity | **unchanged** — no row add/raise |
| PTY marker contract | `state:{s}` contiguous, ISIG, 1049h/l, geometry exit — unchanged |
| Session v1 / Trace v1 / headless-v1 / Core | unchanged |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Border closure | header/cards/editor/status become **vaxis bordered child windows** (single_rounded, same pattern as the existing drawModal `root.child(.{ .border = ... })`); hand-placed `┌─`/`│`/`├─` prefixes replaced by vaxis edge drawing (which draws all 4 sides + corners + insets interior); bottom border closes the frame; constrained mode stays 3-line minimal (no chrome) |
| Border styles | borders take a theme role (new `card_border` + `modal_border` roles per theme.md:253/255 — closing the doc/code drift; `card_bg`/`modal_bg` roles removed from the enum since the contract never had them); default builtin: muted border vs content fg |
| Theme unification | card rows styled with `card_fg` (delete the dead `_ = card_style`); `card.kind` drives color: host_error → `error_fg`, run_terminal/drop_note → `muted_fg`, ordinary → `card_fg`; **fix the bg-role parse bug** (theme.zig:169 must set `.bg` for `*_bg` roles, `.fg` otherwise); distinct `status_fg` vs `accent_fg` in the builtin (status: cyan, accent: yellow or similar); header uses `status_fg` + `status_bg`, editor `editor_fg`/`editor_bg`, modal `modal_fg`/`modal_border` |
| Transcript compaction | (a) drop the `run_start` card (already surfaced by header cfg + state:busy); (b) drop `control_applied` card (header S:/F: counters already surface it); (c) merge `tool_start`+`tool_end` into ONE replace-style row `tool {name}` (existing `replaceNewestOrdinaryTitlePrefix` mechanism); (d) body preview row only for assistant cards (tool rows single title row); (e) update tests_gate.zig assertions (existing :363-366 already expects tool_start-absent; :332-336 pins run_start/run_terminal titles — re-pin to the new behavior) |
| Input completeness | AppKey + mapKey + editor: Home/End (moveHome/moveEnd), Ctrl+A/Ctrl+E (same), Ctrl+W (delete word back), Ctrl+U (kill to line start), Ctrl+K (kill to line end); PgUp/PgDn scroll by the cards window height (not fixed 3); overlay PgUp/Dn + Home/End navigation; keep all existing mappings (arrows/history/slash/alt-s/alt-f) unchanged |
| Constrained mode | unchanged behavior (3-line minimal) |
| PTY/golden fixtures | PTY marker contract (`state:{s}` contiguous etc.) unchanged; render golden fixtures rewritten to the new bordered cell layout; cell-level assertions (0,0)=`┌` etc. updated |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Border closure | full-mode frame cells: top row `┌…┐`, side rows `│…│`, separators `├…┤`, bottom `└…┘`; interior text unchanged; constrained unchanged |
| Theme unification | card rows carry card_fg style; host_error card red (error_fg); bg roles parse to `.bg`; `card_border`/`modal_border` roles parse + apply to borders; builtin has distinct status/accent |
| Transcript compaction | one tool turn → 1 run_start + 1 tool_start/tool_end pair produces NO run_start card, ONE `tool {name}` row, one assistant card, one run_terminal; body preview only for assistant |
| Input | Home/End/Ctrl+A/E move cursor; Ctrl+W deletes word; Ctrl+U/K kill lines; PgUp/Dn page by window height; overlay Home/End/PgUp/Dn navigate; existing mappings regression-green |
| Regression | all existing TUI gates + PTY fixture + default/curl matrices green |

### Gate

- task Gate + merged-main Gate (default + TUI matrices, std + curl); no
  maturity raise.

# non-goals

- Multi-line editor vertical cursor movement (deferred)
- Mouse support, images, kitty-keyboard
- Theme reload/trust/containment expansion (separate contract work — current
  single-root fail-closed behavior unchanged)
- Changes outside packages/zag-tui (except fixture/tests_gate updates)

# related

- [tui-vaxis-001](./tui-vaxis-001.md) · [tui-layout-001](./tui-layout-001.md) · [theme.md](../../modules/theme.md)
- [tui-canvas-grok-gap.md](../../plan/analysis/2026-08-06-tui-canvas-grok-gap.md)
