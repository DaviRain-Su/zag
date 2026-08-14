---
id: live-runtime-spike-004
scope: spikes/live-runtime (D-013 prototype track; runtime comparison)
status: done
priority: P1
depends-on:
  - live-runtime-spike-001
---

# objective

User-directed runtime switch candidate: **Gerbil Scheme** (replaces Chez if
viable). Port the spike's live image to Gerbil and run the **same probe
harness** against it, producing decision data for D-015.

**Binding specifications:** spike-001/002 task files (probe semantics) +
[analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md).

# context

- Gerbil v0.18.1 (`gxi`/`gxc`/`gsc`) installed via Homebrew; trivial-script
  boot measured 50–80 ms (gxi, interpreted) vs Chez ~38 ms.
- The spike supervisor (`live-probe`) is runtime-agnostic by design; only
  the image script, spawn command, and escaping discipline are
  runtime-specific.
- Escaping: spike uses canonical Chez `write`; Gerbil/Gambit `write`
  differs — the Gerbil port must adopt canonical **Gambit** escaping on the
  image side (supervisor side already has one codec; document any change).
- Bonus probe: `gxc`-compiled image variant boot time (compiled image could
  remove the runtime-discovery failure class entirely).

# path

| Path | Role |
|------|------|
| `spikes/live-runtime/**` | add `runtime-gerbil.ss` + runtime-selection flag; keep Chez path working |
| `spikes/live-runtime/RESULTS.md` | round-5 comparison section |
| Forbidden | `packages/` (zag-live stays on Chez until D-015), design docs |

# verification (probe checklist)

Same probes, both runtimes, side by side. Verified by develop + independent
review ([live-runtime-spike-004-01](../reviews/live-runtime-spike-004-01.md),
pass, zero blocking).

- [x] boot latency gxi (and compiled variant) vs Chez baseline — 57–61 ms gxi, **4–6 ms gsc-exe**, 52–54 ms Chez
- [x] echo 10k frames, zero framing errors — all three runtimes
- [x] escaping fuzz (≥1000 adversarial strings, Gambit canonical form) — 1500 + independent 8/8
- [x] redefine → SIGKILL → replay restores identical source/value
- [x] discard / commit (incl. suspect quarantine) / watchdog / env-check
- [x] `kernel.inspect`
- [x] interactive mode works with the Gerbil image
- [x] semantic gaps found (threading, ports, eval semantics) recorded honestly — gxc namespacing fatal, gsc-exe is the compiled route; EOF spin not reproduced in shipped config
- [x] comparison table appended to RESULTS.md (analysis doc § round 5)

# non-goals

- Product package changes (zag-live stays Chez until D-015)
- Gerbil-specific features (actors, modules) beyond what the probes need
- D-015 itself (written after data lands)
