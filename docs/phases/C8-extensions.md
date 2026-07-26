# C8 — Extensions

| Item | Content |
|------|---------|
| Prerequisite | Phase H + SDK/process contracts ✅；E2 additionally needs C7 process supervisor |
| Near-term slice | M2 `skills-001` — E1 passive Skills |
| Decision | [D-010 extension tiers](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Module | [extensions](../modules/extensions.md) |

## Tier model

| Tier | Mechanism | Delivery status |
|------|-----------|-----------------|
| E0 | trusted static Zig source composition | SDK L2 closed at `ebdd7ab` |
| E1 | passive runtime packages | `skills-001` planned |
| E2 | runtime process extension over `zag-ext-v1` | deferred: process supervisor + real consumer |
| Research | WASM/component host | no commitment |

No dynamic `.so`/`.dylib` Zig ABI and no embedded Lua/QuickJS/Bun runtime.

## E1 passive Skills (scheduled)

- discover `SKILL.md` from documented jailed roots;
- validate frontmatter/name/description;
- bound per-file and aggregate prompt injection;
- deterministic precedence/conflicts;
- explicit disable and behavior-neutral no-Skill mode;
- no executable/provider/hook/UI/network/environment privilege。

## Lifecycle hooks

Trusted static deny-only hooks may be designed after `harness-events-001`. They consume versioned events and validated descriptors. A hook may make policy stricter; `allow` never overrides a host deny.

Runtime-installed hooks are E2 executable extensions and require C7 process ownership.

## E2 process extensions

Triggered only by a concrete local runtime-extension consumer:

1. C7 process group/job ownership, bounded I/O, deadlines, cancel, TERM→KILL/reap;
2. versioned `zag-ext-v1` handshake/manifest/Tool terminal protocol;
3. D-007 validation before Toolset insertion;
4. explicit environment/secret policy;
5. crash/timeout/malformed/output-overflow fixtures;
6. declarative host-rendered UI only。

A trusted local process may ship after supervisor evidence with an honest non-sandbox claim. A downloaded/untrusted native extension additionally requires an OS-enforcement profile that fails closed.

## UI boundary

Extensions send declarative intents (notify/status/progress/select/confirm/input/markdown/diff/list). Zag owns rendering, focus, redaction, and availability. Pi-style arbitrary component factories/renderers are intentionally unsupported.

## Invariants

- metadata missing/invalid → registration fails closed;
- manifest declaration does not equal enforcement;
- extension Tool follows the same permission/jail/shell/trace path as built-ins;
- extension cannot mutate canonical session/trace/private Agent memory;
- executable failure cannot create false success;
- process separation is not called sandbox;
- no stable C/Zig dynamic plugin ABI。

## Acceptance

### `skills-001`

- [ ] discovery roots/order/conflicts deterministic;
- [ ] symlink/escape rejected;
- [ ] invalid or oversized content fails per contract;
- [ ] disabled/no-Skill path behavior-neutral;
- [ ] no executable path introduced。

### Future E2

- [ ] supervisor lifecycle/output/cancel/reap Gate passes;
- [ ] `zag-ext-v1` negotiation and exactly-one invoke terminal pass;
- [ ] D-007/permission/containment/redaction/trace composition passes;
- [ ] untrusted required-sandbox unavailable → refuse execution;
- [ ] extension crash/timeout cannot corrupt session or run terminal。

## Non-goals

- Pi/npm package-manager compatibility/marketplace;
- Bun/TS host or TS-RPC parity;
- arbitrary extension UI code;
- full WASM platform before evidence;
- executable extensions before C7。
