---
status: complete
id: D-002
title: Canonical messages live in zag-types (L0)
date: 2026-07-20
---

# D-002 — zag-types is L0

## Decision

`Message` / `ToolDefinition` / `ChatError` / `Usage` live in **`packages/zag-types`**.  
`zag-agent-core` depends on zag-types only (not zag-ai). Model catalog/pricing stay in zag-ai.

## Why

Kernel must not import vendor protocols or pricing tables. Types that change with vendors belong in the Model plane.

## Consequences

- Spec: [packaging.md](../../packaging.md), [architecture.md](../../architecture.md)
- Pricing/catalog never move into zag-types
