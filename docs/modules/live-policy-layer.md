# Live policy layer — coding-agent integration

> Binding draft for [zag-live-002](../plan/tasks/zag-live-002.md)
> (D-014 Route A, first live surface: prompt construction).
> Depends on [zag-live.md](./zag-live.md) (**implemented**); direction:
> [D-014](../decisions/active/D-014-live-runtime-productization-route-a.md).
>
> **Status:** contract **draft**, review round 3 — round 1 dual blocked
> (arch A1; safety S1), round 2 arch blocked (B1/B2); all fixes folded in
> (S2–S5, A2–A7, lock lifecycle). Safety axis PASS at round 2.
> Experimental, default-off (`--live`); no maturity claim.

## 1. Purpose

Let a supervised live image compute the **system prompt** at view time, so
the agent's policy is runtime-redefinable, journaled, and rollback-able —
while every existing behavior stays byte-identical when the feature is off,
unavailable, or dead.

## 2. Integration architecture

```text
CLI --live ──► HostResourceOptions.live ──► Agent.Options.live
                                                 │
                              Agent owns ?Live (heap-stable; deinit with LSP children)
                                                 │ state_dir = .zag/live/ + lock
                                                 ▼
                              bridgeContextView: .system =
                                  live healthy ? image policy(base, project) : base_system
                                                 │
                                                 ▼
                              viewForModel (unchanged)
```

Facts this contract is grounded in (recon 2026-08-14, verified by
architecture review round 1):

| Fact | Location |
|------|----------|
| Delegation site: `bridgeContextView` — the sole production consumer of `Session.layers()`, has agent pointer + io + scratch allocator | `packages/zag-coding-agent/src/agent.zig:933-953` (consumer at `:941`) |
| `Session.layers()` itself is `*const`, infallible, allocator-free — NOT the hook (round-1 S3/A2) | `agent.zig:412-420` |
| Base prompt is static `default_system`, threaded as `SessionStartOptions.base_system` | `packages/zag-cli/src/cli.zig:17-34`; threading `cli.zig:1001-1002` |
| Transcript seed row of the merged prompt is audit-only; the view skips it | `agent.zig:400-405` |
| Long-lived children are Agent-owned (LSP precedent); Session dies on swap/fork | `agent.zig:1282-1402`, `:1331-1338` |
| Opt-in flag precedent: `--no-skills` argv → `HostResourceOptions` → options structs | `cli.zig:232-239`, `:868-875`, `:544-565` |
| State dir convention: workspace-relative `.zag/`; Live takes `state_dir: Io.Dir` | `cli.zig:229`; `packages/zag-live/src/live.zig:55` |
| coding-agent test pattern: colocated tests + `MockChat`/`mockProvider` vtable stub | `agent.zig:2216-2293` |

## 3. Flag and wiring

- Runtime flag **`--live`** (default off): argv parse →
  `HostResourceOptions.live: bool` → **`Agent.Options.live`** (A2:
  `Agent.init` precedes per-run `Session.start`, so the hop is Agent's
  options, not `SessionStartOptions`).
- **Compile gating**: `-Dlive` build option + lazy dependency, following
  the zag-tui precedent — but note the full touch list (A3): root
  `build.zig` consumes coding-agent **three** ways (dependency module
  ~:52-57, named re-declaration ~:148-156, test root ~:279-290), each needs
  the conditional import; plus `packages/zag-coding-agent/build.zig(.zon)`
  module + test module, and zon entries in both root and coding-agent.
- `--live` without `-Dlive` = clean CLI error `LiveUnavailable`;
  `zag live …` subcommands without `-Dlive` = same error (A6).
- `state_dir` = `<workspace>/.zag/live/`, opened cwd-relative by the CLI.

## 4. Live supervisor ownership and startup degradation

`Agent` gains `live: ?Live`, initialized at `Agent.init` when flag + build
feature are both on; torn down in `Agent.deinit` alongside the LSP
children.

**Startup degradation (S1, binding):** ANY `Live.init`/`start` failure —
`ImageUnavailable`, `BootProbeFailed`, **`JournalCorrupt`**, or any other
error — is non-fatal: log a bounded notice, store `null`, and every live
surface degrades to static defaults. There is no start failure that fails
the run.

`Live.needsRecovery()` after a degraded start surfaces the recover hint
once (S9: init-vs-start wording per package API).

## 5. The live surface (v1): system prompt

- **Genesis policy is identity.** The image's `base.ss` defines
  `(policy.system-prompt base project)` returning `base` unchanged. Flag on
  + default policy ⇒ byte-identical prompts vs flag off (test-gated).
- **Delegation point (S3, binding):** `bridgeContextView`, per view
  computation, **no caching**. When `Agent.live` is healthy: bounded
  request `(policy.system-prompt <base> <project-body-or-#f>)`; on any
  failure → `.system = base_system`.
- **Deadline (A5, corrected round 3):** the frozen package API has **no
  per-call deadline parameter** — the delegation call is bounded by the
  `Live` request deadline (`WatchdogConfig.deadline_ms`, default 2000 ms);
  a timeout is converted by the package into an image restart, arriving
  host-side as `ImageRestarted` → fallback. While the image
  is unhealthy, worst case is +2 s per view computation, then fallback.
- **Reply contract (S2/S4, corrected round 3):** the type check is enforced
  by the **host-wrapped eval source** — the delegation sends
  `(let ((r (policy.system-prompt …))) (if (string? r) r (error …)))`, so a
  non-string result arrives as a protocol error → fallback. (Host-side,
  datums are flattened; no type tag exists on the wire.) The genesis
  `policy.system-prompt` ships as coding-agent-supplied `Config.base_source`
  — the frozen package's `runtime.ss` is **not** edited. A successful
  string reply is additionally bounded at **64 KiB**; above that →
  fallback. 4 MiB frame cap is not a prompt bound.
- **View-time only.** The transcript seed row stays the static merged
  prompt (audit continuity); compaction/session/ephemeral layers untouched.

## 6. Redefinition path and propagation (A1, binding)

v1 redefinition is host-driven only via CLI **`zag live`** subcommands
(`eval`, `redefine <name> <file>`, `commit`, `discard <name>`, `status`,
`recover`) operating on the workspace's `.zag/live/`.

- **Propagation rule:** a `zag live` redefine lands in the journal (and
  that process's own image). A **running** agent never observes another
  process's journal appends; it picks up the new policy on its **next image
  restart/replay** (crash, watchdog, or next process start). In-process
  redefines through the agent's own `Live` handle apply immediately — v1
  uses this only inside tests.
- **Concurrency (A4 + round-3 lock lifecycle):** single-writer rule via
  `.zag/live/lock` (O_EXCL create). A running agent holds the lock for its
  run and **deletes it in clean `Agent.deinit`**; `zag live` subcommands
  fail closed with `LiveLocked` while it is held. A crashed holder leaves a
  stale lock: `zag live recover` clears it (after holder death) as part of
  its recovery flow. A second **agent** on a locked `state_dir` does not
  error — it degrades per §4 posture (runs without live, one notice).
  Redefine between runs; the next start replays it.
- **Trust model:** user-invoked, same trust as editing a file; weaker than
  the already-accepted AGENTS.md auto-load vector (S5). **Notice rule:** at
  session start with `--live`, if the effective policy differs from genesis
  (journal has live redefine entries), emit a one-time startup notice; the
  policy is **process-global** across Session swap/fork (S5). Degradation
  notices fire once per health transition, not per turn (S6).
- **No model-visible self-modification tool in v1** — separate
  permission-design Gate.

## 7. Errors and degradation (closed)

`LiveUnavailable` (flag/subcommand without build feature) · `LiveLocked`
(concurrent state access) · live delegation failures never reach the user
as errors — they fall back to `base_system` and emit a bounded notice
through the existing observer/notice path. Degradation is the designed
behavior, not an error path.

## 8. Tests (acceptance)

coding-agent package tests with a **capturing MockChat variant** (A7: the
stock MockChat discards the view at `agent.zig:2225`; tests 1–3 need the
view's system layer captured) + a real `Live` on a temp `state_dir`
(skip-if-no-gxi gate):

| # | Class | Expect |
|---|-------|--------|
| 1 | flag off | prompts byte-identical to current behavior (golden) |
| 2 | flag on + identity policy | byte-identical to flag off |
| 3 | in-process host-driven redefine | capturing mock observes the new system prompt on the next view |
| 4 | image killed mid-run | next view falls back to `base_system`; run continues; one notice |
| 5 | startup failure matrix | `ImageUnavailable` (bad/missing `.image`), `BootProbeFailed`, **corrupt journal at start (S1)** — each degrades, run works, notice emitted |
| 6 | bad policy replies | non-string (image-side error), >64 KiB, hang past 2 s — fallback each time; no run failure |
| 7 | cross-process propagation | `zag live redefine` on a stopped workspace → new agent process start replays policy → capturing mock observes it |
| 8 | recover smoke (S8) | brick the state dir (replay-fatal pending entry), `zag live recover` revives it (M2 path end-to-end) |
| 9 | lock | `zag live` on a locked state_dir → `LiveLocked`; a second **agent** on a locked state_dir → degrades per §4 (runs without live, one notice); stale lock cleared by `zag live recover` |

CLI-level: `zag live status` on empty state; `--live` and `zag live`
without `-Dlive` → `LiveUnavailable`.

## 9. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| [zag-live.md](./zag-live.md) | consumed as-is; no changes to its protocol or package |
| Phase H / SDK / headless | untouched; flag default-off; headless paths degrade identically |
| D-011 / Core | no Core changes; hook is coding-agent `bridgeContextView` only |
| [cli-interaction.md](./cli-interaction.md) | new flag + subcommand follow existing CLI conventions |
| Maturity | no row; experimental |
| zag-live-003 (provider bridge) | not needed by this surface; separate task |

## 10. Non-goals (v1)

Model-visible self-modification tool; image-originated provider calls
(zag-live-003); tool registry / memory policy surfaces; TUI affordances;
in-process redefine UX beyond tests; any change when `--live` is off.
