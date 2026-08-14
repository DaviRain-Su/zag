# zag-live-002 — provider bridge via zag-ai

> Binding draft for [zag-live-002](../plan/tasks/zag-live-002.md)
> (D-014 Route A — first host port that talks to a real model).
> Depends on [zag-live.md](./zag-live.md) v1 (**implemented**).
>
> **Status:** **draft** — docs-only. No product code until dual review
> PASS and this task is `ready`. No maturity claim.

## 1. Purpose

Fulfill `zag-live`'s `ProviderPort` with a **host-side** adapter that
calls `zag-ai` (resolve + WireAdapter). The Chez image may request
`(provider.call …)`; credentials, HTTP, and retry stay in the host.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| **Host adapter** (new file under `zag-coding-agent` or a thin `zag-ai` helper — decided at review) | Map image sexp → canonical `ChatOptions` / messages; call `zag-ai`; return a bounded sexp reply allocated with the Live gpa | Import `zag-live` into `zag-ai`; put HTTP inside `zag-live` |
| `zag-live` | Existing `ProviderPort` vtable; frame cap; nack on `PortAbsent` | Depend on `zag-ai` or `openai-zig` (packaging: `zag-types` only) |
| `zag-agent-core` | nothing | Any live / provider-port types |

**Packaging law:** `packages/zag-live/` stays L2 and `zag-types`-only.
The bridge is a *consumer* of both packages, not a new import edge into
zag-live.

## 3. Invariants

1. **Credentials never enter Chez.** The image sees request/reply sexps
   only. Child env remains the zag-live allowlist.
2. **Bounded.** Host must bound runtime and reply size; frame cap (4 MiB)
   still applies on the wire.
3. **No transparent retry across image restart.** `ImageRestarted` is
   returned to the caller once (zag-live.md §4). The bridge must not
   hide that by retrying a non-idempotent chat.
4. **Default-off.** Constructing the bridge does not enable a coding-agent
   surface (that is zag-live-003).
5. **Fail closed.** Missing key / resolve failure / wire error → port
   error sexp, not a hang and not a Core `LoopEvent`.

## 4. Non-goals

- Prompt construction / Agent wiring (zag-live-003)
- Tool registry live surface
- Streaming into the image as a first slice (one-shot chat is enough)
- Changing zag-live's dependency set
- Maturity row

## 5. Tests (when implemented)

| # | Class | Expect |
|---|-------|--------|
| 1 | Fake WireAdapter | image `provider.call` round-trip; no network |
| 2 | Port absent | nack `PortAbsent`; image alive |
| 3 | Env | `*KEY*` / `*TOKEN*` still absent in the child after a call |
| 4 | ImageRestarted | in-flight call fails once; no duplicate chat |
| 5 | Ownership | `packages/zag-live` `build.zig.zon` still has no `zag-ai` |

## Related

- [zag-live.md](./zag-live.md) · [zag-ai-provider.md](./zag-ai-provider.md)
- [D-014](../decisions/active/D-014-live-runtime-productization-route-a.md)
- [packaging.md](../packaging.md)
