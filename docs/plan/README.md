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
| Zig SDK | **done/L2** at `ebdd7ab` — external consumer 7/7 |
| Headless/Process | **done/L2** at `a1a1e0f` — `headless-v1`, fixture 4/4 |
| Product direction | **done** — `pi-alignment-001`; D-009/D-010 + 11-dimension feature map |
| Core responsibility correction | **observation ownership done** at `b0cabb3` — [D-011](../decisions/active/D-011-thin-agent-core-boundary.md); policy/context ownership moves remain serialized |
| Next code task | `core-policy-ownership-001` **in-progress** (impl committed on task branch; pending merged-main closeout); `harness-events-001` remains re-queued behind the migration |

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
    core-policy-ownership-001 (in-progress)
          → core-context-ownership-001
                  │
                  ▼
        harness-events-001 (M1 product adapter)
           ├────► harness-steering-001
           └────► session-fork-001
                           │
                           ▼
          skills-001 → prompt-templates-001
                    + edit-sharpness-001 (M2)
                           │
                           ▼
                     tui-minimal-001
```

`pi-alignment-001`, `cli-sigint-001`, the D-011 docs node `core-boundary-001`, seam step `core-seams-001`, durable session move `core-session-ownership-001`, and observation move `core-observation-ownership-001` are complete. Source review found that the earlier lifecycle design would add a third Core event channel while leaving product policy/state in the kernel. `core-policy-ownership-001` implementation is committed on the task branch (pending merged-main closeout); all code nodes are serialized, and `harness-events-001` returns only after the thin-Core migration. Task priorities express safety impact; the dependency chain, not priority labels, fixes delivery order.

The [Pi feature correspondence](./analysis/2026-07-26-pi-feature-correspondence.md) maps all 11 documented Pi dimensions to Zig-native outcomes. D-010 records a formal post-foundation extension track: common semantics → C7.1 / E2 process binding → E3 WIT → runtime → capabilities → package, with later Provider/UI worlds separately gated. Zag-native `rpc-v1`, runtime model data, theme, and extension UI are distinct planned capabilities, not ready tasks or implementation claims.

## Task index

### Active / next

| ID | Priority | Status | Scope |
|----|----------|--------|-------|
| [core-policy-ownership-001](./tasks/core-policy-ownership-001.md) | P0 | in-progress | Permission/workspace/shell implementation ownership → coding-agent |
| [core-context-ownership-001](./tasks/core-context-ownership-001.md) | P1 | pending | Protocol history/Core vs context projection/product split |
| [harness-events-001](./tasks/harness-events-001.md) | P1 | pending | Coding-agent SDK lifecycle adapter after D-011 migration |

### Completed foundation

| ID | Priority | Status | Scope |
|----|----------|--------|-------|
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
