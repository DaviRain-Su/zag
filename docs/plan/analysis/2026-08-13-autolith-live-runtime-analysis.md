# Autolith → Zag live-runtime analysis

> Date: 2026-08-13
> Scope: public Autolith source tree + `docs/architecture.org` (read-only, nothing executed)
> Decision output: [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md)
> Probe task: [live-runtime-spike-001](../tasks/live-runtime-spike-001.md)

## Question

Can Zag gain **live self-modification** — an agent that inspects and rewrites
its own running behavior with trustworthy rollback — without embedding a
script VM in the host process (rejected by [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md))
and without giving up systems-language ownership and safety?

## Reference: Autolith

[Autolith](https://github.com/lambda-symbolics/autolith) is a terminal agent
inside a live Common Lisp (SBCL) image. Facts taken from its
`docs/architecture.org` and source layout:

- **Process split is deliberate.** Stable launcher, active image, isolated
  workers, and pristine recovery image are distinct artifacts: "a problem in
  one must not turn into authority to overwrite or silently trust another."
- **Durable state is readable s-expressions.** Append-only logs, atomic
  replacement, incomplete-tail repair, `*read-eval*` bound to `nil`.
- **Live mutation is two-tier.** Exploratory installs are discardable;
  `self.commit` snapshots, **replay-probes in a clean process**, commits to a
  private mutation-history Git repo, then atomically selects startup state.
- **Authority is the replay script, not the heap.** Retained cores
  (`sbcl-generations`) are caches; "the tracked source remains the base
  system; the selected private script reconstructs user-specific changes."
- **Checkpoint hygiene is explicit.** Quiesce work, clear credentials, detach
  workers, verify provenance; an unpublished core must boot and identify
  itself before selection.
- **Recovery is conservative.** Recovery image tries compatible generations,
  then a clean source checkout; the input vault never auto-resubmits.

## Key lessons

1. Even with SBCL's real heap dump available, Autolith keeps the **declarative
   replay script authoritative**. Heap images are accelerators. A Scheme
   without live-heap dump (Chez) is therefore not a blocker.
2. Autolith's "fixed kernel" is **convention** (package locks dropped during
   modification, restored afterward). Its real safety net already lives
   outside the image. A Zig supervisor turns that convention into a physical
   boundary.

## Design mapping

| Autolith (pure CL) | Zag kernel + Scheme | Note |
|--------------------|---------------------|------|
| stable launcher + provenance checks | **Zig supervisor**: generation selection, journal, watchdog, recovery orchestration | compiled TCB instead of shell scripts |
| active SBCL image (agent, tools, state) | **Chez Scheme subprocess**: agent loop, tool registry, prompt/memory policy | maximal self-modification coverage stays here |
| sbcl-generations retained cores | **base image + replay script** snapshots; ephemeral fork checkpoints | content-addressed, diffable, no dump dependency |
| mutation-history private Git | same: replay scripts in a private repo | — |
| pristine recovery image | pristine Scheme image + minimal recovery module, spawned by Zig | — |
| `lisp.*` heap-isolated SBCL workers | pristine Scheme workers spawned by Zig | more natural: the supervisor already exists |
| sexp-store durable records | **Zig-owned** (or Scheme-written, Zig-fsynced) | records survive Scheme crashes |
| credentials, dynamically scoped + scrubbed at checkpoint | **Zig-held**, injected per provider request | tokens never enter the Scheme heap |
| terminal (primary screen, OSC 133) | **Zig-owned** | terminal survives image crash; recovery renders live |

## What the split buys

- **Physical TCB.** Kernel primitives, journal, and recovery path are
  compiled Zig; Scheme cannot redefine, disable, or corrupt them.
- **Credentials by construction.** Autolith must actively scrub tokens before
  checkpoint; here they never enter the mutable heap.
- **Terminal and journal survive image crashes**; recovery is visible to the
  user in real time.
- **Turn ordering enforced by the supervisor**, not by in-image discipline.

## What it costs

- **Introspection fidelity.** `describe`/source lookup/disassembly are
  uniform in one heap; across IPC, `kernel.inspect` must deliberately return
  source + metadata + reverse-dependency info or the agent's self-observation
  degrades.
- **No same-heap closures/continuations across tool calls.** Small in
  practice: model tool calls are already serialized data.

## Design rules (v0)

1. **Persistence is a privilege, not a ban on mutation.** Only kernel-tracked
   bindings survive restore; all other mutation is generation-local and lost
   on restart.
2. **Journal authority lives in the kernel**: append-only, fsync before the
   change is applied inside Scheme.
3. **Generations are declarative**: base image + replay script, hashed,
   parented, timestamped. The journal is an audit log, not a replay log.
4. **`kernel.commit` = spawn a clean Scheme, replay base + script, run
   recorded checks, then atomically flip the current-generation pointer.**
   Failure keeps the old pointer and marks the exploratory change suspect.
5. **Exploratory vs committed is explicit**; `kernel.discard` reverses one
   effective exploratory change.
6. **Macros**: v0 durable redefine covers functions and data. Macro changes
   stay exploratory-only; committing them requires full replay validation.
7. **Watchdog uses kernel-side liveness probes** (call a known procedure with
   a deadline), never the image's self-report.
8. **Short-term undo via ephemeral fork checkpoints; durable rollback via
   generations.**

## Relation to existing decisions

- [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md):
  this is **not** a new extension tier. The Scheme image is a supervised
  process consumer of the same supervision direction as
  [process-supervisor-001](../tasks/process-supervisor-001.md); no product
  wiring.
- [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md): Core is
  untouched; the spike lives outside `packages/`.
- Maturity: unchanged. The spike produces measurements, not claims.

## Open questions the spike must answer

| Question | Probe | Pass signal |
|----------|-------|-------------|
| Chez cold boot + preload latency | measure startup to first eval | < 100 ms on dev host |
| s-expr IPC framing and latency | length-prefixed echo loop, 10k messages | no framing errors; round-trip ≪ model latency |
| `kernel.redefine` closed loop | redefine → journal fsync → `SIGKILL` → replay | restored binding has identical source/value |
| `kernel.discard` | exploratory change then discard | binding returns to last committed state |
| `kernel.commit` probe | clean-process replay + checks + atomic flip | new generation selected only after probe pass |
| watchdog path | hang the Scheme, let deadline expire | supervisor kills, reloads committed generation, journal intact |
| secret hygiene | inspect Scheme argv/env/memory-visible inputs | no tokens present |

## Non-goals for the spike

Agent loop, provider calls, TUI, durable macro redefinition, multi-worker,
OS-sandbox claims, productization.

## Spike findings (2026-08-14)

Probe: [live-runtime-spike-001](../tasks/live-runtime-spike-001.md), code in
`spikes/live-runtime/`, independent review
`docs/plan/reviews/live-runtime-spike-001-01.md` — **pass**, zero blocking.

Every open question above is answered:

| Question | Result |
|----------|--------|
| Chez cold boot | median **~38–55 ms** (quiet host), 30–40 ms raw `chez --script` — under the 100 ms target |
| s-expr IPC | **~1800–2000 msgs/sec**, 10k round-trips, zero framing errors — irrelevant vs model latency |
| redefine → journal → `SIGKILL` → replay | PASS — identical value and byte-identical source after respawn+replay |
| `kernel.discard` | PASS — binding returns to last committed state; unknown names get `kernel.nack`, no hang |
| `kernel.commit` probe | PASS both paths — clean-process replay + atomic pointer flip on success; failure keeps old pointer |
| watchdog | PASS — 2 s kernel-side deadline on hung image, kill, reload committed generation, journal intact |
| secret hygiene | PASS — child spawned with allowlist env; 9 injected `*KEY*`/`*TOKEN*`/`*SECRET*` names all absent |

Design rules validated by working code: fsync-before-apply, declarative
generations, clean-process commit probe with atomic flip, kernel-side
watchdog, exploratory/committed split.

Two design notes discovered by the spike (not in the original rules):

1. **Suspect quarantine is required.** A failed commit's rejected change must
   be journaled as `(suspect ...)` and skipped by every replay path;
   otherwise later reloads boot the rejected value. Implemented and verified
   in the spike; belongs in the rules when they are promoted to a contract.
2. **The journal currently doubles as the replay log for pending
   (uncommitted) entries**, against the letter of rule 3 ("audit, not a
   replay log"). Acceptable for the spike; promotion to a contract must
   either formalize this dual role or split pending state into its own
   record.

   **Resolved 2026-08-14 (spike-002):** the dual role is kept and formalized
   as one typed entry schema — `redefine` / `discard` / `suspect` / `commit`,
   replay = fold. See [live-runtime-spike-002](../tasks/live-runtime-spike-002.md).

## Spike findings, round 3 (2026-08-14, spike-002)

Probe: [live-runtime-spike-002](../tasks/live-runtime-spike-002.md);
independent review `docs/plan/reviews/live-runtime-spike-002-01.md` —
**pass**, zero blocking. Suite now 9/9 (original 7 + `fuzz` + `inspect`).

- **Escaping is now one discipline: canonical Chez `write` form on both
  sides** (named escapes; other control bytes as uppercase `\xHH;`; ≥0x80
  raw UTF-8). Strict decoding turns any deviation into a loud error.
  Independent adversarial round-trips (NUL, DEL, literal `\x41;` as data,
  lone backslash, 4 KB mixes): byte-identical; `\e` / `\xZZ;` fail loudly at
  the reader. This was correctness-critical before LLM-generated redefines.
- **Frame cap 4 MiB both sides**; oversize frames rejected cleanly, image
  survives, supervisor kills/respawns on garbage from the image.
- **`kernel.inspect`** returns source + status (committed/pending/unknown) +
  generation + shallow dependents; probe covers all three statuses.
- **F8/F9 closed**: commit stages into `.staging-<n>/` and renames only on
  probe pass (no orphan dirs); suspect quarantine is a `defer` over every
  failure exit including clean-process apply/check *errors*.
- **Typed journal**: `(redefine|discard|suspect <name> <seq> ...)` and
  `(commit <gen> "<hash>" <ts>)`; torn-tail detection rejects unknown line
  kinds. The `<ns>` field from the task table is implemented as a 0-based
  sequence number (accepted by review as the ordering/identity intent).
- Latent bug found by the new structured-reply assertions: `parseDatum`
  greedily trimmed trailing `)`, corrupting list datums since round 1 —
  fixed. Lesson recorded: substring-only assertions hid it; assert on
  structured replies.

## Spike findings, round 4 (2026-08-14, spike-003)

Probe: [live-runtime-spike-003](../tasks/live-runtime-spike-003.md);
independent review `docs/plan/reviews/live-runtime-spike-003-01.md` —
**pass**, zero blocking. Suite now 10/10 (9 + `agent`).

**The track's central claim is now demonstrated end-to-end** (scripted fake
provider, deterministic): the agent redefined its own `system-prompt` policy
mid-conversation (transcript proves V1→V2 via provider echo at entry 11),
the conversation continued with the new behavior, the image was SIGKILLed
between turns AND mid-turn, and after replay both the conversation history
and the pending policy were alive.

Architecture that survived contact:

- **Conversation store** (`conversation.sexp`): Zig-owned append-only typed
  entries; user input durable before any provider work; torn-tail tolerant.
- **Fake provider script position = count of durable completed replies.**
  Strongest choice of the round: every kill point (mid-IPC,
  post-call-pre-append, mid-tool, post-tool) is retry-safe **by
  construction** — duplicates are impossible, not detected. Review verified
  with a 12-run chaos harness across 4 kill windows: zero duplicates, zero
  missing entries. Principle for a real provider: a durable entry per
  completed step makes a turn a resumable continuation.
- **Agent loop in the image**: policy (`system-prompt`, `tool-registry`) is
  ordinary tracked bindings; loop dispatches on the last durable entry —
  `user`/`tool-result` → provider call; `tool-call` → re-invoke the
  RECORDED call, never a fresh provider reply.
- **Tool shim**: `fs.read` with realpath containment; review threw 12 escape
  attempts (`..`, absolute, symlink→`/etc/passwd`, symlink→journal,
  dir-symlink traversal) — all rejected.
- Interactive mode now drives agent turns with bare text — the hands-on
  demo of live policy surgery (`(kernel.redefine 'system-prompt ...)`
  mid-conversation, then `:kill`, then keep talking).
