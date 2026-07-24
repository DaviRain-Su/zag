# Zag documentation index

> Single entry for humans and agents. Status truth: [maturity.md](./maturity.md).  
> Taxonomy mirrors **XPlan-style** buckets: Active · Complete · Product Spec · Reference · Quality.

## Buckets

| Bucket | Meaning | Paths |
|--------|---------|-------|
| **Product Spec** | What Zag is / package law / L0–L3 bar | [vision](./vision.md) · [maturity](./maturity.md) · [architecture](./architecture.md) · [packaging](./packaging.md) · [modules/](./modules/) |
| **Active** | In-flight design & delivery | [phases/H-harden](./phases/H-harden.md) · [plan/](./plan/) · [decisions/active/](./decisions/active/) |
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
