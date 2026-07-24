---
id: h-integration-001
scope: phase-h/integration-e2e
status: in-progress
priority: P1
depends-on: [h-session-001, h-tool-runtime-001, h-workspace-001, h-trace-001, h-context-001, h-provider-001, h-redact-001, h-doctor-001]
---

# objective

Close Phase H through real product composition, not duplicate module tests: add the two missing Agent-level failure chains (default Tool policy/containment and cancellation between accepted Tools), verify the existing P0/P1 matrix plus doctor through product composition, and update production-floor truth only if every exit condition passes.

# progress (develop)

- **Package evidence landed** in `packages/zag-coding-agent/src/agent.zig`:
  1. `h-integration: default Agent ask-deny write leaves target, permission_denied, save/resume+trace`
  2. `h-integration: default Agent yolo escaping-symlink jail_deny, outside intact, save/resume+trace`
  3. `h-integration: cancel between accepted Tools preserves IDs, skips pending, one cancelled terminal`
- **Hygiene rework (post review-01):** `ScopedCwd.leave` fail-loud restore; exact `FileNotFound` target-absent; exact permission/jail/tool_call/tool_result counts; structured session JSONL pairing (assistant id occurrence ==1 ↔ tool record body/code); independent raw forbid needle for jail outside secret; structured unique `run_end` parse; distinct second/third pending cancel tools; loop-turn Agent cancel checkbox remains open until Gate.
- Status stays **in-progress** (not done). Phase H / Workspace / Loop / Quality remain **L1+** until independent review + main-branch std/curl Gate.
- Not claimed: mid-flight Tool/shell preemption, SDK-ready, headless, Phase H L2.

# context

- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/quality/contracts.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- integration/golden/fault fixtures under the existing package test layout
- `packages/zag-agent-core/`
- `packages/zag-coding-agent/`
- `packages/zag-ai/`
- `packages/zag-cli/`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/roadmap.md`
- `README.md`
- `SECURITY.md`
- `chapters/H-harden/README.md`

# required composition fixtures

1. **Default Agent policy and containment failures.** Script real default built-in Tool calls through `Agent.reply` (not raw `Registry.execute`):
   - an ask/policy-denied mutation leaves the target unchanged and records descriptor-derived permission denial;
   - an escaping-symlink file request under an otherwise permissive gate does not expose or mutate outside bytes and records a jail denial;
   - each Tool result keeps the stable machine-readable code, appears in the transcript, survives session save/resume with its original Tool-call ID, emits the matching permission/jail trace event, and ends with the truthful run terminal (a recovered soft Tool denial may still complete normally).
2. **Cancellation between accepted Tools.** A complete provider turn containing at least two accepted Tool calls cancels after the first invocation and before the next:
   - the already executed call and every pending call retain their original provider Tool-call IDs;
   - every pending accepted call receives a machine-readable `cancelled` Tool body without handler execution;
   - API Result, transcript, persisted/resumed session, and trace agree on one `cancelled` terminal.

This task verifies only the current between-Tool cancellation contract. It must not claim that an already running Tool/shell process can be preempted; that process-ownership work is post-H.

# verification

- the two required fixtures above execute through the coding-product Agent with real policy, containment, session, and trace implementations;
- existing Agent fixtures continue to cover context final-view accounting, provider timeout/cancel/unsupported/failure terminals, session/trace persistence faults, strict Tool bundles, and redaction; low-level serializer/allocator/wire edge cases remain owned by their module suites rather than being copied here;
- all applicable P0/P1 fixtures in `docs/quality/evals.md` are reachable through real composition, with no stub or name-based fallback bypassing the contracts;
- doctor output and the integration evidence agree with README/SECURITY/maturity threat-model claims;
- root and every package test pass;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- only after independent review, both main-branch backend runs, and every Phase H exit sentence passes may maturity/README change Phase H to L2.
