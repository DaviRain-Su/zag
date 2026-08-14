# Review: zag-live-001 — architecture/ownership axis

- Task: [zag-live-001](../tasks/zag-live-001.md)
- Under review: [zag-live.md](../../modules/zag-live.md) (binding contract draft)
  + [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- Track: independent contract review (read-only; did not author these docs)
- Context read: [packaging.md](../../packaging.md),
  [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md),
  [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md),
  [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md),
  [analysis](../../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md),
  spike reviews
  [001-01](./live-runtime-spike-001-01.md) /
  [002-01](./live-runtime-spike-002-01.md) /
  [003-01](./live-runtime-spike-003-01.md),
  [process-supervisor.md](../../modules/process-supervisor.md) (sibling contract)
- Result, round 1: **blocked** (4 blocking: A1 ownership contradiction,
  A2 D-010/state-secrets omission, A3 cross-contract ownership overlap,
  A4 recovery-semantics ambiguity; 2 P2 + 3 P3 non-blocking)
- Result, round 2 (re-review of the revised contract): **pass** — all 4
  blocking findings fixed; A5–A9 fixed or adequately closed; 3 P3
  residual notes (see Round 2 below)

Scope of this axis: contract completeness vs the module-doc bar, ownership
fit against packaging law / D-010 / D-011, fidelity to spike evidence
rounds 1–4, internal consistency (types ↔ API ↔ errors, recovery,
commit/quarantine, G4).

## What holds (checked, no finding)

- **Dependency law.** `zag-types`-only, L2 domain service, host-injected
  ports for provider/tool, no network in-package — consistent with
  packaging rules 1–3 (§2, §6, §12). Credentials staying behind the host's
  `ProviderPort` matches the spike's "tokens never enter the heap" evidence
  and D-010's host-owned-auth rule.
- **D-011.** No Core surface, integration via `zag-coding-agent` only;
  task file forbids `packages/zag-agent-core` edits. Consistent.
- **Escaping/frame fidelity.** Canonical Chez `write` both directions,
  strict decode as hard error, 4 MiB cap both sides — exactly what
  spike-002 proved and its review verified adversarially.
- **Generations/journal fidelity.** Typed 4-kind journal schema, staging
  dir + rename-on-probe-pass (F8), suspect quarantine (F9), `<ns>` as
  0-based sequence — all match spike-002 and its accepted review readings.
- **G4 distillation.** "Infra failure retries once, then
  `commit_unavailable`; quarantine reserved for replay/check failures of
  the change itself" is a legitimate decision on the open question
  spike-002's review (G4) explicitly handed to promotion, and
  `CommitUnavailable` is in the error vocabulary. Internally consistent.
- **Route split.** Contract promotes only the policy-binding substrate;
  the in-image agent loop is correctly absent (D-014 defers Route B).
- **Shape rhyme.** Section layout, closed first-line error atoms with
  no-path/errno/secret leakage, acceptance-test table, and
  relationship-to-existing-contracts table all rhyme with
  `process-supervisor.md`.

## Findings

### A1 — P2, blocking: H3 has no owner — boundary forbids tool execution, yet the contract gates dirfd containment in this package

- Location: `zag-live.md` §2 boundary ("Must not: … tool execution") vs
  §5 promotion-fix row H3 ("tool-port file reads resolve containment via
  dirfd-relative open") and §10 test 10 ("dirfd containment incl. symlink
  tricks (H3)"). D-014 Consequences: "backlog … H3 (realpath TOCTOU) …
  all fixed in zag-live-001."
- Problem: in the spike, the jailed `fs.read` lived in the supervisor
  (`jailedRead`, main.zig). In the product split the contract defines,
  `ToolPort` is a **host-injected callback** (§6) — the real file-reading
  tool will live downstream (coding-agent, zag-live-003). zag-live's own
  boundary table forbids tool execution, so there is no product code in
  this package that can satisfy H3. Testing dirfd containment "through
  fake ports" (test 10) verifies the test fixture, not the product.
- Fork risk: one implementer ships a built-in jailed-read port inside
  zag-live (violating §2 "must not: tool execution"); another omits H3
  (violating D-014's "all fixed in zag-live-001"). Both read the docs
  honestly.
- Resolution options: (a) amend §2 to carve out a zag-live-owned
  **reference jailed-fs ToolPort implementation** (FS I/O is not network;
  layering allows it) and make H3 bind that; or (b) re-scope H3 to the
  task that wires the real tool port and drop it from zag-live-001's
  gates, recording the move in D-014.

### A2 — P2, blocking: child-environment hygiene (spike-proven, D-010-required) is absent from contract and tests

- Location: `zag-live.md` §2/§6/§7 state credential isolation only as
  "provider auth stays behind the host's ProviderPort"; nothing anywhere
  pins the child's process environment. §10 has no env-check class.
- Evidence: spike round-1 proved "child spawned with allowlist env; 9
  injected `*KEY*`/`*TOKEN*`/`*SECRET*` names all absent" and every later
  suite kept the `env-check` probe green. D-010 (State/packaging/secrets):
  "E2 children inherit a **minimal explicit environment**, not the full
  host environment" — and this contract explicitly claims to follow the
  E2 supervision direction (§12).
- Problem: as written, an implementation that passes the ambient host
  environment to `std.process.Child` is contract-conformant while
  silently re-introducing the token-leak class the spike proved closed.
  "Credentials never enter the image" (§6) then holds for the port path
  but not the env path.
- Fix: add a child-spawn invariant (explicit env allowlist; no ambient
  host env) to §3/`Image` or §7, and an env-check row to §10.

### A3 — P2, blocking: unresolved spawn-ownership overlap with the process-supervisor contract

- Location: `zag-live.md` §2 owns "Image lifecycle (spawn/probe/kill/reap)"
  and §12's relationship table has no process-supervisor row.
  `process-supervisor.md` §1.1: "Every executable child has an owner in
  product code (`zag-coding-agent` or a future dedicated process package
  under coding-agent ownership)"; its ownership table has future services
  "register as supervised slots" and forbids raw `std.process.Child`
  outside the supervisor.
- Problem: zag-live is an L2 package depending on `zag-types` only; it
  **cannot** import the supervisor, which lives in `zag-coding-agent`
  (L3) — that would be an upward dependency. So either zag-live spawns
  raw `Child` (contradicting the sibling contract's ownership table), or
  the supervisor must enter as a third host-injected port (absent from
  §6). D-013/analysis say "same supervision **direction** as
  process-supervisor-001", which does not settle component ownership.
- Both contracts are drafts under dual review, so this is the moment to
  resolve it: either record zag-live's self-spawn as a documented
  exception in `process-supervisor.md`'s ownership table, or add a
  supervisor/spawn port to §6. Silence forks implementations.

### A4 — P2, blocking: `ImageRestarted` in-flight semantics are ambiguous, and the acceptance tests don't pin them

- Location: §4 "host callers see `error.ImageRestarted` once per
  in-flight request, then continue"; §8 error list; §10 test 8 covers
  only watchdog kill → reload of committed state.
- Problem: two honest readings diverge observably:
  (a) the supervisor fails the in-flight request once with
  `ImageRestarted` and the **caller** decides whether to re-issue;
  (b) the supervisor **transparently retries** the request against the
  replayed image. They differ on duplicate side effects: an eval whose
  journal fsync landed but whose reply didn't would be applied twice
  under (b).
- Crucially, the spike's "retry-safe by construction" property
  (store-derived provider position) lived in the round-4 conversation
  store + in-image agent loop, **neither of which is promoted in v1**.
  Nothing in v1 makes host-driven eval idempotent, so the contract must
  not leave room for reading (b).
- Fix: freeze (a) explicitly — in-flight request fails once with
  `ImageRestarted`; the `Live` instance remains usable; no
  supervisor-side request replay — and add an in-flight-during-kill row
  to §10.

### A5 — P2, non-blocking: journal-corruption rule drops the spike's mid-file vs torn-tail distinction

- Location: §3 `JournalEntry` invariant ("unknown line kind = torn tail,
  truncated on read") and §8 `JournalCorrupt` ("tail truncated, then
  proceeds").
- Evidence: spike behavior (verified in spike-003's review) is "torn
  **final** line tolerated; any other bad line is corruption." The
  contract's literal rule treats an unknown kind **anywhere** as a torn
  tail and truncates — silently discarding valid later entries after a
  mid-file corruption, a weaker property than what was proven.
- Also slightly unclear whether `JournalCorrupt` is returned, logged, or
  merely surfaced before proceeding.
- Fix: restore the spike distinction — truncation only at the final
  line; mid-file unknown kind = hard `JournalCorrupt` failure.

### A6 — P2, non-blocking: live-image disposition after a failed commit is unspecified

- Location: §5 (commit semantics) and §10 test 7.
- Problem: on quarantine, the journal is settled (`suspect` entries,
  replay skips them), but the contract never says whether the **running
  image** keeps the rejected definition live until restart/discard (spike
  behavior) or is reloaded to the last committed generation. One
  implementer leaves the suspect binding live; another respawns —
  divergent observable behavior right after `CommitRejected`.
- Fix: one sentence in §5 (recommend spike fidelity: rejected binding
  stays live in the current image, is excluded from every replay path,
  and disappears on next restart).

### A7 — P3, non-blocking: H2 row references the conversation store, which v1 does not own

- Location: §5 H2 row ("conversation/journal append = one fsynced write
  per entry") vs §7 state ownership (journal + generations only) and §11
  non-goals. D-014 also phrases it as "single-write **conversation**
  append."
- The round-4 `conversation.sexp` store is correctly out of v1 scope
  (Route A defers the loop), but then "conversation append" has no
  referent in this package, and no doc says which later task owns the
  conversation store (zag-live-002/003?). Scope H2 to the journal for
  v1 and name the conversation store's owning task.

### A8 — P3, non-blocking: G4 retry rule leaves pending-set disposition open

- Location: §5 G4 row, §8 `CommitUnavailable`.
- After "retry once, then `commit_unavailable`", are the pending entries
  still pending (caller may fix infra and commit again) or quarantined?
  The G4 wording implies preserved (quarantine is reserved for
  change-defects), but it should be said outright, with a §10 assertion.

### A9 — P3, non-blocking: API sketch leaves bounds and error mapping implicit

- Location: §4.
- `eval` is "bounded" with no stated deadline/result-size parameter;
  which errors each call can raise (e.g. can `start()` raise
  `JournalCorrupt`? can `stop()` raise `DeadlineExceeded`?) is nowhere
  tabulated; the Chez **version floor** is named but not valued (spike
  evidence is 10.4.1). All implementable, but each is a divergence point
  a one-line table would close.

## Conclusion (round 1)

**blocked.** The contract's dependency shape, D-011/D-014 fit, and most
of its spike distillation are sound, but four items must be resolved
before `ready`: H3's owner inside a package that forbids tool execution
(A1), the missing child-env allowlist (A2), spawn ownership vs the
process-supervisor contract (A3), and the ambiguous `ImageRestarted`
in-flight semantics (A4). A5/A6 should be fixed in the same revision;
A7–A9 are cheap clarifications. None of the blockers requires new spike
evidence — all are contract-text amendments within the existing evidence
base.

---

# Round 2 — re-review of the revised contract (2026-08-14)

Re-read the full revised `zag-live.md` (carries the "Review round 1"
note) and the new D-014 consequence bullet. Per-finding verdicts:

| Finding | Verdict | Evidence in revised contract |
|---------|---------|------------------------------|
| A1 (H3 owner) | **fixed** | §2 boundary now owns "reference jailed `fs_read` ToolPort helper (§6)" and narrows the must-not to "general tool execution beyond the shipped reference helper"; §5 H3 row assigns the helper to zag-live with §10 test 11 gating the shipped helper (not the fixture); §6 specifies `fsReadPort()` (dirfd-relative, symlink-safe, 16 KiB bound). Ownership contradiction resolved; FS I/O in an L2 package violates no packaging rule (only network is barred). |
| A2 (env allowlist) | **fixed** | §4 binding environment rule: fixed allowlist (`PATH`/`HOME`/`TERM`) + host-controlled `extra_env` only, ambient env never inherited; §3 `Image` invariant ("scrubbed environment"); §10 test 2 = spike env-check parity with injected `*KEY*`/`*TOKEN*`/`*SECRET*` probes; §12 D-010 row cites the minimal-env rule. Pinned and testable. |
| A3 (process-supervisor overlap) | **fixed** (one P3 residual, R1) | §2 process-ownership note: deliberate documented exception with the correct rationale (L2 cannot import the L3 supervisor; the image is the package's own child, not a tool execution; migration reconsidered if a shared L2 process package emerges); §12 gains a process-supervisor row; D-014 records the exception as a consequence bullet. |
| A4 (`ImageRestarted`) | **fixed** | §4 recovery semantics are now binding and unambiguous: in-flight request fails once with `ImageRestarted`; no transparent retry ("no duplicate side effects by construction"); caller may retry idempotent requests; post-restart requests run against replayed state. §10 test 9 now covers in-flight disposition including the no-duplicate assertion. |
| A5 (torn-tail) | **fixed** | §3 `JournalEntry`: non-conforming **final** line = torn tail, truncated; unknown kind earlier = `JournalCorrupt`, fail closed, never silent mid-file truncation. §8 mirrors it. Spike fidelity restored. |
| A6 (failed-commit disposition) | **fixed** | §5 binding paragraph: rejected commit leaves the live image unchanged (change stays exploratory-live), entries journaled `(suspect …)`, excluded from all future replay, next restart shows last committed — exactly the spike behavior; §10 test 8 asserts it. |
| A7 (H2 wording) | **fixed** (P3 residual R2) | H2 row reworded to "every journal/state entry append" — the dangling conversation-store reference is gone. |
| A8 (CommitUnavailable pending set) | **fixed** | §5: after `CommitUnavailable` the pending set stays pending and a later commit may retry; §10 test 8 asserts "pending set intact". |
| A9 (floor + eval bounds) | **fixed** (P3 residual R3) | §4: Chez floor valued (≥ 10.0, boot-probe-verified at `start()`); eval documented as "bounded result + host deadline". |

## Round-2 check of newly introduced text

The revision adds material beyond the nine fixes; verified it introduces
no new contradictions:

- §5 commit check forms (default recorded check vs caller-supplied
  `check expected`; mismatch **or eval error** rejects) — consistent with
  `CommitRejected` and with spike-002's F9 check-eval-error evidence.
- `kernel.eval` reclassified as a host→image request, not an image
  primitive — corrects round-1 §5's primitive list; consistent with §4.
- §6 "boundedness is a host duty" — honest enforcement-point analysis
  (watchdog covers image-side liveness only; a hung port is the host's
  problem). Removes the round-1 implication that zag-live bounds ports.
- §7 "containment honesty" — the image retains ambient FS access; the
  process boundary is a crash/trust boundary, not an OS sandbox. This
  silently corrects round-1 §7's overclaim ("the image's filesystem
  access goes through the ToolPort, not ambient FS"), which the spike
  never proved. Consistent with §11 non-goals and process-supervisor's
  no-OS-sandbox stance. Good change.
- §3 `Generation` "stale staging removed on next start" — closes the
  crash-between-staging-and-rename window F8 left implicit.
- §10 renumbering to 11 classes with env scrub (2) and in-flight
  disposition (9) — consistent with §4/§5 semantics throughout.

## Round-2 residual notes (all P3, non-blocking)

- **R1:** the exception is recorded on the zag-live side (§2, §12) and in
  D-014, but `process-supervisor.md`'s ownership table itself still reads
  "no raw `std.process.Child` outside supervisor" without a pointer. Add
  a one-line exception reference at that contract's next revision (it is
  itself a draft under dual review).
- **R2** (A7 residual): no doc yet names which later task owns the
  round-4 conversation store (presumably zag-live-002/003). One clause in
  §11 or D-014's "Later tasks" bullet would close it.
- **R3** (A9 residual): error→API-call mapping remains implicit (which
  calls can raise `JournalCorrupt`, `DeadlineExceeded`, etc.). Acceptable
  at sketch level; a small table in §4/§8 would remove the last
  divergence point.

## Conclusion (round 2)

**pass** (architecture/ownership axis). All four round-1 blocking
findings are resolved with binding contract text plus matching acceptance
tests, the non-blocking set is fixed or adequately closed, and the newly
added text (commit check forms, host-duty boundedness, containment
honesty, stale-staging cleanup) is internally consistent and stays within
the spike evidence base — the containment-honesty rewrite removes an
overclaim rather than adding one. Ownership fit against packaging law,
D-010, and D-011 now holds. Residual notes R1–R3 are P3 polish, none
blocking. This axis passes; `ready` still awaits the safety/lifecycle
axis PASS per the task's dual-review rule.
