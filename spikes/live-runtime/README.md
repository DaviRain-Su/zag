# live-runtime spike (D-013 / live-runtime-spike-001)

A measurement probe: can a **Zig supervisor** drive a **Chez Scheme
subprocess** through a full live-self-modification cycle — redefine →
journal → SIGKILL → replay → discard/commit — with measured boot and IPC
latency? Spike code only; not wired into the root build; no maturity claims.

## Build

```sh
cd spikes/live-runtime
zig build          # produces zig-out/bin/live-probe (Zig 0.16.0)
```

Requires `chez` on PATH (Chez Scheme 10.4.1, Homebrew).

## Run

**Run from this directory** — paths are relative (`runtime.ss`, `.work/`).

```sh
live-probe boot                 # 10x spawn->first-eval timing, min/median/max
live-probe echo [n]             # n framed round-trips (default 10000)
live-probe redefine-cycle       # redefine -> journal+fsync -> SIGKILL -> replay
live-probe discard              # exploratory redefine, then kernel.discard
live-probe commit               # clean-process replay probe + atomic gen flip
                                #   (plus failure path: bad check keeps old gen)
live-probe watchdog             # hang image, 2s liveness deadline, kill, reload
FAKE_API_KEY=x live-probe env-check   # assert child env is scrubbed
live-probe fuzz                 # 1500 adversarial-string round-trips + frame-cap tests
live-probe inspect              # kernel.inspect on committed/pending/unknown names
live-probe agent                # scripted agent scenario: turns, tools, policy redefine, kills
live-probe interactive          # hands-on demo: eval forms, agent turns, :kill recovery
live-probe reset                # rm -rf .work (use between stateful probes)
```

Stateful probes (`redefine-cycle` … `watchdog`) share `.work/`; run
`live-probe reset` first for a clean slate.

## Try it yourself

```sh
cd spikes/live-runtime
zig build
./zig-out/bin/live-probe interactive
```

You get a live Chez image with one committed definition,
`(greeting) => "hello, live image"`. Type forms at the prompt; colon
commands are supervisor operations (`:help`). Suggested sequence:

1. `(greeting)` — see the committed value.
2. `(kernel.redefine 'greeting "(define (greeting) \"hacked at runtime\")")`
   then `(greeting)` — the running image is now modified (journaled +
   fsynced by the supervisor before it was applied).
3. `:kill` — SIGKILLs the image mid-conversation; a fresh image boots and
   the journal replays: `(greeting)` comes back as `"hacked at runtime"`.
4. `:commit` — snapshot as the next generation (clean-process replay probe
   first), or `:discard greeting` to throw the change away instead.
5. `:status` — generation, journal size, pending redefines, liveness.

6. **Agent turn**: type bare text (no parens), e.g. `hello agent` — the
   supervisor journals your message, the image's agent loop calls the fake
   provider, and you see the reply. Redefine the policy mid-conversation
   with `(kernel.redefine 'system-prompt "(define (system-prompt) \"be brief.\")")`,
   keep chatting, then `:kill` and watch the conversation AND the new
   policy survive. For the full scripted scenario run `live-probe agent`.

Also try `(display "side effects are captured")` — printed output is
captured into the reply so it cannot corrupt the frame stream — and
`(exit)` — the image dies for real and the supervisor respawns and replays
automatically. Ctrl-D quits. Piped (non-TTY) input works line-by-line.
The genesis seed is `(define (greeting) "hello, live image")` in
`.work/generations/0/base.ss`; `live-probe reset` wipes back to it.

## Agent loop in the image (spike-003)

```text
user input
  │
  ▼
Zig supervisor ──append user entry (fsync)──► .work/conversation.sexp
  │ send turn
  ▼
Scheme image: agent loop (RE-DEFINABLE policy)
  │  system-prompt fn + tool registry + history from store
  │ provider.call ──► Zig fake provider (scripted, deterministic)
  │ tool.invoke   ──► Zig tool shim (fs.read, workspace-jailed)
  │ conv.append   ──► Zig appends to conversation.sexp (fsync)
  ▼
assistant reply rendered
```

- **Policy lives in tracked bindings**: `system-prompt` and
  `tool-registry` are ordinary genesis definitions, redefinable via
  `kernel.redefine` (commit/discard/suspect semantics apply). The agent
  loop mechanics (`agent-continue`, `provider.call`, `tool.invoke`,
  `conv-append`) are fixed image infrastructure in `runtime.ss`.
- **Conversation store** `.work/conversation.sexp`: Zig-owned append-only,
  fsync per append. Schema (`<seq>` = line number, `<ts>` = realtime ns,
  `<echo>` = system prompt the provider echoed):

  | entry | fields | appended by |
  |-------|--------|-------------|
  | `(user <seq> "<text>" <ts>)` | user input | **supervisor**, fsynced BEFORE any provider work |
  | `(assistant <seq> "<text>" "<echo>" <ts>)` | final reply + policy echo | image via `conv.append` |
  | `(tool-call <seq> <tool> "<path>" "<echo>" <ts>)` | provider-issued call | image via `conv.append` |
  | `(tool-result <seq> <tool> "<result>" <ts>)` | tool output/error | image via `conv.append` |

  Reads tolerate a torn FINAL line (crash mid-append); any other bad line
  is corruption.
- **Fake provider** `.work/provider-script.sexp`: one response per line,
  consumed in order: `(say "<text>")` or `(call fs.read ("<path>"))`.
  **Script position = count of assistant + tool-call entries in the
  conversation store** — derived from durable state, so a mid-turn kill
  retried later deterministically gets the same scripted response and no
  entry can be duplicated. Every reply echoes the received system prompt,
  so the transcript proves which policy produced each turn.
- **Tool shim**: `fs.read` only, jailed to `.work/workspace/` (rejects
  absolute paths and `..` components, realpath containment check, output
  bounded to 16 KiB).
- **Recovery**: on respawn the image rebuilds context from
  `conversation.sexp` (`conv-history`) + policy from the journal.
  `agent-continue` dispatches on the last durable entry: `user`/`tool-result`
  → (re)issue the provider call (store-derived position makes the retry
  deterministic); `tool-call` → re-invoke the RECORDED call, never a new
  provider reply.

New IPC (Scheme → supervisor, same nested-request machinery):

| request | reply |
|---------|-------|
| `(conv.append <kind> <fields...>)` | `(kernel.ack conv)` after validate+fsync |
| `(conv.history)` | `(kernel.history <entries...>)` |
| `(provider.call "<system-prompt>" "<history-text>")` | `(provider.reply (say "<text>" "<echo>"))` or `(provider.reply (call fs.read "<path>" "<echo>"))` |
| `(tool.invoke fs.read "<path>")` | `(tool.result "<content>")` / `(tool.error "<msg>")` |

Interactive mode: **bare text** (not `(` or `:`) runs an agent turn and
prints the reply; the default provider script has two canned `say`s (then
`[provider script exhausted]`).

## Runtime selection (spike-004: Chez vs Gerbil)

The supervisor picks the image runtime via env var `LIVE_PROBE_RUNTIME`:

| value | spawn | image script |
|-------|-------|--------------|
| `chez` (default) | `chez --script runtime.ss` | `runtime.ss` |
| `gerbil` | `gxi runtime-gerbil.ss` | `runtime-gerbil.ss` |
| `gerbil-bin` | `./runtime-gerbil-bin` | compiled by `live-probe build-gerbil-bin` (gsc -exe, Gambit native — gxc's module namespacing breaks eval visibility; see RESULTS round 5) |

Every probe runs unchanged under all three. The wire protocol is identical;
the only codec difference is the hex-escape CASE in string literals: Chez
`write` emits `\x1F;` (uppercase), Gambit `write` emits `\x1f;`
(lowercase). The supervisor encodes with the selected runtime's canonical
case and decodes case-insensitively, so payloads round-trip byte-identically
under both (fuzz-verified on both runtimes).

Known Gambit semantic gap handled in the image: `(getenv "MISSING")` RAISES
("Unbound OS environment variable") where Chez returns `#f`;
runtime-gerbil.ss shadows `getenv` with Chez semantics. Also: gxi prints
uncaught exceptions to STDOUT (would corrupt the frame stream) — the image
wraps its main loop in a top-level catcher reporting to stderr (exit 70);
and Gambit ports do not reliably report stdin EOF, so polite shutdown is an
explicit `(kernel.quit)` frame (both images), not pipe EOF.

## Framing

One framing, both directions, on the child's stdin/stdout:

```
+------------+----------------------+
| u32 LE len | UTF-8 payload (len)  |
+------------+----------------------+
```

Payload is exactly **one s-expression, single line**. There is no request
id: exactly one outstanding request per direction; nested kernel requests
are serviced synchronously (see below).

**String escaping — ONE discipline, both directions: canonical Chez
`write` escapes.** Named escapes `\" \\ \n \r \t \a \b \v \f`; any other
byte `< 0x20` or `0x7F` as `\xHH;` (uppercase minimal hex,
semicolon-terminated); bytes `>= 0x80` raw. Payloads must be valid UTF-8.
Decoding is strict — an unknown escape or malformed `\x..;` is an error,
never silently mangled. Arbitrary control bytes (incl. NUL), quotes,
backslashes, literal `\x..;` text, and UTF-8 round-trip byte-identically
(proven by `live-probe fuzz`, 1500 adversarial strings).

**Frame length cap:** `max-frame-bytes` = **4 MiB**, a named constant on
BOTH sides (`runtime.ss`, `src/main.zig: max_frame_bytes`). The image
discards an oversize inbound payload (bounded chunks, stream stays
aligned), replies `(err "frame-too-large")`, and keeps running. The
supervisor treats an oversize frame FROM the image as misbehavior: rejects
it, kills + respawns the image with a clear message, and keeps working.

### Supervisor → Scheme

| frame | reply |
|-------|-------|
| `(kernel.eval "<source>")` | `(ok <datum>)` / `(err "<msg>")` — eval one form |
| `(kernel.evalc "<source>")` | `(ok "<datum>" "<captured-output>")` / `(err "<msg>")` — same, but the form's printed output is captured into the reply (interactive mode uses this so `display` cannot corrupt the frame stream) |
| `(kernel.apply "<source>")` | `(ok applied)` / `(err "<msg>")` — eval 1+ top-level forms, record `define` sources in the image's registry |
| `(kernel.echo "<payload>")` | `(ok "<payload>")` |
| `(kernel.quit)` | `(ok bye)` then the image exits (polite shutdown; Gambit ports don't reliably report stdin EOF) |
| `(kernel.ack <name>)` | — (ack for a pending kernel request) |
| `(kernel.nack <name> "<reason>")` | — (negative ack; the primitive raises a readable condition instead of hanging) |
| `(kernel.err "<msg>")` | — (negative ack for `kernel.commit`) |

### Scheme → supervisor (kernel requests)

Sent by the primitives `kernel.redefine` / `kernel.discard` / `kernel.commit`
when evaled user code calls them. Because they run **inside** an eval, the
primitive sends its request frame and then runs a nested frame-read loop
(`kernel-wait`), dispatching any further supervisor requests until its ack
arrives. The supervisor mirrors this: while waiting for an eval reply it
services kernel request frames.

| frame | supervisor behavior |
|-------|---------------------|
| `(kernel.redefine <name> "<source>")` | append journal entry, **fsync**, then `kernel.apply` the source, then ack |
| `(kernel.discard <name>)` | if `<name>` has a committed definition: append journal entry, fsync, `kernel.apply` it, ack; else **nack** (`not-committed`) without journaling — the image raises a readable condition |
| `(kernel.commit "<check>" "<expected>")` | build generation n+1 in a hidden staging dir from journal-pending redefines; spawn a **clean** chez; replay base+script; run `<check>`; on match rename staging into place, atomically flip `.work/current` (write tmp + fsync + rename) and journal `(commit n hash ts)`, ack; on ANY failure (value mismatch OR apply/check error) journal `(suspect <name> seq ts)` per pending entry (quarantine), delete staging, keep old pointer, nack |
| `(kernel.inspect <name>)` | reply `(kernel.inspect.result (source <string-or-#f>) (status committed\|pending\|unknown) (generation <n-or-#f>) (dependents <symbols>))`. Source/status from the journal pending set first, then the current generation. Generation: 0 for base.ss bindings, else earliest gen whose replay.ss defines it. Dependents (v0, shallow): tracked definitions (current-gen committed + pending) whose source mentions the name as a delimited symbol — lexical scan only, no macro/closure analysis |

## File layout

```
spikes/live-runtime/
  build.zig / build.zig.zon   own build, not wired into root
  src/main.zig                the supervisor (all subcommands)
  runtime.ss                  the live image: frame loop + kernel primitives
  .work/                      runtime state (git-ignored)
    journal.sexp              append-only, one typed entry per line (schema below)
    current                   generation pointer (atomic replace)
    conversation.sexp         agent conversation store (typed schema above)
    provider-script.sexp      fake provider script: (say "...") / (call fs.read ("..."))
    workspace/                fs.read tool jail root
    generations/<n>/
      base.ss                 base definitions
      replay.ss               declarative: ordered committed definitions
      meta.sexp               (gen n parent p hash "<sha256(replay.ss)>" ts <ns>)
    generations/.staging-<n>/ transient commit staging; renamed into place only
                              after the replay probe passes, deleted on failure
```

Journal schema (typed; replay = fold over entries; `<seq>` = 0-based entry
line number, `<ts>` = realtime nanoseconds):

| entry | meaning | replay effect |
|-------|---------|---------------|
| `(redefine <name> <seq> "<source>" <ts>)` | pending change | applies until superseded |
| `(discard <name> <seq> <ts>)` | exploratory rollback | removes matching pending redefine |
| `(suspect <name> <seq> <ts>)` | quarantined by failed commit | removes matching pending redefine |
| `(commit <gen> "<hash>" <ts>)` | generation flip recorded | none (pointer file is authoritative) |

Restore semantics: replay into a fresh image = `base.ss` + current
generation's `replay.ss` + journal redefines since the last `(commit ...)`
(dropping ones canceled by a later `(discard ...)` or quarantined by a
`(suspect ...)` marker from a failed commit probe). In this spike the
journal doubles as the replay source for uncommitted changes; the analysis
calls it an audit log — noted as a simplification.

## Interactive mode

`live-probe interactive` (alias `demo`) loops over stdin lines. A line
starting with `(` is evaluated in the live image via `kernel.evalc` (reply
datum + captured output printed readably). EOF (Ctrl-D) quits; piped input
works line-by-line. If the image dies outside `:kill` (e.g. the user evals
`(exit)`), the supervisor detects the closed pipe, prints what happened,
and auto-runs the same respawn+replay path.

Colon commands (handled by the supervisor itself):

| command | behavior |
|---------|----------|
| `:kill` | SIGKILL the image, respawn, replay; prints restored `(greeting)` |
| `:commit` | existing commit flow (clean-process replay probe + atomic flip) with a trivially-true recorded check; prints current generation |
| `:discard <name>` | existing discard mechanics (journal + re-apply committed source); prints result |
| `:status` | generation number, journal entry count, pending redefines, liveness |
| `:reset` | wipe `.work` to genesis (printed warning), respawn |
| `:help` / `:quit` | help text / clean child shutdown |

## Notes / known limitations

- The child is always spawned with a **scrubbed allowlist environment**
  (`PATH`, `HOME`, `TERM`). `env-check` proves supervisor-side secrets do
  not cross.
- Failed commits **quarantine** their pending redefines with `(suspect ...)`
  journal markers; replay skips them (F2 fix). The live image keeps its
  exploratory state — it is generation-local and lost on restart anyway.
- A discard of an unknown/uncommitted name is nacked, not journaled (F4
  fix); the image raises `(error 'kernel.discard "not-committed")`.
- Watchdog deadline reads use `poll(2)` on the pipe fd (2 s). No async
  runtime involved.
- Directory fsync after the pointer rename is skipped (POSIX rename is
  atomic; durability across power loss is out of spike scope).
- Macro redefinition, multi-worker, and introspection beyond
  `kernel.source-of` are out of scope (spike non-goals).
