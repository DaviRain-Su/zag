# zag-live

Supervised live Chez Scheme image — the product's runtime-redefinable
policy layer. A Zig supervisor owns the trust-critical substrate: frame
protocol (canonical Chez escaping, 4 MiB cap, strict decode), typed journal
(fsync before apply, one fsynced write per entry, torn-tail tolerance),
declarative generations (staged, probe-gated, atomic flip), kernel
primitives (redefine / inspect / commit / discard / nack), watchdog
(probe + deadline + kill/reload), env-scrubbed spawn (allowlist + explicit
`extra_env` only), and host-injected ports (`ProviderPort` / `ToolPort`,
absent → nack) including the shipped jailed `fsReadPort()` helper
(dirfd-relative containment, symlink-safe, 16 KiB bound).

Commit failure dispositions (M1): spawn-stage failures of the
clean-process replay probe — any error class — retry once, then
`CommitUnavailable` with the pending set intact; anything after a
successful spawn (replay/apply/check death or error, value mismatch) is a
defect of the change → `CommitRejected` with the pending entries
quarantined as `(suspect …)`.

**Binding contract:** [`docs/modules/zag-live.md`](../../docs/modules/zag-live.md)
(task `zag-live-001`, D-014 Route A). Experimental, default-off; no
maturity claim. Depends on `zag-types` only; no network.

Requires Chez Scheme >= 10.0 (`chez` on PATH, or `Config.chez_path`);
verified by a boot probe at `start()`.

## Recovery affordance (`Live.recover`)

A pending (uncommitted) journal entry that kills replay — e.g.
`(kernel.redefine 'evil "(exit)")`, journaled+fsynced before the live apply
dies — otherwise **bricks the state dir**: `start()` fails with
`BootProbeFailed` forever, the watchdog restart loop dies the same way, and
`commit` cannot run without a live image. zag-live never auto-quarantines;
the caller decides:

```zig
var live = try zag_live.Live.init(gpa, io, .{ .state_dir = dir });
live.start() catch |e| {
    if (e == error.BootProbeFailed and live.needsRecovery()) {
        const summary = try live.recover(); // quarantines ALL pending entries
        // summary.quarantined entries journaled (suspect ...), image now
        // running the last committed generation
    }
};
```

`recover()` journals `(suspect <name> …)` for every pending entry (they are
excluded from all future replay), restarts the image from the committed
generation, and returns the quarantine count. `needsRecovery()` is true
when a start/restart died during replay with a non-empty pending set.

## Build / test

```sh
zig build          # builds the zag-live module
zig build test     # unit + acceptance tests (§10 classes 1-11), self-contained
```

Tests spawn real Chez subprocesses against temp state dirs with fixture
ports; no network.

## Shape

```zig
const zag_live = @import("zag-live");

var live = try zag_live.Live.init(gpa, io, .{ .state_dir = dir });
defer live.deinit();
try live.start();                    // spawn + replay current generation
const v = try live.eval("(greeting)"); // bounded result + host deadline
try live.stop();
```
