---
id: zag-live-001
scope: packages/zag-live (D-014 Route A)
status: done
priority: P1
depends-on:
  - live-runtime-spike-003
---

# objective

Create `packages/zag-live/`: the clean-room product promotion of the spike's
supervised live-image substrate — frame protocol, journal, generations,
kernel primitives, watchdog, host-injected ports — per the binding contract,
with the three recorded promotion fixes (H2/H3/G4) closed.

**Binding specification:** [zag-live.md](../../modules/zag-live.md) +
[D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)

**Status:** **`ready`** — dual contract reviews PASS (round 2):
[architecture](../reviews/zag-live-001-01-architecture.md) ·
[safety](../reviews/zag-live-001-02-safety.md). Implementation eligible.

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — [zag-live.md](../../modules/zag-live.md) round-2; 8 blocking findings fixed, dual PASS; P3 residuals in [backlog](../backlog.md) |
| Implementation | **done** (2026-08-14) — `packages/zag-live/`; 23/23 tests green from clean (10 unit + 11 acceptance + M1/M2 fixes); review [zag-live-001-03](../reviews/zag-live-001-03-implementation.md) **pass** + fix-round pass |
| Maturity | **unchanged** — experimental default-off surface; no row added |
| Unblocks | zag-live-002 (provider bridge via zag-ai), zag-live-003 (coding-agent prompt surface) |

# context

- [zag-live.md](../../modules/zag-live.md) — binding contract (types, API,
  ports, errors, acceptance tests).
- [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
  — Route A decision, Racket reconsideration trigger.
- [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) —
  spike evidence rounds 1–4 the contract is distilled from.
- `spikes/live-runtime/` — reference implementation to promote **cleanly**
  (rewrite with product structure; do not copy spike shortcuts).
- [packaging.md](../../packaging.md) — L2 domain service rules; depends on
  `zag-types` only; no network.

# path

| Path | Role |
|------|------|
| `docs/modules/zag-live.md` | binding contract (this task's contract track) |
| `docs/plan/tasks/zag-live-001.md` | this task |
| Future reviews | `docs/plan/reviews/zag-live-001-*.md` |
| Future impl (after ready) | `packages/zag-live/**` only; own `build.zig`; root build untouched until a consumer exists |
| Forbidden | `packages/zag-agent-core` (no Core changes, D-011); `zag-ai` imports; `spikes/` edits; `.github/`; `docs/maturity.md` |

# verification

## Contract track (before ready)

- [x] Binding module draft authored
- [x] Independent architecture/ownership review PASS (round 2, after 4 blocking fixes)
- [x] Independent safety/lifecycle review PASS (round 2, after 4 blocking fixes)
- [x] Task → `ready`

## Implementation track (after ready)

- [x] Package tests: all acceptance classes in zag-live.md §10 pass (11/11; 23/23 total with unit + fix tests)
- [x] Promotion fixes H2/H3/G4 verified by dedicated tests (+ M1/M2 fix round)
- [x] `zig build test` in `packages/zag-live/` self-contained and green from clean
- [x] `git status` shows no changes outside `packages/zag-live/` and docs

# non-goals

- Provider bridge to zag-ai (zag-live-002)
- Any coding-agent / CLI / TUI wiring (zag-live-003)
- Multi-worker, durable macros, vault, OS-sandbox claims
- Any maturity row or change to existing contracts
