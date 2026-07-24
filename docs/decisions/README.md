# Design decisions

XPlan-style decision log. Each note has YAML:

```yaml
---
status: active    # or complete
id: D-00N
title: Short title
date: YYYY-MM-DD
---
```

| Folder | Meaning |
|--------|---------|
| [active/](./active/) | Still constraining current work |
| [complete/](./complete/) | Settled; do not re-litigate without a new decision |

Index (keep in sync when adding notes):

| ID | Status | Title |
|----|--------|-------|
| [D-001](./complete/D-001-loop-not-graph.md) | complete | H ships a loop, not a workflow graph |
| [D-002](./complete/D-002-zag-types-l0.md) | complete | Canonical messages live in zag-types (L0) |
| [D-003](./active/D-003-agents-md-thin-entry.md) | active | Root AGENTS.md is a thin doc index |
| [D-004](./active/D-004-docs-xplan-buckets.md) | active | Docs use Active/Complete/Product Spec/Reference/Quality |
| [D-005](./complete/D-005-outbound-http-std-not-httpz.md) | complete | Outbound HTTP: std default + curl opt-in; httpz no |
| [D-006](./active/D-006-session-open-and-durability.md) | active | Session open modes and durability fail closed |
| [D-007](./active/D-007-tool-runtime-descriptor.md) | active | Tool runtime capabilities are explicit and fail closed |
| [D-008](./active/D-008-sdk-and-process-boundaries.md) | active | SDK readiness and process interfaces use separate gates |
