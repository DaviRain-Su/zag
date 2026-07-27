# zag-tui

Minimal host TUI product package for Zag (`tui-minimal-001`).

## Ownership

- **Only** TUI owner: terminal channel, layout, editor, history, card ring,
  permission modal UI, reply-worker rendezvous, product-internal `SignalHost`
  port type.
- Depends **down** on `zag-coding-agent` (public Agent / Session / lifecycle /
  Gate / redactor APIs). May import `zag-agent-core` only for public types
  already exposed on the product path (e.g. cancel flag, stop reasons).
- **Must not** import `zag-cli` or `sigint.zig`.

## Build

Enabled only when the monorepo root passes `-Dtui=true` (default **false**).
Default builds never resolve this package.

```bash
zig build test -Dtui=true
```

## Contract

Binding: [`docs/modules/tui-minimal.md`](../../docs/modules/tui-minimal.md).
Implementation candidate — not maturity promotion, not Linux remote claim.
