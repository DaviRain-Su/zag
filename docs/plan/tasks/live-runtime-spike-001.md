---
id: live-runtime-spike-001
scope: spikes/live-runtime (D-013 prototype track)
status: done
priority: P2
depends-on: []
---

# objective

Build a minimal runnable probe that answers the
[D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) spike
questions: can a Zig supervisor drive a Chez Scheme subprocess through one
full live-modification cycle — redefine → journal → kill → replay →
discard/commit — with measured boot and IPC latency?

**Binding specifications:**
[analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) ·
[D-013](../../decisions/active/D-013-live-runtime-prototype-track.md)

**Status:** **`done`** — spike complete 2026-08-14; independent review
[live-runtime-spike-001-01](../reviews/live-runtime-spike-001-01.md) **pass**
(zero blocking; F2/F4 fixed and re-verified; P3s in
[backlog](../backlog.md)).

# status truth

| Track | Status |
|-------|--------|
| Design docs | analysis + D-013 authored; findings appended to analysis (§ Spike findings 2026-08-14) |
| Implementation | **spike complete** — `spikes/live-runtime/`; 7/7 probes PASS across develop + independent verify + fix regression |
| Maturity | **unchanged** — spike is exempt; produced measurements, not claims |
| Unblocks | decision on Scheme runtime fit; later productization decisions |

# context

- [Autolith → Zag live-runtime analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md)
  — reference facts, design mapping, design rules v0, open questions.
- [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) —
  prototype track scope and isolation.
- [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md)
  — process supervision direction the spike borrows; no product wiring.

# path

| Path | Role |
|------|------|
| `spikes/live-runtime/**` | spike code; own `build.zig`; **not** wired into the root build |
| `docs/plan/analysis/2026-08-13-autolith-live-runtime-analysis.md` | findings appended here |
| Forbidden | `packages/`, root `build.zig` / `build.zig.zon`, `.github/`, `docs/maturity.md`, `chapters/` |

# verification (probe checklist)

Maps 1:1 to the analysis open-questions table. All items verified by develop,
independent review, and fix regression (see
[review](../reviews/live-runtime-spike-001-01.md)).

- [x] Chez cold boot to first eval measured (< 100 ms dev host target) — median ~38–55 ms
- [x] Length-prefixed s-expr IPC echo, 10k messages, no framing errors — ~1800–2000 msgs/sec
- [x] `kernel.redefine` → journal fsync → `SIGKILL` → replay restores
      identical source/value
- [x] `kernel.discard` returns binding to last committed state (+ `kernel.nack` on unknown names)
- [x] `kernel.commit` spawns clean Scheme, replay-probes, flips generation
      pointer atomically; failure path keeps old pointer (+ `(suspect ...)` quarantine)
- [x] Watchdog deadline on a hung Scheme → kill → reload committed
      generation; journal intact
- [x] No tokens/secrets visible in Scheme argv/env
- [x] Findings (measurements + failures) appended to the analysis doc

# non-goals

- Agent loop, provider calls, TUI integration
- Durable macro redefinition (exploratory-only in v0)
- Multi-worker orchestration, OS-sandbox claims
- Anything under `packages/` or any maturity claim
