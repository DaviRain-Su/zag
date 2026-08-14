---
id: zag-live-002
scope: packages/zag-live provider port (D-014 Route A)
status: draft
priority: P1
depends-on:
  - zag-live-001
---

# objective

Docs-first contract for a host-side `ProviderPort` that calls `zag-ai`
without adding a `zag-ai` dependency to `packages/zag-live/`.

**Binding:** [zag-live-provider.md](../../modules/zag-live-provider.md)

**Status:** **`draft`** — not ready for implementation until dual review
PASS.

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** |
| Implementation | not started |
| Maturity | unchanged; experimental track |
| Unblocks | zag-live-003 |

# path

| Path | Role |
|------|------|
| `docs/modules/zag-live-provider.md` | binding |
| Future impl | host adapter outside `zag-live` (coding-agent or thin helper) |
| Forbidden | `zag-live` importing `zag-ai`; Core edits; credentials in Chez env |

# verification (contract track)

- [x] Binding drafted
- [ ] Architecture/ownership review PASS
- [ ] Safety review PASS (credentials, ImageRestarted, bounds)
- [ ] Task → `ready`

# non-goals

- Prompt surface (zag-live-003)
- Streaming-into-image as v1
- Maturity raise

# related

- [zag-live-001](./zag-live-001.md) · [zag-live.md](../../modules/zag-live.md)
- [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- [2026-08-14 next delivery plan](../analysis/2026-08-14-next-delivery-plan.md) Track L
