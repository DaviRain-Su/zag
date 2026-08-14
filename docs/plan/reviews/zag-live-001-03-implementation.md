# Review: zag-live-001 — implementation verification

- Task: [zag-live-001](../tasks/zag-live-001.md)
- Binding: [zag-live.md](../../modules/zag-live.md) (frozen, round-2) · [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- Track: implementation verify (read-only on source; reviewer wrote the
  safety-axis contract reviews and ran all spike verifications)
- Result: **pass** — zero blocking; 2 P2 + 4 P3 non-blocking

## Test counts (independent, from clean tree)

Wiped `packages/zag-live/zig-out` and `.zig-cache`, then `zig build test`:

```
Build Summary: 3/3 steps succeeded; 21/21 tests passed
run test 21 pass (21 total) 13s MaxRSS:165M
```

21/21 confirmed = 9 named unit tests (frame ×3, journal ×1, generations ×1,
ports ×2, live ×2) + 1 anonymous reference test (root.zig) + 11 acceptance
tests matching §10 classes 1–11 one-to-one. Developer's "10 unit + 11
acceptance" claim is accurate under that counting. Tests spawn real Chez
subprocesses against temp state dirs; no stubs, no network.

## Contract conformance (section by section)

- §3 Frame: codec in `frame.zig` is byte-for-byte the spike-proven
  discipline (canonical Chez escapes, strict decode, 4 MiB cap both sides,
  single-paren datum trim) with unit tests for nasty strings and loud
  unknown-escape errors. ✓
- §3 JournalEntry: `journal.zig` implements B3 exactly — `lineComplete`
  (prefix + trailing `)`), torn final line truncated silently, mid-file
  unknown kind = `JournalCorrupt` (unit-tested both ways; independently
  re-verified below). H2: one `writeStreamingAll` per entry incl. newline +
  fsync, dirfd-relative to state_dir. ✓
- §3 Generation: staged `.staging-<n>/`, disarmed cleanup on probe pass,
  `deleteTree` on failure, stale staging removed on `start()`
  (`cleanupStaleStaging` — covers my round-2 N3 nit). Pointer flip =
  tmp+fsync+rename. ✓
- §4: env rule is `buildEnvLocked` (live.zig:253-263) — PATH/HOME/TERM
  allowlist via `std.c.getenv` + explicit `extra_env` only; ambient never
  inherited. Boot probe + version floor ≥ 10.0 (`checkVersionFloor`,
  unit-tested). Recovery semantics (never transparently retry,
  `ImageRestarted` once) implemented in `boundaryDisposition`
  (live.zig:197-210) and acceptance class 9. ✓
- §5: commit has both B4 forms; default check = replay completes + every
  tracked binding resolves (`trackedNames`, live.zig:915-936); mismatch or
  check-eval error rejects and quarantines; nack on unknown discard;
  `NothingToCommit` added to the error set (my round-2 nit). ✓
- §6: ports synchronous, absent → `(port.nack … "PortAbsent")` (class 11);
  port error names stripped to first-line atoms (`firstLineAtom`). ✓
- §7: all durable state under `state_dir` (journal, generations, current,
  and the embedded `image.ss` written there — nice: the image script is
  state-dir-resident, not cwd-relative as in the spike). ✓
- §8: closed vocabulary + `NothingToCommit` + documented `OutOfMemory`
  escape hatch. ✓
- §10: all 11 acceptance classes present and real (no vacuous tests);
  class 8 covers value-mismatch quarantine, check-eval-error quarantine
  (F9), G4 infra retry→`CommitUnavailable` with pending intact + later
  retry success, no-orphan assertions, exploratory-live disposition; class
  9 covers in-flight `ImageRestarted` + journal-intact + watchdog idle
  restart; class 11 covers ports, absent-port nacks, H2 line integrity,
  and the shipped `fsReadPort` through `Live`.

## Independent adversarial verification (own harness in /tmp)

Scratch harness (`/tmp/zaglive-verify`, imports the package by path; no
repo files touched). All sections passed:

1. **Env scrub with fresh names**: injected `VERIFIER_SECRET_KEY_9261` /
   `VERIFIER_TOKEN_9261` into the supervisor env → both `(getenv …)` = `#f`
   in the image; `extra_env` override passes through with the host's
   explicit value; allowlisted PATH present. B1 mechanism works against
   names the developer never saw.
2. **Journal durability**: crafted a torn final line (crash mid-append
   simulation) → restart tolerates it and the real pending entry replays;
   crafted mid-file `GARBAGE-LINE` → `start()` fails with
   `JournalCorrupt`, fail closed. B3 rule confirmed end-to-end through the
   public API.
3. **Replay-fatal pending entry** (see M2): `(kernel.redefine 'evil
   "(exit)")` errors host-side as the live image dies at apply; a fresh
   `Live` on the same state dir then fails `start()` with
   `BootProbeFailed` — the state dir is bricked — and supervisor-side
   quarantine surgery via the public `journal.appendSuspect` revives it.
4. **fsReadPort beyond dev tests**: symlink chain (`link-a → link-b →
   ../../outside`) → `IsSymlink`; intermediate-component symlink to an
   outside dir (`extdir → /tmp`, then a real file through it) →
   `IsSymlink`; `..` traversal, absolute path, unknown tool → rejected;
   plain and subdirectory reads work. The dirfd + `O_NOFOLLOW` per-component
   walk has no realpath-then-open TOCTOU — H3 is properly closed and
   strictly stronger than the spike version I attack-tested earlier.
5. **Lifecycle sanity**: `stop()` after ops returns promptly; stop/start
   cycle preserves pending state; `stop()` after `forceKillImage` is
   idempotent.

## Findings

### M1 — P2, non-blocking: G4 infra/defect classification has two reverse-error edges

- Location: `live.zig:874` (clean spawn `try`), `live.zig:901-913`
  (`classifyProbeError`/`isInfraError`), `live.zig:802-807` (retry loop).
- (a) Spawn-time failures other than `FileNotFound` (e.g.
  `SystemResources` under fork exhaustion) propagate out of `commitProbe`
  unclassified, fail `isInfraError`, and are treated as a **change
  defect**: the innocent pending set is quarantined and the caller sees
  `CommitRejected` — the reverse of the G4 gate.
- (b) Post-spawn clean-process death during replay (`ImageDied`/
  `ImageRestarted`/`FrameTooLarge` from the apply/eval requests) is
  classified as **infra** → retried once → `CommitUnavailable`, no
  quarantine — but such death can be caused by the change itself
  (replay-fatal source, oversize output triggered by the change).
- The tested paths (FileNotFound seam, scheme errors) classify correctly;
  these edges are code-read findings. Fix shape: infra = only
  `spawnCleanLocked`'s own failures; any error after the clean process has
  booted = defect of the change.

### M2 — P2, non-blocking: replay-fatal pending entry bricks the state dir (demonstrated)

- A journaled pending redefine whose source is replay-fatal (e.g.
  `(exit)`, interpreter-crashing forms) is applied to the live image
  immediately (journal-first is correct), killing it; every later
  start/restart then dies during replay (observed: `BootProbeFailed`), and
  the watchdog restart loop cannot recover. The commit probe never gets a
  chance to quarantine it because serving `kernel.commit` requires a live
  image.
- The spike had the same unprobed hole; the contract makes no claim here,
  so this is not a deviation — but G4's intent (quarantine defects before
  they poison replay) leaks through the redefine path.
- Recovery exists: `journal.appendSuspect` is public and revives the dir
  (demonstrated). Recommend: document this in the README + consider a
  `Live`-level quarantine/discard-pending API so operators never edit the
  journal by hand.

### M3 — P3, non-blocking: request deadline covers only the first frame byte

- Location: `frame.readFrameDeadline` (frame.zig:85-97) polls once, then
  `readFrame` blocks indefinitely mid-frame. A pathological image that
  flushes a partial frame and then hangs blocks the host request forever
  (the watchdog won't fire: the request holds the mutex). Threat model is
  trusted local code (§7 containment honesty), so P3 hardening note:
  deadline the whole frame read.

### M4 — P3, non-blocking: `stop()` has no kill budget (contract §4 comment says "kill after budget")

- Location: live.zig:148-167 — close stdin + `wait`, kill only on wait
  error. A never-exiting image would hang `stop()`. Developer flagged this
  honestly ("stop() via EOF-exit not timer"). I could not construct a
  hung-at-stop state through the public API: every image-executing path is
  mutex-serialized behind a deadline-bounded request that restarts on
  deadline, and the watchdog kills idle-hung images — so the gap is
  latent, not reachable today. Either amend the §4 comment at closeout or
  add the budget as defense-in-depth.

### M5 — P3, non-blocking: journal line validation is structural-shallow for discard/suspect/commit

- Location: journal.zig:158-181 — a prefix-valid, `)`-terminated but
  semantically bogus line (e.g. `(commit X "" 1)`) folds as a commit and
  silently clears the pending set. Requires write access to the trusted
  state_dir (tampering-only); hardening note: validate field shapes per
  kind on read, as `redefine` already effectively does.

### M6 — P3, non-blocking: hygiene notes

- Test seams (`fail_clean_spawn` field, `forceKillImage`,
  `sendRawFrameUnchecked`) are pub on the product type; own-instance-only
  and safe, but worth a "test support" doc note. `NotRegularFile` in
  `PortError` is unused. The acceptance test reaches into `l.child`
  internals (acceptance.zig:268) — same-package, acceptable.

## Isolation

`git status --porcelain`: the developer's footprint is `packages/zag-live/`
(untracked) plus docs edits already declared (`docs/modules/README.md`
registration, `docs/INDEX.md`, plan/backlog/quality index rows). Root
`build.zig`/`build.zig.zon` untouched; no other package modified;
`packages/zag-live/build.zig.zon` depends on `../zag-types` by path only —
no network, no forbidden imports (`zag-agent-core`, `zag-ai` absent).

## Conclusion

**pass.** The implementation is a faithful, clean-room-structured
promotion of the spike: every normative contract section maps to real,
tested code; all 11 acceptance classes run green from a clean tree
(21/21); the three promotion gates (H2 single-write, H3 dirfd containment,
G4 retry-vs-quarantine) are implemented and independently re-verified
beyond the developer's tests (fresh env-scrub names, crafted journal
corruption, chained/outside-dir symlink escapes). No stubs, no contract
deviations in acceptance paths, isolation clean. M1/M2 (P2) are
edge-classification and operator-recovery gaps for the backlog before any
default-on consideration; M3–M6 are P3 hardening notes. Nothing blocks
`zag-live-002` (provider bridge) from proceeding against this package.

---

# Fix round (M1/M2) — regression verification

Developer claims re-verified independently. Conclusion: **both fixed;
conclusion stays pass.**

## Test counts

Clean tree (`zig-out`/`.zig-cache` wiped), `zig build test`:

```
Build Summary: 3/3 steps succeeded; 23/23 tests passed
run test 23 pass (23 total) 13s
```

23/23 = the previous 21 + `accept 8 edges (M1)` + `recover() … (M2)`.
Claim accurate.

## M1 — FIXED

- Structural/temporal boundary is exactly as disclosed: staging writes and
  `spawnCleanLocked` are the last infra-capable steps (`commitProbe`,
  live.zig:907-944); any error there propagates, retries once, then
  `CommitUnavailable` with pending intact (doCommit, live.zig:864-882).
  Everything after a successful spawn — apply death, oversize, scheme
  error, check mismatch — returns `.reject` → quarantine +
  `CommitRejected` (live.zig:946-976). `OutOfMemory` passes through
  correctly at both levels. The old error-name classifiers
  (`isInfraError`/`classifyProbeError`) are deleted.
- Both edges I flagged are closed: `accept 8 edges (M1)` forges a
  `SystemResources` spawn failure (not `FileNotFound`) — no suspect entry,
  retry succeeds; and a journal-side `(exit)` pending entry kills the
  clean probe post-spawn — `(suspect evil …)` journaled, pointer
  unchanged, no orphan dirs, live image unaffected. Both run in the 23/23.
- **Disclosed trade-off judgment — acceptable direction.** Post-spawn
  death defaults to *defect* even when truly innocent (e.g. a transient
  resource flake killing the clean process after spawn): a falsely
  quarantined change costs a re-`redefine`, while the reverse (false
  infra) risks the M2 brick. Quarantine-default protects replay integrity,
  which is the property the whole design exists for; and `recover()` now
  exists as backstop. The boundary is also crisp and testable (spawn is
  the temporal cut). Endorsed.

## M2 — FIXED (verified via my original brick procedure, public API only)

- My `/tmp/zaglive-verify` harness section 3 re-runs the exact round-1
  demonstration — `(kernel.redefine 'evil "(exit)")`, restart on the same
  state dir — then recovers **without journal surgery**:
  - bricked `start()` fails with `BootProbeFailed` ✓
  - `needsRecovery()` latch reads true (set on replay death with
    non-empty pending, live.zig:135-146 and 433-439) ✓
  - `recover()` quarantines the fatal entry (`(suspect evil …)`), revives
    to committed genesis, clears the latch ✓
  - the revived instance survives a subsequent `forceKillImage` +
    watchdog restart ✓
- Genesis now writes the `current` pointer file (live.zig:394-395),
  closing the missing-pointer default-to-0 asymmetry.
- Notes (non-blocking, no action needed): `recover()` quarantines ALL
  pending entries, not just the fatal one — blunt but caller-initiated and
  disclosed; and the latch correctly does NOT fire when replay dies with
  an empty pending set (a generation-store defect, a different failure
  class with no contract claim).

## Harness errata (my bugs, not the package's)

Two failures in my first fix-round run were harness bugs, recorded for
honesty: (1) I asserted the first eval after `forceKillImage` must
succeed — the contract-correct behavior is `ImageDied` (child already
reaped; watchdog restarts) or `ImageRestarted` (in-flight death), then
retry succeeds; (2) an early error return skipped `deinit`, leaking a
watchdog thread onto a reused stack frame — the resulting segfault was
mine. Fixed harness: all 5 sections pass clean, no leaks.

## Conclusion (fix round)

**pass** stands. M1's classification boundary is structural, both reverse
edges are test-gated, and the disclosed post-spawn-defect default is the
safe asymmetry. M2's `recover()`/`needsRecovery()` covers my demonstrated
brick end-to-end through the public API. M3–M6 (P3) remain as previously
recorded hardening notes.
