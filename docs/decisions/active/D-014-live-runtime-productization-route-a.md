---
status: active
id: D-014
title: Productize the live runtime as an opt-in live policy layer (Route A), new zag-live package
date: 2026-08-14
---

# D-014 — Live runtime productization: Route A

## Decision

The D-013 prototype track productizes as **Route A: a live policy layer**,
not as a wholesale loop replacement.

1. **New package `packages/zag-live/`** — an L2 domain service owning the
   supervised Chez image: frame protocol, journal, generations, watchdog,
   and the kernel primitives. Clean-room promotion from the spike
   (`spikes/live-runtime/`), not a copy. Depends on `zag-types` only;
   provider and tool execution are **host-injected ports** (packaging rule
   3: no network in a domain package).
2. **`zag-coding-agent` integration is opt-in and degradable.** A config/flag
   enables the live image; when the image is dead or disabled, every live
   surface falls back to its current static default. No existing behavior
   changes when the flag is off.
3. **First live surface: prompt construction.** The system-prompt/policy
   function becomes a kernel-tracked binding, redefinable at runtime via the
   kernel protocol, with journal + generations giving audit and rollback.
   Later surfaces (tool registry, memory policy) are separate tasks.
4. **Route B (whole agent loop in the image) is explicitly deferred.** The
   spike proved it technically; it is rejected for now because it would
   re-open Phase H / SDK / headless L2 contracts that repo rules forbid
   weakening.
5. **No maturity changes.** zag-live ships as an experimental, default-off
   surface; no maturity row is added or raised by its landing.

## Why

- The spike evidence base (spike-001/002/003, all independently reviewed)
  demonstrates the full claim: mid-conversation policy redefinition
  surviving SIGKILL + replay, with the supervisor enforcing durability,
  quarantine, and recovery by construction.
- Route A delivers the differentiating capability — a coding agent whose
  behavior is live, inspectable, auditable, and rollback-able — without
  touching any closed contract.
- The dependency shape (L2 service + host ports) follows D-010 E2 process
  supervision and D-011 thin-Core: Core never sees a process, a PID, or a
  frame.

## Alternatives considered

- **Route B (loop in image).** Deferred, see above. Revisit only with a
  dedicated plan for re-earning the L2 contracts.
- **Racket instead of Chez.** Rejected for now (recorded 2026-08-14): the
  spike's image-side needs stayed inside Chez's standard library for three
  rounds because heavy lifting lives in Zig; migration cost (frame protocol
  and escaping discipline are Chez-canonical; boot ~38 ms vs Racket's
  heavier startup) buys nothing today. **Reconsideration trigger:** a real
  need for image-side ecosystem (e.g. `#lang` policy DSLs) — then run the
  runtime-comparison probe against the same checklist before deciding.
- **In-process embedding.** Permanently rejected for the trust-critical
  image (D-013): the process boundary is what makes kill/replay recovery,
  credential isolation, and the physical TCB possible.

## Consequences

- `spikes/live-runtime/` remains as evidence and playground; it is not the
  product code path.
- Promotion must close the spike's recorded promotion gates: backlog H2
  (single-write conversation append), H3 (realpath TOCTOU), G4
  (quarantine-vs-retry on infra failure) — all fixed in `zag-live-001`.
- Chez becomes a **runtime dependency**: zag-live requires a discoverable
  Chez (`chez`) with a version floor and a boot probe; absence disables the
  live surface (fail-closed to static defaults), it never breaks the base
  product.
- Later tasks: provider bridge via zag-ai (`zag-live-002`), coding-agent
  prompt surface (`zag-live-003`). Deeper surfaces (tool registry, memory
  policy, input vault, multi-image) each need their own task.
- **Process-ownership overlap (from contract review A3):** zag-live owns its
  image child process directly — a documented exception to
  process-supervisor's ownership of coding-agent *tool* children (an L2
  package cannot import the L3 supervisor). Recorded in
  [zag-live.md](../../modules/zag-live.md) §2.

## Related

- [D-013](./D-013-live-runtime-prototype-track.md) — prototype track
- [analysis](../../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md)
  — reference, design rules, four rounds of spike findings
- [zag-live module](../../modules/zag-live.md) — binding contract
- [D-010](./D-010-extension-tiers-and-process-protocol.md) ·
  [D-011](./D-011-thin-agent-core-boundary.md) ·
  [packaging](../../packaging.md)
