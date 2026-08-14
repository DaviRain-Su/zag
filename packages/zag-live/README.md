# zag-live

Supervised live Scheme image (Gambit binding, D-015) — the product's
runtime-redefinable policy layer. A Zig supervisor owns the trust-critical
substrate: frame protocol (canonical Gambit escaping — lowercase `\xhh;`,
4 MiB cap, strict case-insensitive decode; frame-stream purity: image
diagnostics go to bounded stderr + nonzero exit, never stdout), typed
journal (fsync before apply, one fsynced write per entry, torn-tail
tolerance), declarative generations (staged, probe-gated, atomic flip),
kernel primitives (redefine / inspect / commit / discard / nack), watchdog
(probe + deadline + kill/reload), env-scrubbed spawn (allowlist + explicit
`extra_env` only), host-injected ports (`ProviderPort` / `ToolPort`, absent
→ nack) including the shipped jailed `fsReadPort()` helper (dirfd-relative
containment, symlink-safe, 16 KiB bound), and `Live.recover()` /
`needsRecovery()` for replay-fatal state dirs.

**Binding contract:** [`docs/modules/zag-live.md`](../../docs/modules/zag-live.md)
(D-015 revision; tasks `zag-live-001`, `zag-live-004`). Experimental,
default-off; no maturity claim. Depends on `zag-types` only; no network.

## Image spawn forms

The image source ships embedded in the package (plain top-level Gambit;
gxc's module system is deliberately not used — its namespacing hides the
image's kernel primitives from interaction-eval).

- `.interpreted` (default): embedded source via `gxi` (PATH or explicit
  `gxi_path`); version floor Gerbil >= 0.18 checked at `start()`.
- `.compiled`: host-supplied path to a `gsc -exe` binary built from the
  embedded source; verified by the self-id handshake at `start()`
  (stale/foreign binary → `ImageUnavailable`).

```zig
var live = try zag_live.Live.init(gpa, io, .{
    .state_dir = dir,
    .image = .{ .compiled = path }, // or .{ .interpreted = .{} }
});
try live.buildImage();  // writes state_dir/image-bin; gsc discovered via
                        // gxi (path-expand "~~bin/gsc"), never PATH
```

Commit failure dispositions: spawn-stage failures of the clean-process
replay probe — any error class — retry once, then `CommitUnavailable` with
the pending set intact; anything after a successful spawn (replay/apply/
check death or error, value mismatch) is a defect of the change →
`CommitRejected` with the pending entries quarantined as `(suspect …)`.

Stop discipline: `stop()` sends `(kernel.quit)`, waits up to
`deadline_ms`, then SIGKILLs — bounded under quit/EOF-ignoring images
(Gambit's stdin-EOF unreliability never hangs `deinit()`).

## Build / test

```sh
zig build          # builds the zag-live module
zig build test     # unit + acceptance tests (§10 classes 1-14, both spawn
                   # forms; compiled-form tests skip-gated if gsc absent)
```

Tests spawn real images (gxi + a shared gsc-built binary) against temp
state dirs with fixture ports; no network.
