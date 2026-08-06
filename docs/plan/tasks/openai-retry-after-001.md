---
id: openai-retry-after-001
scope: wire/openai-retry-after
status: contract-draft
priority: P1
depends-on:
  - retry-after-wire-001
---

# objective

Extend Retry-After support to the OpenAI wire (retry-after-wire-001 was
scoped to Anthropic because the openai-zig transport drops headers). The
SDK transport gains the same `retry_after_out` out-param pattern that
zag-ai's own HTTP layer already ships (used by the Anthropic wire), so
429/503 `Retry-After` values flow into the existing Core backoff slot.

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent review |
| Implementation | not started |
| retry-after-wire-001 | already landed (Anthropic path + Core loop + provider vtable slot; openai wire fns currently accept-and-ignore the slot) |
| ChatError / events / Session v1 / Trace / PTY | unchanged |

# context

Recon facts (all verified):
- No transport vtable — `transport/http.zig:10-15` comptime facade over
  http_std.zig / http_curl.zig; both must change in lockstep.
- `Transport.Response = { status, body }` — no headers; errors are bare
  tags (errors.zig:74-87) — an out-param is the ONLY channel.
- http_std: `parseRetryAfterSeconds(&response.head)` already exists
  (923-933; integer seconds only, HTTP-date → null) at 392/591; the
  value is DROPPED on the error return (410-416, 610-614).
- http_curl: `attemptOnce` already returns `retry_after_ms`
  (284-289 via headerRetryAfterMs 503-508) at 419/439; dropped at
  266-272.
- In-tree precedent to mirror EXACTLY: packages/zag-ai/src/http_std.zig
  (request retry_after_out 125-141, capture 275-330) + http_curl.zig
  (148-163, captureRetryAfterMs 358-376) + anthropic_messages.zig
  consumer (87-91, 134-143: clear unless RateLimited/ServerError).
- No test fakes exist in openai-zig (tests use real backends).
- Core slot already exists (provider vtable + loop, wired by
  retry-after-wire-001); openai_compat.zig chat/chatStream currently do
  `_ = retry_after_out;` (107/144).

# path

| Path | Role |
|------|------|
| `packages/openai-zig/src/transport/http_std.zig` | add `retry_after_out: ?*?u64` (final param) to `request` 180, `requestWithOptions` 192, `requestStream` 236, `requestStreamWithOptions` 248, `requestInternal` 261, `requestStreamInternal` 424; fill at the error returns (410-416, 610-614) and success (419, 629) with `retry_after_ms`; body-read/stream-error returns that already return without filling stay unfilled (intended — mirror zag-ai http_std.zig:310-316); add a defensive comment at the loop-exhausted returns (421, 631) |
| `packages/openai-zig/src/transport/http_curl.zig` | same params (152,162,173,185,198); fill `outcome.retry_after_ms` at error 266-272 and success 277-279 |
| `packages/openai-zig/src/transport/common.zig` | `sendJsonTyped` 8-17, `sendJsonTypedWithOptions` 19-53, `sendStreamTypedWithDoneWithOptions` 310-343 gain + forward (the OTHER 5 helper call sites inside common.zig — 39/86/123/153/186/200 + 333 — also forward) |
| `packages/openai-zig/src/chat.zig` | `create_chat_completion` 610-616, `create_chat_completion_stream_with_options_and_done` 894-936 gain + forward; ALL 14 wrapper variants (618/636/645/663/671/697/838/855/875/938/957/976/996) updated mechanically with explicit null |
| `packages/openai-zig/src/signature_tests.zig` | update the pinned parameter counts (63-64, 52-53) for the new final params |
| `packages/openai-zig/src/**` (resource files) | ~35 files / 100+ call sites of the changed common.zig helpers gain explicit `null` — mechanical sweep (list in the commit: assistants/audio/batch/certificates/completions/conversations/embeddings/evals/fine_tuning/groups/images/invites/moderations/projects/realtime/responses/roles/skills/uploads/users/vector_stores/videos/spend/default...) |
| `packages/zag-ai/src/openai_compat.zig` | drop the `_ =` (107/144); pass through to the SDK calls; in catches mirror the anthropic consumer: keep the out slot only when the mapped error is RateLimited/ServerError, else clear — INCLUDING the stream path's state.err branch (clear unconditionally); success → the transport fills null |
| Forbidden | ChatError set, event shapes, Session/Trace/headless, the Core loop (already done) |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Channel | out-param only (errors are bare tags). Zig 0.16 has NO fn-param defaults — the ripple is explicit: transport internals + common.zig helpers + chat.zig wrappers + ~100 resource-file call sites all pass the slot (real slot or explicit null) — mechanical sweep, enumerated in the path table |
| Fill rule | transport writes `retry_after_ms` (parsed integer seconds ×1000 — NO new saturation; the pre-existing extreme-value behavior at parseRetryAfterSeconds is documented, not changed) at the error/success returns listed in the path table; body-read/stream-error returns stay unfilled (intended); the WIRE layer (openai_compat) decides what the Core sees: keep only for mapped RateLimited/ServerError errors, else clear — INCLUDING the stream path's state.err branch (anthropic consumer parity, anthropic_messages.zig:134-143); success → transport fills null |
| Parsing | reuse `parseRetryAfterSeconds` (integer seconds; HTTP-date → null) — no new parsing; the pre-existing overflow behavior on absurd values (parse traps in Debug) is documented as inherited, not fixed in this slice |
| max_retries | agent path keeps forcing 0 (single attempt — the out value is terminal-return truth) |
| Zig 0.16 | no fn-param defaults — every call site passes the slot explicitly (null where unused); the SDK's internal retry loop (max_retries>0 direct callers) forwards its local value so the LAST exchange wins (fixture: 429+RA then success → out null) |
| Non-goals | HTTP-date parsing, header passthrough to events, SDK retry-loop changes |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| std backend | 429 + `Retry-After: 5` → out 5000ms on the error return; success → out cleared; absent header → null |
| curl backend | same via attemptOnce outcome |
| openai_compat | RateLimited → out kept; ServerError → out kept; other errors → out cleared; success → cleared (mirror anthropic consumer) |
| Loopback | real-server test: single-connection server returns 429 + header → wire out slot carries the value into the Core backoff (mirror the retry-after-wire-001 contract_tests pattern); SSE-level failure (stream state.err) → out cleared |
| Regression | existing SDK tests + all 4 matrices + PTY 14/14 green |

# non-goals

- HTTP-date parsing, telemetry of Retry-After, SDK retry changes

# related

- [retry-after-wire-001](./retry-after-wire-001.md) · [m4-sampler-resilience-001](./m4-sampler-resilience-001.md)
