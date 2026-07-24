---
status: complete
id: D-001
title: H ships a loop, not a workflow graph
date: 2026-07-01
---

# D-001 — Loop ⊂ Graph (Graph is Capability)

## Decision

Phase H implements a **single-agent loop** (model → tools → transcript).  
Workflow DAGs / multi-agent graphs are **C6+**, not the H default runtime.

## Why

Production floor needs a trustworthy turn harness first. Graph engines add surface without fixing edit/permission/safety L2 bars.

## Consequences

- Spec: [architecture.md](../../architecture.md), [modules/loop-turn.md](../../modules/loop-turn.md)
- Do not replace `loop.run` with a generic graph runtime in H
