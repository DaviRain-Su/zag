# Delivery plan (Active)

XPlan-style **Active** delivery track. Owned workflow: analysis → tasks → reviews → backlog.

```text
docs/plan/
├─ README.md          (this file)
├─ analysis/          topic analyses (not assigned to implementers)
├─ tasks/             {area}-{seq}.md
├─ reviews/           {id}-{seq}.md
└─ backlog.md         non-blocking findings / deferrals
```

## Status

| Area | Notes |
|------|-------|
| Phase H | Spec in [../phases/H-harden.md](../phases/H-harden.md); H1+H2 largely landed |
| Tasks | Add files under `tasks/` when splitting work; see skill `docs-sprint` |

## Task file skeleton

```yaml
---
id: h3-001
scope: permissions
status: pending   # pending | ready | in-progress | done | blocked
depends-on: []
---

# objective
…

# context
- docs/modules/permissions.md

# path
- packages/zag-agent-core/src/permissions.zig
- docs/modules/permissions.md

# verification
- zig build test
```

## Rules

- Design docs in **Product Spec** / **decisions** before coding contract changes.
- Task `context` must point at existing specs.
- Blocking review findings must be fixed before merge; non-blocking → `backlog.md`.
