---
id: h-provider-001
scope: phase-h/provider-deadline-cancel
status: in-progress
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
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-types/src/root.zig` — `RequestControl`, `CancelFlag`, `Cancelled`, mono time, retry policy
- `packages/zag-agent-core/src/{provider,loop,cancel}.zig` — control through chat; `timeout` stop_reason
- `packages/zag-coding-agent/src/{wire_provider,agent}.zig` — merge timeout; facade ok mapping
- `packages/zag-ai/src/{http_std,http_curl,request_control,openai_compat,anthropic_messages,contract_tests}.zig`
- `packages/openai-zig/src/transport/{lifecycle,http_std,http_curl}.zig`
- docs: provider/loop/trace/maturity/SECURITY/H chapter/evals/contracts

# verification

- a configured timeout is enforced or rejected as unsupported; no backend silently stores an ineffective timeout;
- cancellation interrupts or closes an in-flight stream within a bounded contract;
- a partially assembled tool call is never appended/executed after cancellation;
- std and curl backend contract fixtures cover the documented behavior;
- terminal trace state is cancelled/timeout rather than completed;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`.

# implementation note (local; status remains in-progress for orchestrator)

## Design

1. **L0 `RequestControl`**: monotonic absolute deadline + borrowed `*CancelFlag`; dependency-clean; `check` prefers Cancelled over Timeout.
2. **Provider API**: `chat(..., control: RequestControl)` — truthful lifecycle surface (mocks/fixtures updated).
3. **Wire**: control on `ChatOptions.control`; WireProvider merges loop control with optional `timeout_ms`.
4. **HTTP enforcement**:
   - **curl**: `CURLOPT_TIMEOUT_MS` from remaining budget; xferinfo abort; **no** silent 60s default when unset.
   - **std**: deadline checks between reads; watchdog thread shuts down `Io.net.Stream` (~25ms poll) for active abort.
5. **Retry**: Timeout/Cancelled never loop-retried; deadline end-to-end across attempts; sleep bounded by remaining budget.
6. **Partial tools**: stream error paths skip `finish()`; incomplete turns never append/execute.
7. **Terminals**: Result `cancelled` (ok=true) / `timeout` (ok=false); one terminal via existing facade; session/transcript resume-safe (no half assistant on provider abort).

## Tests (no public network)

- zag-types unit: control math, mono clock, retry policy.
- zag-ai contract: preflight, loopback slow server timeout wall bound, cancel abort, deadline share, mapSdkError Cancelled.
- loop: Timeout/Cancelled Results, no retry on Timeout, control reaches provider.
- Dual backend + ReleaseFast/ReleaseSafe compile.

## Limits (documented)

Trusted-host cooperative interrupt only — not OS sandbox. std bound depends on watchdog scheduling; curl on libcurl timeout/progress.
