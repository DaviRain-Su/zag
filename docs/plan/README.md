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
| Zig SDK | **done/L2** at `ebdd7ab` — Gate fixture 7/7; current external consumer **24/24** (was **23/23** at `61326ae`) |
| Headless/Process | **done/L2** at `a1a1e0f` — `headless-v1`, fixture 4/4 |
| Product direction | **done** — `pi-alignment-001`; D-009/D-010 + 11-dimension feature map |
| Core responsibility correction | **done** through `aecf402` — [D-011](../decisions/active/D-011-thin-agent-core-boundary.md); ownership migration plus the product lifecycle adapter are closed without changing existing L2 rows |
| Product SDK lifecycle | **done** at `aecf402` — coding-agent `LifecycleObserver` over Core source facts plus facade run facts; no Core lifecycle channel |
| Bounded steering/follow-up | **done** at `a5ff2b7` — Session-owned queues + explicit Core `ControlInput`; SDK/Loop enrichment with no maturity change |
| Session fork | **done** at `0a3087f` — idle-only durable child, parent immutability, schema v1, SDK 21/21; Session remains L2 |
| E1 Skills | **done** at `caafef5` — passive discovery/catalog/`read_skill`/activation; SDK 22/22; Runtime Extensions remains L0 |
| Linux SIGINT raw errno | **done** at `bc737025` — `ci-hang-sigint-linux-errno-001`; candidate Gate std 611/611, curl 610/610; merged-main local macOS std 611/611, curl 610/610; maturity unchanged |
| CI safety fuses | **done/closed** at `97f43de` — [ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md); binding [quality/README](../quality/README.md); exact fuses `${{ github.workflow }}-${{ github.ref }}` + `cancel-in-progress: true` + 30m/job; full dual-OS dual-backend retained; independent review + ff-only local merge; **no push**; maturity unchanged |
| Process-idle residual | **done** (Phase B Pass path): [ci-hang-sigint-process-idle-001](./tasks/ci-hang-sigint-process-idle-001.md) — existing idle oracle PASS on fresh remote Linux at tip `8a93ec6` / Actions run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) (Ubuntu std **611/611** + process fixture **2/2**; curl **610/610** + **2/2**; macOS job success; no product/fixture change; fuses did **not** fire). Current Linux idle status is PASS at that exact tip/run only — not a universal future guarantee. CI fuses remain host rails only. |
| Final Linux dual-backend Gate | **done** (docs-only): [linux-dual-backend-gate-001](./tasks/linux-dual-backend-gate-001.md) — full remote dual-OS dual-backend Gate closed at exact product tip `8a93ec6` / Actions run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) (Ubuntu std **40/40 · 611/611** + process fixture **2/2** `126ms`; curl **42/42 · 610/610** + **2/2** `126ms`; libcurl install success; macOS job + both std/curl success; OpenAPI **287/287**; catalog **40**; docs **91/73**; fuses configured but **did not fire**). M0 Linux dual-backend reliability closed **only** at that tip/run — not a universal future guarantee. No product/build/`.github` changes after the remote run (base `b953e0b` is two later docs evidence commits only). |
| Prompt Templates (E1) | **done** at `61326ae` — [prompt-templates-001](./tasks/prompt-templates-001.md) + binding [prompt-templates.md](../modules/prompt-templates.md); passive coding-agent slice + thin CLI routing; Runtime Extensions remains L0 (no E1 maturity raise) |
| Edit sharpness (C4 first slice) | **done** at `7be5151` — [edit-sharpness-001](./tasks/edit-sharpness-001.md) + binding [tools-edit.md](../modules/tools-edit.md) § C4 + [C4-edit-sharpness](../phases/C4-edit-sharpness.md); contract PASS @ `07b8dab`/`f13b0f8` → impl `cfdc81b` → fix `241374a` → docs truth/closeout `7be5151`; candidate + merged-main local macOS std **40/40 · 655/655**, curl **42/42 · 654/654**; coding **375**, CLI **36**, SDK **24/24**; OpenAPI **287**; catalog **40**; docs **92/74**; **no push** / no fresh remote Linux for this tip; Tools · write/edit stays **L2** |
| Minimal TUI (M2 / C9 first slice) | **done** at `f8f7f55` — [tui-minimal-001](./tasks/tui-minimal-001.md) + binding [tui-minimal.md](../modules/tui-minimal.md); contract PASS @ `c7a8f3a` → impl final `f8f7f55` (dual final reviews PASS, zero blockers; PTY + gate21 exclusive workspace); local ff-only merge; task + merged-main local macOS default std **42/42 · 656/656**, curl **44/44 · 655/655**, TUI std **47/47 · 711/711**, TUI curl **49/49 · 710/710**; OpenAPI **287**; catalog **40**; docs **92/74** (55 files); local reflog shows external/other push of `f8f7f55` to `origin/main` (not by this closeout; docs closeout local-only); **no** maturity raise; post-TUI remote default dual-backend Gate is **not** claimed by TUI closeout — see [post-tui-remote-dual-backend-gate-001](./tasks/post-tui-remote-dual-backend-gate-001.md) (**in-progress**, Phase A; target tip `b151307`) |
| Post-TUI remote dual-backend Gate | **in-progress** (Phase A contract) — [post-tui-remote-dual-backend-gate-001](./tasks/post-tui-remote-dual-backend-gate-001.md); exact target tip `b1513073190089bd2dc2473a466373c8a1702f1f` (impl `f8f7f55` + docs closeout lineage); default non-TUI CI matrix only; **no** run id; **no** Gate green; **no** push; Phase B needs fresh authorization; **no** remote `-Dtui`; **no** maturity raise; theme remains pending |

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
curl-linked test artifacts. Maturity unchanged. Process-idle residual later closed via Phase B (see baseline row);
CI fuses (`ci-hang-ci-fuses-001`) **closed** at `97f43de` as host rails only
(`group: ${{ github.workflow }}-${{ github.ref }}`, `cancel-in-progress: true`,
30m per matrix job; full ubuntu/macos + std/curl retained; no `continue-on-error`).
Independent review → `candidate_for_coordinator`; coordinator ff-only local main
`af293b0` → `97f43de` preserving unrelated canonical `.gitignore` (**no push**);
merged-main local macOS Gate again std **40/40 · 611/611**, curl **42/42 · 610/610**,
OpenAPI **287/287**, catalog **40**, docs lint, readability **91**, security **73**.
Remote Actions fuse enforcement is **not** claimed. Process-idle residual
[ci-hang-sigint-process-idle-001](./tasks/ci-hang-sigint-process-idle-001.md)
is **done** via Phase B Pass path on fresh Actions run
[30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011)
against tip `8a93ec6` (created `2026-07-27T14:10:10Z`, completed success
`2026-07-27T14:12:09Z`): Ubuntu job `Zig ubuntu-latest` success — std
**40/40 · 611/611** with process-level SIGINT `run test 2 pass (2 total)
126ms`; curl **42/42 · 610/610** with process-level SIGINT `run test 2 pass
(2 total) 126ms`; libcurl install success; macOS job `Zig macos-latest`
success. Idle oracle (readiness + `waitBounded(4000)` + exit 0 + stderr/leak
assertions) and active std **130** / curl **11** retained inside the 2-test
fixture; **no** product/fixture change; fuses configured but **not** fired.
Linux idle status **PASS** at that exact tip/run only. Final merged-path
Linux dual-backend Gate
[linux-dual-backend-gate-001](./tasks/linux-dual-backend-gate-001.md) is
**done** (docs-only) on the same tip/run: full dual-OS dual-backend matrix
green (OpenAPI **287/287**, catalog **40**, docs **91/73**); M0 Linux
dual-backend reliability closed **only** at exact tip `8a93ec6` / run
`30273762011` — not a universal future guarantee. `prompt-templates-001` is
**done** at `61326ae` (contract `e00255b` → implementation `5487c4b` → review
fix/candidate `61326ae`; merged-main local macOS std **40/40 · 633/633**, curl
**42/42 · 632/632**; Runtime Extensions remains L0; no push / no fresh remote
Linux evidence for this tip).

The `prompt-templates-001` candidate Gate at `61326ae` passed std **40/40 steps,
633/633 tests**, curl **42/42 steps, 632/632 tests**, docs lint/score, and
committed-range diff clean. Independent correctness/boundary review **PASS**
(zero remaining blockers). Coordinator ff-only advanced local main `4fcfb31` →
`61326ae` while preserving an unrelated existing canonical `.gitignore` edit
(**no push**). Merged-main local macOS Gate again: std **40/40 · 633/633**, curl
**42/42 · 632/632**, OpenAPI **287/287**, catalog **40**, docs lint, readability
**91/100** (54 files), security **73/100** (54 files), diff check pass.
Generated quality reports changed timestamps only and were restored. Runtime
Extensions remains L0; no E1 maturity row was raised; Core / session schema v1 /
Trace v1 / headless-v1 / `project.zig` / `--no-project` unchanged.

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
                  │     ├─► ci-hang-ci-fuses-001 (done/closed @ 97f43de; host fuses only)
                  │     ├─► ci-hang-sigint-process-idle-001 (done @ Phase B; tip 8a93ec6 / run 30273762011)
                  │     └─► linux-dual-backend-gate-001 (done; tip 8a93ec6 / run 30273762011; exact tip/run only)
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
          skills-001 (done @ caafef5) ✅ → prompt-templates-001 (done @ 61326ae) ✅
                    + edit-sharpness-001 (done @ 7be5151; Tools write/edit L2)
                           │
                           ▼
                     tui-minimal-001 (done @ f8f7f55; contract PASS @ c7a8f3a)
                           │
                           ▼
          post-tui-remote-dual-backend-gate-001 (in-progress Phase A;
            target tip b151307; no run id; no push)
```

`pi-alignment-001`, `cli-sigint-001`, the D-011 ownership nodes, `harness-events-001`,
`harness-steering-001`, `session-fork-001`, `skills-001`, `prompt-templates-001`,
`edit-sharpness-001`, `tui-minimal-001`, and
`ci-hang-sigint-linux-errno-001` are complete. `edit-sharpness-001` closed at
`7be5151` (contract PASS @ `07b8dab`/`f13b0f8` → impl `cfdc81b` → fix `241374a` →
docs/closeout `7be5151`; candidate + merged-main local macOS std **655/655**, curl
**654/654**; Tools · write/edit stays **L2**; no push / no fresh remote Linux for
this tip).
[tui-minimal-001](./tasks/tui-minimal-001.md) is **done** at `f8f7f55` with binding
[tui-minimal.md](../modules/tui-minimal.md): contract PASS @ `c7a8f3a`;
implementation under **only** `packages/zag-tui/` (lazy `-Dtui`, CLI wire, §11 +
PTY fixtures); dual independent final reviews **PASS** (zero blockers); local
ff-only merge; task + merged-main local macOS default std **656/656**, curl
**655/655**, TUI std **711/711**, TUI curl **710/710**; **no** maturity raise.
Local remote-tracking reflog records an external/other push of `f8f7f55` to
`origin/main`; this closeout did not execute or authorize that push; docs
closeout remains local; remote branch presence is not a Linux/remote Gate.
Post-TUI default-path remote dual-backend Gate is owned by
[post-tui-remote-dual-backend-gate-001](./tasks/post-tui-remote-dual-backend-gate-001.md)
(**in-progress**, Phase A contract): exact target tip
`b1513073190089bd2dc2473a466373c8a1702f1f` (impl `f8f7f55` + local docs closeout
lineage); **no** run id; **no** Gate green; **no** push; Phase B requires fresh
authorization; **no** remote `-Dtui` claim; historical M0 tip/run
`8a93ec6`/`30273762011` is **not** reusable as this tip’s PASS. Source
review rejected the earlier lifecycle design because it would add a third Core event channel while leaving product
policy/state in the kernel; the replacement coding-agent adapter closed at `aecf402`. Bounded steering/follow-up then
closed at `a5ff2b7` with Session-owned queues and a thin Core insertion seam. The safe idle-only durable fork closed at
`0a3087f` after independent reviews and merged-main Gates, without changing session schema v1 or the Session L2 row. E1
passive Skills closed at `caafef5` (coding-agent only; Runtime Extensions remains L0). E1 passive Prompt Templates
closed at `61326ae` (coding-agent only + thin CLI routing; Runtime Extensions remains L0; no E1 maturity raise). The
Linux raw-errno SIGINT hotfix closed at `bc737025` after independent review-fix PASS and merged-main local macOS
dual-backend Gate; pure raw-Linux decoder regressions ran in both std and curl-linked test artifacts. It does not
reopen M0 lifecycle design and does not raise maturity.
[ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md) is **done/closed** at `97f43de` as host rails only
(`workflow+ref` concurrency cancel-in-progress + 30m/job; timeout/cancel ≠ product hang proof; remote Actions
enforcement not claimed). Process-idle residual
[ci-hang-sigint-process-idle-001](./tasks/ci-hang-sigint-process-idle-001.md) is **done** via Phase B Pass path
(no product/fixture change) on Actions
[30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) at tip `8a93ec6` (Ubuntu std
**611/611** + process fixture **2/2**; curl **610/610** + **2/2**; macOS success; `waitBounded(4000)` preserved;
fuses did not fire). Linux idle status **PASS** at that exact tip/run only — not a universal future guarantee.
Final merged-path Linux dual-backend Gate
[linux-dual-backend-gate-001](./tasks/linux-dual-backend-gate-001.md) is **done** (docs-only) on the same tip/run
(Ubuntu std **40/40 · 611/611** + fixture **2/2** `126ms`; curl **42/42 · 610/610** + **2/2** `126ms`; macOS
success; OpenAPI **287/287**; catalog **40**; docs **91/73**). M0 Linux dual-backend reliability is **closed only
at exact tip `8a93ec6` / run `30273762011`** — not a universal future guarantee. `prompt-templates-001` is
**done** at `61326ae` ([task](./tasks/prompt-templates-001.md), binding
[module](../modules/prompt-templates.md)); merged-main local macOS dual-backend Gate std **40/40 · 633/633**, curl
**42/42 · 632/632**; **no push** and no fresh remote/Linux evidence claimed for this tip.
Task priorities express safety impact; the dependency chain, not priority labels, fixes delivery order.

The [Pi feature correspondence](./analysis/2026-07-26-pi-feature-correspondence.md) maps all 11 documented Pi dimensions to Zig-native outcomes. D-010 records a formal post-foundation extension track: common semantics → C7.1 / E2 process binding → E3 WIT → runtime → capabilities → package, with later Provider/UI worlds separately gated. Zag-native `rpc-v1`, runtime model data, theme, and extension UI are distinct planned capabilities, not ready tasks or implementation claims.

## Task index

### Active / next

| Planned node | Status | Scope |
|--------------|--------|-------|
| [post-tui-remote-dual-backend-gate-001](./tasks/post-tui-remote-dual-backend-gate-001.md) | **in-progress** (Phase A) | Docs-first post-TUI **default-path** remote dual-OS dual-backend Gate contract; target tip `b1513073190089bd2dc2473a466373c8a1702f1f`; no run id; no push; Phase B needs fresh authz; **no** remote `-Dtui`; **no** maturity raise |
| theme-001 / RPC / ACP / extension-UI | **pending** (not ready) | **fresh Goal** still required; this Gate does **not** auto-select them |

### Completed foundation

| ID | Priority | Status | Scope |
|----|----------|--------|-------|
| [tui-minimal-001](./tasks/tui-minimal-001.md) | P1 | **done** @ `f8f7f55` | M2/C9 minimal host TUI; contract PASS @ `c7a8f3a` → impl final `f8f7f55` (dual final reviews PASS, zero blockers; PTY + exclusive gate21 workspace); local ff-only merge; task + merged-main local macOS default std **42/42 · 656/656**, curl **44/44 · 655/655**, TUI std **47/47 · 711/711**, TUI curl **49/49 · 710/710**; OpenAPI **287**; catalog **40**; docs **92/74** (55 files); binding [tui-minimal.md](../modules/tui-minimal.md); local reflog external/other push of `f8f7f55` to `origin/main` (not by this closeout; docs closeout local-only); **no** maturity raise; remote default-path Gate deferred to [post-tui-remote-dual-backend-gate-001](./tasks/post-tui-remote-dual-backend-gate-001.md) |
| [edit-sharpness-001](./tasks/edit-sharpness-001.md) | P1 | **done** @ `7be5151` | C4 first slice: `apply_hunk` + `include_digest` + mandatory hunk review + optional post-commit verifier; contract `07b8dab`/`f13b0f8` PASS → impl `cfdc81b` → fix `241374a` → docs `7be5151`; candidate + merged-main local macOS std **40/40 · 655/655**, curl **42/42 · 654/654**; coding **375**, CLI **36**, SDK **24/24**; OpenAPI **287**; catalog **40**; docs **92/74**; no push / no fresh remote Linux for this tip; Tools · write/edit stays **L2** |
| [prompt-templates-001](./tasks/prompt-templates-001.md) | P1 | **done** @ `61326ae` | E1 passive Prompt Templates; coding-agent discovery/catalog/one-pass expand + thin CLI routing; contract `e00255b` PASS → impl `5487c4b` → fix `61326ae`; candidate + merged-main local macOS std **40/40 · 633/633**, curl **42/42 · 632/632**; OpenAPI **287/287**; catalog **40**; docs **91/73**; no push / no fresh remote Linux for this tip; Runtime Extensions remains L0 |
| [linux-dual-backend-gate-001](./tasks/linux-dual-backend-gate-001.md) | P0 | **done** (docs-only Gate) @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) | Final merged-path remote Linux dual-backend Gate; Ubuntu std **40/40 · 611/611** + fixture **2/2** `126ms`, curl **42/42 · 610/610** + **2/2** `126ms`; macOS success; OpenAPI **287/287**; catalog **40**; docs **91/73**; `waitBounded(4000)` + idle 0 + std 130/curl 11 + `linuxRawErrno` + exact fuses preserved; fuses did **not** fire; M0 dual-backend reliability closed **at exact tip/run only**; prompt-templates unblocked for planning; maturity unchanged |
| [ci-hang-sigint-process-idle-001](./tasks/ci-hang-sigint-process-idle-001.md) | P0 | **done** (Phase B) @ tip `8a93ec6` / run [30273762011](https://github.com/DaviRain-Su/zag/actions/runs/30273762011) | Idle process-fixture residual; Ubuntu std **611/611** + fixture **2/2**, curl **610/610** + **2/2**; macOS success; no product/fixture change; `waitBounded(4000)` + std 130/curl 11 preserved; final Linux Gate closed by [linux-dual-backend-gate-001](./tasks/linux-dual-backend-gate-001.md); maturity unchanged |
| [ci-hang-ci-fuses-001](./tasks/ci-hang-ci-fuses-001.md) | P0 | done/closed @ `97f43de` | Exact fuses `${{ github.workflow }}-${{ github.ref }}` + cancel-in-progress + 30m/job; dual-OS dual-backend retained; review + ff-only local merge; no push; process-idle residual **done**; final Linux Gate **done** at exact tip/run; maturity unchanged |
| [ci-hang-sigint-linux-errno-001](./tasks/ci-hang-sigint-linux-errno-001.md) | P0 | done | Raw Linux `std.os.linux.errno` decode for SIGINT self-pipe under curl/`link_libc`; closed at `bc737025`; maturity unchanged; broader M0 dual-backend Gate closed later at exact tip/run only |
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
