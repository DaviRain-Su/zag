# Review: zag-live-004 — architecture / ownership (zag-live.md D-015 revision)

- Task: [zag-live-004](../tasks/zag-live-004.md)
- Binding: [zag-live.md](../../modules/zag-live.md) (D-015 revision draft;
  header lines 12-17)
- Evidence base re-verified: [D-015](../../decisions/active/D-015-live-runtime-gerbil-gambit.md),
  [spike-004 review](./live-runtime-spike-004-01.md) (independent verify,
  pass), `spikes/live-runtime/RESULTS.md` round 5 (lines 342-436),
  `spikes/live-runtime/runtime-gerbil.ss`, plus the implemented package
  (`packages/zag-live/src/live.zig`) for init/start and config-shape truth
- Track: contract / architecture+ownership axis
- Result: **blocked** — 2 blocking (P2), 4 non-blocking (2 P2, 2 P3)

## 1. Fidelity to evidence (axis 1): mostly exact, one overreach

Verified against spike-004's reviewed numbers and semantic findings:

| Revision claim | Verdict |
|----------------|---------|
| gsc-exe boot "~5 ms" (§1) | ✅ within evidence — medians 4.13 ms (theirs) / 5.95 ms (independent); D-015's "4–6 ms" matches |
| gxc rejection: namespacing breaks interaction-eval (§1) | ✅ confirmed firsthand by the spike reviewer (F-check (c): `probe#main` namespacing, unbound under interaction-environment) |
| Codec profile: Gambit lowercase `\xhh;`, strict decode, case-insensitive hex (§3) | ✅ RESULTS round 5 + reviewer adversarial check (a) (uppercase accepted, image writes `\x1f;`) |
| gsc discovery via `gxi` `path-expand "~~bin/gsc"`, never PATH (§4) | ✅ reviewer (d) confirmed PATH's `gsc` is Ghostscript on the probe host and the path-expand route works |
| Full probe matrix on both forms (§10 preamble) | ✅ 10/10 × gxi + gsc-exe, independent runs |
| Version floor only on interpreted; compiled = file-exists + boot probe (§4, §10 test 1) | ✅ coherent — a gsc-exe binary carries its own runtime, so there is no version to floor |
| Commit clean probe uses the live image's spawn form (§5) | ✅ parity stated; commit probes passed under both forms in the spike |
| EOF situation | ✅ revision's silence is consistent with the record: hazard not reproduced in the shipped configuration, kill paths are SIGKILL, `kernel.quit` is image-supported but unused on the wire (spike review F1; task file carries this correctly) |
| Chez retirement scope (§1, §12) | ✅ matches D-015: product path retires Chez; spike harness keeps both |

**Overreach — see B1 below (§10 test 12 "byte-reproducible").**

## Blocking

### B1 — P2, blocking: §10 test 12 claims "byte-reproducible output" — stronger than anything verified

- Location: `zag-live.md` §10 test 12 ("`buildImage()` … produces a
  booting binary; **byte-reproducible output**"); mirrored in the task
  file's implementation track ("binary boots, byte-reproducible").
- Evidence: the spike review's reproducibility check (d) says the rebuilt
  binary was **byte-*size*-identical** (129760 B) — same size, not a
  bit-for-bit comparison. RESULTS.md round 5 makes no reproducibility
  claim at all; D-015 doesn't either. Compiler binaries commonly embed
  build paths/timestamps; nothing in the record shows a gsc `-exe` build
  is bit-reproducible.
- As written, the acceptance gate can fail spuriously on a conforming
  implementation, or pressure the implementer into an unverifiable claim.
- Fix (one clause): relax test 12 to the verified property — "rebuild
  produces an equal-size, booting binary passing the boot probe" — or run
  an actual byte-identity check in the spike first and cite it. Task file
  implementation track needs the same edit.

### B2 — P2, blocking: the rename/reconfig blast radius on `live-policy-layer.md` is unacknowledged

- Locations: `zag-live.md` §4 (`.image` union replaces `chez_path`),
  §8 (`ImageUnavailable` replaces `ChezUnavailable`); vs
  `live-policy-layer.md` §4 (startup degradation enumerates
  **`ChezUnavailable`**), §8 test 5 ("**`ChezUnavailable`** (bad
  `chez_path`)"), §5 (genesis via **`Config.base_source`**).
- The downstream integration contract just went through four review
  rounds (architecture PASS round 4; safety PASS round 2) and is binding
  text for zag-live-002 — which the D-015 revision explicitly holds
  ("unblocks zag-live-002", task status truth). The revision renames the
  error and replaces the config field that contract cites, yet §12's
  relationship table has **no row for live-policy-layer.md**, and
  zag-live-004's verification doesn't include syncing it (its forbidden
  list permits docs outside `docs/maturity.md`, so the sync is in-scope
  if assigned).
- This is also the missing **backward-compat statement** (axis 3): a
  breaking Config + error-vocabulary change is acceptable here — the
  package has no shipped consumers (zag-live-002 held pre-implementation,
  003 planned; experimental, no maturity row) — but the revision never
  says so.
- Fix (one §12 row + one task line): "live-policy-layer.md — Chez-era
  references (`ChezUnavailable`, `chez_path`) superseded by
  `ImageUnavailable`/`.image`; sync folded into zag-live-004 (breaking
  change accepted: no shipped downstream consumers)". Note
  `Config.base_source` survives unchanged (live-policy-layer.md §5
  depends on it; implemented at `live.zig:63-65`).

## Non-blocking

### N1 — P2: `buildImage()` output location unspecified; §7 state inventory unchanged

- §4 introduces a package helper that builds a binary, but never says
  where the output lives. §7's state inventory (`journal.sexp`,
  `generations/`, `current`; "the package never writes outside
  `state_dir`") predates the build route. If the binary lands in
  `state_dir` (e.g. `.zag/live/`), §7 should list it as a regenerable
  artifact (host-specific; inherits the D-015 off-host caveat). If it
  lands elsewhere, §7's write-containment claim needs an explicit
  exception. One sentence either way.

### N2 — P2: §4 assigns the boot probe to `Live.init`; the implemented binding probes at `start()`

- §4: "`Live.init` validates the chosen form: compiled = file exists +
  boot probe; interpreted = gxi version floor + boot probe." The
  implemented Chez binding probes at **`start()`** (`live.zig:116`, doc
  "Spawn + boot probe (version floor) + replay"), and `init` is
  side-effect-light (realpath + alloc, `live.zig:100-105`). Moving the
  probe to `init` gives `init` process-spawn side effects — a deliberate
  API-semantics change worth stating, or a slip to correct
  ("validation at `start()`"). live-policy-layer.md §4 covers both
  ("ANY `Live.init`/`start` failure"), so either choice is compatible
  downstream; the contract just has to pick one.

### N3 — P3: §4 API sketch drops `base_source`

- The old sketch's `Config` included the genesis-definitions field
  (implemented as `base_source`, `live.zig:63-65`); the revised sketch
  shows only `.state_dir` / `.image` / ports / env / watchdog. It says
  "v1 sketch", so omission isn't removal — but since live-policy-layer.md
  §5's genesis mechanism rides on `Config.base_source`, keeping it in the
  sketch (or noting it's unchanged) removes a plausible misread.

### N4 — P3: "~5 ms boot, no host runtime dependency" is within evidence but carries two caveats already on record

- The independent run saw a 430 ms first-spawn outlier (cold exec cache;
  median is the honest figure — as the spike review itself notes), and
  "no host runtime dependency" is the upstream-supported `gsc -exe`
  static-ish property whose off-host (Linux) truth is explicitly
  unverified (D-015 caveat; §11 non-goal covers it). No text change
  required; flagging so the implementation review doesn't treat §1's
  parenthetical as a measured guarantee beyond the probe host.

## What holds

- Runtime binding (§1) accurately reflects the decision and the probe:
  two spawn forms, gxc rejection with the correct reason, Chez retired
  from the product path only.
- The codec-profile row (§3) states exactly the discipline the reviewer
  verified on the wire (lowercase canonical encode, case-insensitive
  strict decode).
- `.image` union + `ImageUnavailable` rename are internally consistent
  across §4/§8/§10 (axis 3's consistency question: yes, inside this
  document).
- Commit clean-probe spawn parity (§5), version-floor scoping (§4/§10
  test 1), and dual-form acceptance gating (§10 preamble + task
  verification) address the Chez→Gambit swap's structural risks.
- Task file fitness (axis 4): depends-on chain, forbidden list
  (`packages/zag-live/**` only, spike untouched), and both-form
  acceptance re-run are the right gates — minus the B1/B2 items above.
- No Chez-specific mechanism text left behind: the old floor
  ("Chez ≥ 10.0") and `ChezUnavailable` are fully replaced; remaining
  Chez mentions are historical (header) or harness-scope (§12).

## Conclusion

**blocked** on two small, mechanical defects: B1 — §10 test 12's
"byte-reproducible" exceeds the verified evidence (byte-*size*-identical)
and must be relaxed or evidenced; B2 — the revision silently invalidates
the just-reviewed `live-policy-layer.md` (`ChezUnavailable`/`chez_path`
references) without a §12 row, a sync assignment, or the (easy,
justified) breaking-change statement. Both are contract-text fixes; N1/N2
should ride along (build-output location, init-vs-start probe). Nothing
found requires new spike work or changes the D-015 direction — the
evidence fidelity is otherwise exact, and the runtime swap's load-bearing
claims (gxc rejection, codec profile, discovery route, boot numbers) all
reproduce to the reviewed record.

---

# Round 2 re-review (2026-08-14) — D-015 revision

- Contract: [zag-live.md](../../modules/zag-live.md) (header lines 12-15,
  "review round 2"); task: [zag-live-004](../tasks/zag-live-004.md)
- Re-verified against: spike-004 review, `RESULTS.md` round 5,
  `runtime-gerbil.ss`, `packages/zag-live/src/live.zig`
- Result: **PASS** — all round-1 findings resolved; safety folds
  cross-checked, no contradictions; one P3 residue

## Per-finding verdicts

### B1 (P2, blocking) — **RESOLVED**

§10 test 12 (line 247) now gates on the verified properties: gsc-via-gxi
discovery, booting binary answering the self-id handshake, stale/foreign
binary → `ImageUnavailable`, rebuild **byte-size identical**; sha256
reproducibility is explicitly demoted to "recorded on-host observation,
not a gate" (also §4, lines 102-104). Task file implementation track
mirrors this (lines 71-73). The acceptance gate no longer exceeds the
evidence.

Residue (P3, non-blocking): the "three consecutive `gsc -exe` builds were
sha256-identical" parenthetical has **no recorded evidence in the spike**
— grep of `spikes/live-runtime/` finds sha256 only as the journal
replay-hash mechanism (`src/main.zig:1355`), no build-reproducibility
record. Non-gating, so not blocking, but a binding contract shouldn't
carry an unrecorded measurement: either append the three hashes to
RESULTS.md round 5 or drop the parenthetical.

### B2 (P2, blocking) — **RESOLVED**

§12 gained the live-policy-layer row (line 265): sync owned by
zag-live-004, enumerating `ChezUnavailable` → `ImageUnavailable`,
`chez_path` → `.image`, `Config.base_source` confirmed — with the
deliberate-breaking-change statement ("no shipped consumers,
zag-live-002 held"). Task file carries it twice: path table ("Contract
sync (arch B2)", line 55) and a verification checkbox (lines 78-80).
The blast radius is now acknowledged, assigned, and gated.

### N1 (P2) — **RESOLVED**

`buildImage()` output pinned to `state_dir/image-bin` (§4 line 93-94,
"inside state_dir per §7"); §7 inventory (lines 192-195) now lists
`image-bin` as `buildImage()` output. Write-containment claim intact.

### N2 (P2) — **RESOLVED**

§4 (lines 87-89): "`Live.init` validates configuration cheaply …; the
**boot probe runs at `start()`** (N2 — matches the implemented binding)".
Matches `live.zig:100-105` (init: realpath + alloc) and `:116` (start:
spawn + probe + replay). §10 test 1 updated to "boot + boot probe at
`start()`". Consistent with live-policy-layer.md §4's init/start
degradation wording.

### N3 (P3) — **RESOLVED**

`.base_source = null` restored to the §4 sketch (line 74) with the
embedded-genesis default and the live-policy-layer dependency noted
in-line.

## Safety-fold cross-check (R1–R3): no contradictions

- **§3 frame-stream purity (R2):** top-level catcher → stderr + nonzero
  exit, never stdout — matches `runtime-gerbil.ss:295-309` (the catcher
  exists precisely because gxi prints uncaught exceptions to stdout) and
  the review's torn-frame trial (exit 70). The ≤ 4 KiB stderr bound is a
  new binding requirement (the spike image doesn't bound), but it's
  gated by test 14 and contradicts nothing; §8's error-payload rule now
  points at it (lines 219-220). Coherent.
- **§4 stop discipline (R1):** `kernel.quit` → `deadline_ms` → SIGKILL.
  Consistent with the record on both sides: `runtime-gerbil.ss:161`
  implements `(kernel.quit)` → `(ok bye)` + exit 0, and this fold
  resolves spike-review F1 (quit frame previously dead on the wire) in
  the recommended direction — the product supervisor now sends it.
  `deinit()`-never-hangs is the right binding for the Gambit EOF caveat;
  test 13 gates the doctored-image path. §5 (line 128) declares
  `kernel.quit` a host→image frame, matching the protocol. Coherent.
- **§4 compiled-image identity (R3):** self-id handshake as the compiled
  form's boot probe, stale/foreign → `ImageUnavailable` — the split is
  clean against the rest of the contract: interpreted keeps the version
  floor (§4, §10 test 1), compiled gets identity (§3 Image row, §10 test
  12), both probe at `start()`. New mechanism, but it's binding text with
  an acceptance gate, not an evidence claim. Coherent.

## Round-2 conclusion

**PASS — architecture/ownership axis.** Both round-1 blockers are fixed
correctly: test 12 no longer gates beyond the verified evidence, and the
`live-policy-layer.md` sync is acknowledged, owned, and gated with the
breaking-change statement on record. N1–N3 landed as recommended. The
safety folds integrate cleanly with the architecture facts — the stop
discipline matches the image's implemented `kernel.quit` and closes
spike-review F1, frame-stream purity matches the top-level catcher, and
the self-id/boot-probe/floor split is consistent across §3/§4/§10. One
P3 residue: the sha256×3 observation lacks a recorded basis in the spike
(record the hashes in RESULTS.md or drop the parenthetical — non-gating).
Nothing on this axis requires further contract rounds; zag-live-004 can
proceed to `ready` once the safety axis confirms the current text.
