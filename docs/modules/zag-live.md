# zag-live — supervised live Scheme image

> Binding contract for [zag-live-001](../plan/tasks/zag-live-001.md)
> (implemented) and [zag-live-004](../plan/tasks/zag-live-004.md)
> (runtime port).
> Direction: [D-013](../decisions/active/D-013-live-runtime-prototype-track.md)
> + [D-014](../decisions/active/D-014-live-runtime-productization-route-a.md)
> + [D-015](../decisions/active/D-015-live-runtime-gerbil-gambit.md);
> evidence: [analysis](../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md)
> rounds 1–5.
>
> **Status:** **implemented** (Chez binding, 23/23) — **D-015 revision,
> review round 2**: round-1 dual blocked (safety R1–R3, arch B1–B2), fixes
> folded into this text; dual re-review required before zag-live-004
> implements against it.
> Experimental, default-off; no maturity claim.
> Earlier history: initial draft round 1 dual blocked (8 findings fixed),
> round 2 dual PASS (Chez binding).

## 1. Purpose

`zag-live` owns a **supervised live Scheme image** acting as the product's
live policy layer: runtime-redefinable, kernel-tracked bindings with
journaled audit, declarative generations, and kill/replay recovery.
It lets product code delegate redefinable policy (first: prompt
construction) to a living image without giving the image any trust.

**Runtime binding (D-015):** the image is Gambit-flavored Scheme. Two spawn
forms: a **compiled image binary** (`gsc -exe`, production form — single
binary, ~5 ms boot, no host runtime dependency) and an **interpreted form**
(`gxi` + embedded script, development/fallback). Gerbil's `gxc` module
system is NOT used for the image (namespacing breaks interaction-eval; see
analysis round 5). The previous Chez binding is retired from the product
path (spike harness retains it).

## 2. Boundary

| Owns | Must not |
|------|----------|
| Image lifecycle (build-discovery/spawn/probe/kill/reap), frame protocol, journal, generations, commit probe, watchdog, reference jailed `fs_read` ToolPort helper (§6) | Network I/O; provider credentials; product policy decisions (which surfaces are live is the caller's); general tool execution beyond the shipped reference helper |

Provider calls and tool executions the *image* requests are fulfilled
through **host-injected ports** (§6). `zag-live` depends on `zag-types`
only. Core (`zag-agent-core`) never sees zag-live types; integration enters
through `zag-coding-agent` (D-011, D-014).

**Process-ownership note (A3):** zag-live owns its image child process
directly. This is a deliberate, documented exception to
[process-supervisor.md](./process-supervisor.md), whose ownership claim
covers *product tool* children (`run_shell`, LSP/MCP slots) inside
`zag-coding-agent`. zag-live is an L2 package and cannot import that L3
supervisor; its image is also not a tool execution but the package's own
reason to exist. If a future shared process package emerges at L2,
migration is reconsidered then.

## 3. Core types (v1)

| Type | Content | Invariants |
|------|---------|------------|
| `Frame` | length-prefixed s-expr payload, 4-byte LE u32 header | ≤ `max_frame_bytes` (4 MiB); payload valid UTF-8; strings in the **runtime's canonical `write` escaping** (Gambit: lowercase `\xhh;`), decode strict and case-insensitive on hex; unknown escape = hard error. **Frame-stream purity (R2):** the image installs a top-level exception catcher — uncaught exceptions and diagnostics go to **stderr** (bounded, ≤ 4 KiB) + nonzero exit, never to the stdout frame stream |
| `JournalEntry` | `(redefine \| discard \| suspect <name> <seq> …)` / `(commit <gen> "<hash>" <ts>)` | append-only; **one fsynced write per entry**; a non-conforming **final** line is a torn tail, truncated on read; an unknown kind anywhere earlier is `JournalCorrupt` — **fail closed**, never silently truncate mid-file |
| `Generation` | `base.ss` + `replay.ss` + `meta.sexp` (hash, parent, ts) | staged into `.staging-<n>/`, renamed only after the clean-process probe passes; no orphan dirs (stale staging removed on next start) |
| `Binding` | name → source, status (`committed`/`pending`), generation, dependents (shallow) | only tracked bindings survive replay |
| `Image` | child process handle (compiled binary or gxi+script), liveness deadline | one live image per `Live` instance; spawned with a **scrubbed environment** (§4); compiled form must pass self-identification (§4) |

## 4. Host API (Zig, v1 sketch)

```zig
const Live = @import("zag-live").Live;

var live = try Live.init(gpa, io, .{
    .state_dir = dir,                 // journal + generations root
    .image = .{ .compiled = path },   // or .{ .interpreted = .{ .gxi_path = null } }
    .base_source = null,              // null = embedded genesis; hosts override (live-policy-layer rides this)
    .provider_port = my_provider,     // optional; image provider.call
    .tool_port = my_tools,            // optional; image tool.invoke
    .extra_env = &.{},                // host-controlled additions ONLY; see env rule
    .watchdog = .{ .probe_interval_ms = 1000, .deadline_ms = 2000 },
});
defer live.deinit();

try live.start();                     // spawn + boot probe + replay current generation
try live.eval("(greeting)");          // host-driven eval; bounded result + request deadline
try live.stop();                      // kernel.quit → deadline → SIGKILL
```

`Live.init` validates configuration cheaply (paths exist, spawn form
well-formed); the **boot probe runs at `start()`** (N2 — matches the
implemented binding), including replay of the current generation.

**Image source rule (D-015, binding):** the image source ships embedded in
the package. `.compiled` takes a host-supplied path to a `gsc -exe` binary
built from that source — `Live.buildImage()` performs this build, writing
to `state_dir/image-bin` (inside state_dir per §7), discovering Gambit's
`gsc` by asking `gxi` (`path-expand "~~bin/gsc"`), never PATH — PATH's
`gsc` may be Ghostscript. `.interpreted` runs the embedded source via `gxi`
(discovered on PATH or explicit; version floor **Gerbil ≥ 0.18**).

**Compiled-image identity (R3, binding):** the boot probe is a
**self-identification handshake** — the image answers with its
protocol/source version; a stale or foreign binary answers wrong (or not at
all) → `ImageUnavailable`. (On-host observation, not a gate: three
consecutive `gsc -exe` builds were sha256-identical — recorded in
[review zag-live-004-02](../plan/reviews/zag-live-004-02-safety.md);
off-host reproducibility is the D-015 gate, not assumed here.)

**Stop discipline (R1, binding):** `stop()` sends the `(kernel.quit)`
frame, waits up to `deadline_ms`, then SIGKILLs. Gambit EOF unreliability
(D-015 caveat) must never hang `deinit()`.

**Environment rule (binding):** the image is spawned with a fixed
allowlist environment (`PATH`, `HOME`, `TERM`) plus any `extra_env` pairs
the host passes explicitly. The ambient host environment is **never**
inherited. This is the mechanism behind "credentials never enter the
image"; a conforming implementation must prove it (§10 test 2).

**Recovery semantics (binding):** on image death (watchdog, crash, kill)
the image is respawned and replayed from `current` generation + journal. An
in-flight host request fails once with `error.ImageRestarted`; **zag-live
never retries host requests transparently** (no duplicate side effects by
construction). The caller may retry idempotent requests. After restart, new
requests run against the replayed state.

## 5. Image-side protocol (kernel primitives)

`(kernel.redefine name source)` · `(kernel.inspect name)` ·
`(kernel.discard name)` · `(provider.call …)` / `(tool.invoke …)` when ports
are registered. `kernel.eval` is a **host→image request**, not an image
primitive. `kernel.quit` is the host→image polite-stop frame (§4).

**Commit (binding):** `(kernel.commit reason)` runs the default recorded
check in the clean probe process — replay completes and every tracked
binding resolves. `(kernel.commit reason check expected)` records a
caller-supplied check expression and expected value, evaluated in the clean
probe process after replay; mismatch **or eval error** rejects the commit.
The clean probe uses the same spawn form (compiled or interpreted) as the
live image.

Semantics as proven in the spike: journal fsync **before** apply; commit =
clean-process replay probe + staged generation + atomic flip; discard
restores the last committed definition; unknown-name discard =
`kernel.nack`.

**Failed-commit disposition (binding):** a rejected commit leaves the live
image unchanged (the change stays installed and exploratory-live), but the
pending entries are journaled `(suspect …)` and excluded from **all future
replay**; the next restart shows the last committed state. After
`CommitUnavailable` (infra failure, see G4) the pending set stays pending
and a later commit may retry.

**Recovery affordance (binding):** `Live.recover()` quarantines ALL pending
entries and restarts from the committed generation (caller-initiated only —
never automatic); `Live.needsRecovery()` is the hint latch set when start
dies in replay with a non-empty pending set.

**Promotion fixes (binding, from spike backlog):**

| Gate | Rule |
|------|------|
| H2 | every journal/state entry append = one fsynced write (no entry/newline split) |
| H3 | the reference `fs_read` ToolPort helper ships **in zag-live** and resolves containment via dirfd-relative open (no realpath-then-open TOCTOU); hosts adopt it or reimplement to the same bar (§10 test 11 gates the shipped helper) |
| G4 | clean-process **infra** failure = spawn-stage only (staging writes + spawn, any error class): retry once, then `CommitUnavailable`; anything after a successful spawn (replay/apply/check death or error) = defect of the change → quarantine. Post-spawn death from genuine host flakiness quarantines an innocent change — accepted safe direction |

## 6. Ports (host-injected)

```zig
pub const ProviderPort = struct {
    call: *const fn (ctx, request_sexp) anyerror![]const u8,
};
pub const ToolPort = struct {
    invoke: *const fn (ctx, name, args_sexp) anyerror![]const u8,
};
```

Ports are synchronous; the image blocks on the reply. **Boundedness is a
host duty:** port implementations must bound their own runtime and reply
size (frame cap applies on the wire); the contract has no enforcement point
inside zag-live, so the watchdog covers image-side liveness only and a hung
port is the host's responsibility. Port absence = the corresponding
primitive returns a nack (`PortAbsent` host-side).

Credentials never enter the image: provider auth stays behind the host's
ProviderPort, and the env rule (§4) keeps ambient secrets out of the child.

**Reference tool helper:** zag-live ships `fsReadPort()` — a jailed
`fs.read` ToolPort implementation (dirfd-relative containment, symlink-safe,
16 KiB output bound). Product hosts wire this helper or an equivalent;
fixture ports in tests verify the port mechanics, and the shipped helper
carries the containment acceptance tests.

## 7. State ownership

All durable state under the caller-provided `state_dir`:
`journal.sexp` (typed, append-only) · `generations/<n>/{base,replay}.ss +
meta.sexp` · `current` pointer file (atomic rename) · `image-bin`
(`buildImage()` output). The package never writes outside `state_dir`.

**Containment honesty (binding):** the image process retains ambient
filesystem access with user privileges — the process boundary is a
**crash/trust boundary, not an OS sandbox** (consistent with §11). Only the
ToolPort-mediated paths are jailed (§6). Product policy must treat image
code as trusted local code, exactly as it treats `run_shell` output.

## 8. Errors (closed vocabulary)

`ImageUnavailable` · `BootProbeFailed` · `ImageDied` · `ImageRestarted` ·
`FrameTooLarge` · `ProtocolError` · `JournalCorrupt` · `CommitRejected` ·
`CommitUnavailable` · `NotCommitted` · `NothingToCommit` · `PortAbsent` ·
`DeadlineExceeded`. (`OutOfMemory` rides along as the allocator escape
hatch, documented non-domain.)

`JournalCorrupt` semantics: raised only for mid-file corruption; a torn
final line is truncated silently on read and replay proceeds.

The default commit check catches unresolved bindings after replay; errors
that only surface at call time need the 4-arg form
`(kernel.commit reason check expected)` with a real exercising check.

First-line atoms only; no absolute paths, errno strings, or env values leak
into error payloads. Image diagnostics (backtraces etc.) are bounded at the
boundary (§3 frame-stream purity).

## 9. Extension points

Later surfaces register more tracked bindings (tool registry, memory
policy) without protocol change. Multi-image workers, durable macro
redefinition, and the input vault are separate Gates; none are in v1.

## 10. Tests (acceptance)

Port the spike probe set as package tests against a fixture provider/tool
port (no network). All image-touching tests run against **both spawn
forms** (compiled + interpreted), skip-gated when the toolchain is absent:

| # | Class | Expect |
|---|-------|--------|
| 1 | boot + boot probe at `start()` | bounded startup per form; version floor (interpreted); `ImageUnavailable` paths clean |
| 2 | child env scrub | child sees only allowlist + `extra_env`; injected `*KEY*`/`*TOKEN*`/`*SECRET*` host vars absent (spike env-check parity) |
| 3 | echo 10k frames | zero framing errors |
| 4 | escaping fuzz | ≥1000 adversarial strings byte-identical (Gambit canonical profile); invalid escapes loud |
| 5 | frame cap both sides | clean rejection, image survives |
| 6 | redefine → SIGKILL → replay | identical source/value restored |
| 7 | discard / nack | committed restored; unknown name nacked, image alive |
| 8 | commit probe + staged flip; failure paths | no orphan dirs; suspect quarantine incl. apply/check error; infra failure = retry once then `CommitUnavailable` with pending set intact; rejected commit leaves live image unchanged but excluded from replay |
| 9 | watchdog kill → reload + in-flight disposition | committed state, journal intact; in-flight request fails once with `ImageRestarted`, no transparent retry, no duplicate side effect |
| 10 | inspect | committed/pending/unknown statuses |
| 11 | ports | provider.call/tool.invoke through fake ports; absent port nacks; single-write append property (H2); shipped `fsReadPort` containment incl. `..`/absolute/symlink tricks via dirfd (H3) |
| 12 | build route + identity | `buildImage()` discovers gsc via gxi (never PATH), produces a booting binary answering the self-id handshake; a stale/foreign binary at the path → `ImageUnavailable`; rebuild byte-size identical (sha256 reproducibility recorded as on-host observation, not a gate) |
| 13 | stop discipline | doctored image ignoring quit and EOF → SIGKILL after `deadline_ms`; `deinit` never hangs |
| 14 | crash discipline | doctored image throwing at top level → diagnostics on stderr (bounded), nonzero exit, stdout frame stream unpolluted |

## 11. Non-goals (v1)

Real provider wiring (zag-live-003), coding-agent surfaces (zag-live-002),
multi-worker, durable macros, vault, OS-sandbox claims, TUI, any maturity
row, off-host (Linux) portability claims for the compiled image.

## 12. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| Phase H / SDK / headless | untouched; zag-live is additive and default-off downstream |
| D-010 | follows E2 supervision direction; is **not** an extension tier; child env is explicit allowlist per E2's minimal-env rule |
| D-011 | no Core changes; integration via coding-agent only |
| D-015 | runtime binding: Gambit image (gsc-exe compiled / gxi interpreted); Chez retired from product path |
| [live-policy-layer.md](./live-policy-layer.md) | **needs sync at zag-live-004** (B2): `ChezUnavailable` → `ImageUnavailable`, `chez_path` → `.image` config, `Config.base_source` confirmed in §4 sketch. The rename is a deliberate breaking change — no shipped consumers, zag-live-002 held. Owned by the port task |
| process-supervisor | owns coding-agent tool children; zag-live owns its image child directly as a documented L2 exception (§2) |
| packaging | L2 domain service; depends on `zag-types` only; no network |
| spikes/live-runtime | evidence + playground + comparison harness (keeps both runtimes); product code is a clean promotion |
