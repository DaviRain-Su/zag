# Quality: Provider Behavior Contracts

> Contract tests lock wire assembly, error/lifecycle behavior, and cancellation safety—not model intelligence.

## Location and network rule

- Existing package suite: `packages/zag-ai/src/contract_tests.zig`.
- Stable raw fixtures may live under `packages/zag-ai/testdata/contracts/`.
- CI contract tests do not call the public internet.
- Both `std` and `curl` build paths run the shared behavior suite where applicable.

## L2 contract matrix

| Boundary | Required fixture |
|----------|------------------|
| Non-stream chat | Request shape, canonical text/Tool calls, finish reason, usage |
| Stream assembly | Fragmented text and Tool arguments assemble deterministically |
| Error mapping | auth/rate-limit/timeout/server/bad-request map to stable canonical errors |
| Retry | attempt owner/count/backoff terminal state is bounded and traceable |
| Deadline | configured deadline executes or returns explicit unsupported/config error |
| Cancellation | cancel reaches in-flight stream; terminal state is cancelled |
| Partial Tool call | cancellation/parse failure before complete JSON never executes/appends a Tool call |
| Redaction | configured secrets do not enter logs/trace/session fixtures |

At least OpenAI-compatible and Anthropic-style fixtures cover the canonical behaviors they expose. Adding a provider preset does not require a new native protocol fixture unless behavior differs.

## Assertions

- Tool arguments are complete valid JSON before execution.
- Usage saturates/maps according to `zag-types.Usage`.
- Non-retryable auth/bad-request failures do not retry.
- Retryable failures do not multiply unexpectedly across transport and loop layers.
- Cancellation produces exactly one terminal lifecycle and no post-cancel Tool execution.
- Timeout configuration is never silently ignored.

## Current status

Request/turn/error/SSE assembly fixtures exist. **h-provider-001** adds:

- L0 `RequestControl` + `CancelFlag` + non-retryable Timeout/Cancelled.
- std and curl enforce `timeout_ms` / control (loopback slow-server wall bound; cancel abort).
- Preflight cancel/zero-timeout fails before network.
- Partial tool-call fragments discarded (no finish on error); loop does not append incomplete turns.
- Deadline shared across retries; Timeout not retried.
- Dual backend: `zig build test` and `zig build test -Dhttp_backend=curl`.

Stable raw fixture directory naming under `testdata/contracts/` remains optional polish.

## L3

- per-native-protocol fixture corpus;
- fallback/multi-key behavior;
- performance/cost baselines after correctness.

## Related

- [provider module](../modules/zag-ai-provider.md)
- [evals](./evals.md)
- [task h-provider-001](../plan/tasks/h-provider-001.md)
