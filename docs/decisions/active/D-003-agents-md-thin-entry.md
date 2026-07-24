---
status: active
id: D-003
title: Root AGENTS.md is a thin doc index
date: 2026-07-24
---

# D-003 — Thin AGENTS.md

## Decision

Root `AGENTS.md` is an **agent entry directory**: package map, stable hard rules, links into `docs/INDEX.md`.  
It must **not** duplicate maturity scoreboards or phase checklists (those go stale and burn prompt tokens).

## Why

Zag injects project `AGENTS.md` into the system prompt. Fat entries raise cost and drift from `maturity.md`.

## Consequences

- Lint enforces a line budget and forbids claiming production-ready without L2
- Phase progress lives only in maturity / roadmap / plan
