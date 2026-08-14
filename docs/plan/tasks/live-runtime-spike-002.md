---
id: live-runtime-spike-002
scope: spikes/live-runtime (D-013 prototype track)
status: done
priority: P2
depends-on:
  - live-runtime-spike-001
---

# objective

Harden the spike protocol before LLM-generated code enters the image, and give
the agent its self-observation eye. Three workstreams:

1. **Protocol hardening** (backlog F5/F6): symmetric string escaping between
   the Zig frame parser and Chez `write` — arbitrary model output must
   round-trip losslessly; frame length caps on both sides.
2. **`kernel.inspect`**: return a binding's source plus metadata (defined-at
   generation, pending/committed status, known dependents).
3. **Commit-path correctness** (backlog F8/F9): no orphan generation dir on
   failed commit; suspect quarantine also runs when the clean-process
   apply/check *errors*, not only on value mismatch.

**Binding specifications:**
[analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) ·
[D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) ·
[spike-001](./live-runtime-spike-001.md) ·
[review 001-01](../reviews/live-runtime-spike-001-01.md)

# status truth

| Track | Status |
|-------|--------|
| Design docs | analysis findings current; journal dual-role **resolved** (typed schema below, validated in code) |
| Implementation | **done** — 9/9 probes PASS; independent review [live-runtime-spike-002-01](../reviews/live-runtime-spike-002-01.md) **pass** (zero blocking; G1–G4 P3s in [backlog](../backlog.md)) |
| Maturity | **unchanged** — spike exempt; measurements, not claims |
| Unblocks | live-runtime-spike-003 (agent-in-the-image) |

# design decision: journal dual role (resolves analysis note 2)

The journal **keeps its dual role** — audit log and pending-state record —
now formalized as one typed schema instead of splitting into two files. One
append-only file, one fsync discipline, replay = fold over typed entries:

| Entry | Meaning | Replay effect |
|-------|---------|---------------|
| `(redefine <name> <ns> <source> <ts>)` | pending change | applies until superseded |
| `(discard <name> <ns> <ts>)` | exploratory rollback | removes matching pending redefine |
| `(suspect <name> <ns> <ts>)` | quarantined by failed commit | removes matching pending redefine |
| `(commit <gen> <hash> <ts>)` | generation flip recorded | none (pointer file is authoritative) |

# context

- [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) § Spike
  findings 2026-08-14 (the two design notes).
- [review 001-01](../reviews/live-runtime-spike-001-01.md) findings F5/F6/F8/F9.
- [backlog](../backlog.md) rows 2026-08-14.

# path

| Path | Role |
|------|------|
| `spikes/live-runtime/**` | all code + spike-local docs |
| `docs/plan/analysis/2026-08-13-autolith-live-runtime-analysis.md` | findings appended at closeout |
| Forbidden | `packages/`, root `build.zig` / `build.zig.zon`, `.github/`, `docs/maturity.md`, `chapters/` |

# verification (probe checklist)

All items verified by develop + independent review
([live-runtime-spike-002-01](../reviews/live-runtime-spike-002-01.md)).

- [x] Escape round-trip: fuzz ≥1000 generated strings (quotes, backslashes,
      unknown `\x` escapes, control bytes, Unicode, NUL) Zig→Chez→Zig,
      byte-identical — 1500/1500 + independent adversarial 8/8
- [x] Frame length cap enforced on both sides; oversize frame rejected
      cleanly (no hang, no crash, image still alive) — 4 MiB cap
- [x] `kernel.inspect` on committed / pending / unknown names returns
      source + metadata (generation, status, dependents)
- [x] Journal entries conform to the typed schema (all four writers)
- [x] F8: failed commit leaves no orphan `generations/<n+1>/` dir
- [x] F9: clean-process apply/check **error** also journals `(suspect ...)`
      and quarantines (not only value mismatch)
- [x] Original spike-001 7-probe suite still passes (regression)
- [x] Findings appended to the analysis doc (§ Spike findings, round 3)

# non-goals

- Agent loop, provider bridge, conversation records (spike-003)
- New protocol concepts beyond `kernel.inspect`
- Anything under `packages/` or any maturity claim
