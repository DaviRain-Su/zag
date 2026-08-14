---
id: zag-live-004
scope: packages/zag-live (D-015 runtime port)
status: done
priority: P1
depends-on:
  - zag-live-001
  - live-runtime-spike-004
---

# objective

Port `packages/zag-live/` from the Chez binding to the **Gerbil/Gambit
binding** per the revised contract: Gambit-flavored image source, two spawn
forms (compiled `gsc -exe` binary / interpreted `gxi`), Gambit codec
profile, gsc discovery via gxi, and the full acceptance suite re-run on
both forms.

**Binding specification:** [zag-live.md](../../modules/zag-live.md)
(D-015 revision) + [D-015](../../decisions/active/D-015-live-runtime-gerbil-gambit.md)

**Status:** **`done`** — implementation verified PASS
([zag-live-004-03-implementation](../reviews/zag-live-004-03-implementation.md);
42/42 tests green from clean build, dual spawn forms).

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — [zag-live.md](../../modules/zag-live.md) D-015 revision round 2; 5 blocking fixed (stop discipline, frame purity, image self-id, test-12 evidence scope, contract sync row) |
| Implementation | **done** — [verify PASS](../reviews/zag-live-004-03-implementation.md): 42/42 from clean build, 14 classes × both spawn forms; 2 non-blocking notes |
| Maturity | **unchanged** |
| Unblocks | zag-live-002 (held) implementation on the Gambit image — **unblocked** |

# context

- [zag-live.md](../../modules/zag-live.md) — revised binding contract
  (image source rule §4, codec profile §3, build route §10 test 12).
- [D-015](../../decisions/active/D-015-live-runtime-gerbil-gambit.md) —
  switch decision + honest caveats (incl. off-host portability gate).
- `spikes/live-runtime/runtime-gerbil.ss` — proven image port (spike-004);
  promote cleanly, as with zag-live-001.
- Spike semantic gaps to carry: gsc discovery via
  `gxi -e '(display (path-expand "~~bin/gsc"))'` (PATH `gsc` may be
  Ghostscript); Gambit EOF behavior (kill paths are SIGKILL; `kernel.quit`
  frame exists but unused on the wire); gxc module system NOT used.

# path

| Path | Role |
|------|------|
| `docs/modules/zag-live.md` | revised contract (this task's contract track) |
| `docs/plan/tasks/zag-live-004.md` | this task |
| Future reviews | `docs/plan/reviews/zag-live-004-*.md` |
| Future impl (after ready) | `packages/zag-live/**` only |
| Contract sync (arch B2) | `docs/modules/live-policy-layer.md` — rename/config sync at port time |
| Forbidden | other packages, root build, `spikes/`, `docs/maturity.md`, `.github/` |

# verification

## Contract track (before ready)

- [x] Revised contract authored (D-015 runtime-neutral + Gambit binding)
- [x] Independent architecture/ownership review PASS (round 2)
- [x] Independent safety/lifecycle review PASS (round 2)
- [x] Task → `ready`

## Implementation track (after ready)

- [x] All §10 acceptance classes pass on **both** spawn forms
      (skip-gated when toolchain absent)
- [x] `buildImage()` test: gsc discovered via gxi, binary boots and answers
      the self-id handshake; stale/foreign binary → `ImageUnavailable`;
      rebuild byte-size identical
- [x] `stop()` discipline test: quit/EOF-ignoring image SIGKILLed after
      `deadline_ms`; crash-discipline test: stderr + nonzero exit, stdout
      frame stream unpolluted
- [x] Chez-specific code removed from the package; spike harness untouched
- [x] **Contract sync (arch B2):** `live-policy-layer.md` updated —
      `ChezUnavailable` → `ImageUnavailable`, `chez_path` → `.image`,
      `Config.base_source` confirmed
- [x] `zig build test` green from clean; `git status` clean outside
      `packages/zag-live/` and docs

# non-goals

- Off-host (Linux) portability claims for the compiled image (D-015 gate)
- zag-live-002 integration work (separate task, unblocked after this lands)
- Gerbil module-system features; actor model
