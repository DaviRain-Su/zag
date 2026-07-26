# C7 — Process Supervisor / Optional OS Enforcement

| Item | Content |
|------|---------|
| Prerequisite | Phase H safety/Tool descriptor/lifecycle contracts ✅ |
| Near-term status | Deferred until a concrete E2 extension/background/process-cancel consumer |
| Decisions | [D-008](../decisions/active/D-008-sdk-and-process-boundaries.md) · [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Module | [workspace-sandbox](../modules/workspace-sandbox.md) L3 |

## Two separate Gates

### C7.1 Process supervisor

Required before any runtime executable extension:

1. spawn with process-group/job ownership;
2. bounded stdout/stderr/frame capture;
3. startup/operation/shutdown deadlines;
4. cooperative cancel → TERM → KILL;
5. child/descendant reap and structured diagnostics;
6. minimal explicit environment/secret injection policy。

This provides lifecycle and crash isolation. It is **not an OS sandbox**.

### C7.2 OS enforcement

Required before calling a native extension untrusted or enabling higher-autonomy execution:

1. evaluated macOS/Linux enforcement adapters;
2. filesystem/network/environment policy;
3. required profile fails closed when unavailable/setup fails;
4. constructive escape tests;
5. no silent downgrade to trusted-host mode。

WASM host capability enforcement is a separate future research Gate, not a substitute claim made by C7 docs.

## Current boundary

- Ctrl+C idle REPL repair does not justify C7.
- Plain trusted-host L2 remains valid without OS sandbox.
- Trusted static Zig composition remains same-process trusted code.
- Runtime process extension E2 cannot begin until C7.1 passes.
- Downloaded/untrusted native E2 cannot begin until C7.2 passes.

## Acceptance

### Supervisor

- [ ] process tree cancelled/reaped within bounds;
- [ ] stdout/stderr/frame bodies bounded with retained diagnostics;
- [ ] crash/hang/malformed output have deterministic outcomes;
- [ ] secrets absent unless explicitly granted;
- [ ] direct-process fixtures cover supported hosts。

### Enforcement

- [ ] required enforcement failure prevents child execution;
- [ ] filesystem/network/env escape fixtures fail per profile;
- [ ] on/off/unsupported behavior documented/security-tested;
- [ ] Kernel API contains policy/capability abstractions, not platform implementation types。

## Non-goals now

- normalizing `zig build run` foreground process groups;
- std HTTP active cancellation claim;
- multi-tenant/cloud isolation;
- building a sandbox without an executable consumer。
