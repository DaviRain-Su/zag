# Review: zag-live-002 — safety / lifecycle / degradation (contract)

- Task: [zag-live-002](../tasks/zag-live-002.md)
- Binding: [live-policy-layer.md](../../modules/live-policy-layer.md) (draft under review)
- Context consumed: [zag-live.md](../../modules/zag-live.md) (frozen, round-2
  PASS) + the verified `packages/zag-live/` implementation + recon targets
  (`agent.zig`, `cli.zig`) checked against the working tree
- Track: contract / safety+lifecycle axis (reviewer verified all three spikes
  and the zag-live package implementation, incl. its M1/M2 fix round)
- Result: round 1 **blocked** (S1) → round 2 **pass** (see below)

The draft is well-grounded: the §2 recon facts check out against the tree
(`layers()`'s only production consumer is `bridgeContextView`,
agent.zig:941 — other hits are tests; the `--no-skills` threading precedent
exists at cli.zig:232-239; the LSP-children ownership precedent is real).
The default-off + compile-gate + degrade-always posture is the right shape,
and surfacing `recover` as a `zag live` subcommand correctly carries the
package's M2 fix to operators. One enumeration gap blocks; the rest are
precision fixes.

## Blocking

### S1 — P2, blocking: init-time degradation enumeration is incomplete against the package's real error set

- Location: `live-policy-layer.md` §4 ("`Live.init` failure
  (`ChezUnavailable`, `BootProbeFailed`) is not fatal").
- The verified package: `Live.start` also returns **`JournalCorrupt`**
  (mid-file-corrupt journal from a crashed earlier run — I exercised this
  exact path against the implementation: crafted mid-file garbage →
  `start()` fails `JournalCorrupt`, fail-closed by design). `FrameTooLarge`
  and `ProtocolError` are also in `start`'s reachable set in principle.
- §5's view-time fallback covers "any error/timeout/`ImageRestarted`", but
  §4's init-time enumeration names only two errors. A conforming
  implementation written against §4 as written can plausibly propagate
  `JournalCorrupt` at startup and fail the run — violating the contract's
  own core promise ("every existing behavior stays byte-identical when the
  feature is … dead"). §7 has no corrupt-journal test class to catch this.
- Fix (one line + one test row): "`Live.init`/`start` failure of **any**
  kind (incl. `ChezUnavailable`, `BootProbeFailed`, `JournalCorrupt`)
  degrades to flag-off with a notice"; add §7 class: corrupt journal /
  bricked state dir at startup → run works, base prompt, notice emitted.

## Non-blocking

### S2 — P2: the "reply must be a string" gate is unimplementable host-side as literally written

- Location: §5 delegation point.
- Verified against the package: `Live.eval` flattens the datum — a policy
  returning the string `"42"` and one returning the number `42` produce the
  identical host-visible payload (`safe-eval` writes `(ok <datum>)`;
  `parseDatum` unquotes strings and passes atoms raw). There is no type tag
  on the wire, so the host **cannot** distinguish "wrong type" from a valid
  short string.
- The gate is achievable within the frozen package by moving the type check
  image-side — the delegation call should be specified as a wrapper:
  `(let ((r (policy.system-prompt …))) (if (string? r) r (error 'policy
  "not-a-string")))` — image error → `ProtocolError` → fallback. §7 class 6
  (wrong type) would catch a naive implementation, so this is test-gated;
  but the contract should state where the check lives, since as written it
  implies a host-side type check that does not exist.

### S3 — P2: delegation-point structure doesn't match the cited code shape

- Location: §2 diagram / §5 ("`Session.layers()` computes `.system`").
- `Session.layers()` today is `*const Session`, infallible, allocator-free
  (agent.zig:412-420), and Session has no access to the Agent-owned `Live`.
  A bounded, fallible, 2 s-deadlined IO request cannot live in that
  signature without changing it. The sole production consumer,
  `bridgeContextView` (agent.zig:933-953), already has the agent pointer
  (→ `Live`), `io`, and a scratch allocator — it is the natural hook.
- The contract should bless the actual call site and state two behavioral
  rules regardless of site: (a) the delegation runs **per view
  computation** (no session-start caching — otherwise "policy changes apply
  to subsequent replies" is violated); (b) worst-case added latency while
  the image is unhealthy is +`deadline` per view computation, self-healing
  via the package watchdog (hung image is killed and restarted; dead image
  fails fast with `ImageDied`). Both are acceptable; they should be
  written down.

### S4 — P2: prompt size bound of "≤ frame cap" is not a real bound

- Location: §5 ("reply must be a string ≤ frame cap").
- The frame cap is 4 MiB — three orders of magnitude past anything a system
  prompt can be. A buggy/hostile policy can return a 4 MiB string that
  passes the gate and then detonates downstream: context-budget accounting,
  provider rejection, or a failed turn — and the §5/§6 fallback does **not**
  cover a *successful* delegation with toxic content (only delegation
  failure). Trust posture is "trusted local code", so this is robustness,
  not a vulnerability — but the contract should set a sane bound (order
  32–64 KiB) above which the reply falls back, and say so.

### S5 — P3: "same trust as editing a file" is defensible, but startup visibility should be required

- The parent's concern — indirect prompt injection into future sessions via
  a repo-shipped `.zag/live/` — is real but **weaker than an already-
  accepted vector**: project instructions (AGENTS.md) are auto-loaded into
  the system prompt by default in any repo you open, while the live policy
  requires the default-off `--live` flag. The marginal risk is acceptable.
- Still, cheap hardening the contract lacks: require a startup notice when
  a session begins with non-genesis policy (generation > 0 or pending
  entries present) — one line through the existing notice path, mirroring
  how trust decisions are surfaced elsewhere. Also state explicitly: live
  policy is **process-global**; Session swap/fork does not fork or reset it
  (Agent-owned `Live` survives; the journal makes it process-persistent).

### S6 — P3: degradation notice cardinality

- §6 says failures "emit a bounded notice"; per-turn notices on a dead
  image would spam. Specify notice-on-transition (healthy→degraded and
  back), and extend §7 classes 4/6 to assert the notice (only class 5
  checks it today).

### S7 — P3: the 2 s deadline inherits the package's partial-frame hole

- Cross-reference zag-live implementation review M3: the request deadline
  covers the first frame byte only; an image that flushes a partial frame
  then hangs blocks the view call unboundedly. Not reachable by accident
  (product image runs trusted local policy; a `display` in policy code
  corrupts framing → `FrameTooLarge`/`ProtocolError` → fallback, which is
  fail-safe), so P3 — but §5's "hung image can't stall a reply" guarantee
  is exactly as strong as that package note. Track in the zag-live
  hardening backlog; no text change needed here beyond a reference.

### S8 — P3: test-matrix gaps vs the axis-1 failure modes

- No `BootProbeFailed` class (class 5 covers `ChezUnavailable` via bad
  path only; a too-old Chez or a crash-on-boot binary is the other half).
- No corrupt-journal-at-startup class (see S1).
- CLI smoke runs `recover` on an *empty* state only; add the bricked-state
  case (the package's M2 scenario end-to-end through `zag live recover`).

### S9 — P3: terminology

- §4 attributes `ChezUnavailable`/`BootProbeFailed` to `Live.init`; in the
  verified package those are `start()` errors (`init` only realpaths the
  state dir). One word.

## What holds (checked against the verified package and tree)

- View-time-only delegation; transcript seed row stays static/audit
  (matches `appendSystem` + view-skip at agent.zig:399-409).
- Degradation at view time covers error/timeout/`ImageRestarted`/oversize
  (`FrameTooLarge` restarts the image inside the package; pending policy
  survives via journal — verified in the package tests).
- No model-visible self-modification tool in v1; host-only `zag live`
  redefinition — correct Gate separation.
- Compile-gating (`-Dlive` lazy dep, `LiveUnavailable` without it) keeps
  the default binary clean; golden byte-identical flag-off test is the
  right acceptance anchor.
- `recover` in the subcommand set — the M2 operator path is surfaced.
- Recon facts table: all four code citations verified accurate.

## Conclusion

**blocked** on S1 alone — a one-line enumeration fix plus one §7 row —
because it is a completeness defect in the contract's central promise
(degrade on *any* image failure) against the package's actual error set.
Everything else is precision work: S2/S3 tell the implementor where the
type check and the call site actually live (both solvable inside the frozen
package), S4 sets a real size bound, S5–S9 are notices, coverage rows, and
wording. None require reopening `zag-live.md` or touching
`packages/zag-live/`.

---

# Round 2 — re-review after full revision ("review round 2" header)

Re-read the full revised `live-policy-layer.md` (172 lines). Every round-1
safety finding is closed; the merged architecture-axis additions introduce
no safety regression. Three new P3 notes, none blocking.

## Per-finding disposition

| Finding | Verdict | Evidence in revision |
|---------|---------|----------------------|
| S1 (P2, blocking) init degradation | **fixed** | §4 "Startup degradation (S1, binding)": ANY init/start failure — `ChezUnavailable`, `BootProbeFailed`, **`JournalCorrupt`**, or any other error — degrades to static defaults with a bounded notice; "there is no start failure that fails the run." §8 test 5 is now a startup failure **matrix** including corrupt journal at start. The `needsRecovery()` hint after degraded start (§4) correctly surfaces the M2 path. |
| S2 (P2) wrong-type gate | **fixed** | §5 "Reply contract (S2/S4, binding)": type check is image-side; the wrapper errors on non-string → protocol error → fallback; the wire-flattening rationale (no type tag) is stated — matches what I verified in the package's `parseDatum`/`safe-eval` path. |
| S3 (P2) delegation site | **fixed** | §5 "Delegation point (S3, binding)": `bridgeContextView`, per view computation, no caching; §5 "Deadline (A5)": own 2 s host deadline per call, worst case +2 s per view while unhealthy, then fallback. The facts table explicitly records that `layers()` is `*const`/infallible and NOT the hook — matches the tree (agent.zig:412-420, 933-953). |
| S4 (P2) size bound | **fixed** | §5: 64 KiB prompt bound with fallback above it; "4 MiB frame cap is not a prompt bound." |
| S5 (P3) trust model / visibility | **fixed** | §6 notice rule: one-time startup notice when the effective policy differs from genesis; process-global across Session swap/fork stated; the AGENTS.md-weaker-vector reasoning is on the record. (Accepted over-notice edge: a redefine-then-discard journal still trips the heuristic — safe direction.) |
| S6 (P3) notice cardinality | **fixed** | §6: degradation notices once per health transition; §8 test 4 asserts "one notice". |
| S8 (P3) test gaps | **fixed** | §8 test 5 adds `BootProbeFailed` + corrupt journal; test 8 bricks the state dir and revives via `zag live recover` (the M2 scenario end-to-end through the subcommand, as requested). |
| S9 (P3) init/start wording | **fixed** | §4 attributes the errors to `init`/`start` correctly (S9 noted in-line). |

## Arch-axis additions, safety-axis check

- **Propagation rule (A1, §6)**: sound and fail-closed. A running agent's
  view delegations read its own live image, never another process's
  journal appends; cross-process policy lands only at the next
  restart/replay — a controlled, fsynced read path. No mid-run surprise.
- **Lock rule (A4, §6)**: single-writer via O_EXCL `.zag/live/lock`;
  subcommands fail closed with `LiveLocked` while held. Fail-closed is the
  safe direction; combined with propagation it keeps the shared state
  single-writer. **No degradation regression.** §8 test 9 proves
  exclusivity (second agent/subcommand → `LiveLocked`) — but see R2-N1:
  it does not prove release/reuse.

## New findings (all P3, non-blocking)

- **R2-N1 — stale-lock lifecycle unspecified.** O_EXCL create with no
  release/staleness rule: a crashed lock-holder leaves `.zag/live/lock`
  behind and every later run/subcommand fails `LiveLocked` until manual
  removal. Fail-closed = safe, but availability-poor. Specify
  delete-on-clean-exit plus a staleness story (pid in the lock file, or
  documented manual removal), and extend test 9 to prove the lock is free
  after the first holder exits cleanly.
- **R2-N2 — agent-side `LiveLocked` disposition ambiguous.** For the `zag
  live` subcommand a clean `LiveLocked` error is right; for a second
  *agent* process, §4's posture implies degrade-with-notice (run without
  live), not a fatal error. One line to disambiguate.
- **R2-N3 — "policy wrapper in `runtime.ss`" phrasing (§5).** The task's
  path table forbids `packages/zag-live/**` changes; the wrapper actually
  lives in the host-supplied genesis `base_source` (or the delegation eval
  text), not in the frozen package's image script. One-line clarification
  to prevent an implementor reading it as a frozen-package edit.

## Conclusion (round 2)

**pass.** S1 — the sole round-1 blocker — is closed with binding language
that covers the package's full start-error set and a test row that gates
it. S2–S5 are fixed exactly along the lines this review recommended, and
S6/S8/S9 are disposed. The merged arch-axis additions (propagation rule,
lock rule, capturing-mock test note) preserve the fail-closed degradation
posture. R2-N1–N3 are one-paragraph clarifications for `ready` closeout,
none affecting the safety core. From the safety/lifecycle axis,
`zag-live-002` may proceed to `ready` once the architecture axis passes.

---

# Round 3 — final safety confirmation (post-architecture-axis deltas)

Re-read current §4–§8 after the architecture axis's two extra rounds. Four
deltas claimed; each checked against the verified `packages/zag-live/`
implementation and my round-2 notes. **No safety regressions; round-2 pass
confirmed.**

1. **§5 deadline correction** — accurate against the package: `Live.eval`
  is bounded by `WatchdogConfig.deadline_ms` (there is no per-call
  parameter; live.zig:446), and a deadline expiry becomes restart +
  `ImageRestarted` via `boundaryDisposition` (live.zig:197-210) — the §5
  fallback ("on any failure") covers it identically. The correction makes
  the text *more* faithful than the round-2 version (which implied a
  per-call deadline parameter that does not exist). My recorded package
  note (deadline covers first frame byte only; zag-live-001-03 review, M3)
  is unaffected and stays on the zag-live hardening backlog.
2. **§5 reply-contract correction** — exactly the R2-N3 resolution: the
  type check is a host-wrapped eval source, genesis `policy.system-prompt`
  ships as coding-agent-supplied `Config.base_source` (exists,
  live.zig:63-65), and the frozen package's `runtime.ss` is explicitly
  untouched. Implementable entirely within the frozen package API. ✓
3. **§6 lock lifecycle** — resolves R2-N1 and R2-N2 as recommended: clean
  `Agent.deinit` deletes the lock; `zag live recover` clears a stale lock
  after holder death; a second agent on a locked state_dir degrades with
  one notice instead of erroring. Single-writer invariant preserved (the
  second agent never takes the lock and never writes the journal).
   residual (P3, no text change required): the holder-death determination
  mechanism for stale-lock clearing is unspecified (pid liveness vs user
  judgment); `recover` is already a user-invoked override of a fail-closed
  default, so this is acceptable as written.
4. **§8 test 9 split** — covers all three lock dispositions (subcommand →
  `LiveLocked`; second agent → degrade; stale cleared by `recover`). One
  cheap addition worth considering at implementation time: assert the lock
  is also free after a *clean* first-agent exit (the deinit-delete path),
  since test 9 as written exercises only contention and stale recovery.

**Final conclusion (safety/lifecycle axis): PASS.** The contract is ready
from this axis; no outstanding blocking or safety-relevant non-blocking
findings.
