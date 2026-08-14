---
id: zag-live-002
scope: zag-coding-agent live policy layer (D-014 Route A, reordered)
status: ready
priority: P1
depends-on:
  - zag-live-001
  - zag-live-004
---

# objective

Wire the live image into `zag-coding-agent` as the first live policy
surface: **system-prompt construction delegates to the image at view time
when `--live` is on, with byte-identical behavior when off and graceful
fallback on any image failure.** Includes the host-driven `zag live`
subcommand for policy redefinition (no model-visible tool in v1).

**Binding specification:** [live-policy-layer.md](../../modules/live-policy-layer.md)
+ [zag-live.md](../../modules/zag-live.md) +
[D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)

**Status:** **`ready`** — dual contract reviews PASS ([arch round
4](../reviews/zag-live-002-01-architecture.md) · [safety round
3](../reviews/zag-live-002-02-safety.md)). Implementation **unblocked** by
[zag-live-004](./zag-live-004.md) (**done** — Gambit port landed, verify
PASS).

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — [live-policy-layer.md](../../modules/live-policy-layer.md) dual review PASS (arch round 4 · safety round 3); synced to Gambit binding by zag-live-004 |
| Implementation | **ready** — unblocked by zag-live-004 (done) |
| Maturity | **unchanged** — experimental, default-off, `-Dlive` compile-gated |
| Unblocks | zag-live-003 (provider bridge via zag-ai) |

# context

- [live-policy-layer.md](../../modules/live-policy-layer.md) — binding
  contract incl. recon-grounded hook points (§2 facts table).
- [zag-live.md](../../modules/zag-live.md) — consumed package contract.
- Flag/wiring precedent: `--no-skills` threading; build gating precedent:
  zag-tui lazy `-Dtui`.

# path

| Path | Role |
|------|------|
| `docs/modules/live-policy-layer.md` | binding contract (contract track) |
| `docs/plan/tasks/zag-live-002.md` | this task |
| Future reviews | `docs/plan/reviews/zag-live-002-*.md` |
| Future impl (after ready) | `packages/zag-coding-agent/**`, `packages/zag-cli/**`, root `build.zig`/`build.zig.zon` (lazy dep), `packages/zag-coding-agent/build.zig(.zon)` |
| Forbidden | `packages/zag-agent-core` (D-011); `packages/zag-live/**` changes (frozen by zag-live-001; deviations = stop and report); `docs/maturity.md`; `.github/` |

# verification

## Contract track (before ready)

- [x] Binding module draft authored
- [x] Independent architecture/ownership review PASS
- [x] Independent safety/lifecycle review PASS
- [x] Task → `ready`

## Implementation track (after ready)

- [ ] coding-agent package tests: all 7 acceptance classes in
      live-policy-layer.md §7 pass (skip-if-no-gxi gate)
- [ ] CLI smoke: `zag live status/redefine/recover`; `--live` without
      `-Dlive` → `LiveUnavailable`
- [ ] `zig build test` green at root and in touched packages; full local
      std suite green
- [ ] With `--live` off: zero diff in behavior (golden test proves)

# non-goals

- Provider bridge (zag-live-003)
- Model-visible self-modification tool (separate permission-design Gate)
- Tool registry / memory policy surfaces; TUI; maturity changes
