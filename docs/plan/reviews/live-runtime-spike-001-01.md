# Review: live-runtime-spike-001 — independent verification

- Task: [live-runtime-spike-001](../tasks/live-runtime-spike-001.md)
- Binding: [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) · [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md)
- Track: independent verify (read-only; did not write this code)
- Verifier host: macOS aarch64, Zig 0.16.0, Chez 10.4.1, load avg ~6.5/12 cores
- Result: **pass** (zero blocking findings; 2 P2 + 7 P3 non-blocking)
- Rev 2: F2 and F4 fixes re-verified (see "Re-verification, rev 2" below);
  F1/F3 unchanged; two new P3 observations (F8/F9).

All seven checklist probes were rebuilt and re-run independently from
`spikes/live-runtime/` (`zig build`, then each subcommand per README). No
stubs, fakes, or mock shortcuts found in any probe path: the probes use a
real Chez subprocess, real `fsync` on the journal, real `SIGKILL`, a real
second clean Chez process for the commit replay probe, and real `poll(2)`
deadlines for the watchdog.

## Findings

### F1 — P2, non-blocking: findings not appended to the analysis doc (OPEN)

- Design-doc location: task file verification checklist item 8
  (`docs/plan/tasks/live-runtime-spike-001.md:64`) and the path table
  (`:47`, "findings appended here").
- Code/doc location: findings live only in `spikes/live-runtime/RESULTS.md`;
  `docs/plan/analysis/2026-08-13-autolith-live-runtime-analysis.md` ends at
  "Non-goals for the spike" with no findings section (grep for
  finding/result: no hits).
- The measurements and failures exist and are accurate (verified below),
  but the checklist contract says they are appended to the analysis doc.
  That box cannot honestly be ticked until they are (or the task file is
  amended to point at RESULTS.md).

### F2 — P2, non-blocking: failed commit's suspect change replayed into fresh images (FIXED, rev 2)

- Design-doc location: analysis design rule 4 — failure "keeps the old
  pointer **and marks the exploratory change suspect**"
  (`2026-08-13-autolith-live-runtime-analysis.md:90-92`).
- Fix: `doCommit` now journals `(suspect <name> <ns>)` per pending entry on
  the replay-check-failure path (`src/main.zig:656-663,723`);
  `journalPendingRedefs` drops entries quarantined by a `(suspect ...)`
  marker (`src/main.zig:445-457`); `cmdCommit` asserts a post-failure
  reload boots the committed value (`src/main.zig:946-961`).
- Rev-1 reproduction re-run exactly as before (`reset && commit`, then
  `watchdog` with no reset): the journal now shows
  `(suspect greeting ...)` after the failed commit, and the watchdog
  reloaded `(greeting) => hacked` — the committed generation-1 value, not
  the rejected `"broken"`. **Closed.**

### F3 — P2, non-blocking: journal doubles as the replay log for pending changes (OPEN)

- Design-doc location: analysis design rule 3 — "The journal is an audit
  log, **not a replay log**" (`:87-89`).
- Code location: `replayCurrent` replays `journalPendingRedefs` into fresh
  images (`src/main.zig:521-529` area).
- Disclosed in README ("In this spike the journal doubles as the replay
  source for uncommitted changes … noted as a simplification"). Acceptable
  for a probe; must be resolved before any productization decision.

### F4 — P3, non-blocking: `kernel.discard` failure path hung the image and mis-journaled (FIXED, rev 2)

- Fix: the supervisor looks up the committed source FIRST and replies
  `(kernel.nack <name> "not-committed")` without journaling when the name
  is unknown (`src/main.zig:363-374`); the Scheme primitive accepts
  ack-or-nack and raises `(error 'kernel.discard "not-committed")` on nack
  (`runtime.ss:167-187`), which the eval guard turns into a readable
  `(err ...)` reply.
- Verified in the `discard` probe: `(kernel.discard 'never-defined)`
  returned the Scheme error `not-committed irritants=()`, no journal entry
  was written for it, and the image stayed alive and correct afterwards
  (`(greeting)` still `hello`). **Closed.**

### F5 — P3, non-blocking: asymmetric string escaping (OPEN)

- Code location: `parseSchemeString` (`src/main.zig:152-178`) handles only
  `\n \t \r \\ \"` and silently drops the backslash on anything else. Chez
  `write` can emit other escapes (e.g. `\xHH;` for control characters), so
  a payload containing such characters would mis-decode supervisor-side.
  Probe payloads are plain ASCII, so no probe is affected.

### F6 — P3, non-blocking: shallow integrity checks (OPEN)

- Code location: Scheme `frame-read` has no length cap
  (`runtime.ss:39-48`) while the supervisor enforces 16 MiB — asymmetric
  but supervisor-trusting, fine for a spike. The watchdog's "journal
  intact" check (`countJournalLines`) only verifies each line starts with
  `(`; it would not catch truncation or torn tail lines.

### F7 — P3, non-blocking: minor probe hygiene (OPEN)

- `cmdCommit` hard-codes generation-1 assertions, so it only passes from a
  clean `.work/` (README says to `reset` first). `requestApply` ignores the
  reply datum instead of asserting `(ok applied)`. `Scheme.shutdown` is
  dead code. Directory fsync after the pointer rename is skipped —
  disclosed in README; power-loss durability is out of spike scope.

### F8 — P3, non-blocking: failed commit leaves an orphan generation directory (NEW, rev 2)

- Code location: `doCommit` stages `generations/<n+1>/{base.ss,replay.ss,
  meta.sexp}` BEFORE the clean-process replay probe (`src/main.zig:694-712`)
  and does not clean them up when the probe fails.
- Observed in the F2 reproduction: after the failed commit,
  `.work/generations/` contains `0 1 2` while `current` reads `1`. The
  orphan is inert (generation selection goes through the pointer), but a
  later successful commit reuses `generations/2/` via `createDirPath` +
  overwrite, so a partial/crashed staging could silently mix with a future
  generation. Pre-existing (v1 had the same ordering); surfaced during
  re-verification.

### F9 — P3, non-blocking: quarantine only covers the value-mismatch failure branch (NEW, rev 2)

- Code location: `journalSuspect` is called only in the
  got≠expected branch (`src/main.zig:721-724`). If the clean-process
  `requestApply` of base/replay fails, or the check eval itself raises a
  Scheme error (`try` at `src/main.zig:717-719`), `doCommit` propagates the
  error BEFORE quarantining — yet `handleKernelReq` still reports the
  change as "suspect" (`src/main.zig:387-390`). In that path the pending
  entries stay un-quarantined and would still replay into fresh images.
- Reachable when a pending redefine applies cleanly as a definition but its
  check errors at runtime in the clean image (e.g. depends on exploratory
  non-kernel-tracked mutation). Not exercisable through the fixed probe
  scripts without source changes; confirmed by code inspection. The fix is
  the same shape as F2's: quarantine on every `doCommit` failure exit, not
  just the mismatch branch.

## Contract checks that hold

- **Rule 2 (journal fsync BEFORE apply)**: `handleKernelReq` journals and
  `f.sync`s before `requestApply` (`src/main.zig:348-361`). Correct order.
- **Rule 4 (commit = clean-process replay probe + atomic flip + suspect
  marking)**: second Chez spawned for the probe; flip is tmp-write + fsync
  + rename; failure keeps the pointer AND now journals `(suspect ...)`
  quarantine markers. Both halves of the rule verified.
- **Generations declarative**: `base.ss` + ordered `replay.ss`, sha256,
  parent, timestamp; layout matches README exactly.
- **Rule 7 (watchdog = kernel-side probe)**: known eval frame with a 2 s
  `poll(2)` deadline, no image self-report.
- **Isolation**: `git status --porcelain` at repo root shows only new
  `spikes/` files, this review file, and the pre-declared doc edits (task
  file, `docs/plan/README.md`, `docs/plan/analysis/*`, `docs/decisions/*`,
  `docs/INDEX.md`, `docs/quality/*`); the doc edits are link-index
  additions only. Nothing under `packages/`, root `build.zig`, `.github/`,
  `docs/maturity.md`, or `chapters/` touched.
- **Framing/journal/generation formats** match the README: u32-LE length
  prefix both directions; journal `(redefine|discard|commit|suspect)`
  lines; `generations/<n>/{base.ss,replay.ss,meta.sexp}` with
  `hash = sha256(replay.ss)`; `(kernel.nack ...)` documented and
  implemented.

## Independent measurements vs RESULTS.md (rev 2 runs)

| Probe | RESULTS.md claim | My rev-2 run | Match |
|-------|------------------|--------------|-------|
| boot (median, N=10) | 37–55 ms quiet; worse under load | **41.74 ms** (min 40.43, max 52.16), load ~6.5 | yes, PASS < 100 ms |
| echo 10k | 905–1984 msgs/sec, 0 framing errors | **1859 msgs/sec**, 5380 ms, 0 errors | yes |
| redefine → fsync → SIGKILL → replay | PASS, identical source/value | PASS (`hacked`, source byte-identical) | yes |
| discard + unknown-name nack (F4) | nack `not-committed`, image alive | PASS (err `not-committed irritants=()`, image alive) | yes |
| commit (both paths) + suspect quarantine (F2) | gen 1 kept on failure; reload boots `hacked` | PASS, `(suspect greeting ...)` journaled, reload `hacked`, exit 0 | yes |
| watchdog after failed commit (rev-1 repro) | reload committed value | **fixed**: reloaded `hacked` (was `broken` in rev 1) | yes |
| watchdog (clean) | deadline ~2 s, reload `hello`, journal intact | 2001 ms, `hello`, 0 lines intact | yes |
| env-check | allowlist env, all sensitive names `#f` | PASS, 9 sensitive names all `#f` | yes |

## Conclusion

**pass.** F2 and F4 are genuinely closed — both fixes verified by
re-running the exact rev-1 reproduction sequences, not just the new
in-probe assertions. No regressions in any other probe. Remaining open
items are unchanged from rev 1 (F1 findings-placement, F3 journal-as-
replay-log simplification, F5–F7 hygiene) plus two new P3 observations
from the fix pass (F8 orphan generation dir, F9 quarantine gap on probe-
error paths). None block the spike; F8/F9 should be noted alongside F2/F3
as design-doc open questions before any productization decision, and F1
still gates ticking the task's last checkbox.
