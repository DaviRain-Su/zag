---
id: h-integration-001
scope: phase-h/integration-e2e
status: done
priority: P1
depends-on: [h-session-001, h-tool-runtime-001, h-workspace-001, h-trace-001, h-context-001, h-provider-001, h-redact-001, h-doctor-001, h-shell-001, h-edit-integrity-001, h-read-search-bounds-001]
---

# objective

Close Phase H through real product composition, not duplicate module tests: retain the independently verified default Tool policy/containment and between-accepted-Tools cancellation chains, add the shell runtime/observability evidence owned by `h-shell-001`, rerun the full product Gate, and update production-floor truth only if every exit condition passes.

# completed composition evidence

The original package evidence is merged in `packages/zag-coding-agent/src/agent.zig` and passed independent verification plus both main-branch HTTP backend suites:

1. `h-integration: default Agent ask-deny write leaves target, permission_denied, save/resume+trace`
2. `h-integration: default Agent yolo escaping-symlink jail_deny, outside intact, save/resume+trace`
3. `h-integration: cancel between accepted Tools preserves IDs, skips pending, one cancelled terminal`

Post-review hardening also landed: fail-loud cwd restore; exact `FileNotFound`; exact permission/jail/tool event counts; structured per-record session JSONL pairing; independent raw secret rejection; one parsed same-object terminal; distinct pending handlers/counters; duplicate-ID and contaminated-session negative fixtures.

This evidence closes the previously missing Agent product chains. It does **not** claim mid-flight Tool/shell preemption, SDK-ready, headless-ready, or Phase H L2 by itself.

# shell dependency closed

The prior Phase H audit found a missing shell module gate, and independent shell review 01 exposed policy command leakage, invalid UTF-8 representation, and missing real-runner boundary evidence. [h-shell-001](./h-shell-001.md) fixed all three, passed independent re-review plus Oracle, and passed the ff-only merged main Gate (`384/384` default; `383/383` curl; supported macOS shell fixtures zero skip).

Shell is **done** and remains L2 for its scoped synchronous contract.

# Phase H closeout

The 2026-07-25 executable final audit returned **FAIL** on two default file-surface counterexamples (historical). Both blockers are now closed:

1. `write_file` / `search_replace` published through in-place truncate/write and lacked target-preserving write/flush/replace fault evidence — closed by [h-edit-integrity-001](./h-edit-integrity-001.md).
2. `list_dir` / `read_file` / `grep` / `glob` did not yet prove the shared byte ceiling and could hide walker/source cutoffs as complete output — closed by [h-read-search-bounds-001](./h-read-search-bounds-001.md).

A fresh 11-sentence integration audit was then executed against `d22ce6e`:

- all 11 Phase H exit sentences **PASS**;
- final adversarial panel (3 core reviewers + 1 independent ship oracle) returned **SHIP**;
- merged-main Gate passed: zag-types **12/12**, zag-agent-core **157/157**, zag-coding-agent **138/138**, root default **432/432**, curl **431/431**, docs lint, readability **91/100**, security **65/100**, OpenAPI **287/287**, catalog **40**, with no explicit skips.

This closes Phase H at **L2 for single-user, trusted-host scope only**. It does not claim SDK-ready, headless-ready, OS sandbox, process-tree ownership, mid-flight Tool/shell preemption, power-loss/fsync durability, exhaustive concurrent traversal, DLP/zeroization, or generic third-party Tool body guarantees.

# context

- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/modules/tools-shell.md`
- `docs/quality/evals.md`
- `docs/quality/contracts.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`
- `docs/plan/analysis/2026-07-25-phase-h-final-audit.md`
- `docs/plan/tasks/h-edit-integrity-001.md`
- `docs/plan/tasks/h-read-search-bounds-001.md`

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

# retained composition requirements

1. **Default Agent policy and containment failures — passed.** Real default built-in Tool calls run through `Agent.reply`:
   - an ask/policy-denied mutation leaves the target unchanged and records descriptor-derived permission denial;
   - an escaping-symlink file request under an otherwise permissive gate does not expose or mutate outside bytes and records a jail denial;
   - each Tool result keeps the stable machine-readable code, appears in the transcript, survives session save/resume with its original Tool-call ID, emits the matching permission/jail trace event, and ends with one truthful recovered terminal.
2. **Cancellation between accepted Tools — passed.** A complete provider turn with three accepted Tool calls cancels after the first invocation and before the next:
   - the executed and pending calls retain exact original provider Tool-call IDs;
   - every pending call receives a machine-readable `cancelled` body without handler invocation;
   - API Result, transcript, persisted/resumed session, and one parsed trace terminal agree on `cancelled`.
3. **Synchronous shell composition — passed its module delivery Gate.** Fixed policy denial and each required shell-v1 runtime class, including real invalid UTF-8/base64, survive transcript/session/resume and a parsed single-call exact-one trace correlation, then recover through one truthful terminal. h-shell-001 passed independent/Oracle review and main std/curl.

This task verifies only between-Tool cancellation. It must not claim that an already running Tool/shell process can be preempted; that process-ownership work is post-H.

# verification

- retained policy/containment/cancel fixtures continue to execute through the coding-product Agent with real policy, containment, session, and trace implementations;
- shell-v1 module and Agent matrices from `h-shell-001` are permanent and run on supported macOS/Linux Gate hosts;
- existing Agent fixtures continue to cover context final-view accounting, provider timeout/cancel/unsupported/failure terminals, session/trace persistence faults, strict Tool bundles, and redaction;
- all applicable P0/P1 fixtures in `docs/quality/evals.md` are reachable through real composition, with no stub or name-based fallback bypassing contracts;
- doctor output and integration evidence agree with README/SECURITY/maturity threat-model claims;
- `zig build test --summary all` passes on main;
- `zig build test -Dhttp_backend=curl --summary all` passes on main;
- docs lint/score pass;
- only after every Phase H exit sentence passes may this task become `done` and maturity/README claim Phase H L2.

This task is now **done**: the 11-sentence integration audit **PASS**, the adversarial panel returned **SHIP**, the merged-main Gate numbers above are verified, and the closeout state has been synchronized to `docs/maturity.md`, README, SECURITY, roadmap, architecture, packaging, phases, plan, chapters, gaps, quality/evals, and module docs.
