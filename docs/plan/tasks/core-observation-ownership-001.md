---
id: core-observation-ownership-001
scope: coding-agent/observation-ownership
status: done
priority: P0
depends-on:
  - core-session-ownership-001
---

# objective

Move durable Trace, redaction, and verbose logging implementations to `zag-coding-agent`. Keep only the canonical
borrowed/fallible loop source-event contract in Core. Implement coding-agent fan-out that preserves durable fail-closed
Trace behavior and best-effort redacted verbose behavior without duplicate loop execution or terminal ownership.

# context

- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/trace-observability.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/headless-contract.md`

# path

- `packages/zag-agent-core/src/observer.zig`
- `packages/zag-agent-core/src/trace.zig`
- `packages/zag-agent-core/src/redact.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- destination coding-agent event/trace/redaction modules
- `packages/zag-coding-agent/src/runtime/`
- `packages/zag-cli/src/headless_writer.zig`
- Trace/redaction/headless/SDK fixtures
- `docs/modules/core-boundary.md`
- `docs/modules/trace-observability.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/tasks/core-observation-ownership-001.md`
- generated quality reports

# contract

1. Core emits one canonical source fact per witnessed phase through `LoopEventSink`; it performs no Trace serialization,
   persistence, redaction, or stderr logging.
2. Coding-agent fan-out preserves current event ordering and maps durable Trace failure to visible run failure.
3. Trace remains version 1, transactional, redacted before serialization, latest-reply atomic, and facade-terminal-owned.
4. Verbose logging may drop on redaction OOM but never falls back to raw bytes.
5. Run preflight/start/terminal remain in coding-agent and are not added to Core `LoopEvent`.
6. Headless remains independently versioned and never serializes the internal Zig union directly.
7. No separate Core lifecycle observer/channel is added.

# verification

- Every current Trace kind is sourced once from the appropriate loop/facade fact.
- post-start OOM, Trace emit/persist failure, session failure, cancel, timeout, and unsupported-control retain truthful
  exactly-one terminals and existing precedence.
- Trace v1, `headless-v1`, and session v1 parsed schema fixtures are unchanged.
- configured secret fixtures remain absent from verbose/Trace/session/headless output; redaction OOM remains fail-closed.
- Core source/root scan contains no Trace/redaction/logger implementation or product import.
- external SDK fixture copies borrowed source-event payloads and retains them safely.
- package tests, root std/curl suites, process fixtures, docs lint, and quality checks pass.

# non-goals

- changing event/schema vocabulary beyond the internal source union needed by D-011;
- public lifecycle-v1, deltas, Tool updates, async delivery, or backpressure;
- changing Trace/session/headless schema versions.
