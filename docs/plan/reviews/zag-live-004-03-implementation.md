# Review: zag-live-004 — implementation verification (D-015 runtime port)

- Task: [zag-live-004](../tasks/zag-live-004.md)
- Binding: [zag-live.md](../../modules/zag-live.md) (D-015 revision, review
  round 2 — safety axis passed by this reviewer)
- Prior reviews whose blockers must be confirmed landed:
  [zag-live-004-01-architecture](./zag-live-004-01-architecture.md) ·
  [zag-live-004-02-safety](./zag-live-004-02-safety.md)
- Track: independent implementation verify (reviewer did not write this code;
  previously verified spikes 001–004 and the zag-live-001 implementation)
- Result: **PASS** — zero blocking; 2 notes (neither blocking)

## Test run (independent, clean tree)

Wiped `packages/zag-live/.zig-cache` + `zig-out`, then `zig build test`:

```
Build Summary: 3/3 steps succeeded; 42/42 tests passed
run test 42 pass (42 total) 41s
```

Claim verified. Because the wipe removed `.zig-cache/zag-live-test-image/`,
its reappearance during the run (110 KB `image-bin`, freshly built via
`buildImage()` inside the test harness) proves the **compiled form actually
executed** — the dual-form coverage is not vacuous on this host. Caveat
(Note 1): skip gates are early-return-pass, so a toolchain-less host would
report green without running the image tests; CI for this package should
pin a gxi+gsc-present host.

## §10 class-by-class mapping (all 14 classes present, dual-form where required)

| §10 class | acceptance.zig test(s) | Assessment |
|---|---|---|
| 1 boot + boot probe | accept 1 ×2 forms + ImageUnavailable paths (missing gxi / missing binary / wrong identity) | full; startup bounded by the boot probe's `readFrameDeadline` (deadline_ms), not a stopwatch assertion — bounded by construction (Note 2) |
| 2 env scrub | accept 2 ×2 forms (setenv-injected secrets → `#f`, extra_env passthrough, PATH present) | full, spike env-check parity both forms |
| 3 echo 10k | accept 3 ×2 | full |
| 4 escaping fuzz | accept 4 ×2 (Gambit lowercase profile + strict loud decode) | full |
| 5 frame cap both sides | accept 5 ×2 (incl. uncapped-seam inbound rejection + oversize image reply → restart) | full |
| 6 redefine→SIGKILL→replay | accept 6 ×2 | full |
| 7 discard/nack | accept 7 ×2 | full |
| 8 commit paths | accept 8 ×2 + M1b edge ×2 (post-spawn replay death quarantined) | full; G4 structural boundary re-verified on both forms |
| 9 watchdog + in-flight | accept 9 ×2 (ImageRestarted once, journal intact, no dup side effect) | full |
| 10 inspect | accept 10 ×2 | full |
| 11 ports | accept 11 ×2 (fixture ports, absent nacks, H2 line integrity, fsReadPort via Live) | full |
| 12 build route + identity | accept 12: buildImage → gsc via gxi (never PATH), boots, self-id handshake; foreign binary (shell script answering `(ok (wrong 0))`) → ImageUnavailable; rebuild byte-SIZE identical | full for the mechanism; the disclosed limitation is accurate — "answers wrong/absent" is covered, "answers an *old* version" fixture is unconstructible, and both hit the same exact-identity compare (`live.zig:499`), so no semantic hole |
| 13 stop discipline | accept 13 ×2: doctored image answers self-id+apply then ignores quit AND EOF forever; asserts stop() takes ≥ the budget (quit frame honored) AND < 5 s (SIGKILL bounded) | full; this is the R1 contract fix made real, incl. the compiled form with a 2 s budget for cold-start asymmetry |
| 14 crash discipline | accept 14 ×2: corrupt stream (huge header + partial payload + EOF) → image exits nonzero, NOT signaled; stdout reads clean EOF; captured stderr ≤ 4 KiB and non-empty | full; R2 made real, both forms, with `capture_image_stderr` plumbing |

No missing classes, no semantic shrinkage found.

## Contract-fix confirmation (round-2 safety + arch blockers)

- **R1 stop discipline** (`live.zig:249-287`): sends `(kernel.quit)`,
  closes stdin, WNOHANG wait loop up to `deadline_ms`, then SIGKILL +
  blocking reap; idempotent; watchdog joined before the mutex. Matches the
  binding text exactly. ✓
- **R2 frame-stream purity** (`runtime.ss:236-258`): top-level catcher
  truncates diagnostics to 4 KiB → stderr, exit 70; image header comment
  states the invariant. `capture_image_stderr` gives tests the stderr pipe.
  ✓
- **R3 compiled-image identity** (`runtime.ss:131,138` —
  `image-identity '(zag-live 1 gambit)` answered by `kernel.self-id`;
  `live.zig:488-500` — exact-match handshake at `start()`, any
  write/read/mismatch failure → `ImageUnavailable`). ✓ Self-id as primary
  mechanism, as endorsed in my contract review.
- **Arch folds**: `.image` union (`compiled` path / `interpreted` gxi) with
  cheap init-time validation (live.zig:131-135); boot probe at `start()`;
  `buildImage()` writes `state_dir/image-bin` via gsc discovered from
  gxi's `path-expand "~~bin/gsc"` — never PATH (verified: PATH's gsc is
  Ghostscript on this host); clean commit probe spawns the **same form**
  (`spawnArgvLocked` shared, live.zig:442-454). ✓
- **Env rule** holds for both forms (shared `buildEnvLocked`, allowlist +
  extra_env only). ✓

## Independent re-verification beyond the package's tests

My pre-existing adversarial harness (`/tmp/zaglive-verify`, written against
the Chez binding for the zag-live-001 review) ran **unmodified** against
the Gambit port — all 5 sections green: fresh-name env scrub, torn-tail
vs mid-file journal corruption (fail-closed `JournalCorrupt`), the M2
brick → `BootProbeFailed` → `needsRecovery()` → `recover()` revival cycle,
fsReadPort chained/outside-dir symlink escapes, lifecycle sanity. The
port preserves every externally observable behavior my harness probed.

## Scope / isolation

- `git status`/`diff`: this task's footprint is `packages/zag-live/**`
  (modified) + `docs/modules/live-policy-layer.md` (sync edits, untracked
  file so diff-by-read: §4 error rename to `ImageUnavailable`, §8 test 5
  `.image` wording, `Config.base_source` reference — nothing beyond the
  declared sync) + the expected docs-index rows.
- The `M spikes/live-runtime/*` entries are the **uncommitted spike-004
  work I already reviewed** (kernel.quit in the spike image, runtime
  selection, round-5 README/RESULTS), not this task's changes — verified
  by reading the diff. The spike harness (both runtimes) is intact.
- Chez-specific code removed from the package: the only remaining "Chez"
  mention is a comment in `runtime.ss` explaining the `getenv` shadow's
  compatibility target. No `gxc` usage anywhere; build route is gsc-only.
- Root build untouched; no other package modified.

## Notes (non-blocking)

1. **Skip-gates pass vacuously.** `formAvailable`/`interpretedAvailable`
   early-return counts as pass; a host without gxi/gsc reports 42/42 with
   the image tests never run. Contract permits skip-gating; CI should pin
   a toolchain-present host so the dual-form gate means something.
2. **§10 test 1 "bounded startup"** has no stopwatch assertion; boundedness
   is by construction (boot probe reads under `deadline_ms`), and the
   disclosed compiled-form cold-start asymmetry (~171 ms first spawn, ~4 ms
   warm) is absorbed by per-form watchdog budgets (test 13 uses 2 s for
   compiled). Acceptable; a timing assertion would be flake-prone anyway.

## Conclusion

**PASS.** The implementation matches the round-2 contract point for point:
all 14 acceptance classes present and substantive on both spawn forms, the
three safety blockers (stop discipline, frame-stream purity, compiled-image
identity) are real code with real doctored-image tests, the arch folds are
faithful to the verified Chez-era implementation, and the disclosed
asymmetries (cold-start budget, test-12 fixture limitation, cwd-path
validation) are honestly reported and accurately described. Independent
confirmation beyond the suite: clean-tree 42/42 with the compiled image
provably built and run, plus my own adversarial harness passing unmodified
against the Gambit binding. zag-live-004 is done on this axis;
zag-live-002 can unfreeze against it.
