---
id: retry-after-wire-001
scope: core/retry-after
status: contract-draft
priority: P1
depends-on:
  - m4-sampler-resilience-001
---

# objective

Carry the provider's `Retry-After` header from the wire layer into the
Core retry backoff: on 429/503 the next retry waits `max(retry_after,
exponential)` instead of the plain schedule. M4's decision table already
classifies these errors retryable; this slice adds the value channel.

**v1 scope: the ANTHROPIC wire only.** The OpenAI path has no capture
source without SDK surgery (openai-zig Error is a bare error set, its
Transport.Response carries no headers — review blocker); OpenAI
Retry-After is a documented follow-up slice.

# status truth

| Track | Status |
|-------|--------|
| Contract | **contract-approved** — independent review approve-with-fixes findings absorbed (v1 scope: Anthropic wire only; integer-seconds Retry-After only; HTTP-date → null) |
| Implementation | **implemented** — transport capture (std + curl), wire out-param, provider vtable + all mocks, loop override, wire_provider threading, loopback fixtures + loop backoff fixtures; 4 matrices green, PTY markers 13/13 |
| ChatError set | unchanged (bare `error{}` — no payloads) |
| LoopEvent provider_retry | unchanged shape (retry_after stays out of events; the loop USES it locally) |
| Session v1 / Trace v1 / headless-v1 | unchanged |

# context

Recon facts (all verified):
- zag-ai `Response = { status: u16, body: []u8 }` (http_std.zig:28-31,
  http_curl.zig:25-28) — no header access today.
- http_std: `req.receiveHead` exposes `response.head` with
  `iterateHeaders()` at the call site (http_std.zig:249-256) — capture
  point exists.
- http_curl: `curl.Easy.Response.getHeader(name)` (third_party/zig-curl
  Easy.zig:105,120-127); openai-zig precedent `headerRetryAfterMs`
  (openai-zig transport/http_curl.zig:503-508) called beside status
  reads (417-420) — copy the pattern.
- openai-zig SDK parses Retry-After as INTEGER SECONDS ONLY
  (transport/http_std.zig:923-933); HTTP-date form unparsed everywhere.
- Error path: adapter maps SDK/HTTP errors by @errorName
  (openai_compat.zig:573-604, anthropic_messages.zig:80-85) — the header
  value dies with the Response today.
- Carrier: ChatError is a bare error set; the loop gets retry_after via
  an OUT-PARAM on the provider chat entry points (see Frozen choices).

# path

| Path | Role |
|------|------|
| `packages/zag-ai/src/http_std.zig` | capture `Retry-After` (integer seconds; HTTP-date → parse via std.time.epoch if present, else null) into the error/response path: on retryable status (429/503) return the value alongside the error |
| `packages/zag-ai/src/http_curl.zig` | same via `Easy.Response.getHeader("Retry-After")` |
| `packages/zag-ai/src/openai_compat.zig` + `anthropic_messages.zig` | map the captured value through the error path (an out-param on the wire Client's chat/chatStream: `retry_after_out: ?*?u64`) |
| `packages/zag-agent-core/src/provider.zig` | `chat`/`chat_stream` vtable entries gain `retry_after_out: ?*?u64` (null default — fakes ignore); Core API change, all fakes updated mechanically |
| `packages/zag-agent-core/src/loop.zig` | pass an out slot into the provider call; on `shouldRetry` + value present: `delay = max(retry_after_ms, retryDelayMsSaturating(...))` clamped to 30s; provider_retry event unchanged |
| `packages/zag-coding-agent/src/wire_provider.zig` | thread the out slot from the loop into the wire Client calls |
| Forbidden | ChatError set changes, event shape changes, Session/Trace/headless schema changes |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Carrier | `retry_after_out: ?*?u64` out-param on the provider vtable `chat` + `chat_stream` entries (and the wire Client equivalents). Set ONLY on rate-limit/server errors (429, 500..599 — the statuses mapHttpStatus classifies RateLimited/ServerError; 408 excluded) when the header parses; cleared to null otherwise. Fakes pass `null` (vtable field default null; ~55 mock fn signatures updated mechanically — enumerated in the fixture row). Agent-path wire clients force max_retries=0 (single attempt — the wire-internal retry loop only matters for direct SDK callers; the out slot is still written ONLY on terminal error returns) |
| Parsing | integer seconds ONLY (v1; HTTP-date/RFC1123 → null — std.time.epoch has no string parser in 0.16; a hand-rolled tokenizer is a follow-up). Curl path: getHeader("Retry-After") inside the attempt before easy.deinit; clamp to 30s at the loop |
| Loop | declare `retry_after_out` per attempt iteration; after a retryable error with a value: next sleep = `min(max(retry_after_ms, exponential), 30s)` (saturating math, then the existing remaining-deadline clamp); without a value: plain exponential (zero regression) |
| Events | provider_retry / provider_failed unchanged (retry_after is backoff-only, not surfaced) |
| Attempts | unchanged (3 attempts default) — a large Retry-After just extends the sleep; cancel still interrupts (sleepSliced) |
| Determinism | parsing + override math pure and unit-tested |
| Non-goals | OpenAI Retry-After (SDK surgery — follow-up), HTTP-date parsing (follow-up), header passthrough to events, per-request budgets, circuit breaker |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Anthropic (both backends) | 429 + `Retry-After: 5` → value 5000ms; HTTP-date → null; absent → null; non-retryable status → null; value set only on terminal error returns (single-attempt agent path) |
| http_std / http_curl | capture in the shared request() funnel (anthropic_messages.zig:83-85 2xx check is dead code — capture beside the status read; curl: getHeader before easy.deinit) |
| Adapter | Anthropic RateLimited/ServerError + value → out slot set; other errors → null; OpenAI adapters pass null (out of v1 scope) |
| Loop | retryable + value → next sleep = max(value, exp) (assert via a fake clock or the sleepSliced call record); retryable without value → plain exp; cancel during long Retry-After → cancelled; value clamped at 30s |
| Provider fakes | compile with the new vtable signature (null default) |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Retry-After in events/telemetry
- HTTP-date on the SDK's internal retry path (we bypass SDK retries)
- Session/Trace schema changes

# related

- [m4-sampler-resilience-001](./m4-sampler-resilience-001.md)

# closeout

- Commit: `<hash>` (zag-ai: Retry-After flows into core retry backoff (retry-after-wire-001)) — closeout line lands as a doc-only follow-up.
