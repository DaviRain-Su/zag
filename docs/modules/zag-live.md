# zag-live — supervised live Scheme image

> Binding draft for [zag-live-001](../plan/tasks/zag-live-001.md)
> (D-014 Route A — live policy layer productization).
> Direction: [D-013](../decisions/active/D-013-live-runtime-prototype-track.md)
> + [D-014](../decisions/active/D-014-live-runtime-productization-route-a.md);
> evidence: [analysis](../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md)
> rounds 1–4.
>
> **Status:** **implemented** ([zag-live-001](../plan/tasks/zag-live-001.md)
> done 2026-08-14; 23/23 package tests; reviews pass). Experimental,
> default-off; no maturity claim.
> Review round 1: dual blocked (8 findings), all contract-text; fixed in
> this revision (B1–B4, A1–A4 folded; non-blocking notes marked in-line).

## 1. Purpose

`zag-live` owns a **supervised Chez Scheme subprocess** acting as the
product's live policy layer: runtime-redefinable, kernel-tracked bindings
with journaled audit, declarative generations, and kill/replay recovery.
It lets product code delegate redefinable policy (first: prompt
construction) to a living image without giving the image any trust.

## 2. Boundary

| Owns | Must not |
|------|----------|
| Image lifecycle (spawn/probe/kill/reap), frame protocol, journal, generations, commit probe, watchdog, reference jailed `fs_read` ToolPort helper (§6) | Network I/O; provider credentials; product policy decisions (which surfaces are live is the caller's); general tool execution beyond the shipped reference helper |

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
| `Frame` | length-prefixed s-expr payload, 4-byte LE u32 header | ≤ `max_frame_bytes` (4 MiB); payload valid UTF-8; strings in canonical Chez `write` escaping both directions; decode is strict (unknown escape = hard error) |
| `JournalEntry` | `(redefine \| discard \| suspect <name> <seq> …)` / `(commit <gen> "<hash>" <ts>)` | append-only; **one fsynced write per entry**; a non-conforming **final** line is a torn tail, truncated on read; an unknown kind anywhere earlier is `JournalCorrupt` — **fail closed**, never silently truncate mid-file |
| `Generation` | `base.ss` + `replay.ss` + `meta.sexp` (hash, parent, ts) | staged into `.staging-<n>/`, renamed only after the clean-process probe passes; no orphan dirs (stale staging removed on next start) |
| `Binding` | name → source, status (`committed`/`pending`), generation, dependents (shallow) | only tracked bindings survive replay |
| `Image` | child process handle, liveness deadline | one live image per `Live` instance; spawned with a **scrubbed environment** (§4) |

## 4. Host API (Zig, v1 sketch)

```zig
const Live = @import("zag-live").Live;

var live = try Live.init(gpa, io, .{
    .state_dir = dir,                 // journal + generations root
    .chez_path = null,                // null = discover; boot probe + version floor
    .provider_port = my_provider,     // optional; image provider.call
    .tool_port = my_tools,            // optional; image tool.invoke
    .extra_env = &.{},                // host-controlled additions ONLY; see env rule
    .watchdog = .{ .probe_interval_ms = 1000, .deadline_ms = 2000 },
});
defer live.deinit();

try live.start();                     // spawn + replay current generation
try live.eval("(greeting)");          // host-driven eval; bounded result + host deadline
try live.stop();                      // graceful; kill after budget
```

**Environment rule (B1/A2, binding):** the image is spawned with a fixed
allowlist environment (`PATH`, `HOME`, `TERM`) plus any `extra_env` pairs
the host passes explicitly. The ambient host environment is **never**
inherited. This is the mechanism behind "credentials never enter the
image"; a conforming implementation must prove it (§10 test 2).

**Chez floor (A9):** version ≥ 10.0, verified by boot probe at `start()`.

**Recovery semantics (A4, binding):** on image death (watchdog, crash,
kill) the image is respawned and replayed from `current` generation +
journal. An in-flight host request fails once with `error.ImageRestarted`;
**zag-live never retries host requests transparently** (no duplicate side
effects by construction). The caller may retry idempotent requests. After
restart, new requests run against the replayed state.

## 5. Image-side protocol (kernel primitives)

`(kernel.redefine name source)` · `(kernel.inspect name)` ·
`(kernel.discard name)` · `(provider.call …)` / `(tool.invoke …)` when ports
are registered. `kernel.eval` is a **host→image request**, not an image
primitive (N6).

**Commit (B4, binding):** `(kernel.commit reason)` runs the default recorded
check in the clean probe process — replay completes and every tracked
binding resolves. `(kernel.commit reason check expected)` records a
caller-supplied check expression and expected value, evaluated in the clean
probe process after replay; mismatch **or eval error** rejects the commit.

Semantics as proven in the spike: journal fsync **before** apply; commit =
clean-process replay probe + staged generation + atomic flip; discard
restores the last committed definition; unknown-name discard =
`kernel.nack`.

**Failed-commit disposition (A6/A8, binding):** a rejected commit leaves the
live image unchanged (the change stays installed and exploratory-live), but
the pending entries are journaled `(suspect …)` and excluded from **all
future replay**; the next restart shows the last committed state. After
`CommitUnavailable` (infra failure, see G4) the pending set stays pending
and a later commit may retry.

**Promotion fixes (binding, from spike backlog):**

| Gate | Rule |
|------|------|
| H2 | every journal/state entry append = one fsynced write (no entry/newline split) |
| H3 | the reference `fs_read` ToolPort helper ships **in zag-live** and resolves containment via dirfd-relative open (no realpath-then-open TOCTOU); hosts adopt it or reimplement to the same bar (§10 test 10 gates the shipped helper) |
| G4 | clean-process **infra** failure (spawn/IO error) retries once, then reports `CommitUnavailable`; quarantine is reserved for replay/check failures of the change itself |

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
host duty (N1):** port implementations must bound their own runtime and
reply size (frame cap applies on the wire); the contract has no enforcement
point inside zag-live, so the watchdog covers image-side liveness only and
a hung port is the host's responsibility. Port absence = the corresponding
primitive returns a nack (`PortAbsent` host-side).

Credentials never enter the image: provider auth stays behind the host's
ProviderPort, and the env rule (§4) keeps ambient secrets out of the
child.

**Reference tool helper (A1):** zag-live ships `fsReadPort()` — a jailed
`fs.read` ToolPort implementation (dirfd-relative containment, symlink-safe,
16 KiB output bound). Product hosts wire this helper or an equivalent;
fixture ports in tests verify the port mechanics, and the shipped helper
carries the containment acceptance tests.

## 7. State ownership

All durable state under the caller-provided `state_dir`:
`journal.sexp` (typed, append-only) · `generations/<n>/{base,replay}.ss +
meta.sexp` · `current` pointer file (atomic rename). The package never
writes outside `state_dir`.

**Containment honesty (B2, binding):** the image process retains ambient
filesystem access with user privileges — the process boundary is a
**crash/trust boundary, not an OS sandbox** (consistent with §11). Only the
ToolPort-mediated paths are jailed (§6). Product policy must treat image
code as trusted local code, exactly as it treats `run_shell` output.

## 8. Errors (closed vocabulary)

`ChezUnavailable` · `BootProbeFailed` · `ImageDied` · `ImageRestarted` ·
`FrameTooLarge` · `ProtocolError` · `JournalCorrupt` · `CommitRejected` ·
`CommitUnavailable` · `NotCommitted` · `NothingToCommit` · `PortAbsent` ·
`DeadlineExceeded`.

`JournalCorrupt` semantics (B3): raised only for mid-file corruption; a
torn final line is truncated silently on read and replay proceeds.

The default commit check catches unresolved bindings after replay; errors
that only surface at call time need the 4-arg form
`(kernel.commit reason check expected)` with a real exercising check.

First-line atoms only; no absolute paths, errno strings, or env values leak
into error payloads.

## 9. Extension points

Later surfaces register more tracked bindings (tool registry, memory
policy) without protocol change. Multi-image workers, durable macro
redefinition, and the input vault are separate Gates; none are in v1.

## 10. Tests (acceptance)

Port the spike probe set as package tests against a fixture provider/tool
port (no network):

| # | Class | Expect |
|---|-------|--------|
| 1 | boot + boot probe | bounded startup; version floor enforced; `ChezUnavailable` path clean |
| 2 | child env scrub | child sees only allowlist + `extra_env`; injected `*KEY*`/`*TOKEN*`/`*SECRET*` host vars absent (spike env-check parity) |
| 3 | echo 10k frames | zero framing errors |
| 4 | escaping fuzz | ≥1000 adversarial strings byte-identical; invalid escapes loud |
| 5 | frame cap both sides | clean rejection, image survives |
| 6 | redefine → SIGKILL → replay | identical source/value restored |
| 7 | discard / nack | committed restored; unknown name nacked, image alive |
| 8 | commit probe + staged flip; failure paths | no orphan dirs; suspect quarantine incl. apply/check error; infra failure = retry once then `CommitUnavailable` with pending set intact; rejected commit leaves live image unchanged but excluded from replay |
| 9 | watchdog kill → reload + in-flight disposition | committed state, journal intact; in-flight request fails once with `ImageRestarted`, no transparent retry, no duplicate side effect |
| 10 | inspect | committed/pending/unknown statuses |
| 11 | ports | provider.call/tool.invoke through fake ports; absent port nacks; single-write append property (H2); shipped `fsReadPort` containment incl. `..`/absolute/symlink tricks via dirfd (H3) |

## 11. Non-goals (v1)

Real provider wiring (zag-live-002), coding-agent surfaces (zag-live-003),
multi-worker, durable macros, vault, OS-sandbox claims, TUI, any maturity
row.

## 12. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| Phase H / SDK / headless | untouched; zag-live is additive and default-off downstream |
| D-010 | follows E2 supervision direction; is **not** an extension tier; child env is explicit allowlist per E2's minimal-env rule |
| D-011 | no Core changes; integration via coding-agent only |
| process-supervisor | owns coding-agent tool children; zag-live owns its image child directly as a documented L2 exception (§2) |
| packaging | L2 domain service; depends on `zag-types` only; no network |
| spikes/live-runtime | evidence + playground; product code is a clean promotion |
