---
id: zag-live-003
scope: zag-coding-agent live prompt surface (D-014 Route A)
status: draft
priority: P1
depends-on:
  - zag-live-002
---

# objective

Docs-first contract for the first coding-agent live surface: prompt
construction as a kernel-tracked binding. Flag/config off must be
byte-stable vs today's static prompt.

**Binding:** [zag-live-prompt.md](../../modules/zag-live-prompt.md)

**Status:** **`draft`** — not ready for implementation until dual review
PASS. Prefer zag-live-002 ready first (provider port), but a prompt-only
slice with no provider port is allowed if review says so.

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** |
| Implementation | not started |
| Maturity | unchanged |
| Depends-on | zag-live-001 **done**; zag-live-002 **draft** |

# path

| Path | Role |
|------|------|
| `docs/modules/zag-live-prompt.md` | binding |
| Future impl | `zag-coding-agent` + thin CLI flag |
| Forbidden | Core live types; default-on; `--yolo` implying live |

# verification (contract track)

- [x] Binding drafted
- [ ] Dual review PASS
- [ ] Task → `ready`

# non-goals

- Route B
- Tool registry / memory policy / vault
- TUI inspect chrome
- Maturity raise

# related

- [zag-live-002](./zag-live-002.md) · [zag-live-prompt.md](../../modules/zag-live-prompt.md)
- [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- [2026-08-14 next delivery plan](../analysis/2026-08-14-next-delivery-plan.md) Track L
