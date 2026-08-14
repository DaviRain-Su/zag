# Review: zag-live-004 — safety / lifecycle axis (D-015 runtime-switch revision)

- Task: [zag-live-004](../tasks/zag-live-004.md)
- Binding: [zag-live.md](../../modules/zag-live.md) (D-015 revision) · [D-015](../../decisions/active/D-015-live-runtime-gerbil-gambit.md)
- Evidence baseline: my spike-004 review ([live-runtime-spike-004-01](./live-runtime-spike-004-01.md))
  plus the zag-live-001 implementation verification (23/23, incl. M1/M2 round)
- Track: contract / safety+lifecycle axis
- Result: round 1 **blocked** (R1–R3) → round 2 **pass** (see below)

The revision carries the frozen Chez-era semantics over faithfully (typed
journal + B3 torn-tail rule, staged generations, G4's structural
spawn-stage-only infra boundary now written into the gate table, failed-
commit disposition, `recover()`/`needsRecovery()`, env rule, containment
honesty, closed error vocabulary with `ImageUnavailable` replacing
`ChezUnavailable`, dual-form gating in §10). The runtime swap itself is
well-supported by spike evidence. Three gaps block — all are places where
the runtime-neutral rewrite dropped a property that Chez provided
*by accident of its defaults* and Gambit does not, or where the new
compiled form introduces a risk class the Chez form never had.

## Blocking findings

### R1 — P2, blocking: `stop()`'s "kill after budget" is not operationalized, and the swap removes the property that made that safe

- Location: §4 sketch (`try live.stop(); // graceful; kill after budget`).
- Facts: the implemented (Chez) package never had a kill budget — `stop()`
  closes stdin and waits (zag-live-001 implementation review, M4). That was
  tolerable under Chez because (a) Chez exits reliably on stdin EOF, and
  (b) every image-executing path is mutex-serialized behind a
  deadline-bounded request. Under Gambit, leg (a) is gone by the
  contract's own admission: D-015 records stdin-EOF unreliability as an
  accepted caveat, and the task context repeats it. My spike-004
  verification did not reproduce the spin in the shipped configuration
  (15+ clean EOF exits), but the property is now *probabilistic by the
  record*, and `stop()`'s graceful leg is precisely the path that depends
  on it. An idle Gambit image that misses EOF hangs `stop()` — and
  `deinit()` — indefinitely.
- Fix (one sentence + one test row): "stop() sends `(kernel.quit)` (the
  frame already exists in both spike images and is currently unused on the
  wire — spike-004 review F1), waits up to `deadline_ms`, then SIGKILLs;
  stop() is bounded under an image that never exits." Add a §10 class: a
  doctored image that ignores quit/EOF is SIGKILLed within budget. This
  also closes the old M4 note properly instead of by accident.

### R2 — P2, blocking: the frame-stream purity invariant is not stated, and Gambit violates it by default

- Location: §3 `Frame` invariants / §5 — nowhere does the revision state
  that the image writes **only protocol frames to stdout**.
- Facts: spike-004 found that gxi prints uncaught exceptions to STDOUT;
  the shipped Gerbil image wraps its main loop in a top-level catcher →
  stderr + exit 70 (verified: torn frame → exit 70, diagnostic on stderr,
  stream uncorrupted). Under Chez this property held by runtime default
  (uncaught → stderr), so the frozen Chez-era contract never had to say
  it. A runtime-neutral rewrite must. A clean port that drops the catcher
  would pass most of §10 (the supervisor treats stdout garbage as
  `FrameTooLarge`/`ProtocolError` and restarts) while silently regressing
  a spike-proven property: one bad frame can desynchronize or mask the
  real error.
- Fix: add to §3/§5 the invariant "the image never writes non-frame bytes
  to stdout; image diagnostics go to stderr; uncaught image failure exits
  non-zero after a stderr report" and a §10 row that kills the image at an
  uncaught-error point and asserts the first post-crash supervisor read is
  a framing error, not silent acceptance.

### R3 — P2, blocking: no provenance/identity check for the compiled image

- Location: §4 image source rule — `.compiled` init validates "file exists
  + boot probe"; §10 test 12 requires byte-reproducible `buildImage()`
  output (verified feasible: three consecutive on-host rebuilds are
  sha256-identical).
- Facts: the compiled binary is the **production form** and the whole
  point of embedding the image source in the package is that the package
  owns the protocol. Yet nothing at init ties the binary to that embedded
  source: a stale binary (built from a previous package version's source)
  at the host-supplied path passes "exists + boots" and silently speaks a
  possibly-older protocol. The interpreted form has a toolchain floor
  (Gerbil ≥ 0.18); the compiled form has no equivalent. Byte-
  reproducibility (test 12) makes the check cheap.
- Fix (pick one, both cheap): boot-probe self-identification — the image
  answers a protocol/source-version query at boot and init rejects
  mismatch — or an init-time (or `buildImage`-time) hash comparison of the
  binary against a rebuilt/known digest. Add a §10 row: stale/foreign
  binary at the path → `ImageUnavailable`.

## Non-blocking findings

### N1 — P3: image error text under Gambit can be huge and path-bearing

Spike round 5: Gambit renders errors with full backtraces into err frames
("large but harmless" — the supervisor substring-checks atoms). §8's
"no absolute paths … in error payloads" covers zag-live's domain errors,
but image-side diagnostics flowing into `last_image_error` can carry
absolute source paths and unbounded size. Bound image error text
(bytes/lines) at the package boundary; keep it diagnostics-only, never
parsed. One sentence in §8.

### N2 — P3: byte-reproducibility is verified on-host only

Test 12's "byte-reproducible output" held across three consecutive builds
here (identical sha256), but this is host- and toolchain-specific;
off-host (Linux) reproducibility is unverified, consistent with the D-015
portability gate. Fine as written — just note in the test comment that the
assertion is on-host, or hash-compare modulo toolchain version.

### N3 — P3: `buildImage()` output-location convention unstated

§4 has the host supply the compiled path; where `buildImage()` writes by
default (state_dir? package cache dir?) and who rebuilds after a package
upgrade (the natural trigger for R3's staleness) is unspecified. One
sentence each; interacts with R3's fix.

## What holds under the swap (checked against spike evidence)

- Codec profile: Gambit lowercase `\xhh;` canonical encode + strict
  case-insensitive decode is written into §3 — verified on the wire and
  fuzzed under both runtimes (spike-004, incl. my own adversarial strings).
- Commit clean probe uses the **same spawn form** as the live image (§5) —
  the correct parity pin; same source, same Gambit evaluator underneath
  both forms, and the spike matrix passed both, including F9 quarantine.
- Env rule, containment honesty, G4 structural classification, B3
  torn-tail rule, recovery semantics: carried verbatim; all previously
  verified in the implemented package.
- `kernel.quit` present in both spike images; the interpreted-form
  toolchain floor (Gerbil ≥ 0.18) matches the probed version (0.18.1).
- §10 dual-form gating covers the risk matrix: fuzz (4) and env scrub (2)
  and every other image-touching class run under BOTH forms,
  skip-gated — exactly the right shape.

## Conclusion

**blocked** on R1–R3 — all one-sentence-plus-one-test-row fixes, all
places where the runtime-neutral rewrite lost a Chez-by-default property
(R1 graceful shutdown reliability, R2 stdout purity) or where the new
compiled production form adds a risk class with no Chez analog (R3 binary
provenance). N1–N3 are wording notes. Nothing here questions the D-015
decision itself — the spike evidence for the swap is solid and
independently reproduced — and no fix requires new spike work; the spike
images already demonstrate the R1/R2 mechanisms.

---

# Round 2 — re-review of the D-015 revision ("review round 2" header)

Re-read the full revised text (268 lines). All three blocking findings are
closed with binding language plus acceptance-test rows; N1–N3 disposed;
the architecture-axis folds carry no safety regression.

## Per-finding disposition

| Finding | Verdict | Evidence in revision |
|---------|---------|----------------------|
| R1 (P2) stop budget | **fixed** | §4 "Stop discipline (R1, binding)": `stop()` sends `(kernel.quit)`, waits up to `deadline_ms`, then SIGKILLs; "Gambit EOF unreliability … must never hang `deinit()`." §5 classifies `kernel.quit` as the host→image polite-stop frame (activating the previously dead-on-the-wire frame from spike-004 F1). §10 **test 13** gates it with a doctored quit/EOF-ignoring image → SIGKILL within budget, `deinit` never hangs. The test is constructible (doctored compiled image that passes boot+self-id then ignores frames). This also closes the Chez-era M4 note properly instead of by accident. |
| R2 (P2) frame-stream purity | **fixed** | §3 `Frame` row now carries the invariant: top-level exception catcher; uncaught exceptions and diagnostics → **stderr, bounded ≤ 4 KiB**, nonzero exit, never the stdout frame stream. §10 **test 14** gates it (top-level throw → bounded stderr + nonzero exit + unpolluted stdout). §8 cross-references bounded diagnostics, disposing N1's path-leak concern on that channel. |
| R3 (P2) compiled-image provenance | **fixed** | §4 "Compiled-image identity (R3, binding)": boot probe is a **self-identification handshake** (protocol/source version); stale or foreign binary → `ImageUnavailable`. §3 `Image` invariant references it; §10 **test 12** gates both the build route (gsc via gxi, never PATH) and stale/foreign rejection. Byte-reproducibility correctly demoted to recorded on-host observation (matches my verification: three consecutive sha256-identical builds), not a gate. |
| N1 (P3) image error text | **disposed** | §8: image diagnostics bounded at the boundary via the §3 purity rule. Residual remark (no action needed): err-*frame* payloads on the wire remain capped only by the 4 MiB frame cap — acceptable, they are diagnostics-only and never parsed. |
| N2 (P3) on-host reproducibility | **disposed** | Test 12 records sha256 reproducibility as observation, not gate; off-host stays with the D-015 portability gate. |
| N3 (P3) buildImage location | **fixed** | Output pinned to `state_dir/image-bin`; §7 state ownership updated to include it. Post-upgrade rebuild trigger is covered by R3's identity handshake (detection) with `buildImage()` as the host's rebuild action. |

**Self-id vs hash comparison (asked explicitly):** I endorse self-id as the
primary mechanism. It checks the operationally relevant property — "does
this binary implement the protocol/source version I embed" — directly at
boot, works for legitimately off-host-built binaries (where a strict hash
check would be toolchain-fragile), and is mechanism-independent. Hash
equality proves byte provenance; self-id proves contract compatibility.
The latter is the right gate for init, and test 12 exercises it with a
doctored binary. A forged handshake is out of scope under the
trusted-local posture (§7 containment honesty).

## Arch-axis folds, safety cross-check

- **Boot probe moved to `start()`** (arch N2): matches the verified
  implementation (Chez package probes in `startLocked`); §4 sketch and
  test 1 updated consistently. Cheap-validation-at-init + probe-at-start
  keeps `Live.init` side-effect-free — a small safety-positive.
- **`.base_source = null` in the options sketch**: matches the implemented
  package (`Config.base_source` with embedded default) and is the channel
  live-policy-layer rides; host-supplied policy source is trusted-local
  per §7. No regression.
- **§12 live-policy-layer sync row (arch B2)**: the
  `ChezUnavailable`→`ImageUnavailable` / `chez_path`→`.image` rename is
  declared, owned by the port task, and hits a held task (zag-live-002)
  with no shipped consumers. My 002 round-3 pass is rename-invariant (the
  degradation semantics are unchanged); the sync must fold the rename into
  live-policy-layer §4/§7/§8 test 5 before 002 implements — already stated
  in the row. No silent drift.

## Conclusion (round 2)

**pass.** R1–R3 are closed with binding text plus test rows that exercise
the actual failure modes (quit/EOF-ignoring image, top-level crash,
stale/foreign binary). The D-015 revision no longer relies on any
Chez-default property, and the compiled production form now has the
identity gate the Chez form never needed. From the safety/lifecycle axis,
`zag-live-004` may proceed to `ready` once the architecture axis passes.
