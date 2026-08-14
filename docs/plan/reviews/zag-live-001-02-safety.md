# Review: zag-live-001 — safety / lifecycle / durability (contract)

- Task: [zag-live-001](../tasks/zag-live-001.md)
- Binding: [zag-live.md](../../modules/zag-live.md) · [D-014](../../decisions/active/D-014-live-runtime-productization-route-a.md)
- Track: contract / safety+lifecycle axis (independent; reviewer also ran the
  spike verification rounds 001–003)
- Result: round 1 **blocked** (4 blocking) → round 2 **pass** (see below)

The contract is a faithful distillation of the spike in most places —
frame discipline, journal schema, staged generations, suspect quarantine,
H2/H3/G4 promotion gates, watchdog, and the acceptance-test classes all
match what was proven in `spikes/live-runtime/` (see cross-check below).
The blocking findings are places where the draft **omits a mechanism the
security claims depend on**, **overclaims containment beyond the spike**,
**relaxes a proven durability rule**, or is **internally inconsistent**
about the commit primitive.

## Blocking findings

### B1 — P1, blocking: env-scrubbed spawn is missing; "credentials never enter the image" has no mechanism

- Location: `zag-live.md` §4 (`Live.init` options: state_dir, chez_path,
  ports, watchdog — no environment discipline), §6 (credentials claim),
  §10 (no env test class).
- Spike evidence: the child was spawned with an **allowlist environment**
  (PATH/HOME/TERM only) and the `env-check` probe proved 9 sensitive
  `*KEY*`/`*TOKEN*`/`*SECRET*` host vars invisible via `getenv` in the
  image (spike-001 checklist, verified independently twice).
- The contract keeps the *claim* (§6: "Credentials never enter the image")
  but drops the *mechanism*. A conforming implementation that spawns Chez
  with an inherited host environment satisfies every sentence of this
  contract while placing all host API keys in the image's environment —
  directly destroying the D-013 credentials-by-construction property.
- Fix: add to §3/§4 an invariant "image spawned with an allowlist
  environment (exact list specified); no host env inheritance" and a §10
  test class porting `env-check` (sensitive names set in the supervisor
  env must be absent in the image).

### B2 — P2, blocking: §7 overclaims filesystem mediation ("not ambient FS")

- Location: `zag-live.md` §7: "the image's filesystem access goes through
  the ToolPort, **not ambient FS**."
- Spike reality: the Chez process has full ambient filesystem access
  through its own runtime; only the `tool.invoke`/`fs.read` path is jailed
  (verified: 12 escape attempts incl. symlink tricks all rejected on the
  mediated path — but nothing stops image code from calling
  `open-file-input-port` directly). The contract itself lists "OS-sandbox
  claims" as a non-goal (§11), so §7's sentence is both unimplemented and
  internally contradictory.
- Fix: reword §7 — e.g. "all *tool-mediated* filesystem access is jailed
  via the ToolPort (H3 dirfd rule); the image process retains ambient FS
  access — v1 makes no OS-sandbox claim; do not load untrusted code into
  the image." As written, a reader can rely on a containment property the
  architecture does not provide.

### B3 — P2, blocking: torn-tail rule relaxed below the spike-proven semantics

- Location: `zag-live.md` §3 JournalEntry invariant ("unknown line kind =
  torn tail, truncated on read") and §8 (`JournalCorrupt` glossed "tail
  truncated, then proceeds").
- Spike-proven rule (verified on disk, spike-002): a non-conforming
  **final** line is dropped (crash mid-append); a non-conforming line
  **anywhere else** is `JournalCorrupt` and aborts. The contract's wording
  licenses treating *any* unknown line as a torn tail and truncating from
  there — silent loss of audit/pending entries mid-file with no error
  surfaced. It is also unclear whether `JournalCorrupt` is ever raised at
  all, given its own gloss says "then proceeds."
- Fix: state the spike rule exactly — "only a non-conforming final line
  may be dropped on read; any earlier non-conforming line =
  `JournalCorrupt`, fail closed" — and define when `JournalCorrupt` is
  raised vs. when truncation proceeds.

### B4 — P2, blocking: `kernel.commit` drops the recorded replay check; contract contradicts its own test

- Location: `zag-live.md` §5 (`(kernel.commit reason)`) vs. §10 test 7
  ("suspect quarantine incl. **apply/check error**") and §5's own
  semantics sentence ("commit = clean-process replay probe + …").
- Spike-proven semantics: `(kernel.commit "<check-source>" "<expected>")`
  — the clean process replays base+script and runs a recorded check;
  quarantine (F9) keys on apply **and check** failures, both verified
  live. The draft replaces check+expected with a `reason` string and never
  says where the replay check comes from. If v1's probe is "replay loads
  cleanly" only, test 7's "check error" case cannot occur; if checks
  exist, the protocol line omits them. An implementor cannot build the
  core durability primitive from this text.
- Fix: either restore `(kernel.commit check expected [reason])`, or state
  explicitly that v1's probe is load-only and amend test 7 accordingly.

## Non-blocking findings

### N1 — P2, non-blocking: port-call hangs are undetectable by the watchdog as specified

- Location: §4 (watchdog config), §6 ("Ports are synchronous and bounded").
- Spike-proven behavior: while the image pends in `kernel-wait` on a port
  reply, it still **dispatches and answers** other supervisor frames — a
  kernel-side liveness probe is serviced during a hung port call, so the
  watchdog sees a live image forever. "Bounded" has no enforcement point:
  zag-live invokes the port callback synchronously on its own request
  path.
- Fix: assign the obligation — port implementors must accept a deadline
  budget (parameter on `ProviderPort.call`/`ToolPort.invoke`), and specify
  the supervisor's action on port overrun (e.g. kill image, surface
  `DeadlineExceeded`/`ImageRestarted` to the in-flight request). Also
  state the supervisor threading model this implies.

### N2 — P3: journaled-but-unacked kernel requests

If the image dies after the supervisor journals a redefine but before
apply/ack, the change becomes pending without the requester knowing; on
retry the entry is appended again. Spike semantics make this safe
(same-source redefine folds idempotently), but the contract should state
it: "a kernel request is durable once journaled; journal fold is
idempotent for same-source redefines; all host operations are
at-least-once safe to retry after `ImageRestarted`."

### N3 — P3: stale staging after supervisor crash

§3's "no orphan dirs" invariant holds for process-alive failures
(spike-002 verified: `defer deleteTree`), but a supervisor crash between
staging and rename leaves `.staging-<n>/`. The spike cleans it on the next
commit; the contract should say cleanup-on-boot or on-next-commit.

### N4 — P3: commit durability ordering and durability class unstated

Pointer flip (tmp+fsync+rename) precedes the journal `(commit …)` entry;
a crash in between is benign only because replaying already-folded
redefines is idempotent — worth one sentence. Also state the durability
class explicitly (process-crash/kill in scope; power-loss best-effort —
directory fsync after the pointer rename remains out of scope, as in the
spike).

### N5 — P3: error surface mapping and bounds unspecified

When does a caller see `ImageDied` vs. `ImageRestarted` vs.
`DeadlineExceeded`? "eval (bounded)" (§4) and "ports … bounded" (§6) don't
say by what (frame cap? wall-clock?). `deinit` on a running image
unstated. Host-API concurrency model unstated (spike discipline: one
outstanding request per direction — say so). Orphan-image behavior on
supervisor death relies on pipe-EOF making the image exit; that is the
spike's actual (sound) mechanism and should be named as the reaping story.

### N6 — P3: text residue

§5 gate row H2 says "conversation/journal append" but the conversation
store is Route-B territory, not v1 (journal is the append log here). §5
lists `(kernel.eval …)` under "image-side" primitives; in the proven
protocol it is supervisor→image. Dependents are shallow lexical (§3) —
correctly carried over.

## Spike-evidence cross-check (claims that DO hold)

| Contract claim | Spike verification |
|----------------|--------------------|
| Frame: canonical Chez `write` escaping, strict decode, 4 MiB cap both sides | spike-002 fuzz 1500/1500 + reviewer's own adversarial strings; oversize rejected cleanly both directions |
| Journal fsync before apply; typed schema; suspect quarantine on all failure exits | spike-001/002, verified incl. apply-error and check-error paths |
| Generations staged `.staging-<n>/` → rename after probe; no orphans | spike-002 F8, verified on disk |
| Watchdog = kernel-side probe, kill, reload committed generation | spike-001, reproduced incl. after failed commit |
| `kernel.discard` / nack; `kernel.inspect` three statuses | spike-001/002 probes |
| Policy redefine survives SIGKILL + replay; recovery from last durable entry, no duplicates | spike-003 + reviewer's 6 independent chaos kills |
| H3 dirfd containment intent | spike jail held against 12 escape attempts (realpath-based); dirfd rule is the correct promotion fix for the TOCTOU noted in review 003 (H3) |
| Fail-closed Chez absence (D-014) | consistent with spike spawn path; boot probe/version floor new but modest |

## Conclusion (round 1)

**blocked.** The safety spine of the spike is carried over correctly, but
four contract defects must be fixed before `zag-live-001` can go `ready`:
B1 (env-scrub mechanism missing behind the credential claim — the most
serious, since it invisibly breaks the D-013 trust story), B2 (ambient-FS
overclaim), B3 (torn-tail relaxation permitting silent audit loss), B4
(commit check/expected dropped while test 7 assumes it). N1 should be
resolved in the same pass (port-deadline obligation), N2–N6 are
one-sentence clarifications. None of these require new spike work — all
answers already exist in the proven spike semantics; the draft just has to
say them.

---

# Round 2 — re-review after contract revision ("Review round 1" note)

Re-read the full revised `zag-live.md` (214 lines). All four blocking
findings are closed; the non-blocking dispositions are as recommended.

## Per-finding disposition

| Finding | Verdict | Evidence in revised contract |
|---------|---------|------------------------------|
| B1 (P1) env scrub | **fixed** | §4 "Environment rule (B1/A2, binding)": fixed allowlist (PATH/HOME/TERM) + explicit `extra_env` only, ambient never inherited; §3 `Image` invariant references scrubbed env; §10 **test 2** gates it (env-check parity: injected `*KEY*`/`*TOKEN*`/`*SECRET*` host vars absent); §6 credentials paragraph now points at the env rule; §12 D-010 row cites the minimal-env rule. Mechanism pinned and test-gated. |
| B2 (P2) containment overclaim | **fixed** | §7 "Containment honesty (B2, binding)": ambient FS access with user privileges admitted outright; process boundary = crash/trust boundary, not an OS sandbox; only ToolPort-mediated paths jailed; consistent with §11 non-goals (OS-sandbox claims still excluded). Wording nit (non-blocking): "treat image code as trusted local code, exactly as it treats `run_shell` output" — image code *executes*, run_shell output is data; the posture is right, the analogy is loose. |
| B3 (P2) torn tail | **fixed** | §3 `JournalEntry`: "a non-conforming **final** line is a torn tail, truncated on read; an unknown kind anywhere earlier is `JournalCorrupt` — **fail closed**, never silently truncate mid-file" — exactly the spike-proven rule. §8: "`JournalCorrupt` raised only for mid-file corruption; torn final line truncated silently on read, replay proceeds" — raise semantics now unambiguous. |
| B4 (P2) commit check | **fixed** | §5 "Commit (B4, binding)": `(kernel.commit reason)` runs a default recorded check (replay completes + every tracked binding resolves); `(kernel.commit reason check expected)` restores the recorded-check form; mismatch **or eval error** rejects — matches the F9 semantics verified live in spike-002. §10 test 8 (renumbered) is now consistent: quarantine incl. apply/check error, infra failure = retry once then `CommitUnavailable` with pending intact, rejected-commit disposition matches §5's new binding paragraph. |
| N1 (P2) port boundedness | **fixed (as disposition)** | §6: "Boundedness is a host duty (N1)" — port implementors bound runtime and reply size; the contract explicitly states there is no enforcement point inside zag-live and the watchdog covers image-side liveness only. Exactly the assigned-obligation resolution recommended. |
| N2 (P3) unacked/retry | **fixed** | §4 "Recovery semantics (A4, binding)": in-flight request fails once with `ImageRestarted`, no transparent retry ("no duplicate side effects by construction" — sound because same-source redefine folds idempotently), caller may retry idempotent requests. |
| N3 (P3) stale staging | **fixed** | §3 `Generation`: "no orphan dirs (stale staging removed on next start)". |
| N4 (P3) commit ordering / durability class | **remaining (P3)** | Pointer-flip-before-journal-entry ordering and the durability class (process-crash in scope; power-loss best-effort, no directory fsync) are still unstated. One-sentence fix at closeout. |
| N5 (P3) error mapping / bounds / threading | **partially fixed (P3)** | Fixed: §4 eval bound clarified ("bounded result + host deadline"); §10 test 9 pins the in-flight disposition. Remaining: supervisor threading model, `deinit` on a running image, and orphan-image reaping via pipe-EOF still unstated. |
| N6 (P3) text residue | **fixed** | H2 row now reads "every journal/state entry append = one fsynced write" (conversation reference gone); §5 states `kernel.eval` is a host→image request, not an image primitive. |

## New nits introduced by the revision (P3, non-blocking)

- **Empty-pending commit**: no `NothingToCommit` in the §8 vocabulary;
  whether `kernel.commit` on an empty pending set is `CommitRejected` or a
  nack is unstated.
- **Default check granularity**: "every tracked binding resolves" catches
  unbound names, not call-time errors (a define whose body references an
  exploratory-only binding resolves but errors when called). The 4-arg
  form covers callers who need more; worth one sentence so hosts know the
  default is shallow.
- §2/§6 now ship the reference `fsReadPort` helper inside zag-live with
  §10 test 11 gating its containment (dirfd, `..`/absolute/symlink
  tricks) — this is the right response to the spike's TOCTOU note and is
  safety-positive on this axis.

## Conclusion (round 2)

**pass.** All four round-1 blockers are closed with binding contract text
that matches the spike-proven semantics, and each is now gated by an
acceptance test (env scrub → test 2, commit paths → test 8, in-flight
disposition → test 9, containment → test 11). Remaining items are P3
clarifications (N4 ordering/durability class, N5 threading/deinit/orphan
residue, empty-pending commit, default-check granularity) — none affect
the safety posture and all can be settled at implementation time without
reopening the contract. From the safety/lifecycle axis, `zag-live-001` may
proceed to `ready` once the architecture-axis review also passes.
