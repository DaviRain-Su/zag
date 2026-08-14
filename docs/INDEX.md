# Zag documentation index

> Single entry for humans and agents. Status truth: [maturity.md](./maturity.md).  
> Taxonomy mirrors **XPlan-style** buckets: Active · Complete · Product Spec · Reference · Quality.

## Buckets

| Bucket | Meaning | Paths |
|--------|---------|-------|
| **Product Spec** | What Zag is / package law / L0–L3 bar | [vision](./vision.md) · [maturity](./maturity.md) · [architecture](./architecture.md) · [packaging](./packaging.md) · [D-009](./decisions/active/D-009-pi-semantics-not-parity-fork.md) · [D-010](./decisions/active/D-010-extension-tiers-and-process-protocol.md) · [D-011](./decisions/active/D-011-thin-agent-core-boundary.md) · [D-012](./decisions/active/D-012-complete-local-coding-agent-target.md) · [modules/](./modules/) · [context M3](./modules/session-item.md) · [SDK contract](./modules/sdk-contract.md) · [headless contract](./modules/headless-contract.md) · [minimal TUI](./modules/tui-minimal.md) (**done** @ `f8f7f55`) · [TUI streaming](./modules/tui-streaming.md) (**done** @ `2d57e84`) · [TUI layout](./modules/tui-layout.md) (**done** @ `189de9e`) · [TUI vaxis](./modules/tui-vaxis.md) (**done** @ `76360ab`) · [Theme](./modules/theme.md) (**contract PASS**; canvas-track impl) · [canvas gap](./plan/analysis/2026-08-06-tui-canvas-grok-gap.md) |
| **Active** | In-flight design & delivery | **[next delivery plan](./plan/analysis/2026-08-13-next-delivery-plan.md)** (from HEAD `6869549`) · [roadmap](./roadmap.md) · [Phase H](./phases/H-harden.md) · [post-TUI remote dual-backend Gate](./plan/tasks/post-tui-remote-dual-backend-gate-001.md) (**in-progress** Phase A; Gate green No; TARGET stale vs HEAD) · [process-supervisor-001](./plan/tasks/process-supervisor-001.md) (**draft** — Wave 1) · [tui canvas gap](./plan/analysis/2026-08-06-tui-canvas-grok-gap.md) · [edit-transaction-001](./plan/tasks/edit-transaction-001.md) (**done** @ `e086df8`) · [Pi / OMP / Hyper analysis](./plan/analysis/2026-08-06-pi-omp-hyper-local-agent-analysis.md) · [D-013 live runtime](./decisions/active/D-013-live-runtime-prototype-track.md) + [Autolith analysis](./plan/analysis/2026-08-13-autolith-live-runtime-analysis.md) + [live-runtime-spike-001](./plan/tasks/live-runtime-spike-001.md) (**done** spike, `spikes/` only) · [live-runtime-spike-002](./plan/tasks/live-runtime-spike-002.md) (**done**) · [live-runtime-spike-003](./plan/tasks/live-runtime-spike-003.md) (**done** — agent-in-the-image, D-014 evidence base) · [D-014](./decisions/active/D-014-live-runtime-productization-route-a.md) Route A + [zag-live](./modules/zag-live.md) contract (**draft**) + [zag-live-001](./plan/tasks/zag-live-001.md) (**done** — `packages/zag-live/` landed) · [plan/](./plan/) · [decisions/active/](./decisions/active/) |
| **Complete** | Finished tutorial / archived decisions | [chapters/](../chapters/) · [decisions/complete/](./decisions/complete/) · [gaps/](./gaps/) (Teaching→L2 debt) |
| **Reference** | External / web / industry notes | [references](./references.md) · [research/](./research/) |
| **Quality** | Evals + generated scores + contracts | [quality/](./quality/) |

```text
AGENTS.md (thin agent entry)
    └─ docs/INDEX.md  (this file)
         ├─ Product Spec ──► vision / maturity / architecture / modules
         ├─ Active ────────► plan/ · decisions/active/ · Phase H
         ├─ Complete ──────► chapters/ · decisions/complete/
         ├─ Reference ─────► references · research
         └─ Quality ───────► evals · contracts · *-report.md (generated)
```

## Reader path

```text
vision → maturity (where am I?)
  → roadmap (Teaching / H / Capability)
  → modules/* (implement)
  → chapters/* (hands-on) or plan/tasks/* (delivery)
  → gaps/* (Teaching → L2 debt)
```

## Maintenance

| Rule | Detail |
|------|--------|
| One truth | Each rule lives in one file; link elsewhere |
| Decision status | `active` or `complete` in YAML frontmatter under `decisions/` |
| Agent entry | Root [AGENTS.md](../AGENTS.md) stays thin — no phase scoreboard |
| Lint / scores | `python3 scripts/lint_docs.py` · `python3 scripts/score_docs.py --check` |
| CI / local | GitHub Actions + `zig build docs-lint` (also hooked into `zig build test`) |

## Related roots

- [../README.md](../README.md) — human project entry  
- [../SECURITY.md](../SECURITY.md) — security defaults  
- [../AGENTS.md](../AGENTS.md) — agent entry  
- [README.md](./README.md) — legacy map (points here)  
