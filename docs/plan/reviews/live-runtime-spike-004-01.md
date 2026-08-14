# Review: live-runtime-spike-004 — independent verification (Gerbil runtime comparison)

- Task: [live-runtime-spike-004](../tasks/live-runtime-spike-004.md)
- Claims: [spikes/live-runtime/RESULTS.md](../../spikes/live-runtime/RESULTS.md) round 5
- Track: independent verify (read-only; reviewer verified spikes 001–003 and
  the zag-live package previously)
- Host: macOS aarch64, Zig 0.16.0, Chez 10.4.1, Gerbil 0.18.1_1 (Gambit
  4.9.5), moderate load
- Result: **pass** — zero blocking; 3 P3 non-blocking

## Probe matrix (independent runs, full suite × 3 runtimes)

| Probe | Chez (theirs/mine) | gxi (theirs/mine) | gsc-exe (theirs/mine) |
|-------|--------------------|--------------------|------------------------|
| boot median | 54.15 / **52.48 ms** | 56.47 / **60.55 ms** | 4.13 / **5.95 ms** |
| boot min/max | 45.62–68.32 / 47.76–57.92 | 54.02–65.89 / 54.73–87.05 | 4.00–11.47 / 4.57–**430.29**¹ |
| echo 10k | 1872 / **1577 msgs/s** | 1801 / **1534 msgs/s** | 1384 / **1205 msgs/s** |
| fuzz 1500 byte-identical | PASS / PASS | PASS / PASS | PASS / PASS |
| redefine → SIGKILL → replay | PASS / PASS | PASS / PASS | PASS / PASS |
| discard + nack | PASS / PASS | PASS / PASS | PASS / PASS |
| commit incl. F9 quarantine | PASS / PASS | PASS / PASS | PASS / PASS |
| watchdog (after-commit + clean) | PASS / PASS | PASS / PASS ×2 | PASS / PASS ×2 |
| env-check (2 injected fakes) | PASS / PASS | PASS / PASS | PASS / PASS |
| kernel.inspect | PASS / PASS | PASS / PASS | PASS / PASS |
| agent (scripted, mid-turn kill) | PASS / PASS | PASS / PASS | PASS / PASS |
| interactive | PASS / full smoke ✓ | PASS / full smoke ✓ | PASS / `:quit` ✓ |

¹ one 430 ms first-spawn outlier (cold exec cache); median is the honest
figure. Boot claims reproduce: gsc-exe is ~**9–13×** faster than Chez
(mine: 52.48/5.95 ≈ 8.8×; theirs 13×). Echo ~25–35% below Chez — same
order, irrelevant at model latency, as claimed.

## Adversarial checks

**(a) Nasty strings through the Gerbil image (own harness, piped
interactive, byte-wise independent escaper using UPPERCASE `\xHH;`):** all
8 reviewer payloads byte-identical via in-image reconstruction from byte
codes (`string-length` + `string=?`): literal `\x41;` as data, lone
backslash+quote, NUL, DEL, raw control bytes, multibyte UTF-8, escape-junk
(`\\x0;\xZZ;\;`), ~4 KB mixed blob (2917 chars), newline/CR/tab/NUL mix.
The lowercase profile claim verified on the wire: the image's own `write`
of byte 31 is `"\x1f;"`. Gambit's reader accepts my uppercase encodings —
the decode-both-cases discipline holds in both directions.

**(b) EOF hazard — does NOT reproduce in the shipped configuration** on
this host/Gambit build:
- empty stdin from start: clean exit 0 (gsc-exe and gxi)
- EOF after 1 frame ×3 each: clean exit 0
- EOF after 20 frames ×10 (gsc-exe): 10/10 clean exits, no CPU spin
- torn frame (header promises 100 B, 10 delivered, EOF): exit 70 via the
  top-level catcher — the `zero-byte read` guard in `read-exact` works
- interactive `:quit` under gerbil-bin (the supervisor's
  close-stdin-and-wait path): clean exit 0

The reported spin was scoped to configurations the final image avoids
(exported `main`; plain top-level script + `current-input-port` is used
deliberately). The hazard may be real in those configurations, but the
shipped image does not hit it in 15+ trials here; and no supervisor path
depends on polite EOF (kill paths are SIGKILL). Mitigation adequacy:
adequate defense-in-depth — with one honesty gap, see F1.

**(c) gxc-vs-gsc claim — confirmed firsthand.** Minimal module
(`/tmp/gxc-probe`): gxc-compiled binary → `(eval '(kernel.probe)
(interaction-environment))` = **Unbound variable**, backtrace shows the
namespaced `probe#main` — eval invisibility is real and fatal for a live
image. Same source as raw Gambit via gsc -exe → prints 42. The gxc build
also hits the reported openssl@3/3.2.1 link-path failure firsthand; the
documented `-ld-options` workaround builds fine. `gsc -exe` is Gambit's
documented primary route for standalone executables ([Gambit manual
§3.4.1](https://gambitscheme.org/4.6.2/manual/): "the simplest way to
create an executable program is to invoke gsc with the '-exe' option") —
a supported, stable path, not a hack.

**(d) Build reproducibility:** deleted `runtime-gerbil-bin`, rebuilt via
`live-probe build-gerbil-bin` → byte-size-identical (129760 B). gsc
resolution via `path-expand "~~bin/gsc"` works (PATH's `gsc` is indeed
Ghostscript here — verified: the collision claim is real on this host).

**(e) Chez regression after the codec-profile refactor** (`escStr`):
fuzz / commit / agent re-run under default runtime — all PASS.

**(f) Interactive full smoke under gxi:** bare-text turn → live
`system-prompt` redefine (provider echo proves `G-POLICY` on the next
turn) → `:kill` → history rebuilt (4 entries) → clean `:quit`; store
conforms (seq 0–3, echo flip at entry 3).

## Findings

### F1 — P3, non-blocking: `kernel.quit` is never sent by the supervisor

- Location: RESULTS.md round 5 ("the supervisor sends it before closing
  stdin") vs `src/main.zig` `Scheme.shutdown` (main.zig:419-426) — closes
  stdin bare; grep finds no quit-frame send anywhere supervisor-side.
  `kernel.quit` exists in both images (runtime.ss:194,
  runtime-gerbil.ss:161) but is dead code on the wire.
- Harmless today (bare EOF exits cleanly in all my trials; kill paths are
  SIGKILL), but the RESULTS sentence overstates the mechanism. Either send
  the frame in `shutdown` or correct the sentence.

### F2 — P3, non-blocking: RESULTS.md formatting artifact

Line 436: `## Findings / surprises## Findings / surprises` — duplicated
header from the round-5 append. Cosmetic.

### F3 — P3, non-blocking: EOF-spin claim should be narrowed in the record

The round-5 text says the spin was observed with "gsc exe on EOF after
frames" — not reproduced in 13 trials of exactly that configuration here.
Likely configuration/timing-dependent (Gambit build flags, timing). The
final record for D-015 should mark it "observed in pre-port
configurations, not in the shipped image; mitigation retained as
insurance" rather than a live hazard. No code change needed.

## Isolation

`git status --porcelain`: `spikes/live-runtime/` additions only (plus the
expected docs from prior tasks). The built `runtime-gerbil-bin` is covered
by the spike's `.gitignore` ✓. `packages/` untouched — zag-live stays on
Chez per the task's forbidden list.

## Conclusion

**pass.** The full probe matrix reproduces under all three runtime
configurations (10/10 × 3, including the hardest probes: commit
quarantine, watchdog reload, mid-turn kill recovery, agent loop); the
headline numbers reproduce within load variation (gsc-exe boot ~5 ms vs
Chez ~52 ms); the two load-bearing semantic claims (gxc eval invisibility,
Gambit lowercase hex profile) are confirmed firsthand; the EOF hazard does
not manifest in the shipped configuration and no supervisor path relies on
it. Findings are P3 record-keeping only.

**Reviewer read on gsc-exe attractiveness vs risk** (input to D-015):
attractive and real — ~10× boot makes respawn-after-kill effectively
invisible, a single static binary removes the runtime-discovery failure
class, and the build route is upstream-supported. The costs are honest
ones: two image sources to keep in lockstep (runtime.ss /
runtime-gerbil.ss), and the viable compiled path is *raw Gambit* semantics
(gsc), not Gerbil's module system — so "switch to Gerbil" in practice
means "switch to Gambit with Gerbil's toolchain mostly unused," which
weakens the ecosystem argument that motivated Gerbil over plain Gambit.
The two absorbed quirks (EOF insurance, getenv shadow) are contained in
the image and verified. Reasonable D-015 shape: keep Chez as the default
product runtime (already shipped, frozen, reviewed), and hold gsc-exe as
the designated candidate for the fast-respawn/recovery-image role pending
a portability check of the compiled binary off the build host.
