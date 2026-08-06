---
id: tui-transcript-001
scope: host-shell/tui-transcript
status: done
priority: P1
depends-on:
  - tui-slash-host-001
---

# objective

Scrollable transcript window over card ring; bottom composer fixed.
**Binding:** [tui-transcript.md](../../modules/tui-transcript.md)

**Implementation:** `layout.compute(..., scroll_from_bottom)` · App PgUp/PgDn ·
render label `├─ transcript ─`.

# gate

`-Dtui` layout fixtures updated; PTY `state:{s}` intact; no maturity raise.
