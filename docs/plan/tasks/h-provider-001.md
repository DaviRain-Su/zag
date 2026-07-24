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

- `packages/zag-types/src/root.zig`
- `packages/zag-agent-core/src/provider.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/cancel.zig`
- `packages/zag-ai/src/http_std.zig`
- `packages/zag-ai/src/http_curl.zig`
- `packages/zag-ai/src/wire.zig`
- `packages/zag-ai/src/contract_tests.zig`
- `packages/openai-zig/src/transport/`
- `docs/modules/zag-ai-provider.md`
- `docs/quality/contracts.md`
- `docs/maturity.md`

# verification

- a configured timeout is enforced or rejected as unsupported; no backend silently stores an ineffective timeout;
- cancellation interrupts or closes an in-flight stream within a bounded contract;
- a partially assembled tool call is never appended/executed after cancellation;
- std and curl backend contract fixtures cover the documented behavior;
- terminal trace state is cancelled/timeout rather than completed;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`.
