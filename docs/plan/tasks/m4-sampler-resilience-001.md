---
id: m4-sampler-resilience-001
scope: core/sampler-retry
status: implemented
priority: P1
depends-on: []
---

# objective

Make provider failure handling match production expectations: a **total
retry decision table** over the full ChatError tag set (which errors
retry, which are terminal), bounded exponential backoff with
deterministic tests, and correct attempt/event accounting. Reference:
hyper `retry.rs` sampler semantics; zag stays Zig-native.

**Retry-After is explicitly OUT of scope for v1** (review): neither HTTP
backend exposes response headers (http_std.zig/http_curl.zig discard
them), ChatError is a bare `error{}` set that cannot carry a value, and
openai-zig's SDK parses Retry-After only inside its own retry loop. A
wire-client header-capture change + a Core API carrier is a separate
slice. The decision table classifies rate-limit errors as retryable with
the plain backoff.

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented** — review approve-with-fixes findings absorbed (Retry-After out of scope; Timeout explicitly terminal; NotSupported reaches the table as retryable — removed from the clean-outcome intercept) |
| Implementation | complete — total `shouldRetry` table + gate swap + 6 loop fixtures; 4 matrices green, PTY 13/13 |
| LoopEvent provider_retry/provider_failed | unchanged shapes |
| Session v1 / Trace v1 / headless-v1 | unchanged |

# context

- `loop.zig:615-705 chatWithRetry`: attempts = chat_retries+1 (default
  3), pure exponential `retryDelayMsSaturating` (2^min(attempt,4) ×
  500ms), `zt.isRetryableError(err)` gate (672), provider_retry emit
  (691-693), provider_failed (677-679).
- hyper retry.rs: 15 retries, Retry-After aware, error classes
  (rate_limit/5xx/timeout/network), jittered backoff.

# path

| Path | Role |
|------|------|
| `packages/zag-agent-core/src/loop.zig` | total `shouldRetry(err: ChatError) bool` decision table (pure, enumerated over all 17 tags); attempt accounting; backoff stays `retryDelayMsSaturating` (already pure) |
| `packages/zag-agent-core/src/loop.zig` | chatWithRetry uses the table (replacing the isRetryableError gate — verify equivalence); provider_retry emit count unchanged |
| Forbidden | Session/Trace/headless schema changes; ChatError set changes; wire-layer changes; hyper's image/client-rebuild paths |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Decision table | TOTAL pure function over all ChatError tags. Retryable: rate-limit (429/529 → ServerError class per http_std.zig:167), 5xx (500/502/503/504), transient transport (BadStatus, WriteFailed, Unexpected, NotSupported, StreamFailed — hyper retries mid-stream, retry.rs:11). Terminal: auth (401/403), InvalidRequest, InvalidResponse (fatal per retry.rs:26), Timeout (isRetryableError(Timeout)=false today AND the shared end-to-end deadline makes retry meaningless — review blocker #3: explicitly terminal, documented), Cancelled, UnsupportedControl, OutOfMemory (sink-level, never retried). Table enumerates ALL 17 tags — no default-fallthrough |
| Attempts | default stays `chat_retries = 2` → 3 attempts total (current value; no bump — interactive CLI budget ~3.5s is fine; review: reference's 15 retries/~6min is headless-class) |
| Backoff | unchanged `retryDelayMsSaturating` (base 500ms, 2^min(attempt,4)); sleepSliced unchanged (cancel-aware) |
| Events | provider_retry / provider_failed shapes unchanged (no retry_after field in v1) |
| Determinism | table pure → unit-testable over the full tag set; backoff math already pure |
| Sink discipline | same as today: first sink error latches and aborts the run |
| Clean outcomes | Cancelled / Timeout / UnsupportedControl return ChatOutcome BEFORE the table (loop.zig:667-669) — the "terminal → provider_failed once" fixture only covers error-set tags that REACH the table (auth/invalid/etc.) |
| Non-goals | Retry-After (separate slice), jitter, per-request budget, circuit breaker, image/video retry specials, subagent retry policy |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Decision table | EVERY ChatError tag → retry/terminal verdict (full enumeration, no fallthrough); boundary at max attempts |
| Loop | retryable error → provider_retry with attempt counting; terminal error-set tag → provider_failed once, no retry; clean outcomes (Cancelled/Timeout/UnsupportedControl) → ChatOutcome, NO provider_failed; cancel during backoff → cancelled |
| Equivalence | table verdicts match current isRetryableError behavior for the previously-retried set (no regression); Timeout explicitly terminal |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Jitter / circuit breaker / budgets
- Image retry specials (no image support)
- Session/Trace schema changes

# related

- [provider retry doc](../modules/provider.md) if exists · hyper retry.rs (reference only)
