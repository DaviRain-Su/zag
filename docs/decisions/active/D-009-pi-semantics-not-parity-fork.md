---
status: active
id: D-009
title: Follow Pi harness semantics without becoming a parity fork
date: 2026-07-26
---

# D-009 — Follow Pi harness semantics without becoming a parity fork

## Decision

Zag is a **Pi-inspired, Zig-native agent harness**. It follows selected user-visible and lifecycle semantics from Pi, but it is not a source port, wire-compatible fork, or feature-parity project.

The canonical development line remains this Zag monorepo. Two external snapshots are read-only references:

- current Pi behavior reference: `earendil-works/pi` at `5bc1c2c0a6f07e00e8c240304182f213ab8d311f`;
- historical Zig port: `DaviRain-Su/pi-mono-zig` `zig-implementation` at `9d1f78c509d10907e3dcf1e88f83fed4408db36e`.

The historical port is not merged into Zag and is not resumed as a parity fork. It is a design and test-vector archive.

## Product boundary

Zag has two first-class consumers of one harness:

1. the local `zag` CLI (plain, headless, and minimal TUI via lazy `-Dtui`);
2. Zig callers using the supported source-composition SDK.

This is not an “all-in-one” promise. A capability enters the product only when it closes a reproduced user failure, has a package boundary, and has a deterministic Gate.

## Semantics to align

Near-term alignment is deliberately small:

1. truthful, ordered message/Tool lifecycle events;
2. interactive control: cancellation plus steering/follow-up queues;
3. session branch/fork behavior without weakening Zag durability/redaction;
4. passive `SKILL.md` discovery plus an explicit Prompt Template surface;
5. a minimal terminal shell that only assembles Kernel APIs.

The broader correspondence map is also explicit: Extension, Skill, Prompt Template, Theme, Package, Custom Model, Custom Provider, SDK, RPC, JSON, and TUI/UI. Each category receives a Zag outcome, carrier, maturity, and Gate; this does not require shipping all categories together or copying Pi's API.

Names, package layout, CLI flags, JSON wire shapes, and TypeScript APIs do not need Pi compatibility.

## Zig-native contracts retained

Pi parity never weakens Zag’s existing contracts:

- explicit error sets and documented ownership/lifetimes;
- mandatory Tool descriptors and fail-closed policy metadata;
- default permission `ask` and relative workspace jail;
- redaction before persistence/output;
- truthful trace terminals and atomic session/edit persistence;
- backend-specific cancellation/deadline truth;
- process protocol instead of a promised C or Zig dynamic-plugin ABI.

“Zig-native” here means these concrete contracts. Binary size, startup time, memory use, and cross-compilation advantages remain unclaimed until measured.

## Deliberately omitted

Zag tracks the major user capability categories, but not Pi's exhaustive method/flag/provider/renderer inventory. The following are not parity obligations:

- exhaustive provider and OAuth coverage;
- Bun/TypeScript extension compatibility;
- Pi/npm package-manager or marketplace compatibility;
- Pi RPC command/schema/byte compatibility (a Zag-native `rpc-v1` remains a separate planned capability);
- Pi-compatible WASM APIs or runtime parity (Zag E3 follows D-010 and its own WIT/Gates);
- raw-terminal/ANSI/renderer-pointer access for E2/E3 UI;
- cloud sharing/collaboration, HTML export, image/dashboard breadth;
- Graph, Memory, Oracle, MCP, or OS sandbox without a concrete user failure and prerequisite Gate.

## Reuse and provenance

Default rule: **reuse behavior, not source**.

Code, data, or golden fixtures from Pi or `pi-mono-zig` may be imported only in a scoped task that:

1. records the exact source path and commit;
2. preserves the MIT copyright/license notice;
3. adapts the asset to Zag contracts rather than preserving legacy architecture;
4. proves the imported vector is still relevant to Zag’s public behavior.

Until that task exists, the snapshots remain local read-only research material and are not repository dependencies or submodules.

## Upstream tracking

Pi is reviewed by pinned snapshots, not followed release-for-release. An update is justified when it changes a mapped capability contract or provides a useful failure fixture. A new Pi provider, method, component, or package API may update the correspondence analysis, but does not by itself trigger Zag implementation.

## Consequences

- Zag remains the only implementation mainline.
- The legacy Zig port is mined for event ordering, control queues, session-tree semantics, terminal lifecycle, Skills discovery, and black-box fixtures — not merged wholesale.
- C4–C9 remain capability domains, not a mandatory feature-completion sequence.
- The immediate delivery order is interaction reliability → harness control semantics → selected daily UX.
- Product docs that describe “all-in-one” or feature breadth as a goal are superseded by this decision.

## Related

- [vision](../../vision.md)
- [roadmap](../../roadmap.md)
- [packaging](../../packaging.md)
- [Pi alignment analysis](../../plan/analysis/2026-07-26-pi-zig-alignment.md)
- [Pi feature correspondence](../../plan/analysis/2026-07-26-pi-feature-correspondence.md)
- [D-008 SDK/process boundaries](./D-008-sdk-and-process-boundaries.md)
- [D-010 extension tiers](./D-010-extension-tiers-and-process-protocol.md)
