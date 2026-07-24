---
status: active
id: D-004
title: Docs use XPlan-style buckets
date: 2026-07-24
---

# D-004 — Doc buckets

## Decision

Zag docs are organized (and linted) under:

| Bucket | Role |
|--------|------|
| Product Spec | vision · maturity · architecture · packaging · modules |
| Active | `plan/` · `decisions/active/` · Phase H |
| Complete | chapters · `decisions/complete/` |
| Reference | references · research |
| Quality | evals · contracts · generated readability/security reports |

Entry: `docs/INDEX.md`. CI runs `scripts/lint_docs.py` and `scripts/score_docs.py`.

## Why

Matches the team's XPlan mental model without renaming every historical file. Agents get one index; humans keep Teaching chapters.

## Consequences

- New design decisions go under `docs/decisions/{active,complete}/` with YAML `status`
- Generated reports under `docs/quality/` are overwritten by `score_docs.py` — do not hand-edit scores
