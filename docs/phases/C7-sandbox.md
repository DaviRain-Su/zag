# C7 — Sandbox / Process Supervisor

| Item | Content |
|------|---------|
| Prerequisite | Phase H safety/Tool descriptor/lifecycle contracts |
| Failure mode | lexical jail/denylist can be bypassed; background/executable extensions lack process ownership |
| Module | [workspace-sandbox](../modules/workspace-sandbox.md) L3 |

## Goal

Add product/runtime OS enforcement and process-tree ownership above H's trusted-host containment. Sandbox is not part of Provider/message ABI and does not replace permission prompts.

## Scope

1. Process supervisor: spawn, process-group/job ownership, bounded stdout/stderr, deadline, cancel, TERM→KILL/reap.
2. macOS/Linux enforcement adapters (for example seatbelt/bubblewrap or equivalent evaluated mechanisms).
3. Explicit network policy where the platform can enforce it.
4. Optional worktree isolation for risky tasks.
5. Secret/environment injection policy.
6. Doctor reports support/profile/enforcement state.

## Fail-closed modes

- A mode/profile that declares sandbox **required** refuses execution when unsupported, disabled, or installation fails.
- An explicitly optional trusted-host mode may run without OS sandbox only after clearly reporting the downgrade and preserving ask/policy controls.
- Higher-autonomy/yolo, autonomous background jobs, and untrusted executable extensions cannot silently downgrade.

## Acceptance

- [ ] required enforcement failure prevents child execution;
- [ ] constructive filesystem/network escape fixtures fail under the documented profile;
- [ ] process tree is cancelled and reaped within bounds;
- [ ] output is bounded with retained diagnostics;
- [ ] on/off/unsupported behavior is documented and security-tested;
- [ ] Kernel source API contains policy/capability abstractions, not platform sandbox implementation types.

## Non-goals

- Multi-tenant cloud isolation
- Kernel-escape guarantees
- One identical platform mechanism on every OS
