# Delivery plan (Active)

XPlan-style delivery track: analysis → task → committed develop output → independent review → ff-only merge → merged-main Gate → closeout.

```text
docs/plan/
├─ README.md
├─ analysis/
├─ tasks/
├─ reviews/
└─ backlog.md
```

## Current baseline

| Area | Status |
|------|--------|
| Phase H | **done/L2** — single-user trusted-host; fresh 11-sentence audit PASS; panel SHIP |
| Zig SDK | **done/L2** at `ebdd7ab` — Gate fixture 7/7; current external consumer **22/22** |
| Headless/Process | **done/L2** at `a1a1e0f` — `headless-v1`, fixture 4/4 |
| Product direction | **done** — `pi-alignment-001`; D-009/D-010 + 11-dimension feature map |
| Core responsibility correction | **done** through `aecf402` — [D-011](../decisions/active/D-011-thin-agent-core-boundary.md); ownership migration plus the product lifecycle adapter are closed without changing existing L2 rows |
| Product SDK lifecycle | **done** at `aecf402` — coding-agent `LifecycleObserver` over Core source facts plus facade run facts; no Core lifecycle channel |
| Bounded steering/follow-up | **done** at `a5ff2b7` — Session-owned queues + explicit Core `ControlInput`; SDK/Loop enrichment with no maturity change |
| Session fork | **done** at `0a3087f` — idle-only durable child, parent immutability, schema v1, SDK 21/21; Session remains L2 |
| E1 Skills | **done** at `caafef5` — passive discovery/catalog/`read_skill`/activation; SDK 22/22; Runtime Extensions remains L0 |
| Linux SIGINT raw errno | **done** at `bc737025` — `ci-hang-sigint-linux-errno-001`; candidate Gate std 611/611, curl 610/610; merged-main local macOS std 611/611, curl 610/610; maturity unchanged |
| CI safety fuses | **done** — [ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md); binding [quality/README](../quality/README.md); `.github/workflows/ci.yml` top-level concurrency + `jobs.test` 30m timeout; no push; maturity unchanged |
| Next code task | **Planned:** process-idle fixture + final merged-path Linux dual-backend Gate remain before `prompt-templates-001`. CI fuses are host rails only (not product hang proof). Broader Linux reliability is **not** closed by errno or fuses alone. |

The `harness-steering-001` merged-main Gate at `a5ff2b7` passed std **567/567**, curl **566/566**, Core **89/89**,
Coding **298/298**, external SDK **20/20**, OpenAPI **287/287**, catalog **40**, readability **91/100**, and security
**71/100**. It enriches existing L2 surfaces without adding or raising a maturity row.

The `session-fork-001` merged-main Gate at `0a3087f` passed std **40/40 steps, 579/579 tests**, curl
**42/42 steps, 578/578 tests**, Core **89/89**, Coding **309/309**, external SDK **21/21**, OpenAPI **287/287**,
catalog **40**, readability **91/100**, and security
**72/100**. Session/Resume remains L2; no tree/journal/schema claim was added.

The `skills-001` merged-main Gate at `caafef5` passed std **40/40 steps, 609/609 tests**, curl
**42/42 steps, 608/608 tests**, Core **89/89**, Coding **337/337**, CLI **30/30**, external SDK **22/22**,
OpenAPI **287/287**, catalog **40**, readability **91/100**, and security **72/100**. Runtime Extensions remains L0;
no E1 maturity row was raised.

The `ci-hang-sigint-linux-errno-001` node closed at `bc737025` (contract `b56b238`) after independent review-fix
**PASS** (zero blockers). Candidate Gate: std **611/611**, curl **610/610**, docs lint + score readability **91** /
security **72**, committed-range diff clean. Coordinator ff-only advanced local main `3cd0837` → `bc737025` while
preserving unrelated canonical `.gitignore` (**no push**). Merged-main local macOS Gate again: std **40/40 steps,
611/611 tests**, curl **42/42 steps, 610/610 tests**, OpenAPI **287/287**, catalog **40**, docs lint, readability
**91**, security **72**, committed-range diff clean. Pure raw-Linux decoder regression ran in both std and
curl-linked test artifacts. Maturity unchanged. Broader Linux reliability remains open (no fresh post-fix remote
Linux runner; process-idle and final merged-path Linux Gate still planned).
CI fuses (`ci-hang-ci-fuses-001`) landed as host concurrency + 30m job timeout rails only.

Historical Gate detail remains in each completed task and [maturity](../maturity.md). The accepted capability baseline is [2026-07-26 Pi alignment](./analysis/2026-07-26-pi-zig-alignment.md); historical production-floor assessments are frozen evidence, not the current product roadmap.

## Active DAG

```text
completed foundation
  Phase H ──► SDK-ready
      └─────► Headless-v1
                  │
                  ▼
          pi-alignment-001 (docs) ✅
                  │
                  ▼
          cli-sigint-001 (M0, done) ✅
                  │
                  ├─► ci-hang-sigint-linux-errno-001 (P0, done @ bc737025) ✅
                  │     ├─► ci-hang-ci-fuses-001 (done; host concurrency + 30m timeout)
                  │     ├─► ci-hang-sigint-process-idle-001 (planned; no task file yet)
                  │     └─► final merged-path Linux dual-backend Gate (planned)
                  │     remaining before prompt-templates: process-idle
                  │     + final merged-path Linux dual-backend Gate
                  │
                  ▼
        core-boundary-001 (docs, done) ✅
                  │
                  ▼
        core-seams-001 (done) ✅
                  │
                  ▼
   core-session-ownership-001 (done) ✅
                  │
                  ▼
 core-observation-ownership-001 (done) ✅
                  │
                  ▼
    core-policy-ownership-001 (done) ✅
                  │
                  ▼
   core-context-ownership-001 (done) ✅
                  │
                  ▼
        harness-events-001 (M1 product adapter, done) ✅
           ├────► harness-steering-001 (done @ a5ff2b7) ✅
           └────► session-fork-001 (done @ 0a3087f) ✅
                           │
                           ▼
          skills-001 (done @ caafef5) ✅ → prompt-templates-001
                    + edit-sharpness-001 (M2)
                           │
                           ▼
                     tui-minimal-001
```

`pi-alignment-001`, `cli-sigint-001`, the D-011 ownership nodes, `harness-events-001`,
`harness-steering-001`, `session-fork-001`, `skills-001`, and `ci-hang-sigint-linux-errno-001` are complete. Source
review rejected the earlier lifecycle design because it would add a third Core event channel while leaving product
policy/state in the kernel; the replacement coding-agent adapter closed at `aecf402`. Bounded steering/follow-up then
closed at `a5ff2b7` with Session-owned queues and a thin Core insertion seam. The safe idle-only durable fork closed at
`0a3087f` after independent reviews and merged-main Gates, without changing session schema v1 or the Session L2 row. E1
passive Skills closed at `caafef5` (coding-agent only; Runtime Extensions remains L0). The Linux raw-errno SIGINT
hotfix closed at `bc737025` after independent review-fix PASS and merged-main local macOS dual-backend Gate; pure
raw-Linux decoder regressions ran in both std and curl-linked test artifacts. It does not reopen M0 lifecycle design
and does not raise maturity. **Broader Linux reliability remains open:** no fresh post-fix remote Linux runner ran in
the closeout session; planned `ci-hang-sigint-process-idle-001` (task file not yet authored) and a final merged-path
Linux dual-backend Gate remain required before `prompt-templates-001`.
[ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md) is **done** as host rails only (concurrency + 30m job
timeout; timeout/cancel ≠ product hang proof). Task priorities express safety impact; the dependency chain, not
priority labels, fixes delivery order.

The [Pi feature correspondence](./analysis/2026-07-26-pi-feature-correspondence.md) maps all 11 documented Pi dimensions to Zig-native outcomes. D-010 records a formal post-foundation extension track: common semantics → C7.1 / E2 process binding → E3 WIT → runtime → capabilities → package, with later Provider/UI worlds separately gated. Zag-native `rpc-v1`, runtime model data, theme, and extension UI are distinct planned capabilities, not ready tasks or implementation claims.

## Task index

### Active / next

| Planned node | Status | Scope |
|--------------|--------|-------|
| `ci-hang-sigint-process-idle-001` | planned | M0 follow-on: idle process-fixture reliability; task file not yet authored |
| final merged-path Linux dual-backend Gate | planned | Fresh remote Linux runner after idle + fuses; required before prompt-templates |
| `prompt-templates-001` | planned | E1 passive Prompt Templates over Skills loader foundations; task file not yet authored |

### Completed foundation

| ID | Priority | Status | Scope |
|----|----------|--------|-------|
| [ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md) | P0 | done | CI concurrency + 30m job timeout fuses on dual-OS dual-backend matrix; host rails only; process-idle + remote Linux Gate still open; maturity unchanged |
| [ci-hang-sigint-linux-errno-001](./tasks/ci-hang-sigint-linux-errno-001.md) | P0 | done | Raw Linux `std.os.linux.errno` decode for SIGINT self-pipe under curl/`link_libc`; closed at `bc737025`; maturity unchanged; broader Linux reliability still open |
| [skills-001](./tasks/skills-001.md) | P1 | done | E1 passive Agent Skills; closed at `caafef5`; Runtime Extensions remains L0 |
| [session-fork-001](./tasks/session-fork-001.md) | P1 | done | Safe idle-only durable Session fork; closed at `0a3087f`; schema v1 and Session L2 unchanged |
| [harness-steering-001](./tasks/harness-steering-001.md) | P1 | done | Session-owned bounded steering/follow-up + explicit Core `ControlInput`; closed at `a5ff2b7` |
| [harness-events-001](./tasks/harness-events-001.md) | P1 | done | Coding-agent SDK lifecycle adapter; closed at `aecf402` |
| [core-context-ownership-001](./tasks/core-context-ownership-001.md) | P1 | done | Protocol history/Core vs context projection/product split |
| [core-policy-ownership-001](./tasks/core-policy-ownership-001.md) | P0 | done | Permission/workspace/shell implementation ownership → coding-agent |
| [core-observation-ownership-001](./tasks/core-observation-ownership-001.md) | P0 | done | Trace/redaction/logging ownership → coding-agent |
| [core-session-ownership-001](./tasks/core-session-ownership-001.md) | P1 | done | Durable session ownership → coding-agent |
| [core-seams-001](./tasks/core-seams-001.md) | P0 | done | Required kernel seams + canonical LoopEvent |
| [core-boundary-001](./tasks/core-boundary-001.md) | P0 | done | Thin-Core Product Spec, D-011, and serialized migration DAG |
| [pi-alignment-001](./tasks/pi-alignment-001.md) | P1 | done | Pi feature surface → Zig-native Harness/carrier roadmap |
| [cli-sigint-001](./tasks/cli-sigint-001.md) | P1 | done | Direct CLI Ctrl+C lifecycle and bounded escape |
| [h-session-001](./tasks/h-session-001.md) | P0 | done | Session open/save/concurrency |
| [h-tool-runtime-001](./tasks/h-tool-runtime-001.md) | P0 | done | Tool descriptor + permission |
| [h-workspace-001](./tasks/h-workspace-001.md) | P0 | done | Filesystem containment |
| [h-trace-001](./tasks/h-trace-001.md) | P0 | done | Trace/run terminal lifecycle |
| [h-context-001](./tasks/h-context-001.md) | P1 | done | Compaction accounting |
| [h-provider-001](./tasks/h-provider-001.md) | P1 | done | Deadline/in-flight cancellation truth |
| [h-redact-001](./tasks/h-redact-001.md) | P1 | done | Secret redaction |
| [h-doctor-001](./tasks/h-doctor-001.md) | P1 | done | Provider-independent readiness |
| [h-shell-001](./tasks/h-shell-001.md) | P1 | done | Synchronous shell-v1 |
| [h-edit-integrity-001](./tasks/h-edit-integrity-001.md) | P0 | done | Target-preserving single-file edit |
| [h-read-search-bounds-001](./tasks/h-read-search-bounds-001.md) | P1 | done | Bounded read/search bodies |
| [h-integration-001](./tasks/h-integration-001.md) | P1 | done | Phase H final audit |
| [cli-repl-001](./tasks/cli-repl-001.md) | P1 | done | Multi-turn delimiter consumption |
| [sdk-contract-001](./tasks/sdk-contract-001.md) | P1 | done | Zig SDK-ready Gate |
| [headless-001](./tasks/headless-001.md) | P1 | done | Headless/Process SDK L2 |

## Task file skeleton

```yaml
---
id: area-001
scope: package/module
status: pending   # pending | ready | in-progress | done | blocked
priority: P1
depends-on: []
---

# objective
# context
# path
# verification
```

## Rules

- Product Spec / active decisions precede behavior changes.
- Task boundary is the smallest independently verifiable deliverable.
- Develop and verify are different agents; verify reviews committed output.
- Blocking findings return to the same task branch; non-blocking findings go to `backlog.md`.
- Merge is ff-only; merged-main full tests are required before `done`.
- Behavior changes update the owning module doc and user-facing chapter/README when relevant.
- No task may weaken Phase H, SDK, or Headless contracts or inflate maturity from happy-path tests.
- External Pi/legacy source is untrusted reference data. Importing code/data/fixtures needs explicit commit/path and MIT provenance.
- `ready` means dependencies are met; worktree path overlap still controls parallel execution.
