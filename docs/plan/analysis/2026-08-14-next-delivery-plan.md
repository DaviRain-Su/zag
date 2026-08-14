# Next delivery plan (from HEAD)

> Date: 2026-08-14
> Frozen tip: `fe075f1` (`feat(zag-live): live runtime prototype track + Route A productization`)
> Ancestor of the previous freeze: `6869549` (2026-08-13 plan)
> Decision frame: [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
> Status truth for *maturity claims*: still [maturity.md](../../maturity.md) (L2 floor unchanged)
> Status truth for *what to do next*: **this file** (when roadmap / plan README / task frontmatter disagree)
> Supersedes: [2026-08-13 next delivery plan](./2026-08-13-next-delivery-plan.md) for delivery *order* and HEAD inventory. That file remains historical.

This is an implementable delivery plan, not a capability essay. Each wave names
owner package, first Goal, files, fixtures, and a hard stop.

## 0. How to execute

1. One Goal at a time. Contract (if missing) → dual review → impl → fixtures → closeout.
2. Do not raise a [maturity.md](../../maturity.md) row unless the Goal says so.
3. Do not wait for the post-TUI remote Gate to start Wave 1. That Gate needs a
   **fresh user grant** and a TARGET rebind (see §6).
4. Kernel law stays: no process/LSP/MCP/RPC/ACP/subagent types in `zag-agent-core`.
5. When this file and an older DAG conflict, follow this file, then fix the
   older doc — do not silently re-open a closed L2 row.
6. Live-runtime (D-013/D-014) is **orthogonal** to Wave 1. Do not serialize it
   behind supervisor review, and do not fold it into MCP/sandbox work.

## 1. HEAD inventory (code vs docs)

Code on `fe075f1` is two commits ahead of the 08-13 freeze `6869549`
(`eb27b31` then `fe075f1`). The 08-13 plan's "supervisor not implemented"
sentence is **operationally false** on this tip.

| Capability | Code on HEAD | Task / module truth | Maturity |
|------------|--------------|---------------------|----------|
| Phase H / SDK / headless | closed | closed | **L2** |
| `apply_hunk` / `apply_transaction` | done | done @ `7be5151` / `e086df8` | Tools write/edit **L2** (no L3) |
| Process supervisor | **landed** — `runtime/process_supervisor.zig`; `run_shell` uses `runForeground` | [process-supervisor-001](../tasks/process-supervisor-001.md) was `draft` (review open) | Shell stays L2; no tree-ownership claim |
| `rpc-v1` (`--rpc`) | implemented @ `0eeef5d` | task `implemented`; closeout was pending | no row |
| ACP v1 (`--acp`) | implemented @ `8d2ba64` (32/33; gate15 follow-up) | task `implemented`; closeout was pending | no row |
| `code_intel` / LSP client | implemented @ `75f213b` | task `implemented`; owns spawn until long-lived slots | no row |
| In-process `task` subagent + TUI pane | implemented @ `1dabd25` / `7f058ce` | [subagents-001](../tasks/subagents-001.md) `implemented`; Oracle/Graph still L0 | Subagents/Oracle row **L0** |
| Session `/resume` tree browser | implemented @ `298f207` | task `implemented` | Session stays L2 (no tree schema) |
| TUI canvas / grok chrome / md / thinking / themes / scrollback | landed through `6869549` | polish/scrollback `implemented` | no TUI maturity row |
| Theme | built-in themes landed (`f5e1356`) | [theme-001](../tasks/theme-001.md) **done** | no row |
| `zag-live` package | landed @ `fe075f1` (23/23) | [zag-live-001](../tasks/zag-live-001.md) **done** | experimental; no row |
| Live provider bridge / prompt surface | **absent** | zag-live-002 / 003 were missing tasks | no row |
| MCP / E2 process extensions | **absent** | no task until this plan | Runtime Extensions **L0** |
| Memory Repo | **absent** | [memory.md](../../modules/memory.md) stub | **L0** |
| OS sandbox / mid-flight preemption | **absent** | C7.2 deferred | not claimed |
| Post-TUI remote dual-backend Gate | Phase A docs only | [post-tui-remote-dual-backend-gate-001](../tasks/post-tui-remote-dual-backend-gate-001.md) in-progress; TARGET `f352b60` stale vs HEAD | no raise |

**Implication:** D-012 items 1, 2, 4, and a first in-process slice of item 5
have product code. Item 3 (supervisor) has **code** but was missing dual
review / closeout. Item 6 (MCP/E2) does not. Live policy (D-014) has a
package and no product surface.

## 2. What is actually missing

Four different holes. Do not mix them.

| Hole | Why it blocks | Wave |
|------|---------------|------|
| **A. Docs lie (08-13 tip)** | Agents will treat supervisor as unstarted or skip zag-live | Wave 0 |
| **B. Supervisor unclosed** | Impl exists; contract still `draft`; fixture 7 is policy-only; cancel path must reap | Wave 1 |
| **C. Landed slices unclosed** | Dual review open; ACP gate15 residual; easy to regress | Wave 2 |
| **D. Live policy not wired** | `zag-live` cannot talk to a real provider or change prompts | Track L |
| **E. No long-lived process owner** | LSP/MCP children stay ad-hoc spawn | Wave 3 |
| **F. MCP / Memory / sandbox** | Real product gaps *after* A–E | Wave 3+ / 4 |

## 3. Revised delivery DAG (from HEAD)

```text
Wave 0  docs-truth (this file + pointer updates)
   │
   ├──────────────────────────┬──────────────────────────┐
   ▼                          ▼                          ▼
Wave 1  supervisor            Wave 2  closeout           Track L  zag-live-002
        review → ready →              rpc / ACP /                → zag-live-003
        fixture holes →               LSP / subagent             (orthogonal)
        closeout
   │
   └──────────────┬───────────┘
                  ▼
Wave 3  long-lived stdio slot
        LSP child migrates onto a supervised slot
        mcp-001 (contract first; impl only with a named MCP server)
        optional: process-backed subagent
                  │
                  ▼
Wave 4  deferred until a reproduced user failure
        Memory Repo · repo map · Graph/Oracle · E3 WASM · OS sandbox
        remote `-Dtui` · semver publish
```

Host-shell TUI polish and the post-TUI remote Gate stay **orthogonal**.

## 4. Waves

### Wave 0 — Docs truth (P0, docs-only)

**Goal:** a later agent reading `INDEX` / `roadmap` / `plan/README` /
`modules/README` describes HEAD `fe075f1` correctly and follows **this** file.

**Owner:** docs only. **Forbidden:** `packages/**`, `src/**`, `build.zig*`,
`.github/**` for the pointer commit itself. Later waves may touch product
code under their own Goals.

**Edits:**

| File | Change |
|------|--------|
| this file | freeze |
| [INDEX.md](../../INDEX.md) | next-plan pointer → 08-14; supervisor **impl landed / review**; zag-live-001 done |
| [roadmap.md](../../roadmap.md) | same; D-012 table |
| [plan/README.md](../README.md) | Active / next |
| [analysis/README.md](./README.md) | this file is current delivery truth |
| [maturity.md](../../maturity.md) | **Do not raise rows.** Add a 2026-08-14 sync note |
| [README.md](../../../README.md) | next-plan pointer |

**Done when:** `python3 scripts/lint_docs.py` OK; no Active table still calls
supervisor "not implemented".

**Hard stop:** do not "fix" maturity numbers, Gate counts, or TARGET hashes
without evidence.

### Wave 1 — Process supervisor closeout (P0, D-012 item 3)

Existing task: [process-supervisor-001](../tasks/process-supervisor-001.md)
Binding: [process-supervisor.md](../../modules/process-supervisor.md)

This is C7.1, not C7.2. No OS sandbox claim. **Do not rewrite from zero.**

#### 1a. Dual review → freeze §8

Two independent reviews:

| Review | Asks |
|--------|------|
| architecture/ownership | coding-agent only; no Core process ports; no Session PID fields; §8 four freezes |
| safety/lifecycle | one Terminal per spawn; caps; cooperative then hard kill; no silent zombies |

§8 v1 freeze (now binding, not "proposed"):

| # | Freeze |
|---|----------------|
| 1 | `packages/zag-coding-agent/src/runtime/process_supervisor.zig`. No new package. |
| 2 | Atomic `run_shell` migration. shell-v1 goldens are the regression Gate. No dual backend flag. |
| 3 | Portable **direct-child** PID only. Linux `setpgid` / full tree reaper = later Gate. |
| 4 | First-line atoms reuse overlapping shell-v1 strings; supervisor-specific terminals may add `spawn_failed` / `timed_out` if not already present. |

#### 1b. Fixture holes

Module §6 classes 1–6, 8, 10 already exist as tests in
`process_supervisor.zig`. Required closeout fixes:

1. After `cancel`, `wait` must **reap** (no zombie until `deinit`).
2. Fixture 7 must be a supervisor-side fail-closed seam (`rejectDeniedShell`),
   not only `shell_policy.check`.
3. Fixture 9 remains the existing shell-v1 goldens (run_shell → `runForeground`).

#### 1c. Closeout

Task → `implemented` (or `done` if reviews + fixtures green). Module status
`implemented`. Shell/Workspace rows **stay L2**. No sandbox sentence.

**Hard stop:** do not fold LSP/MCP protocol work into this Goal.

### Wave 2 — Close out what already shipped (P0/P1, parallel with 1a)

Each slice is its own Goal. None wait on Wave 1 impl. None raise maturity.
None rewrite spawn onto Supervisor (that is Wave 3).

| ID | Code commit | Closeout work | Owner |
|----|-------------|---------------|--------|
| rpc-v1-001 | `0eeef5d` | Dual review of frozen module vs server; mark module `implemented`; record fixture **26/26** | `zag-cli` |
| acp-001 | `8d2ba64` | Same; keep ACP ≠ rpc-v1; gate15 remember residual named (fix or dedicated follow-up) | `zag-cli` |
| lsp-001 | `75f213b` | Dual review; document "own spawn until supervisor long-lived slots"; env allow-list stays open | `zag-coding-agent` |
| subagents-001 | `1dabd25` | Binding already splits in-process vs Oracle/Graph; record closeout review | `zag-coding-agent` + `zag-tui` pane |

**Hard stop:** do not rewrite rpc/ACP/LSP to sit on Supervisor in this wave.

### Track L — Live policy (P1, orthogonal)

D-014 Route A. Opt-in, default-off. Image down → static default. Chez missing
→ surface off; must not break L2. zag-live keeps owning its Chez child
(documented supervisor exception).

| ID | Kind | Freeze |
|----|------|--------|
| [zag-live-002](../tasks/zag-live-002.md) | new task + [contract](../../modules/zag-live-provider.md) | Provider port fulfilled via `zag-ai` **outside** `zag-live`; package still depends on `zag-types` only; credentials never enter Chez |
| [zag-live-003](../tasks/zag-live-003.md) | new task + [contract](../../modules/zag-live-prompt.md) | First coding-agent live surface = prompt construction; flag/config off → today's bytes |

Later surfaces (tool registry, memory policy, input vault) are separate
tasks. Do not pre-build them.

### Wave 3 — Supervisor consumers (only after Wave 1 closeout)

v1 supervisor is **foreground-bounded**. It does **not** host zls or MCP.

| ID | Kind | Freeze |
|----|------|--------|
| [process-supervisor-long-lived-001](../tasks/process-supervisor-long-lived-001.md) | new | Persistent bidirectional stdio slot, idle timeout, kill on Agent deinit |
| LSP slot migration | after long-lived | Move `code_intel` child onto the slot; protocol unchanged |
| [mcp-001](../tasks/mcp-001.md) | **contract first** | Local stdio MCP; one process per configured server; D-007 descriptors; missing caps fail-closed; **no** raw `std.process.Child`. Impl only when a named user MCP server exists |
| process-backed subagent | optional | Different Goal from in-process `task`; needs a reproduced runaway / tool-leak / writer-conflict |

### Wave 4 — Deferred (do not start)

| Item | Why deferred |
|------|----------------|
| Memory Repo | [memory.md](../../modules/memory.md): default-off; no write→retrieve→delete use case |
| Repo map | C5.1: wait for measured file-selection failure |
| Oracle / Graph | C6: in-process subagent is not Oracle and not a DAG |
| E3 WASM | after E2 semantics + capability Gates (D-010) |
| OS sandbox (C7.2) | after C7.1 exists *and* an untrusted executable consumer exists |
| Semver / C ABI / second consumer publish | SDK Gate already closed; publish waits on a real second consumer |
| Remote `-Dtui` | not the post-TUI default-path Gate |

## 5. Orthogonal tracks (do not serialize Wave 1)

| Track | Status | Next action |
|-------|--------|-------------|
| post-TUI remote Gate | Phase A; TARGET `f352b60` stale vs HEAD | See §6. Needs **user grant**. |
| openai-retry-after-001 | contract-draft | Independent of supervisor; small wire Goal when someone is in `zag-ai` |
| Remaining TUI bugs | grok chrome landed | File *new* tasks for remaining visual defects only |
| TUI launch | `zig build run -Dtui=true -- --tui` | Requires TTY; exclusive vs `--json`/`--rpc`/`--acp`/`--doctor`/`-v` |

## 6. Post-TUI remote Gate (ops, not product)

[post-tui-remote-dual-backend-gate-001](../tasks/post-tui-remote-dual-backend-gate-001.md)
is **not** a coding-agent feature. It is default-path (non-TUI) remote CI
evidence.

Facts:

- Phase B has **no** grant on HEAD.
- Frozen TARGET `f352b60` is not HEAD. A Gate green on that TARGET does not
  speak for `fe075f1`.
- Historical M0 tip `8a93ec6` / run `30273762011` is not reusable.

**If you want remote evidence for current main:**

1. Class C rebind: docs-only product-delta accounting `f352b60..fe075f1`
   (or whatever HEAD is at rebind time).
2. Fresh user `observation_grant` or `push_grant` naming the **new** TARGET.
3. Phase B run; record run id; only then say Gate green.

**If you do not have a grant:** leave the task in-progress and do Wave 0–2 /
Track L. Do not push "to get CI green" as a substitute for the grant protocol.

## 7. First Goals (start in this order)

| # | Goal | Kind |
|---|------|------|
| **G0** | Wave 0 docs truth | docs |
| **G1** | process-supervisor dual review + fixture holes + closeout | docs + `zag-coding-agent` |
| **G2** | Wave 2 closeout reviews (rpc / ACP / LSP / subagent) | docs; ACP gate15 named |
| **G3** | zag-live-002 + zag-live-003 contracts | docs |
| **G4** | long-lived slot + mcp-001 contracts | docs; no MCP impl |

Suggested commit subjects:

```text
docs: freeze next delivery plan from HEAD fe075f1
docs: process-supervisor-001 dual review PASS → implemented
docs: Wave 2 closeout records for rpc/ACP/LSP/subagent
docs: zag-live-002/003 + long-lived slot + mcp-001 contracts
```

## 8. Non-goals (explicit)

- Raising Tools/Shell/Session/Runtime Extensions above current rows
- Pi / OMP / Hyper API or schema parity (D-009)
- Putting spawn/PID/MCP in Core
- Background job product surface in supervisor v1
- Starting MCP impl, Memory, WASM, or OS sandbox in the same PR as Supervisor
- Using `--yolo` as a default in docs or demos
- Rewriting the TUI while Wave 1 is open, except for regressions you just caused
- Route B (whole agent loop in the Chez image)

## 9. Definition of "D-012 local coding-agent: remaining"

A local developer can already: durable session, multi-file edit, jail+ask,
headless JSON, optional TUI, `--rpc`, `--acp`, `code_intel`, in-process
`task` subagent.

Still required before calling the D-012 target **closed** (each still its own
Gate, none automatic):

1. Supervisor v1 owns `run_shell` and has review/fixture closeout (Wave 1).
2. Long-lived supervised stdio slots exist if LSP/MCP children should not be
   exceptions (Wave 3).
3. MCP v1 contract + impl on those slots — only if you still want D-012
   item 6; it is optional as a *product* until a user needs a specific
   MCP server.
4. Closeout records for rpc/ACP/LSP/subagent so they are not "mystery code".
5. Memory / Oracle / Graph / WASM / sandbox remain **out** of that closeout
   unless a new decision says otherwise.

Live prompt (Track L) is **not** a D-012 closeout requirement.

## 10. This pass (2026-08-14)

Docs + supervisor fixture closeout landed on top of `fe075f1` in the
same working tree as this freeze:

- Wave 0: this file + INDEX / roadmap / plan README / maturity pointer.
- Wave 1: dual review PASS; F1 reap-after-cancel; fixture 7
  `rejectDeniedShell`; task **implemented**.
- Wave 2: closeout reviews for rpc / ACP / LSP / subagent. ACP gate15
  named as [acp-gate15-001](../tasks/acp-gate15-001.md) (not fixed here).
- Track L: [zag-live-002](../tasks/zag-live-002.md) /
  [zag-live-003](../tasks/zag-live-003.md) contracts drafted.
- Wave 3: [long-lived](../tasks/process-supervisor-long-lived-001.md) +
  [mcp-001](../tasks/mcp-001.md) contracts drafted; MCP impl still blocked
  on a named server.

Next engineer Goals: zag-live-002 dual review, or long-lived-slot dual
review, or acp-gate15 root-cause. Do not start MCP impl.

## Related

- [D-012](../../decisions/active/D-012-complete-local-coding-agent-target.md)
- [D-009](../../decisions/active/D-009-pi-semantics-not-parity-fork.md) ·
  [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md) ·
  [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md) ·
  [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) ·
  [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- [2026-08-13 next delivery plan](./2026-08-13-next-delivery-plan.md)
  (superseded for delivery order)
- [2026-08-06 local-agent analysis](./2026-08-06-pi-omp-hyper-local-agent-analysis.md)
- [maturity.md](../../maturity.md) · [roadmap.md](../../roadmap.md)
