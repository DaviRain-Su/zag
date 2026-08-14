# live-runtime-spike-001 — RESULTS

Date: 2026-08-13 (round 1), 2026-08-13 (round 2: post-review fixes F2/F4).
Host: macOS (Darwin, aarch64, Apple silicon).
Zig 0.16.0 (Homebrew), Chez Scheme 10.4.1 (Homebrew `chez`).
Build: `zig build` (Debug) in `spikes/live-runtime/`.
Note: the dev host was under heavy parallel load during measurement
(`load averages: 25.69 21.50 15.64` in round 1); timings below include both
quiet and loaded runs, reported separately rather than cherry-picked.

All commands run from `spikes/live-runtime/` with binary
`./zig-out/bin/live-probe`.

## 1. Chez cold boot to first eval — PASS (3 of 4 runs)

Command: `./zig-out/bin/live-probe boot`
(measures spawn → first `(kernel.eval "(+ 1 1)")` reply, N=10 per run)

| run | min | median | max | verdict |
|-----|-----|--------|-----|---------|
| 1 (round 1) | 44.95 ms | 54.29 ms | 86.95 ms | PASS (< 100 ms) |
| 2 (round 1) | 76.23 ms | 121.99 ms | 158.68 ms | FAIL (load spike) |
| 3 (round 1) | 37.88 ms | 38.85 ms | 62.32 ms | PASS |
| 4 (round 1) | 36.37 ms | 37.52 ms | 43.57 ms | PASS |
| 5 (round 2) | 40.34 ms | 46.18 ms | 50.83 ms | PASS |

Reference: raw `time chez --script runtime.ss < /dev/null` = 30–40 ms wall
on the same host. Conclusion: quiet-host median boot-to-first-eval is
**~38–55 ms**, comfortably under the 100 ms target; run 2 coincided with a
load-avg-25 spike and is reported as failing rather than discarded.

## 2. Framed IPC echo, 10k messages — PASS

Command: `./zig-out/bin/live-probe echo 10000`

| run | total | throughput | framing errors |
|-----|-------|------------|----------------|
| 1 (round 1) | 11052.64 ms | 905 msgs/sec | 0 (all payloads asserted equal) |
| 2 (round 1) | 5041.37 ms | 1984 msgs/sec | 0 |
| 3 (round 2) | 5492.78 ms | 1821 msgs/sec | 0 |

Round-trip ≈ 0.5–1.1 ms, three orders of magnitude below model latency.
Throughput is dominated by per-message context switches + Chez
read/eval/write, and by host load.

## 3. redefine → journal+fsync → SIGKILL → replay — PASS

Commands: `./zig-out/bin/live-probe reset && ./zig-out/bin/live-probe redefine-cycle`

```
redefine applied live: (greeting) => hacked
sent SIGKILL to pid 80445; respawning and replaying journal
PASS: after SIGKILL + replay, greeting == "hacked" with identical source
```

The fresh instance's `(greeting)` evaluates to `"hacked"` and
`(kernel.source-of 'greeting)` returns byte-identical source to the
journaled `(redefine ...)` entry.

## 4. kernel.discard — PASS

Commands: `./zig-out/bin/live-probe reset && ./zig-out/bin/live-probe discard`

Round 2 output (includes the F4 fix coverage):

```
committed state: (greeting) => hello
exploratory: (greeting) => hacked (not committed)
kernel.discard restored greeting to last committed value 'hello'
discard: 'never-defined' has no committed definition; nacking
discard of unknown name nacked as Scheme error: not-committed irritants=()
PASS: kernel.discard restores committed value; unknown name nacked without hanging
```

The F4 path: `(kernel.discard 'never-defined)` gets a
`(kernel.nack never-defined "not-committed")` from the supervisor, the
primitive raises `(error 'kernel.discard "not-committed")`, safe-eval turns
it into an `(err ...)` reply, and the image stays alive and functional
afterwards (verified by a follow-up eval).

## 5. kernel.commit — PASS (both paths)

Commands: `./zig-out/bin/live-probe reset && ./zig-out/bin/live-probe commit`

Success path: generation 1 built from the journal's pending redefine,
replay-probed in a clean second Chez process (`(greeting)` => `"hacked"`),
pointer flipped atomically (tmp write + fsync + rename); a fresh image
boots into generation 1.

Failure path: after redefining `greeting` to `"broken"`, a commit with a
check expecting `"this-will-never-match"` was rejected — clean-process
replay check failed, `.work/current` still reads `1`, and the pending
redefine was quarantined with a `(suspect greeting ...)` journal entry
(F2 fix). Round 2 output:

```
commit: generation 1 selected (replay probe passed)
commit accepted; current generation = 1
fresh image on generation 1: (greeting) => hacked
replay check failed in clean process: got 'broken', want 'this-will-never-match'
journaled (suspect greeting ...)
commit rejected, keeping old generation; exploratory change is suspect: ReplayCheckFailed
failed commit kept old pointer (generation 1); change reported suspect
reload after failed commit boots committed value 'hacked' (suspect skipped)
PASS: commit flips pointer only after clean-process replay probe passes; suspect change quarantined
```

The last two lines are the F2 regression assertion: a fresh
spawn + replay after the failed commit boots the last COMMITTED value
(`"hacked"`), not the rejected one (`"broken"`).

## 6. Watchdog — PASS

Commands: `./zig-out/bin/live-probe reset && ./zig-out/bin/live-probe watchdog`
(round 1), and in round 2 deliberately run right after `commit` **without**
a reset — the exact F2 reproduction sequence:

```
committed state: (greeting) => hacked; journal lines = 4
image hung via (kernel.hang); starting liveness probe (2 s deadline)
liveness deadline expired after 2001 ms; killing image
PASS: watchdog killed hung image, reloaded committed state 'hacked', journal intact (4 lines)
```

Pre-fix, this sequence reloaded the rejected `"broken"` value. Post-fix,
the reloaded state is the last committed `"hacked"`. Liveness probe = a
known eval frame with a 2 s `poll(2)` deadline, kernel side only (design
rule 7). After SIGKILL, a fresh image replayed the committed generation;
journal line count and parseability verified.

## 7. Secret hygiene — PASS

Command: `FAKE_API_KEY=sk-test-123 ZAG_SECRET_TOKEN=tok-abc ./zig-out/bin/live-probe env-check`

Supervisor env contained 9 `*KEY*`/`*TOKEN*`/`*SECRET*` names (the two
injected fakes plus 7 real ones from the host shell). The child is spawned
with an allowlist env (`PATH`, `HOME`, `TERM` only). Each sensitive name
was probed inside the image with `(getenv "<name>")` and all returned `#f`.
argv carries no secrets (`chez --script runtime.ss`).

## Round 2: post-review fixes (F2, F4)

Independent review passed the spike with two non-blocking findings; both
are fixed in the spike code and covered by new probe assertions:

- **F2 — failed-commit suspect entries poisoned later replays.** Fix:
  `doCommit` journals `(suspect <name> <ns>)` for each pending redefine
  when the clean-process replay check fails; `journalPendingRedefs` (used
  by every replay path — `redefine-cycle` respawn, `watchdog` reload,
  fresh boots) skips quarantined entries like discarded ones. Covered by
  the new commit-probe assertion ("reload after failed commit boots
  committed value") and by running `watchdog` immediately after `commit`
  without a reset (section 6).
- **F4 — `kernel.discard` on an unknown name hung the image.** Root cause:
  the supervisor returned an error without replying, leaving the image
  stuck in `kernel-wait`. Fix: the supervisor checks the committed-source
  lookup FIRST and replies `(kernel.nack <name> "not-committed")` (no
  journal entry — nothing changed); `kernel.discard` in `runtime.ss`
  accepts ack-or-nack and raises `(error 'kernel.discard "not-committed")`
  on nack. Covered by the discard probe, which also asserts the image is
  still alive afterwards.

Round 2 full-suite run (2026-08-13, same host):
`reset; boot; echo 10000; reset; redefine-cycle; reset; discard; reset; commit; watchdog; env-check`
→ **7/7 PASS** (boot median 46.18 ms; echo 1821 msgs/sec).

Round 2b (2026-08-13): added `live-probe interactive` (alias `demo`) — a
hands-on terminal mode: eval forms in the live image, `:kill` to SIGKILL
and watch journal replay restore the state, `:commit` / `:discard` /
`:status` / `:reset` / `:quit`. Uses the existing frame/journal/generation
machinery plus one eval variant (`kernel.evalc`) that captures the form's
printed output so `display` cannot corrupt the frame stream; unexpected
image death (e.g. evaling `(exit)`) is detected and triggers automatic
respawn+replay. Genesis seed changed to
`(define (greeting) "hello, live image")` (probes compare dynamically, so
results are unaffected). Re-ran the full suite: **7/7 PASS** (boot median
42.34 ms; echo 1779 msgs/sec). Smoke-tested via piped input: redefine →
new value → `:kill` → restored value → `:discard` → committed value →
`(exit)` → auto-respawn.

## Round 3: protocol hardening + kernel.inspect + commit-path fixes (spike-002)

Three workstreams from `live-runtime-spike-002` / review findings F5/F6/F8/F9:

- **F5/F6 — protocol hardening.** One escaping discipline both directions:
  canonical Chez `write` escapes (named `\" \\ \n \r \t \a \b \v \f`, other
  control bytes as `\xHH;` uppercase minimal hex, bytes ≥ 0x80 raw; payloads
  must be valid UTF-8; decoding is strict — unknown escapes are errors, not
  silent mangling). New `live-probe fuzz`: **1500 seeded adversarial
  strings (quotes, backslash soup, literal `\x..;` text, control bytes
  incl. NUL + DEL, UTF-8 multibyte, 4 KB mixes) round-tripped
  byte-identically**, zero failures. Frame cap is now 4 MiB as a named
  constant on BOTH sides (`max_frame_bytes` / `max-frame-bytes`); the fuzz
  probe also proves (a) the image discards a 4 MiB + 64 B inbound frame and
  answers `(err "frame-too-large")` while staying alive, and (b) the
  supervisor rejects an oversize reply from the image (a 5 MB
  `make-string` eval), kills + respawns the image, and keeps working.
- **`kernel.inspect`.** New IPC request: supervisor replies
  `(kernel.inspect.result (source ...) (status committed|pending|unknown)
  (generation <n|#f>) (dependents (...)))`. Dependents are shallow v0:
  tracked definitions whose source mentions the name as a delimited symbol
  (lexical scan only — documented). `live-probe inspect` covers
  committed (generation 0 + source + empty dependents), pending
  (status pending, generation #f, reverse-dependent shows up on the
  depended-upon name), and unknown (all #f/empty). PASS.
- **F8 — no orphan generation dirs.** `doCommit` now stages into
  `generations/.staging-<n+1>/`, renames into place only after the replay
  probe passes, and deletes staging on failure. The commit probe asserts no
  `generations/2` and no `.staging-2` after a failed commit.
- **F9 — quarantine on every commit failure exit.** `doCommit` quarantines
  the pending set via `defer` on ANY error after the pending set is known,
  not only on value mismatch. New probe phase: a malformed pending entry
  (`(define (broken-mal`, written journal-side to simulate a torn state)
  makes the clean-process apply ERROR; asserted: `(suspect broken-mal ...)`
  journaled, pointer unchanged, no orphan dir, and a fresh boot replays
  cleanly.
- **Typed journal schema** (per the task file's table): all four writers
  emit `(redefine <name> <seq> "<source>" <ts>)`, `(discard <name> <seq>
  <ts>)`, `(suspect <name> <seq> <ts>)`, `(commit <gen> "<hash>" <ts>)`;
  `<seq>` is the entry's 0-based line number (interpretation of `<ns>` in
  the task table — flagged for closeout if a different meaning was
  intended). `journalPendingRedefs` folds over the typed forms;
  `countJournalLines` now rejects any line that is not one of the four
  entry kinds (torn-tail detection).
- **Latent bug found by the new probe**: `parseDatum` greedily trimmed ALL
  trailing `)` characters, corrupting list-valued datums (harmless for the
  round-1/2 probes, which only asserted substrings on string/atom datums).
  Now trims exactly one frame-closing paren.

Round 3 full-suite run (2026-08-13, same host):
`reset; boot; echo 10000; reset; redefine-cycle; reset; discard; reset; commit; watchdog; env-check; reset; fuzz; inspect; interactive smoke`
→ **9/9 PASS** (boot median 40.69 ms; echo 1914 msgs/sec). Journal after
the commit probe, conforming to the typed schema with no orphan dirs:

```
(redefine greeting 0 "(define (greeting) \"hacked\")" 1786662083806141000)
(commit 1 "7ede7c2c…4b4b27" 1786662083893815000)
(redefine greeting 2 "(define (greeting) \"broken\")" 1786662083978739000)
(suspect greeting 3 1786662084032031000)
(redefine broken-mal 4 "(define (broken-mal" 1786662084079566000)
(suspect broken-mal 5 1786662084131955000)
```

## Round 4: agent loop in the image (spike-003)

The track's main event: a minimal agent loop inside the live Scheme image
with all trust-critical pieces in Zig. New `live-probe agent` runs a
scripted, deterministic scenario end to end (fake provider, own `.work`):

```
turn 1 (plain): "hello, policy v1 speaking" — user entry fsynced first, echo proves POLICY-V1
turn 2 (tool round): fs.read notes.txt -> "the answer is 42" -> "the file says 42"
turn 3 (jail): fs.read ../journal.sexp rejected (JailEscape), turn completed
turn 4 (policy redefine): provider echo proves redefined system-prompt (POLICY-V2)
SIGKILL between turns (pid 65526); respawning
image rebuilt context: (length (conv-history)) = 12 entries
turn 5 (post-kill): pending POLICY-V2 still active, conversation continues
mid-turn SIGKILL fired (tool-call durable, turn in flight); respawned
recovery: user=6 assistant=6 tool-call=3 tool-result=3; no dups, no half entries, clean tail
PASS: agent loop in the image; policy redefine -> kill -> recovery all proven by transcript
```

Mechanisms:

- **Conversation store** `.work/conversation.sexp`: Zig-owned append-only
  typed entries `(user|assistant|tool-call|tool-result)` with seq + ts;
  image appends via `conv.append` IPC (Zig validates field shapes,
  re-escapes through the one discipline, fsyncs, acks). User entries are
  appended by the SUPERVISOR, fsynced before any provider work. Torn
  FINAL line tolerated on read; any other bad line is corruption.
- **Fake provider** `.work/provider-script.sexp`: `(say "...")` /
  `(call fs.read ("..."))` per line. **Script position = count of
  assistant + tool-call entries in the store** — derived from durable
  state, so mid-turn kills retry deterministically and entries can never
  duplicate. Every reply echoes the system prompt it received; the
  transcript therefore proves policy per turn (visible above: entries 1–9
  carry POLICY-V1, 11+ carry POLICY-V2).
- **Agent loop** in `runtime.ss` (fixed mechanics); policy
  (`system-prompt`, `tool-registry`) lives in genesis base as ordinary
  tracked bindings. `agent-continue` dispatches on the last durable entry
  (`user`/`tool-result` → provider call; `tool-call` → re-invoke the
  RECORDED call).
- **Tool shim** `fs.read`: jail = `.work/workspace/` (absolute paths and
  `..` components rejected, realpath containment verified, 16 KiB output
  bound). The `../journal.sexp` attempt returned `fs.read rejected:
  JailEscape` and the turn continued.
- **Interactive**: bare text now drives an agent turn (verified via piped
  input incl. policy redefine + `:kill` + history length check).

Full transcript of the key sequence (store after the run):

```
(user 0 "hi there" …)
(assistant 1 "hello, policy v1 speaking" "POLICY-V1: you are friendly and verbose." …)
(user 2 "read notes.txt" …)
(tool-call 3 fs.read "notes.txt" "POLICY-V1: you are friendly and verbose." …)
(tool-result 4 fs.read "the answer is 42\n" …)
(assistant 5 "the file says 42" "POLICY-V1: …" …)
(user 6 "read ../journal.sexp please" …)
(tool-call 7 fs.read "../journal.sexp" "POLICY-V1: …" …)
(tool-result 8 fs.read "fs.read rejected: JailEscape" …)
(assistant 9 "escape was rejected, good" "POLICY-V1: …" …)
(user 10 "keep going" …)
(assistant 11 "policy v2 now answering" "POLICY-V2: answer tersely." …)   ← redefine live
(user 12 "still there?" …)                                              ← SIGKILL before this
(assistant 13 "v2 survived the kill" "POLICY-V2: answer tersely." …)      ← pending policy survived
(user 14 "read it again, then die" …)                                     ← SIGKILL mid-turn
(tool-call 15 fs.read "notes.txt" "POLICY-V2: answer tersely." …)
(tool-result 16 fs.read "the answer is 42\n" …)                           ← re-invoked from record
(assistant 17 "mid-turn recovery complete" "POLICY-V2: answer tersely." …)
```

Round 4 full-suite run (2026-08-13, same host): all 9 round 1–3 probes
PLUS `agent` → **10/10 PASS**. Interactive smoke: bare-text turn, live
policy redefine, `:kill`, history rebuilt (4 entries) — all as expected.

### Design notes (for closeout)

- **Who owns the provider script position**: deriving it from the store
  (assistant + tool-call entry count) turned out to be the strongest
  design choice of this round — every mid-turn kill point becomes safe by
  construction (no supervisor memory, no explicit checkpoint), and
  duplicates are impossible rather than merely detected. A real provider
  has no script, but the principle transfers: durable entries per
  completed step make the turn a resumable continuation.
- **Awkward in the task architecture**: the scripted mid-turn SIGKILL has
  no deterministic trigger point without either a test backdoor in the
  tool/provider or timing-based concurrency. Chosen: a background killer
  thread that fires when the target tool-call entry lands durable
  (200 µs poll), with timing-INDEPENDENT outcome invariants (entry
  counts, clean tail, no dups, final echo). The exact kill point varies
  (tool-call window vs. in-flight provider call), but both exercise the
  retry-from-last-durable-entry path. This is honest chaos, not a scripted
  fixture.
- **`(kernel.history ...)` frame shape**: first implementation wrapped
  entries in an extra list; `(cdr f)` vs `(cadr f)` nesting bit twice
  (also on `provider.reply`). Fixed by removing the wrapper.
- **Fake provider script exhaustion** replies `(say "[provider script
  exhausted]")` without advancing — fine for demos; a real loop would
  need a policy decision here.

## Round 5: Gerbil Scheme as image runtime (spike-004, D-015 data)

`runtime-gerbil.ss` ports the image side to Gerbil v0.18.1 (Gambit
4.9.5). `live-probe` selects the runtime via
`LIVE_PROBE_RUNTIME=chez|gerbil|gerbil-bin` (default chez; no flag
changes). The compiled variant is built by `live-probe build-gerbil-bin`
with **gsc -exe** (raw Gambit compile) — gxc was tried first and rejected,
see gaps below. Same probes, all three runtime configurations.

### Comparison table (same host, same harness; quiet-host runs)

| Probe | Chez 10.4.1 | Gerbil gxi 0.18.1 | Gerbil gsc -exe |
|-------|-------------|-------------------|-----------------|
| boot median (N=10) | 54.15 ms | 56.47 ms | **4.13 ms** |
| boot min/max | 45.62 / 68.32 | 54.02 / 65.89 | 4.00 / 11.47 |
| raw exec (script, no frames) | ~40 ms | ~50–90 ms | — |
| echo 10k | 1872 msgs/sec | 1801 msgs/sec | 1384 msgs/sec |
| fuzz 1500 byte-identical | PASS | PASS | PASS |
| redefine -> SIGKILL -> replay | PASS | PASS | PASS |
| discard + unknown nack | PASS | PASS | PASS |
| commit (suspect quarantine incl. F9 apply-error) | PASS | PASS | PASS |
| watchdog kill/reload | PASS | PASS | PASS |
| env-check | PASS | PASS (getenv shadow) | PASS (getenv shadow) |
| kernel.inspect | PASS | PASS | PASS |
| agent (scripted loop incl. mid-turn kill) | PASS | PASS | PASS |
| interactive (incl. :kill, :quit) | PASS | PASS | PASS |

Earlier suite runs under load also passed end-to-end (gxi: all 10 probes;
bin: all 10 probes). Interactive smoke verified under all three.

### Semantic gaps found (Gerbil/Gambit vs Chez)

- **`gxc -exe` is unusable for a live image**: Gerbil's module system
  namespaces top-level definitions (`runtime-gerbil#kernel.redefine`), so
  `(eval ... (interaction-environment))` cannot see the image's own kernel
  primitives — redefine/discard/commit/inspect all fail in a gxc binary.
  Raw **gsc -exe** (Gambit compiler, no module namespacing) preserves eval
  visibility. This is THE load-bearing gap: a live image without eval
  access to its own primitives is dead on arrival.
- **PATH's `gsc` is Ghostscript** on this host; Gambit's gsc lives next to
  gxi in the Cellar. `build-gerbil-bin` asks gxi itself:
  `gxi -e '(display (path-expand "~~bin/gsc"))'`.
- **stdin EOF is unreliable in Gambit ports** (observed in pre-port
  configurations: gxi with an exported `main`, empty-from-start stdin; gsc
  exe on EOF after frames): `read-u8` on a closed pipe could spin (100%
  CPU) instead of returning the eof object. **Not reproduced in the shipped
  configuration** (independent review: empty stdin, EOF-after-N frames all
  exit cleanly). Insurance: both images accept an explicit `(kernel.quit)`
  frame; the kill path is SIGKILL regardless. Note: as of this round the
  supervisor's `Scheme.shutdown` closes stdin **without** sending the quit
  frame — the frame is image-supported but currently unused on the wire.
- **`write` hex-escape case**: Gambit writes `\x1f;` lowercase, Chez
  `\x1F;` uppercase. Same escape set otherwise; strict readers both
  sides. Supervisor encodes with the selected runtime's canonical case,
  decodes case-insensitively; fuzz-verified byte-identical under both.
- **`getenv` raises on missing vars** ("Unbound OS environment
  variable") where Chez returns #f. The image shadows `getenv` with Chez
  semantics (`with-exception-catcher` + `##getenv`).
- **gxi prints uncaught exceptions to STDOUT** (frame-stream corruption
  hazard); the image wraps its main loop in a top-level catcher ->
  stderr + exit 70.
- **Port IO API differs**: Gambit `read-u8vector` fills a preallocated
  vector (2-arg); ranged reads need `read-subu8vector`; writes via
  `write-subu8vector` + `force-output`. Binary-clean on
  current-input/output-port with no port settings (NUL/0x0A verified).
- **Errors render with full backtraces** into err frames — large but
  harmless (supervisor substring-checks atoms).
- gxc's baked-in Homebrew link path references a removed openssl@3/3.2.1
  (`-ld-options "-L/opt/homebrew/opt/openssl@3/lib"` fixes it — moot
  since we use gsc, which links clean).

### Engineering read

Gerbil carries the live-image role — the full probe matrix passes under
both interpreted (gxi) and compiled (gsc -exe) images, including the
hardest ones (commit quarantine, watchdog reload, mid-turn kill
recovery, agent loop). Two caveats are real but bounded: (1) the EOF
quirk forced an explicit quit frame — a small protocol addition that is
arguably better hygiene anyway; (2) the gxc module-namespacing issue
means the compiled path must be gsc, not gxc — anyone productizing
should verify that's a stable, supported build route.

On performance: the compiled Gambit image's boot is the standout —
**4.1 ms median vs Chez 54 ms** (13x), which would let a product treat
image respawn as nearly free (recovery after kill becomes invisible to
users). Echo throughput is modestly lower (1384 vs 1872 msgs/sec, ~26%)
but irrelevant at model-latency scales. The eval-visibility semantics
that the live-image role depends on are identical once module
namespacing is bypassed.

Recommendation input for D-015: Gerbil is viable, and gsc-compiled is
the most attractive variant operationally (fast boot, single static-ish
binary, no runtime discovery). The price is a second image file to
maintain and two documented Gambit quirks (EOF, getenv) already absorbed
by the image.

## Findings / surprises

- **Zig 0.16 API friction** (all worked around, none blocking):
  - `std.posix.open` / `std.posix.write` / `std.posix.writeAll` are gone;
    journal append uses `std.posix.openat` (O struct flags) wrapped in an
    `std.Io.File` for writes + `file.sync(io)` (fsync).
  - Timing via `std.Io.Clock.now(.awake, io).nanoseconds` (i96);
    `std.time.Timer`/`milliTimestamp` gone.
  - `std.process.spawn(io, .{...})` returns a `Child`; pipes via
    `.stdin = .pipe`; `child.kill(io)` = SIGKILL + reap; explicit signal
    via `std.posix.kill(pid, .KILL)`.
  - Deadline reads: `std.posix.poll` on `file.handle` (no async needed).
  - `build.zig.zon` fingerprint is validated against the package name —
    zig rejects a made-up value and suggests the correct one.
  - `i0` is now a reserved primitive name; using it as a parameter is a
    compile error ("name shadows primitive").
  - Juicy main (`pub fn main(init: std.process.Init)`) provides
    args/env/io/gpa; env scrubbing via `std.process.Environ.Map` passed to
    `SpawnOptions.environ_map`.
- **Chez subprocess quirks**:
  - `chez --script` runs the file and exits on stdin EOF (clean shutdown
    path for probe children).
  - Binary frame IO must use `(standard-input-port)` /
    `(standard-output-port)`; `current-input-port` is textual. Every frame
    write needs `(flush-output-port ...)`.
  - No `get-environment-variables` alist API (Guile-ism); only
    `getenv`/`putenv`. env-check probes names individually instead.
  - `(eval form (interaction-environment))` inside the script sees both
    script-level defines and previously eval'd defines.
  - Nested kernel requests work because a primitive called inside an eval
    can run its own frame-read loop (`kernel-wait`) while the main loop is
    suspended in that eval. Supervisor mirrors with the same one-outstanding
    -request discipline.
  - `open-string-output-port` returns TWO values (port + extractor thunk);
    binding it in a single-value `let` fails with "returned 2 values to
    single value return context". Use `let-values` (round 2b, evalc).
  - Without output capture, a user `(display ...)` inside eval writes raw
    bytes into the frame pipe and corrupts framing — `kernel.evalc`
    parameterizes `current-output-port` to a string port during eval.
- **Design wrinkle (round 1, fixed in round 2)**: a *failed* commit's
  suspect change remained pending in the journal and was replayed into
  later fresh images (observed: a watchdog run after the failed commit
  reloaded `greeting` => `"broken"`). Fixed as recommended — `(suspect ...)`
  journal markers quarantine rejected redefines (see Round 2 above). The
  round-1 observation stands as evidence that design rule 4's "marked
  suspect" needs an explicit quarantine mechanism, not just a report.
- **LLM-payload implication (round 3)**: model-generated Scheme source WILL
  contain control characters, NULs, and literal `\x..;` text eventually;
  round 1–2's escaping silently mangled `\xHH;` sequences on the Chez→Zig
  direction (backslash dropped, rest passed through). The fix was not
  additive patching but adopting Chez's canonical `write` form as THE
  discipline and making the Zig decoder strict (unknown escape = hard
  error). Consequence for future protocol work: any payload a model can
  produce round-trips byte-identically, and any deviation fails loudly at
  decode time instead of corrupting a definition. Also note the asymmetry
  this removes: `\e` and `\λ` are REJECTED by Chez's reader — never emit
  them.
- **`<ns>` in the task's typed journal table** was interpreted as the
  entry's 0-based sequence number (`<seq>`); commit keeps `<gen>` as its
  ordering key and carries the replay hash. If closeout intended something
  else (e.g. a namespace field), only the writers/parser in
  `src/main.zig` need to change.
- **Load sensitivity**: spawn-to-first-eval and IPC throughput both moved
  ~2x with host load (boot median 38–122 ms across runs; echo 905–1984
  msgs/sec). Order-of-magnitude conclusions are unaffected.
