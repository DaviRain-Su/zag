---
status: active
scope: host-shell transcript scroll canvas
task: tui-transcript-001
prerequisite:
  - tui-slash-host-001
---

# TUI transcript canvas

Binding for **tui-transcript-001**. Replaces “only newest short card titles”
as the daily reading surface with a **scrollable transcript window** over the
existing card ring (capacity ceiling unchanged).

## Layout

- `transcript` region = former `cards` band; height grows with terminal rows.
- Editor + meta/status stay fixed bottom band (layout bottom-up unchanged).
- Scroll offset measured from bottom (0 = newest visible). PgUp/PgDn or
  overlay-closed ↑↓ when editor empty may adjust offset (product: PgUp/PgDn).

## Render

- Visible window only; wrap/cache fingerprint may land later — v1 paints
  title + body preview lines already produced by card slots.
- Streaming continues via `assistant_delta` → progressive card.

## PTY contract

Unchanged: `state:{s}` in header; min terminal; Ctrl+C Guard.

## Non-goals

Virtualized wrap cache parity with Comet; mouse wheel required; sidebar.

## Related

- [tui-layout.md](./tui-layout.md) · [tui-slash-host.md](./tui-slash-host.md)
- Task: [tui-transcript-001](../plan/tasks/tui-transcript-001.md)
