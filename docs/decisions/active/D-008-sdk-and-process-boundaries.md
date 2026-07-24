---
status: active
id: D-008
title: SDK readiness and process interfaces use separate gates
date: 2026-07-24
---

# D-008 — SDK readiness and process interfaces use separate gates

## Decision

Zag distinguishes three deliverables:

1. **Low-level Zig composition** — importing `zag-types`/`zag-agent-core` and directly assembling Provider, Toolset, Observer, Transcript, and loop.
2. **Zig SDK-ready** — a supported source API with documented ownership, error, event, cancellation, tool, session, compatibility, and release contracts.
3. **Process SDK/headless** — a versioned structured protocol and stable exit/error behavior for non-Zig hosts and automation.

Package separation or a compiling low-level consumer proves only level 1. It does not prove levels 2 or 3.

Additional decisions:

- Phase H fixes correctness contracts required by every level.
- SDK-ready and headless are independent post-H gates; headless JSON/streaming output is earlier than TUI.
- Cross-language integration prefers ACP or another versioned JSON/RPC process boundary.
- Zag does not promise a stable Zig dynamic ABI, C ABI, or in-process dynamic plugin ABI at this stage.
- OS sandbox enforcement belongs to the product runner/process supervisor. Kernel APIs express execution policy/capabilities without embedding platform-specific sandbox types.
- Semver publication/repo split waits for a second real consumer, self-contained tests, migration policy, and a release channel.

## Why

The low-level Kernel can already be composed externally, while the high-level Agent still fixes the default toolset/observer and Tool handlers lack instance state. Treating the existing package split as SDK readiness would freeze incomplete contracts.

A process boundary also isolates non-Zig consumers and ecosystem-heavy components from Zig compiler/API churn.

## Consequences

- `packaging.md` records target stability, not a current compatibility promise.
- A repository-owned external-consumer fixture becomes an SDK gate.
- Headless must keep stdout machine-clean and version its event/error output.
- TUI, MCP, PTY, OAuth, and platform sandbox implementations may use helper processes without changing Kernel message/provider contracts.

## Required gates

### Zig SDK-ready

- stateful custom Tool, custom Provider, Observer, policy, cancellation, and session integration;
- public ownership/lifetime/error documentation;
- versioned event compatibility policy;
- package tests run outside private monorepo imports.

### Process SDK/headless

- structured JSON and streaming JSON;
- stable auth/session/save/cancel/sandbox errors and exit codes;
- no log contamination on stdout;
- protocol/version negotiation before ACP or editor integration.

## Related

- [assessment](../../plan/analysis/2026-07-24-production-floor-assessment.md)
- [packaging](../../packaging.md)
- [task sdk-contract-001](../../plan/tasks/sdk-contract-001.md)
- [task headless-001](../../plan/tasks/headless-001.md)
