---
status: active
id: D-012
title: Target a complete local coding-agent workflow without product or protocol parity
date: 2026-08-06
---

# D-012 — Complete local coding-agent target

## Decision

Zag now targets a **complete local coding-agent workflow**. This expands the
product roadmap beyond the earlier selected daily-Harness slices, while keeping
the D-009 rule: Zag is not a Pi/OMP/Hyper source port, API-compatible fork, or
unbounded batteries-included product.

“Complete” means that a local developer can safely run a durable coding session,
edit a multi-file workspace, use code intelligence, drive the agent from a
long-lived client/editor, delegate bounded work, and customize it through
controlled extension carriers.

## Included capability target

The roadmap may select independently gated work for:

1. reliable multi-file edit transactions and stale-edit detection;
2. repository navigation and LSP-backed code intelligence;
3. process supervision, cancellation, and process-tree ownership;
4. Zag-native long-lived `rpc-v1` and a separately gated ACP adapter;
5. typed, bounded, optionally worktree-isolated subagents;
6. MCP and runtime extensions through supervised-process and later WASM
   carriers;
7. durable session tree/navigation, runtime model data, and default-off
   project memory when their owning contracts are ready.

Each item still needs a reproduced user failure, package owner, design contract,
fixtures, independent review, and merged-main Gate. This decision creates a
product target, not an authorization to implement every item at once.

## Boundary retained

Zag does not target:

- Pi/OMP/Hyper source, CLI, JSON/RPC, package-manager, or plugin-API
  compatibility;
- cloud collaboration/relay, remote session hosting, marketplace operation, or
  account service;
- browser takeover, desktop automation, Slack/app control, voice, image, or
  video product surfaces;
- unrestricted in-process third-party code, raw terminal access, arbitrary ANSI,
  renderer pointers, or a Zig dynamic-library ABI;
- higher-autonomy or untrusted executable operation before the required
  supervisor and OS-enforcement Gates.

## Architecture law

The Kernel remains a single-agent Loop. Orchestration, LSP/MCP, process
supervision, extension runtimes, RPC/ACP, and product shells stay outside
`zag-agent-core` and preserve the one-way package dependency graph.

## Relationship to D-009

D-009 remains binding for implementation and compatibility boundaries. This
decision narrows the phrase “not a batteries-included product”: it excludes
unrelated/cloud/high-privilege product surfaces, not the locally useful coding
workflow capabilities listed above.

## Related

- [D-009 Pi semantics, not a parity fork](./D-009-pi-semantics-not-parity-fork.md)
- [D-010 extension tiers](./D-010-extension-tiers-and-process-protocol.md)
- [D-011 thin Agent Core](./D-011-thin-agent-core-boundary.md)
- [roadmap](../../roadmap.md)
