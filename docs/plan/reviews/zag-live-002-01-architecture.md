# Review: zag-live-002 — architecture / ownership (contract)

- Task: [zag-live-002](../tasks/zag-live-002.md)
- Binding: [live-policy-layer.md](../../modules/live-policy-layer.md) (draft under review)
- Context consumed: [zag-live.md](../../modules/zag-live.md) (implemented),
  [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md),
  [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md),
  [packaging.md](../../packaging.md), root `build.zig`/`build.zig.zon`,
  `packages/zag-coding-agent/build.zig(.zon)`, `packages/zag-cli/build.zig`,
  and the cited code in `agent.zig` / `cli.zig` / `packages/zag-live/src/`
- Track: contract / architecture+ownership axis
- Result: **blocked** — 1 blocking (P1), 6 non-blocking (3 P2, 3 P3)

## 1. Recon-fact verification (axis 1): all citations check out

Every §2 table claim was re-verified against the working tree
(2026-08-14):

| Fact | Verdict |
|------|---------|
| `Session.layers()` at `agent.zig:412-420`, consumer `bridgeContextView` → `viewForModel` at `:933-953` | ✅ exact; production-sole (other `.layers()` hits are tests: `session_fork_tests.zig:314-315,419`, `skills_tests.zig:119`) |
| Static `default_system` at `cli.zig:17-34`, threaded as `SessionStartOptions.base_system` | ✅ field at `agent.zig:118`; CLI threading confirmed at `cli.zig:1001-1002`, `:1182-1183`, `:1332-1333` |
| Transcript seed row audit-only, view skips it (`agent.zig:400-405`) | ✅ (comment at `:399`, code `:400-405`) |
| Long-lived children Agent-owned, LSP precedent (`agent.zig:1282-1402`, `:1331-1338`; deinit `:1394-1396`) | ✅ |
| `--no-skills` threading (`cli.zig:232-239`, `:544-565` → `host_opts` at `:558-565`, `HostResourceOptions` at `:868-875`) | ✅ |
| `.zag/` workspace-relative convention (`cli.zig:229`); `Live` takes `state_dir: Io.Dir` | ✅ (`packages/zag-live/src/live.zig:55`) |
| `MockChat`/`mockProvider` vtable stub (`agent.zig:2216-2293`) | ✅ |

No wrong line refs, no wrong data-flow in the facts table.

## Blocking

### A1 — P1, blocking: "subsequent replies in the same process" contradicts the only specified redefinition path

- Location: `live-policy-layer.md` §5 ("Redefinition path (v1)" and
  "Policy changes apply to subsequent replies in the same process
  (pending)") and §7 test 3 ("redefined policy via `zag live` path →
  MockChat observes the new system prompt on the next reply").
- The v1 redefinition surface is the **`zag live` subcommand — a separate
  process** opening its own `Live` on the workspace's `.zag/live/` state.
  Its `kernel.redefine` lands in *that* process's image and in the journal.
  A concurrently running `zag --live` agent holds a **different image**;
  nothing in the frozen zag-live package makes a running image observe
  journal appends from another process (verified: `Live` applies redefines
  only to its own child; replay happens at `start()`/image restart,
  `live.zig:116`, `:233-238`).
- So as written: changes via `zag live` do **not** apply to subsequent
  replies of a running agent — they apply to agent processes started (or
  images restarted-and-replayed) after the redefine. §7 test 3 passes only
  if the test drives `kernel.redefine` through the *same* in-process `Live`
  the agent holds, which is not the "`zag live` path".
- Fix (contract text, a few sentences): state the propagation rule
  explicitly — e.g. "`zag live` changes take effect for a running agent
  only after its image restarts (replay); within a process, host-driven
  redefines through the agent's own `Live` apply to subsequent view
  computations" — and align §7 test 3's wording with whichever path is
  blessed (in-process host API for the package test; separate-process
  effect covered by test 7's restart persistence).

## Non-blocking

### A2 — P2: flag-threading chain doesn't reach the owner

- Location: §3 ("argv parse → `HostResourceOptions.live` →
  `SessionStartOptions.live` → `Session.start` → retained on `Agent`") vs
  §4 ("initialized at `Agent.init`").
- `Agent` is constructed once (`Agent.init`, `agent.zig:1282`) before and
  independently of the per-run `Session.start` calls
  (`cli.zig:1001/1182/1332`). A `live: bool` arriving via
  `SessionStartOptions` cannot retroactively create the Agent-owned `Live`
  of §4. The chain needs the Agent-scoped hop made explicit
  (`Agent.Options.live` or a CLI-constructed `Live` injected into
  `Agent.Options`), with the session side receiving whatever the delegation
  site needs. Complements safety-review S3 (which blesses
  `bridgeContextView` as the natural site — it already has `bridge.agent`);
  resolve both in the same revision.

### A3 — P2: `-Dlive` build wiring under-specified — "copy the zag-tui precedent" misses the root build's manual re-declarations

- Location: §3 ("root `build.zig` adds a lazy `-Dlive` dependency +
  `build_options` (copy the zag-tui precedent)").
- The tui precedent gates a **leaf** consumed by `zag-cli` alone
  (`packages/zag-cli/build.zig:53-60`: `lazyDependency` + conditional
  `mod.addImport`, `build_options.tui_enabled`). `zag-coding-agent` is
  consumed **three ways** in root `build.zig`: as a dependency module
  (`build.zig:52-57`), as a discarded named re-declaration
  (`build.zig:148-156`), and as an inline-imported test root module
  (`build.zig:279-290`). An implementer copying only the tui pattern will
  ship a `-Dlive` build where `zig build test` at root fails on
  `@import("zag-live")` in the test module.
- The wiring is workable, but §3 should enumerate the full touch list:
  root `build.zig.zon` (`.zag_live = .{ .path = ..., .lazy = true }`,
  mirroring `zag_tui` at lines 53-56); root `build.zig` (option,
  `lazyDependency`, forward `.live` into the `zag_coding_agent` and
  `zag_cli` `b.dependency` calls, conditional `addImport` at **all three**
  consumption sites, `live_enabled` in the CLI `build_options`);
  `packages/zag-coding-agent/build.zig` (accept `live` option,
  `lazyDependency("zag_live")`, own `build_options`, conditional
  `addImport` in module **and** test module at lines 33-54);
  `packages/zag-coding-agent/build.zig.zon` (lazy `zag_live` path dep).
  Comptime-gated source pattern (`if (build_options.live_enabled)
  @import("zag-live") …`) matches the existing `tui_enabled` idiom at
  `cli.zig:13-15`.

### A4 — P2: concurrent access to `.zag/live/` state is unspecified

- `zag live` subcommands open a second `Live` on the same `state_dir`
  while a `--live` agent may be running in the same workspace. zag-live's
  contract is silent on multi-process access; journal appends are
  single-fsynced writes (H2) but generation staging/rename and
  `current`-pointer flips from two processes are uncoordinated. State the
  v1 assumption explicitly (e.g. "`zag live` mutations against a workspace
  with a running `--live` agent are unsupported; effects apply on next
  agent start" — pairs naturally with the A1 fix) or add a lock rule.

### A5 — P3: "host deadline 2 s" is config-level, not per-call

- `Live.eval` (`live.zig:233`) takes no deadline; the bound is
  `Config.watchdog.deadline_ms` (default 2000, `live.zig:48-51`), shared
  with the liveness watchdog. §5's "host deadline 2 s" should say it is
  set via `WatchdogConfig` at `Live.init` (and note the coupling), not
  implied per-request.

### A6 — P3: `LiveUnavailable` placement and `zag live` without `-Dlive`

- §6 lists `LiveUnavailable` as this layer's closed error — fine, but say
  it lives in coding-agent/CLI, not zag-live's vocabulary (zag-live.md §8).
  Also unspecified: `zag live <subcommand>` in a binary built without
  `-Dlive` — presumably the same clean `LiveUnavailable`; one line.

### A7 — P3: test-seam precision

- `MockChat.chat` discards the view (`agent.zig:2225`, `_`), so §7 tests
  1–3 need a capturing variant recording the observed system message;
  worth one clause so "byte-identical (golden)" has a defined observation
  point (the view's system content as seen by the provider port).
- Fact-table nit: the "sole consumer" row could say "sole *production*
  consumer" (tests also call `layers()`), and the threading claim could
  additionally cite `cli.zig:1001-1002`.

## What holds (architecture/ownership axis)

- **Agent-owns-Live is the right call** and correctly reasoned from the
  LSP precedent: `code_intel_state` is heap-stable, Agent-created
  (`agent.zig:1331-1338`) and Agent-torn-down (`:1394-1396`); Sessions are
  per-run/per-REPL constructs created after the Agent. Live policy being
  process-global across Session swap/fork follows naturally.
- **D-011 compliant**: hook stays in `zag-coding-agent`
  (`Session.layers()`/`bridgeContextView`); Core's `ContextView` port and
  loop ordering untouched; no zag-live types cross into Core.
- **Packaging law compliant**: L3 → L2 downward import; zag-live depends
  on `zag-types` only (zag-live.md §2, verified); per-package
  `zig build test` preserved via the skip-if-no-chez gate (§7).
- **Two-flag story coherent**: `-Dlive` compile gate + `--live` runtime
  gate + `LiveUnavailable` for `--live` without `-Dlive` keeps the default
  binary dependency-free, matching D-014's fail-closed-to-static-defaults.
- **Blast radius when off is guaranteed and testable as written**: with
  `-Dlive` off the code is comptime-absent; with `--live` off the `?Live`
  is `null` and `layers()` returns `base_system` unchanged; §7 test 1
  (golden, no chez needed) and test 2 (identity policy, byte-identity
  backed by zag-live's escaping round-trip acceptance) are both real,
  executable gates.
- Delegation boundedness (frame cap on the wire, `ImageRestarted`
  fail-once, fallback set closed over "any error/timeout") maps cleanly
  onto the verified package behavior (`live.zig:256-269`).

## Conclusion

**blocked** on A1: the contract's central surface claim (policy changes
apply to subsequent replies in the same process) is not delivered by the
only redefinition path it specifies (a separate-process `zag live`
subcommand), and §7 test 3 inherits the contradiction. This is a semantic
gap in the binding text, not an implementation risk — a short contract
revision (propagation rule + test-3 wording) resolves it. A2–A4 should be
fixed in the same revision (threading hop to `Agent.Options`, full build
touch list, state-dir concurrency assumption); A5–A7 are wording. No
reopening of `zag-live.md` and no changes to `packages/zag-live/` are
required by any finding on this axis.

---

# Round 2 re-review (2026-08-14)

- Contract: [live-policy-layer.md](../../modules/live-policy-layer.md)
  revision marked "review round 2" (header lines 8-10)
- Re-verified against: `packages/zag-live/src/live.zig`,
  `packages/zag-live/src/runtime.ss` (frozen package), `agent.zig`,
  `cli.zig`, root `build.zig`
- Result: **blocked** — 2 blocking (P2-class precision errors against the
  frozen package, introduced by the round-2 merge), all round-1 findings
  otherwise resolved

## Per-finding verdicts

### A1 (P1, blocking) — **RESOLVED**

§6 now states the propagation rule exactly as required: `zag live`
redefines land in the journal + that process's own image; a running agent
never observes cross-process appends and picks policy up on image
restart/replay or next process start; in-process redefines through the
agent's own `Live` are test-only in v1. §8 test 3 (in-process, capturing
mock observes next view) and test 7 (cross-process, stopped workspace →
new process start replays) are now consistent with the rule and with each
other. No residual contradiction.

### A2 (P2) — **RESOLVED**

§3 flag chain now reads argv → `HostResourceOptions.live` →
**`Agent.Options.live`**, with the reason stated (`Agent.init` precedes
per-run `Session.start`). Matches the verified construction order
(`agent.zig:1282`; sessions at `cli.zig:1001/1182/1332`). Coherent.

### A3 (P2) — **RESOLVED**

§3 enumerates the full touch list: root `build.zig`'s three consumption
sites (~:52-57, ~:148-156, ~:279-290) each needing the conditional import,
plus `packages/zag-coding-agent/build.zig(.zon)` module + test module and
both zon entries. Option-forwarding and `build_options` mechanics are
covered by the explicit "following the zag-tui precedent" reference
(`packages/zag-cli/build.zig:13-17,39-60` shows the exact idiom).
Complete enough for a binding contract.

### A4 (P2) — **RESOLVED, one operational note**

`.zag/live/lock` O_EXCL single-writer rule with fail-closed `LiveLocked`
is sound and testable (§8 test 9), and it makes the A1 cross-process
mid-run case unreachable by design — which correctly simplifies the
propagation story. One wrinkle the contract should note (P3-level):
O_EXCL lock files go **stale** on SIGKILL — a killed agent leaves the lock
behind and every subsequent `zag live`/agent start fails `LiveLocked`
until manual removal. State the recovery (e.g. `zag live recover` clears a
stale lock, or a documented `rm .zag/live/lock` operator step).

### Safety-axis folds (S1–S9) — consistent except two, see below

- S1 fold (§4 any-error startup degradation incl. `JournalCorrupt`; §8
  test 5 matrix; `Live.needsRecovery()` at §4): verified against the
  package (`needsRecovery` is public at `live.zig:167`; `JournalCorrupt`
  reachable from `start`). Consistent.
- S3 fold (delegation site moved to `bridgeContextView`, per-view, no
  caching; §2 diagram + fact table updated): matches the code shape
  (`agent.zig:933-953`, has agent/io/scratch). Consistent.
- S5/S6 folds (startup notice on non-genesis policy, process-global
  statement, notice-on-transition): internally consistent; notice
  cardinality rule is reflected in §8 test 4 ("one notice").
- A6/A7 folds (`zag live` without `-Dlive` → `LiveUnavailable`, §3/§7;
  capturing-mock note, §8 preamble): as recommended. Consistent.

## New findings (round 2)

### B1 — P2, blocking: §5 asserts a per-call deadline API that does not exist in the frozen package

- Location: `live-policy-layer.md` §5 ("each delegation call carries its
  own 2 s host deadline … The watchdog's own config is a separate
  image-level concern").
- Verified against the frozen package: `Live.eval` takes **no** deadline
  parameter (`live.zig:233`); the request deadline inside
  `requestLocked`/`requestEvalLocked` is `self.cfg.watchdog.deadline_ms`
  (`live.zig:510`, doc at `:228-229`) — the request deadline and the
  watchdog deadline are the **same** config field, not separate concerns.
  There is no per-call deadline mechanism to implement §5 as written, and
  zag-live is frozen (§9: "no changes to its protocol or package"; task
  file forbids `packages/zag-live/**`).
- The behavioral guarantee survives unchanged — `deadline_ms` defaults to
  2000 and `DeadlineExceeded` → `ImageRestarted` → fallback
  (`live.zig:256-269`), so §8 test 6 ("hang past 2 s → fallback") is
  deliverable. Only the stated mechanism is wrong.
- Fix (one sentence): "the 2 s bound is `WatchdogConfig.deadline_ms`
  (default 2000) set at `Live.init`; in v1 it is shared with the liveness
  watchdog — a per-call deadline would be a zag-live change and is out of
  scope."

### B2 — P2, blocking: §5 locates the type-check wrapper "in `runtime.ss`" — a frozen file the task forbids changing

- Location: §5 ("the type check is **image-side** — the policy wrapper in
  `runtime.ss` errors on a non-string result").
- Verified: `runtime.ss` today has **no** string check and no policy
  wrapper — `safe-eval` (runtime.ss:103-107) guards whatever source the
  host sends and returns `(err …)` on any raised condition; `kernel.eval`
  dispatches it unchanged (runtime.ss:134). Adding a wrapper to
  `runtime.ss` means editing `packages/zag-live/**` (embedded via
  `@embedFile`, `live.zig:68`) — forbidden by the task file and by this
  contract's own §9 ("consumed as-is").
- The frozen-compatible mechanism exists and needs no package change: the
  **host** (coding-agent) wraps each delegation source it sends —
  `(let ((r (policy.system-prompt <base> <project>))) (if (string? r) r
  (error 'policy "not-a-string")))` — and stock `safe-eval` turns the
  raised error into `(err …)` → host `ProtocolError` → fallback. Same for
  genesis: `policy.system-prompt` is delivered via `Config.base_source`
  (`live.zig:63-65`), which coding-agent supplies — §5's "the image's
  `base.ss` defines" should say so.
- Fix (two sentences): put the wrapper in the host-constructed eval
  source, and attribute the genesis definition to coding-agent's
  `Config.base_source`.

## Round-2 conclusion

**blocked** on B1/B2 — both are small, mechanical contract-text fixes, but
each is a wrong mechanism claim about the frozen `zag-live` package in a
binding document (one asserts a non-existent per-call deadline API; the
other points the implementer at a forbidden file). Everything else from
round 1 (A1–A4, A6, A7) is resolved cleanly, and the safety folds are
otherwise consistent: the A1 propagation rule, the Agent.Options flag hop,
the build touch list, and the lock rule all check out against the tree.
With B1/B2 fixed, this axis passes; nothing on this axis requires
reopening `zag-live.md` or changing `packages/zag-live/`.

---

# Round 3 re-review (2026-08-14)

- Contract: [live-policy-layer.md](../../modules/live-policy-layer.md)
  (§5 "Deadline" and "Reply contract" bullets marked "corrected round 3";
  §6 lock lifecycle fold)
- Re-verified against: `packages/zag-live/src/live.zig` (frozen package),
  `runtime.ss`
- Result: **blocked** — 1 blocking (P2, merge-introduced §6/§8
  contradiction); B1 and B2 resolved

## Per-finding verdicts

### B1 (P2, blocking, round 2) — **RESOLVED** (one P3 wording nit remains)

§5 now correctly states the frozen API has no per-call deadline parameter
and that the delegation is bounded by the `Live` request deadline
(`WatchdogConfig.deadline_ms`, default 2000 ms — `live.zig:50`,
`:510`). Verified accurate.

Residual nit (P3, non-blocking): "a timeout arrives as `DeadlineExceeded`"
is not what the caller observes. `boundaryDisposition`
(`live.zig:256-269`) converts `DeadlineExceeded` into an image restart +
**`error.ImageRestarted`** — the host never sees `DeadlineExceeded` from
`eval`. Behavior is identical (fallback either way, §8 test 6 unaffected),
but the binding text names an error the delegation path cannot surface.
One-word fix: "arrives as `ImageRestarted` (after deadline-induced
restart)".

### B2 (P2, blocking, round 2) — **RESOLVED**

§5 now puts the type check in the **host-wrapped eval source**
(`(let ((r (policy.system-prompt …))) (if (string? r) r (error …)))`) and
attributes the genesis policy to coding-agent-supplied `Config.base_source`
(`live.zig:63-65`), explicitly leaving `runtime.ss` unedited. Verified
frozen-compatible: stock `safe-eval` (runtime.ss:103-107, dispatched at
:134) guards the wrapped form, so a host-side `(error …)` arrives as
`(err …)` → `ProtocolError` → fallback, exactly as §5 claims. No package
change required; §9 intact.

### Round-3 lock lifecycle (§6) — sound, except one contradiction below

Lock deleted in clean `Agent.deinit`; `zag live recover` clears a stale
lock after holder death; second agent on a locked `state_dir` degrades per
§4 instead of erroring. The lifecycle is coherent and matches the
degrade-always posture. (Minor: "after holder death" is operator-judged —
acceptable at contract level.)

## New finding (round 3)

### C1 — P2, blocking: §6 and §8 test 9 now disagree on second-agent behavior

- Locations: §6 Concurrency bullet ("A second **agent** on a locked
  `state_dir` does not error — it degrades per §4 posture (runs without
  live, one notice)") vs §8 test 9 ("second agent/`zag live` on a locked
  state_dir → `LiveLocked`").
- The round-3 fold changed second-**agent** behavior from error to
  degradation but left test 9 expecting `LiveLocked` for both actors. A
  conforming implementation cannot satisfy both; the acceptance gate would
  fail the behavior §6 binds.
- Fix (one line): split test 9 — "second agent on a locked state_dir →
  degrades per §4 with one notice; `zag live` subcommand → `LiveLocked`".

## Round-3 conclusion

**blocked** on C1 alone — a one-line test-wording fix aligning §8 test 9
with the round-3 §6 lock semantics. Both round-2 blockers are resolved
correctly against the frozen package: the deadline bullet now describes
the real `WatchdogConfig.deadline_ms` mechanism, and the reply contract
uses the host-wrapped eval source + `Config.base_source`, leaving
`runtime.ss` untouched. The only other residual is the P3 error-name nit
on B1 (`DeadlineExceeded` → `ImageRestarted`); also cosmetic: the header
status line still says "review round 2". With C1 (and ideally the two
nits) fixed, this axis passes — nothing on this axis requires reopening
`zag-live.md` or changing `packages/zag-live/`.

---

# Round 4 re-review (2026-08-14) — closeout

- Contract: [live-policy-layer.md](../../modules/live-policy-layer.md)
- Result: **PASS**

## Verification

- **C1 (P2, blocking, round 3) — RESOLVED.** §8 test 9 (line 161) now
  splits the actors exactly as §6 binds them: `zag live` on a locked
  `state_dir` → `LiveLocked`; a second **agent** → degrades per §4 with
  one notice; stale lock cleared by `zag live recover`. Test and §6
  concurrency bullet (lines 119-125) are now consistent; the acceptance
  gate is satisfiable as written.
- **B1 residual nit — RESOLVED.** §5 deadline bullet (lines 92-93) now
  states the timeout is converted by the package into an image restart,
  arriving host-side as `ImageRestarted` → fallback — matching
  `boundaryDisposition` (`live.zig:256-269`).
- **Header nit — RESOLVED.** Status line reflects round 3 and records
  the safety axis PASS.

## Final conclusion

**PASS — architecture/ownership axis.** Across four rounds the contract
converged to a state where every claim checks out against the tree and
the frozen package: the recon facts table is accurate; the delegation
site (`bridgeContextView`, per-view, no caching) matches the real code
shape; Agent-owns-`Live` follows the verified LSP precedent; the flag
chain hops through `Agent.Options`; the `-Dlive` build touch list covers
all three root `build.zig` consumption sites plus the package build
files; the propagation rule, lock lifecycle, and degradation posture are
internally consistent and testable (§8 tests 1-9); and the B1/B2 fixes
correctly describe the frozen `zag-live` API (no per-call deadline;
host-wrapped eval source + `Config.base_source`; `runtime.ss` untouched).
No finding on this axis ever required reopening `zag-live.md` or changing
`packages/zag-live/`. With the safety axis already PASS at round 2, the
dual-review gate is satisfied from this side; the task can proceed to
`ready` once the safety reviewer confirms the current text.
