---
status: active
id: D-015
title: Live-image runtime switches from Chez to Gerbil/Gambit (compiled gsc image for production)
date: 2026-08-14
---

# D-015 — Live-image runtime: Gerbil/Gambit

## Decision

The live-image runtime switches from Chez Scheme to **Gerbil/Gambit**,
user-directed, validated by the
[spike-004 comparison probe](../../plan/tasks/live-runtime-spike-004.md)
(independent review pass):

- **Development/interpreted form:** `gxi` (Gerbil interpreter).
- **Production image form:** a single compiled binary via Gambit
  **`gsc -exe`** — ~10× faster boot (verified 4–6 ms vs Chez's ~54 ms),
  no runtime discovery, the `ChezUnavailable` failure class disappears.
- **Gerbil's module system (`gxc`) is deliberately NOT used for the image**:
  its namespacing makes the image's own kernel primitives invisible to
  interaction-environment eval (verified). The image is Gambit-flavored
  Scheme; Gerbil tooling is the dev shell.
- Chez support retires from the product path; it stays in the spike as the
  comparison harness.

## Why

- User direction (2026-08-14): Gerbil is the preferred runtime.
- Probe evidence: the full 10-probe acceptance matrix passes under gxi and
  gsc-exe, including commit quarantine, watchdog reload, and mid-turn kill
  recovery. Protocol-boundary design made the swap cheap — only the image
  script, spawn/build route, and codec profile are runtime-specific.
- The compiled single binary is operationally superior for the recovery
  story: respawn after a kill becomes nearly invisible.

## Honest caveats (recorded, accepted)

- **"Gerbil" in practice means Gambit semantics for the image.** The
  ecosystem argument that motivates choosing Gerbil (modules, packages,
  actor stdlib) applies to dev-side tooling, not to the gsc-compiled image.
- Codec profiles differ in one corner (hex-escape case); handled with
  per-runtime canonical encoders + case-insensitive strict decoders,
  fuzz-verified.
- Gambit stdin-EOF unreliability was observed pre-port, not reproduced in
  the shipped configuration; kill paths are SIGKILL regardless.
- Off-host portability of the gsc-compiled binary (Linux x86-64) is
  **unverified** — gate before any release claim.
- If the Gambit route proves unstable in practice, D-013/D-014's design
  keeps Chez as the documented fallback (spike harness retains it).

## Consequences

- [zag-live.md](../../modules/zag-live.md) gets a runtime-neutral revision
  with the Gambit binding (dual contract review; supersedes its
  Chez-specific text: boot probe, version floor, `ChezUnavailable`).
- `packages/zag-live/` gets a port task (image script, codec profile,
  spawn/build route, tests re-run) — **zag-live-004**; zag-live-002 stays
  held until the port lands and re-verifies.
- The switch moment is deliberately before zag-live-002/003 build further
  on Chez — cheapest point of reversal.

## Related

- [D-013](./D-013-live-runtime-prototype-track.md) ·
  [D-014](./D-014-live-runtime-productization-route-a.md)
- [analysis](../../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md)
  § Spike findings round 5
- [live-runtime-spike-004](../../plan/tasks/live-runtime-spike-004.md) +
  [review](../../plan/reviews/live-runtime-spike-004-01.md)
