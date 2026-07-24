---
id: h-provider-001
scope: phase-h/provider-deadline-cancel
status: done
priority: P1
depends-on: [h-trace-001]
---

# objective

Define and implement enforced provider deadlines and in-flight cancellation across std/curl streaming paths, with incomplete tool-call fragments discarded rather than executed.

# context

- `docs/modules/loop-turn.md`
- `docs/modules/zag-ai-provider.md`
- `docs/quality/contracts.md`
- `docs/decisions/complete/D-005-outbound-http-std-not-httpz.md`

# completion

## Capability truth (not universal active-cancel L2)

| | std (default D-005) | curl |
|--|---------------------|------|
| Ordinary no-timeout HTTP | works | works |
| Configured deadline / timeout_ms | `UnsupportedControl` before network | enforced (TIMEOUT_MS remaining) |
| require_active_cancel | `UnsupportedControl` before network | xferinfo abort |
| Cooperative cancel flag only | preflight + between-chunk (not bounded active) | active |

Removed unsafe std watchdog/cross-thread Stream shutdown (UAF race; incomplete DNS/connect coverage).

## Retry ownership

- Agent/provider path forces wire `max_retries=0`; loop is sole retry/backoff owner.
- Overflow-safe delay (saturating mul); ≤25ms slices with control recheck; shared monotonic deadline.
- Timeout / Cancelled / UnsupportedControl never retried.

## Strict stream + atomic tools

- OpenAI: require explicit SSE `[DONE]` (parser no longer fabricates done on EOF).
- Anthropic: require `message_stop`; malformed SSE JSON fails whole turn.
- `validateCompleteToolCalls`: nonempty id/name; arguments complete JSON object; multi-call atomic.

## Curl setopt

TIMEOUT_MS / NOPROGRESS / XFERINFODATA / XFERINFOFUNCTION results checked; failure → HttpFailed before perform.

## Terminals

`cancelled` ok=true; `timeout` ok=false; `unsupported_control` ok=false; one facade terminal.

## Tests

Merged to `main`; Debug/ReleaseSafe/ReleaseFast std+curl builds and dual suites pass. Permanent fixtures cover curl timeout/cancel, std pre-network unsupported control, exact facade terminals, strict SSE completion, and atomic Tool validation.
