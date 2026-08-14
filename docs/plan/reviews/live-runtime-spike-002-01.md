# Review: live-runtime-spike-002 — independent verification

- Task: [live-runtime-spike-002](../tasks/live-runtime-spike-002.md)
- Binding: [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) · [D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) · [spike-001](../tasks/live-runtime-spike-001.md) · [review 001-01](./live-runtime-spike-001-01.md)
- Track: independent verify (read-only; did not write this code)
- Verifier host: macOS aarch64, Zig 0.16.0, Chez 10.4.1
- Result: **pass** (zero blocking findings; 4 P3 non-blocking, all hygiene)

Scope: protocol hardening (F5/F6 from review 001-01), `kernel.inspect`,
commit-path correctness (F8/F9), typed journal schema. I rebuilt and re-ran
the full suite — the original 7 probes plus `fuzz` and `inspect` — and ran
my own adversarial escaping tests independent of the developer's fuzz
generator (piped through `live-probe interactive`, no files created).

## Checklist verdicts

| # | Checklist item | Verdict |
|---|----------------|---------|
| 1 | Escape round-trip ≥1000 strings, byte-identical | **PASS** — fuzz: 1500/1500 byte-identical; plus my own 8/8 adversarial payloads (below) |
| 2 | Frame cap both sides; oversize rejected cleanly | **PASS** — image discards 4 MiB+64 B inbound, replies `(err "frame-too-large")`, stays alive; supervisor rejects 5 MB image reply, kills+respawns, keeps working (`max_frame_bytes`/`max-frame-bytes` = 4 MiB, named both sides) |
| 3 | `kernel.inspect` committed/pending/unknown | **PASS** — source + status + generation + shallow dependents verified for all three states, incl. reverse-dependent appearing on the depended-upon name |
| 4 | Journal conforms to typed schema (all four writers) | **PASS** — awk-validated every line of two independent journals against the four typed forms; `(commit <gen> "<hash>" <ts>)` hash matches gen meta.sexp exactly |
| 5 | F8: no orphan generation dir on failed commit | **PASS** — after failed commit `.work/generations/` holds only `0 1`; no `2`, no `.staging-2` (staging-dir pattern, renamed only after probe pass) |
| 6 | F9: apply/check **error** also quarantines | **PASS** — apply-error covered by probe (`(suspect broken-mal ...)`); I additionally exercised the check-eval-error path live (below) |
| 7 | Original 7-probe suite still passes | **PASS** — boot/echo/redefine-cycle/discard/commit/watchdog×2/env-check all green |
| 8 | Findings appended to analysis doc | **PASS** — "Spike findings (2026-08-14)" section present with results table + two design notes (suspect quarantine required; journal dual-role) |

## My independent adversarial escaping tests (beyond `fuzz`)

Drove `live-probe interactive` with piped input; each payload was defined
from a string literal and independently reconstructed inside the image via
`(utf8->string (bytevector ...))` from raw byte codes, then compared with
`string=?`. An initial mismatch on 2 cases was **my own harness bug**
(`chr(b)` double-encoding UTF-8) — the spike had round-tripped faithfully.

| Payload | Result |
|---------|--------|
| `\x41;` as literal DATA (5 chars) | byte-exact |
| lone backslash before quote (`\` + `"`) | byte-exact |
| NUL + DEL | byte-exact |
| raw control bytes 0x01 0x02 0x1F 0x7F in the literal | byte-exact |
| multibyte UTF-8 (`λ≈∑π 🚀 混合`) | byte-exact |
| escape-junk as data (`\\x0;\xZZ;\;`) | byte-exact |
| ~4 KB mixed blob (quotes/backslashes/control/UTF-8/DEL) | byte-exact (4000 B / 2960 chars) |
| newline + CRLF + tab + NUL mix | byte-exact |
| `"\e"` (unknown escape) | **loud** Chez reader error — rejected, not mangled |
| `"a\xZZ;b"` (malformed hex escape) | **loud** reader error |

Encoding discipline confirmed symmetric with Chez `write` by code
inspection (`escapeSchemeString`/`parseSchemeString`, main.zig:142-236):
named escapes + `\xHH;` uppercase minimal hex, bytes ≥ 0x80 raw,
strict decode (`UnknownEscape`/`BadHexEscape` are hard errors).

## F8/F9 closure evidence

- **F8**: `doCommit` stages into `generations/.staging-<n+1>/`, renames
  only after the replay probe passes, `defer deleteTree` on failure
  (main.zig:997-1039). Verified on disk after both failure runs.
- **F9**: `defer if (!success) journalSuspect(...)` armed immediately after
  the pending set is known (main.zig:978-981), so every error exit —
  staging failure, clean-spawn failure, apply error, check-eval error,
  value mismatch — quarantines. Probe covers apply-error
  (`(define (broken-mal` journal-side); I covered **check-eval error**
  live: pending `greeting` + `(kernel.commit "(does-not-exist)" "x")` →
  `(suspect greeting ...)` journaled, `#f` returned, pointer stayed 0,
  pending set emptied, no orphan dir.

## `<ns>` interpretation (task-table judgment)

The developer read `<ns>` as the entry's 0-based sequence number
(`journalSeq` = current line count). **I agree this is reasonable, not a
deviation**: the table carries `<ts>` as a separate field, so `<ns>` cannot
mean nanoseconds; a per-entry monotonic sequence serves exactly the
ordering/identity intent of the schema (replay fold order). Verified
conforming: seq equals the 0-based line index across redefine/discard/
suspect entries; commit keeps `<gen>` as its own key. Non-blocking.
(Note for promotion: `journalSeq` re-reads and re-validates the whole
journal per append — O(n²) appends; fine at spike scale.)

## Findings (all P3, non-blocking)

- **G1 — Dependents list can duplicate.** `composeInspect` appends from the
  base.ss scan, the replay.ss scan, and the pending scan without dedup
  (main.zig:899-917); a define present in both base and replay that
  mentions the target would be listed twice. Code-read only; not triggered
  by the probes.
- **G2 — Error text shows raw Chez format placeholders.** `condition->string`
  surfaces `~? at char ~a of ~s` templates (seen in commit/fuzz probe
  output and my `\e` test). Cosmetic; the irritants list carries the real
  detail.
- **G3 — `runtime.ss` comment drift.** The `kernel.inspect` comment
  (runtime.ss:244-246) describes a dotted-pair alist `((source . ...) ...)`;
  the actual wire format is 2-element lists `((source ...) (status ...) ...)`.
  Doc nit only.
- **G4 — Quarantine also fires on supervisor-side infra failure.** The F9
  defer quarantines the pending set even if the failure is, say, a
  clean-process spawn error rather than a defect in the change itself.
  Conservative and safe-direction for the spike; promotion should decide
  whether infra failures should quarantine or retry.

## Isolation

`git status --porcelain`: only `spikes/` (untracked), the two task files,
the review files, D-013, the analysis doc, and the known docs edits
(`docs/INDEX.md`, `docs/decisions/README.md`, `docs/plan/README.md`,
`docs/plan/analysis/README.md`, `docs/plan/backlog.md` — referenced by the
task file itself, `docs/quality/*`). Nothing under `packages/`, root
`build.zig`/`build.zig.zon`, `.github/`, `docs/maturity.md`, `chapters/`.

## Independent measurements vs RESULTS.md (round 3)

| Probe | RESULTS.md round-3 claim | My run | Match |
|-------|--------------------------|--------|-------|
| boot (median) | 40.69 ms | **39.39 ms** (min 38.86, max 43.25) | yes |
| echo 10k | 1914 msgs/sec | **1914 msgs/sec**, 0 errors | yes |
| redefine-cycle | PASS | PASS (byte-identical source) | yes |
| discard + nack | PASS | PASS | yes |
| commit + F2/F8/F9 assertions | PASS, no orphan, typed journal | PASS, exit 0; journal and dirs verified on disk | yes |
| watchdog after commit (no reset) | reload `hacked` | reload `hacked`, journal 6 lines intact | yes |
| watchdog (clean) | PASS | PASS (2001 ms deadline) | yes |
| env-check | PASS | PASS (9 sensitive names all `#f`) | yes |
| fuzz | 1500/1500 byte-identical, caps both sides | **1500/1500**, both oversize directions handled | yes |
| inspect | PASS | PASS (all three states + dependents) | yes |
| my adversarial strings | — | 8/8 byte-exact; `\e`/`\xZZ;` loud errors | n/a |
| F9 check-eval-error | (probe covers apply-error) | verified live: suspect journaled, pointer kept | extends claim |

## Conclusion

**pass.** Every checklist item verifies independently, including both
halves of F9 (apply-error via probe, check-error via my own live drive),
the F8 no-orphan guarantee on disk, and the typed journal schema
(structural validation + hash cross-check). The escaping discipline is
genuinely symmetric and strict: arbitrary model-producible payloads
round-trip byte-identically and malformed escapes fail loudly. The `<ns>`
→ sequence-number reading is accepted. Remaining items are P3 hygiene
(G1–G4) for the promotion track, none blocking spike-003.
