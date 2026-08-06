---
id: tui-slash-host-001
scope: host-shell/tui-slash
status: done
priority: P1
depends-on:
  - tui-vaxis-001
  - theme-001
---

# objective

Host overlay state machine + TUI submit slash routing that reuses coding-agent
skill/template expand. Builtins: `/help` `/settings` `/model` `/theme`.

**Binding:** [tui-slash-host.md](../../modules/tui-slash-host.md)

**Implementation:** `overlay.zig` · `slash_route.zig` · App key/submit/paint.

# gate

`-Dtui` tests green; headless/plain CLI unchanged; no maturity raise.
