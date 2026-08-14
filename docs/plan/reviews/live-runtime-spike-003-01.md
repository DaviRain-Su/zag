# Review: live-runtime-spike-003 — independent verification

- Task: [live-runtime-spike-003](../tasks/live-runtime-spike-003.md)
- Binding: [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) · [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) · [spike-001](../tasks/live-runtime-spike-001.md) · [spike-002](../tasks/live-runtime-spike-002.md)
- Track: independent verify (read-only; did not write this code)
- Verifier host: macOS aarch64, Zig 0.16.0, Chez 10.4.1
- Result: **pass** (zero blocking findings; 1 P2 + 4 P3 non-blocking)

Scope: agent loop inside the live image; Zig-owned conversation store;
scripted fake provider with store-derived position; jailed `fs.read` shim;
mid-conversation policy redefine; kill/recovery between and during turns.
Rebuilt and re-ran the full suite (9 prior probes + `agent`), then
exercised recovery and the jail adversarially with my own harnesses
(piped `interactive`, custom provider scripts and `.work` fixtures — no
source touched).

## Checklist verdicts

| # | Checklist item | Verdict |
|---|----------------|---------|
| 1 | Plain turn: user entry fsynced before provider call; echo proves policy | **PASS** — by construction (`agentTurn` appends user before any eval, main.zig:2174-2177) and by transcript ts ordering; entry 1 carries POLICY-V1 echo |
| 2 | Tool round incl. `..` rejection | **PASS** — `fs.read notes.txt` → result appended → final say; `../journal.sexp` → `JailEscape`, turn completed |
| 3 | Policy redefine mid-conversation | **PASS** — turn 4 echo carries POLICY-V2 while `system-prompt` is still pending (uncommitted) |
| 4 | SIGKILL between turns → history rebuilt + pending policy active | **PASS** — history 12 entries rebuilt; turn 5 answered under POLICY-V2; independently reproduced with my own policy (`ADVERSARIAL-POLICY` survived `:kill`, `(system-prompt)` verified post-respawn) |
| 5 | SIGKILL mid-turn → retry from last durable entry, no half entries, no dup user entries | **PASS** — scripted chaos probe 6/6 runs identical invariants (user=6 assistant=6 tool-call=3 tool-result=3, clean tail); plus my own 6 kill experiments (below) |
| 6 | Interactive bare text drives a turn; live redefine changes later turns | **PASS** — verified with my own script: bare text → reply-one, redefine → reply-two under new policy |
| 7 | 9-probe regression suite | **PASS** — boot 44.54 ms median; echo 1659 msgs/s; redefine-cycle/discard/commit/watchdog×2/env-check/fuzz/inspect all green |
| 8 | Findings appended to the analysis doc | **OPEN** — analysis doc ends at round-3 (spike-002) findings; no spike-003 section (finding H1) |

## My independent adversarial exercises

**Recovery (parent's exact sequence, my own fixtures):** bare-text turn →
`(kernel.redefine 'system-prompt "ADVERSARIAL-POLICY…")` → second turn →
`:kill` → `(length (conv-history))` = 4 → `(system-prompt)` post-respawn
returns the ADVERSARIAL policy → third turn answers `reply-three-after-kill`
(script position correctly derived from the 2 durable assistant entries).
Store on disk: seq 0–5 contiguous, policy echo flips at entry 3 and
persists post-kill. No duplicates.

**Jail (12 attempts, via `tool.invoke` from interactive eval):**
`../journal.sexp`, `/etc/passwd`, `sub/../../journal.sexp`, bare `..`,
empty string → all `JailEscape`. Symlink tricks (existing targets):
`link→/etc/passwd`, `link→../journal.sexp`, `linkdir→/etc` + `passwd`
through it → all `JailEscape` (realpath containment fires). Jail-internal
symlink (`link-in/inner.txt`) correctly **allowed**. `a//notes.txt` →
conservative FileNotFound. Unknown tool → `unknown-tool`. Zero escapes.

**Awkward-moment kills (own Python harness, pre-found pid, in-process
store polling — the developer's killer-thread idea reimplemented):**
SIGKILL fired (a) the instant the tool-call lands (×2), (b) ~2 ms later
(×2), (c) ~8 ms later (post-turn), (d) during the first provider call.
Every run: store exactly `(user, tool-call, tool-result, assistant)`,
seq 0–3, zero duplicates, zero missing entries; windows (a)/(b) provably
went through "image died mid-turn → respawning and resuming" and still
completed with the correct scripted answer. Window (d) consistently
landed post-turn on this host (see H4).

## Design tensions (both judged acceptable)

**(a) Script position = count(assistant)+count(tool-call) from durable
store — "no duplicates by construction": HOLDS.** Verified in 12 total
kill/recovery runs (6 scripted + 6 mine) with byte-exact invariant stores.
The derivation is supervisor-stateless, so any kill before a step's entry
lands retries to the identical scripted line; any kill after lands the
entry exactly once. Caveat, not a violation: the guarantee covers
recovery, not a malfunctioning image double-appending (kernel validates
entry shape, not uniqueness) — image-side trust, correctly out of scope
for v0. P3-none; noted for promotion.

**(b) Killer-thread mid-turn SIGKILL with timing-independent assertions:
acceptable spike probe, does not hide a gap.** The assertions (per-kind
counts, clean tail, no dups, final echo) hold at every observable kill
point, `error.MidTurnKillDidNotFire` fails the probe if the kill never
lands, and the `TurnAlreadyComplete` branch honestly handles the
kill-too-late case. One real limitation (finding H4): on this host the
kill always lands in the tool-call→tool-result window; the pure
"user durable, provider.call in flight" window is covered by construction
(same `agent-provider-loop` path, store-derived position) but was never
demonstrably exercised — mine included. Non-blocking: the uncovered window
reduces to a code path already proven elsewhere.

## Findings

### H1 — P2, non-blocking: spike-003 findings not appended to the analysis doc (OPEN)

- Contract: task checklist item 8 (`live-runtime-spike-003.md:108`).
- Location: `docs/plan/analysis/2026-08-13-autolith-live-runtime-analysis.md`
  ends at "Spike findings, round 3 (spike-002)" (line 194); no round-4
  section. Content exists only in `spikes/live-runtime/RESULTS.md` round 4.
- Same class as spike-001 F1; should be fixed at closeout before the
  checkbox is ticked.

### H2 — P3, non-blocking: conversation append is two writes; crash between them glues lines

- Location: `convAppendRaw` (main.zig:720-731) writes the entry and `"\n"`
  via separate `writeStreamingAll` calls before one fsync. A crash between
  them leaves a newline-less complete entry; the next O_APPEND write glues
  onto it, producing one physical line holding two s-exprs. It passes the
  `(user `/etc. prefix check, counts once, and history reads see only the
  first form — silent entry loss in a rare window. Single-write
  (entry+newline in one buffer) closes it. Code-read only; not reproduced
  (requires dying at the exact syscall boundary).

### H3 — P3, non-blocking: TOCTOU between realpath containment check and read

- Location: `jailedRead` (main.zig:965-990) verifies containment on the
  resolved path but then reads via the unresolved `full` path. A local
  attacker able to swap a workspace symlink between the two syscalls could
  escape the jail. Requires write access to `.work/workspace/` (already
  trusted territory in the spike); note for promotion — open the resolved
  path, or openat-relative-to-jail-fd with `O_NOFOLLOW` semantics.

### H4 — P3, non-blocking: provider-call-in-flight kill window not demonstrably exercised

- Location: `killOnToolCall` (main.zig:2204-2215) fires on tool-call
  durability; observed kill points (12 runs) all fall in the
  tool-call→tool-result window or post-turn. The user→provider-call
  window is safe by construction (position derivation) but untriggered.
  If promotion wants evidence for that window, the provider needs a
  deterministic stall hook (a test backdoor the task explicitly allowed
  trading away) or a slower scripted step.

### H5 — P3, non-blocking: minor notes

- Killer thread re-reads the whole conversation file every 200 µs
  (main.zig:2206-2213) — spike-fine, would not scale. Script exhaustion
  replies without advancing (disclosed in RESULTS; fine for demos).
- Non-existent escaping symlink targets surface as `FileNotFound` rather
  than `JailEscape` — correct and non-leaky, just worth knowing when
  writing jail tests (my first symlink fixtures hit this).

## Contract checks that hold

- Conversation store: Zig-owned, append-only, fsync per append, typed
  entries with seq+ts; image-appended entries validated field-by-field and
  re-escaped through the one discipline (main.zig:821-857); torn FINAL
  line tolerated, any other bad line is corruption (main.zig:739-756).
- User entries appended by the supervisor, fsynced before any provider
  work (main.zig:2174-2177).
- Recovery dispatch on last durable entry is sound: `user`/`tool-result`
  → provider loop; `tool-call` → re-invoke the RECORDED call, not a new
  provider reply (runtime.ss:323-335) — verified live in kill windows.
- Policy bindings are ordinary tracked definitions; spike-001/002
  semantics (journal fsync-before-apply, discard/suspect/commit) apply
  unchanged to `system-prompt`.
- Isolation: `git status --porcelain` — only `spikes/`, the three task
  files, three review files, D-013, the analysis doc, and known docs
  (`docs/INDEX.md`, `docs/decisions/README.md`, `docs/plan/README.md`,
  `docs/plan/analysis/README.md`, `docs/plan/backlog.md`, `docs/quality/*`).

## Independent measurements vs RESULTS.md (round 4)

| Probe | RESULTS.md claim | My run | Match |
|-------|------------------|--------|-------|
| boot | round-3: 40.69 ms median | **44.54 ms** median | same order, PASS |
| echo 10k | round 2–3: 1779–1914 msgs/s | **1659 msgs/s**, 0 errors | same order (host load) |
| 9-probe regression | 9/9 | **9/9** | yes |
| `agent` scenario | PASS, transcript as published | PASS ×6 runs; store byte-matches the published transcript shape (seq 0–17, V1→V2 at entry 11, re-invoked 15→16→17) | yes |
| chaos-kill invariants | user=6 a=6 tc=3 tr=3, no dups | identical invariants ×6 scripted + ×6 mine | yes |
| my recovery sequence | — | history + pending policy survive `:kill` | extends claim |
| my jail attempts | — | 12/12 correctly rejected/served incl. 3 symlink escapes | extends claim |

## Conclusion

**pass.** The track's headline claim — the agent rewrites its own policy
mid-conversation, the image is SIGKILLed, and after replay both the
conversation and the redefined policy are alive — is proven by transcript
and independently reproduced. The store-derived provider position makes
mid-turn kills safe by construction; my own chaos harness (6 kills across
4 windows) produced zero duplicates and zero missing entries. The jail
held against every escape I tried, including symlink tricks with existing
targets. Open items: H1 (analysis-doc findings, closeout task) and P3
hygiene H2–H5 for the promotion track. Nothing blocks the D-014
evidence base.
