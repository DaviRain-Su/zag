# Next delivery plan (from HEAD)

> Date: 2026-08-13
> Frozen tip: `6869549` (`feat(tui): control queue pane + git-diff tool body gutters`)
> Branch: `main` = `origin/main`, clean tree
> Decision frame: [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
> Status truth for *maturity claims*: still [maturity.md](../../maturity.md) (L2 floor unchanged)
> Status truth for *what to do next*: **this file** (when roadmap / plan README / task frontmatter disagree)

This is an implementable delivery plan, not a capability essay. Each wave names
owner package, first Goal, files, fixtures, and a hard stop.

## 0. How to execute

1. One Goal at a time. Contract (if missing) → dual review → impl → fixtures → closeout.
2. Do not raise a [maturity.md](../../maturity.md) row unless the Goal says so.
3. Do not wait for the post-TUI remote Gate to start Wave 1. That Gate needs a
   **fresh user grant** and a TARGET rebind (see §5).
4. Kernel law stays: no process/LSP/MCP/RPC/ACP/subagent types in `zag-agent-core`.
5. When this file and an older DAG conflict, follow this file, then fix the
   older doc in Wave 0 — do not silently re-open a closed L2 row.

## 1. HEAD inventory (code vs docs)

Code on `6869549` is ahead of `roadmap.md`, `docs/plan/README.md`,
`docs/modules/README.md`, and several task/module frontmatters.

| Capability | Code on HEAD | Task / module truth | Maturity |
|------------|--------------|---------------------|----------|
| Phase H / SDK / headless | closed | closed | **L2** |
| `apply_hunk` / `apply_transaction` | done | done @ `7be5151` / `e086df8` | Tools write/edit **L2** (no L3) |
| Process supervisor | **not implemented** | [process-supervisor-001](../tasks/process-supervisor-001.md) **draft** | Shell stays L2; no tree-ownership claim |
| `rpc-v1` (`--rpc`) | implemented @ `0eeef5d` | task `implemented`; module still says **draft** | no row |
| ACP v1 (`--acp`) | implemented @ `8d2ba64` (32/33 fixture gates; gate15 follow-up) | task `implemented`; closeout pending | no row |
| `code_intel` / LSP client | implemented @ `75f213b` | task `implemented`; closeout pending | no row |
| In-process `task` subagent + TUI pane | implemented @ `1dabd25` / `7f058ce` | [subagents-001](../tasks/subagents-001.md) **implemented**; Oracle/Graph still L0 | Subagents/Oracle row **L0** |
| Session `/resume` tree browser | implemented @ `298f207` | task `implemented` | Session stays L2 (no tree schema) |
| TUI canvas / grok chrome / md / thinking / themes / scrollback | landed through `6869549` | polish/scrollback **implemented**; remaining bugs = new tasks | no TUI maturity row |
| Theme | built-in themes landed (`f5e1356`) | [theme-001](../tasks/theme-001.md) **done** | no row |
| MCP / E2 process extensions | **absent** | no task | Runtime Extensions **L0** |
| Memory Repo | **absent** | [memory.md](../../modules/memory.md) stub | **L0** |
| OS sandbox / mid-flight preemption | **absent** | C7.2 deferred | not claimed |
| Post-TUI remote dual-backend Gate | Phase A docs only | [post-tui-remote-dual-backend-gate-001](../tasks/post-tui-remote-dual-backend-gate-001.md) in-progress; TARGET `f352b60` **~70 commits behind HEAD** | no raise |

**Implication:** D-012 items 1, 2, 4, and a first in-process slice of item 5
already have product code. Item 3 (supervisor) and item 6 (MCP/E2) do not.
The 2026-08-06 "supervisor before LSP/rpc/ACP/subagents" DAG is **historically
true as intent, operationally false as HEAD**. Later slices documented
"does not block on supervisor" and shipped anyway. This plan starts from that
fact instead of pretending the old order is still open.

## 2. What is actually missing

Three different holes. Do not mix them.

| Hole | Why it blocks | First wave |
|------|---------------|------------|
| **A. Docs lie** | Agents and humans will implement "roadmap-only rpc/LSP" or skip closeout | Wave 0 |
| **B. No process owner** | `run_shell` is still synchronous capture; LSP/MCP children are ad-hoc spawn; no truthful cancel/reap/timeout API for *all* executable children | Wave 1 |
| **C. Landed slices unclosed** | Dual review open, module status draft, contradictory task bodies, no Gate record — easy to regress | Wave 2 |
| **D. MCP / Memory / sandbox** | Real product gaps, but they are *after* A–C | Wave 3+ |

## 3. Revised delivery DAG (from HEAD)

```text
Wave 0  docs-truth (no product code)
   │
   ├──────────────────────────────────────────────┐
   ▼                                              ▼
Wave 1  process-supervisor-001                    Wave 2  closeout already-landed
        draft → dual review → ready → impl                rpc-v1 / ACP / LSP
        migrate run_shell onto Supervisor                 subagents module+task
        Shell goldens stay green                          TUI stale-task closeout
   │                                              │
   └──────────────┬───────────────────────────────┘
                  ▼
Wave 3  supervisor consumers (only after Wave 1 impl)
        LSP child migrates onto a supervised slot
        mcp-001 (new contract) — E2 process adapter
        optional: process-backed subagent (current is in-process)
                  │
                  ▼
Wave 4  deferred until a reproduced user failure
        Memory Repo · repo map · Graph/Oracle · E3 WASM · OS sandbox
        remote `-Dtui` · semver publish
```

Host-shell TUI polish and the post-TUI remote Gate stay **orthogonal**. They
must not serialize Wave 1.

## 4. Waves (implementable)

### Wave 0 — Docs truth (P0, docs-only, start now)

**Goal:** a later agent reading `INDEX` / `roadmap` / `plan/README` /
`modules/README` / task frontmatter describes HEAD correctly.

**Owner:** docs only. **Forbidden:** `packages/**`, `src/**`, `build.zig*`,
`.github/**`.

**Do these edits in one (or two) commits:**

| File | Change |
|------|--------|
| [roadmap.md](../../roadmap.md) §当前状态 | D-012 coding track: rpc/LSP/ACP/subagent **implemented (closeout pending)**; supervisor **draft**; MCP **absent** |
| [plan/README.md](../README.md) Active / next | Point here; stop listing rpc/ACP as "pending / not ready" |
| [modules/README.md](../../modules/README.md) | Add rows for `rpc-v1.md`, `acp.md`, `lsp.md`; mark supervisor still draft; mark subagents "in-process slice landed, module stale" |
| [rpc-v1.md](../../modules/rpc-v1.md) | Status line: contract draft **but implementation landed** @ `0eeef5d` (closeout ≠ unstarted) |
| [acp-001.md](../tasks/acp-001.md) | Delete the contradictory "Implementation: not started" block; one status table |
| [theme-001](../tasks/theme-001.md) / C9 / plan README | Theme **has** canvas implementation; contract PASS is historical, not "no code" |
| [tui-polish-001](../tasks/tui-polish-001.md) / [tui-scrollback-001](../tasks/tui-scrollback-001.md) | Status → `implemented` (or `done` if fixtures already green); do not leave `contract-draft` after merge |
| [subagents-oracle.md](../../modules/subagents-oracle.md) | Split: in-process `task`/`scout`/`reviewer` **exists**; Oracle/Graph/process-backed still L0 |
| [C6-orchestration.md](../../phases/C6-orchestration.md) | Stop saying subagents are unimplemented |
| [C9-product-shell.md](../../phases/C9-product-shell.md) | `rpc-v1` is no longer "future" |
| [maturity.md](../../maturity.md) | **Do not raise rows.** Add a short "code landed, no Gate" note for rpc/ACP/LSP/subagent so the matrix does not look like they are still L0-absent |
| [README.md](../../../README.md) | Stop saying "C4–C9 未开始" |

**Wave 0 status (2026-08-13):** docs truth applied on this working tree.
`python3 scripts/lint_docs.py` is the Gate. Remaining Waves: 1 (supervisor),
2 closeout reviews, 3 MCP/slots.

**Done when:** `python3 scripts/lint_docs.py` OK; no Active table still calls
rpc/LSP/ACP "roadmap-only"; task bodies do not contradict their frontmatter.

**Hard stop:** do not "fix" maturity numbers, Gate counts, or TARGET hashes
without evidence.

### Wave 1 — Process supervisor v1 (P0, the real product hole)

Existing task: [process-supervisor-001](../tasks/process-supervisor-001.md)
Binding: [process-supervisor.md](../../modules/process-supervisor.md)

This is C7.1, not C7.2. No OS sandbox claim.

#### 1a. Dual review → `ready` (docs, ~1 Goal)

Two independent reviews, as the task already requires:

| Review | Asks |
|--------|------|
| architecture/ownership | coding-agent only; no Core process ports; no Session PID fields |
| safety/lifecycle | one Terminal per spawn; caps; cooperative then hard kill; no silent zombies |

Close the four open questions in process-supervisor.md §8 **in the review**,
recommended freeze:

| # | Freeze for v1 |
|---|----------------|
| 1 | New file `packages/zag-coding-agent/src/runtime/process_supervisor.zig`. No new package. |
| 2 | Atomic `run_shell` migration in one impl PR. Keep shell-v1 goldens as the regression Gate; no long-lived dual backend flag. |
| 3 | Portable **direct-child** PID only. Linux `setpgid` / full tree reaper = later Gate. |
| 4 | First-line atoms reuse overlapping shell-v1 strings; new atoms only for supervisor-specific terminals (`spawn_failed`, `timed_out` if not already present). |

Task frontmatter `draft` → `ready` only after both reviews PASS.

#### 1b. Implementation Goal (after `ready`)

| Item | Binding |
|------|---------|
| Package | `zag-coding-agent` only |
| Public-to-product API | internal `Supervisor`: `spawn` / `wait` / `cancel` / `collect` |
| Model Tool | **none new** — `run_shell` becomes a client of Supervisor |
| CLI / TUI | signal still goes through existing Cancel / `sigint.Guard`; they must not `kill` children behind Supervisor |
| Session / Trace / headless schemas | unchanged |
| Background jobs | **out of v1** |

**Files (expected):**

- `packages/zag-coding-agent/src/runtime/process_supervisor.zig` (new)
- `packages/zag-coding-agent/src/runtime/edit_tools.zig` (or current `run_shell` owner) — migrate spawn/pump
- tests next to existing shell fixtures; add the 10 classes already listed in the module

**Fixture classes (already in the binding — implement all 10):**

1. happy echo → `completed` + `exit=0`
2. nonzero exit truthful
3. timeout → `timed_out`; process gone; no hang
4. cooperative cancel → reaped
5. hard kill after cancel budget; no orphan under the test harness
6. output over cap → truncated marker; finite memory
7. ShellPolicy deny → no spawn
8. jail cwd escape → fail closed pre-spawn
9. existing shell-v1 goldens green
10. ownership scan: no Core process symbols

**Done when:** dual review of *code* PASS; shell-v1 matrix green; coding-agent
tests green; maturity Shell/Workspace rows **stay L2**; no sandbox sentence
added anywhere.

**Hard stop:** do not fold LSP/MCP protocol work into this PR. Supervisor is
the execution owner; protocols stay in their modules.

### Wave 2 — Close out what already shipped (P0/P1, parallel with 1a)

Each slice is its own Goal. None of them wait on Wave 1 impl. None raise
maturity.

| ID | Code commit | Closeout work | Owner |
|----|-------------|---------------|--------|
| rpc-v1-001 | `0eeef5d` | Dual review of frozen module vs server; mark module status `implemented`; record fixture counts (task already claims 26/26 process fixture) | `zag-cli` |
| acp-001 | `8d2ba64` | Same; fix internal status contradiction; keep ACP ≠ rpc-v1 | `zag-cli` |
| lsp-001 | `75f213b` | Dual review; document "own spawn until supervisor slot exists"; env allow-list stays open if still open | `zag-coding-agent` |
| subagents (new task `subagents-001` if missing) | `1dabd25` | Write the missing task+binding delta: in-process `task`/`scout`/`reviewer`, depth 1, ephemeral child Session, filtered toolset. Update stub module. Oracle/Graph remain L0. | `zag-coding-agent` + `zag-tui` pane |
| tui-polish / tui-scrollback / md-phase2 | various | Align task status with merged code; only file *remaining* visual bugs as new tasks | `zag-tui` |

**Done when:** a reader of the task file can tell "shipped, closeout pending"
from "not started". Independent review records exist or are explicitly
deferred with a named reason (not silence).

**Hard stop:** do not rewrite rpc/ACP/LSP to sit on Supervisor in this wave.
That is Wave 3.

### Wave 3 — Supervisor consumers (only after 1b)

Start here only when `run_shell` is actually on Supervisor.

#### 3a. LSP slot migration (small)

[lsp.md](../../modules/lsp.md) already says the child migrates when Supervisor
gains long-lived slots. v1 supervisor as drafted is **foreground-bounded**
(mandatory deadline, no background jobs). That is **not** enough for zls.

**Decision required before coding:** either

- **3a-A (recommended):** extend Supervisor in a *second* slice
  `process-supervisor-long-lived-001` — persistent bidirectional stdio slot,
  idle timeout, kill on Agent deinit; **then** move the LSP client onto it; or
- **3a-B:** leave LSP on its hand-rolled spawn until that slice exists, and
  document it as a known exception in maturity/tools-shell.

Do not pretend Wave 1 v1 hosts zls.

#### 3b. `mcp-001` (new, D-012 item 6)

No task exists today. First Goal is **docs-only contract**:

| Freeze | v1 recommendation |
|--------|-------------------|
| Owner | `zag-coding-agent` runtime + thin CLI flag later |
| Transport | local stdio MCP client (one server process per configured server) |
| Carrier | E2 = supervised process (requires 3a-A long-lived slots) |
| Surface | Tools advertised by the MCP server, mapped through D-007 descriptors; missing caps fail-closed |
| Trust | user-configured, same-user, workspace-scoped; not a marketplace |
| Non-goals | network MCP, OAuth, resource subscriptions as a first slice, E3 WASM |

Do not start MCP on raw `std.process.Child`.

#### 3c. Process-backed subagents (optional)

Current `task` tool is **in-process, parent-blocking, ephemeral Session**.
That is a valid first slice. A process-isolated / worktree child is a
**different** Goal and needs Supervisor long-lived (or job) slots plus a
reproduced failure (runaway child, tool-set leak, writer conflict). Do not
schedule it just because D-012 listed "typed subagents".

### Wave 4 — Deferred (do not start)

Need a reproduced user failure + new task. Not implied by D-012 existing.

| Item | Why deferred |
|------|----------------|
| Memory Repo | [memory.md](../../modules/memory.md): default-off; no write→retrieve→delete use case |
| Repo map | C5.1: wait for measured file-selection failure |
| Oracle / Graph | C6: in-process subagent is not Oracle and not a DAG |
| E3 WASM | after E2 semantics + capability Gates (D-010) |
| OS sandbox (C7.2) | after C7.1 exists *and* an untrusted executable consumer exists |
| Semver / C ABI / second consumer publish | SDK Gate already closed; publish waits on a real second consumer |
| Remote `-Dtui` | not the post-TUI default-path Gate |

### Orthogonal tracks (do not serialize Wave 1)

| Track | Status | Next action |
|-------|--------|-------------|
| post-TUI remote Gate | Phase A; TARGET `f352b60` stale vs HEAD | See §5. Needs **user grant**. |
| openai-retry-after-001 | contract-draft | Independent of supervisor; small wire Goal when someone is in `zag-ai` |
| Remaining TUI bugs | grok chrome landed | File *new* tasks for remaining visual defects only after Wave 0 closes stale ones |
| Retry-After Anthropic | already implemented | leave alone |

## 5. Post-TUI remote Gate (ops, not product)

[post-tui-remote-dual-backend-gate-001](../tasks/post-tui-remote-dual-backend-gate-001.md)
is **not** a coding-agent feature. It is default-path (non-TUI) remote CI
evidence.

Facts:

- Phase B has **no** grant on HEAD.
- Frozen TARGET `f352b60` is not HEAD. A Gate green on that TARGET does not
  speak for `6869549`.
- Historical M0 tip `8a93ec6` / run `30273762011` is not reusable.

**If you want remote evidence for current main:**

1. Class C rebind: docs-only product-delta accounting `f352b60..6869549` (or
   whatever HEAD is at rebind time).
2. Fresh user `observation_grant` or `push_grant` naming the **new** TARGET.
3. Phase B run; record run id; only then say Gate green.

**If you do not have a grant:** leave the task in-progress and do Wave 0–1.
Do not push "to get CI green" as a substitute for the grant protocol.

## 6. First three Goals (start in this order)

These are sized for one engineer. Do not parallelize 1b with new protocols.

| # | Goal | Kind | Approx |
|---|------|------|--------|
| **G0** | Wave 0 docs truth | docs | half day |
| **G1** | process-supervisor dual review → `ready` | docs + two reviews | 1 day |
| **G2** | process-supervisor impl + 10 fixtures + shell-v1 regression | product in `zag-coding-agent` | 2–3 days |

After G2 lands, pick **one**: rpc closeout, ACP closeout, or LSP closeout
(Wave 2). Then, and only then, a long-lived supervisor slot (3a-A) if MCP or
zls-on-supervisor is the next product need.

Suggested commit subjects:

```text
docs: freeze next delivery plan from HEAD 6869549
docs: Wave 0 — align roadmap/modules/tasks with landed rpc/ACP/LSP/TUI
docs: process-supervisor-001 dual review PASS → ready
feat: process supervisor v1 — run_shell migrates onto Supervisor
```

## 7. Non-goals (explicit)

- Raising Tools/Shell/Session/Runtime Extensions above current rows
- Pi / OMP / Hyper API or schema parity (D-009)
- Putting spawn/PID/MCP in Core
- Background job product surface in supervisor v1
- Starting MCP, Memory, WASM, or OS sandbox in the same PR as Supervisor
- Using `--yolo` as a default in docs or demos
- Rewriting the TUI while Wave 1 is open, except for regressions you just caused

## 8. Definition of "D-012 local coding-agent: remaining"

A local developer can already: durable session, multi-file edit, jail+ask,
headless JSON, optional TUI, `--rpc`, `--acp`, `code_intel`, in-process
`task` subagent.

Still required before calling the D-012 target **closed** (each still its own
Gate, none automatic):

1. Supervisor v1 owns `run_shell` (Wave 1).
2. Long-lived supervised stdio slots exist if LSP/MCP children should not be
   exceptions (Wave 3a-A).
3. MCP v1 contract + impl on those slots (Wave 3b) — only if you still want
   D-012 item 6; it is optional as a *product* until a user needs a specific
   MCP server.
4. Closeout records for rpc/ACP/LSP/subagent so they are not "mystery code".
5. Memory / Oracle / Graph / WASM / sandbox remain **out** of that closeout
   unless a new decision says otherwise.

## Related

- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
- [D-009](../../decisions/active/D-009-pi-semantics-not-parity-fork.md) ·
  [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md) ·
  [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md)
- [2026-08-06 local-agent analysis](./2026-08-06-pi-omp-hyper-local-agent-analysis.md)
  (capability target; **delivery order superseded by this file**)
- [process-supervisor-001](../tasks/process-supervisor-001.md) ·
  [rpc-v1-001](../tasks/rpc-v1-001.md) ·
  [acp-001](../tasks/acp-001.md) ·
  [lsp-001](../tasks/lsp-001.md)
- [maturity.md](../../maturity.md) · [roadmap.md](../../roadmap.md)
