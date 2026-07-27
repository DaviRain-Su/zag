---
id: ci-hang-sigint-linux-errno-001
scope: product/cli-interaction
status: done
priority: P0
depends-on:
  - cli-sigint-001
---

# objective

Make Linux SIGINT self-pipe reads terminate under curl-linked libc by decoding
raw `std.os.linux` syscall returns with **kernel errno semantics**
(`std.os.linux.errno`) rather than libc-backed `std.posix.errno`.

Audit and correct every sibling raw Linux `pipe2` / `read` / `fcntl` errno
decoder in `packages/zag-cli/src/sigint.zig`. Add focused regression evidence
that raw Linux `EAGAIN` is decoded as would-block **independently of
`link_libc`**, and that an empty nonblocking wake-pipe drain terminates.

Preserve:

- `zag-cli` signal ownership and the thin Core cancel-flag boundary;
- idle first SIGINT exit `0`;
- second pending SIGINT exit `130`;
- std / curl backend capability truth;
- all existing safety and maturity claims.

Do **not** fix or hide the separately tracked idle process-fixture timeout, and
do **not** add CI timeout/concurrency in this node.

Binding behavior remains [CLI interaction contract](../../modules/cli-interaction.md)
(extended by this task for raw-Linux errno decoding).

`ci-hang-sigint-linux-errno-001` closed at `bc737025` after contract
`b56b238`, implementation, independent review-fix PASS (zero blockers),
ff-only local main advance, and merged-main local macOS dual-backend Gate.
Maturity is **unchanged**. This node does **not** close the broader Linux
reliability goal: no fresh post-fix remote Linux runner ran in the closeout
session; separately planned process-idle fixture work, CI fuses, and a final
merged-path Linux dual-backend Gate remain required before prompt-templates
work.

# context

## Bug (verified)

1. `attachCurl` sets `link_libc = true` on curl-linked modules and product test
   artifacts that import the curl path (`build.zig` / package `attachCurl`).
2. Product `sigint.zig` intentionally invokes **raw** `std.os.linux.*` on Linux
   (no product `link_libc` force from this module; see cli-sigint-001 review
   item 1).
3. Those raw returns were previously passed to `std.posix.errno(rc)`.
4. In Zig 0.16, `std.posix.errno = system.errno`, and
   `system = std.c` whenever `builtin.link_libc` is true (or on always-libc
   platforms). `std.c.errno(rc)` treats only `rc == -1` as error and otherwise
   returns `.SUCCESS`.
5. Kernel raw encoding returns errors as negative errno cast to `usize`
   (e.g. `-EAGAIN` is a large unsigned value, **not** `-1`). Under
   libc-backed `posix.errno`, that is misclassified as `.SUCCESS`.
6. `sys.read` then `@intCast(rc)` on the huge value and returns it as a
   successful byte count. `drainWake` loops until `got == 0`, so a would-block
   empty nonblocking pipe never terminates → hang under curl-linked Linux
   artifacts (and any future product path that both uses raw Linux syscalls
   and links libc).

False comment previously in source (corrected by implementation):

> `std.posix.errno(rc)` normalises both [raw Linux and libc].

That is true **only** when `link_libc` is false on Linux. With `link_libc`,
`posix.errno` is libc semantics and must **not** be applied to raw kernel
return values.

## Out-of-scope hang (separately tracked)

The idle process-fixture timeout (bounded wait for `you>` / child exit under
the process fixture) remains a **separate** bounded failure if it still
reproduces. This task must not skip, soften, lengthen, or claim-fixed that
fixture without independent evidence. No `.github` workflow change and no CI
timeout/concurrency knobs.

Separately planned follow-ons (not authored as task files yet; no links):

- `ci-hang-sigint-process-idle-001` — idle process-fixture reliability;
- `ci-hang-ci-fuses-001` — CI timeout/concurrency fuses;
- final merged-path Linux dual-backend Gate (fresh remote Linux runner after
  those nodes).

These remain **required** before treating broader Linux SIGINT reliability as
closed and before prompt-templates work. This errno node alone does not
satisfy them.

## References

- `docs/modules/cli-interaction.md` (**binding**)
- `docs/plan/tasks/cli-sigint-001.md` (closed M0 lifecycle)
- `docs/modules/sdk-contract.md` (Agent cancel flag only)
- `docs/modules/headless-contract.md` (exit `11` / hard `130` truth)
- `docs/modules/zag-ai-provider.md` (std vs curl control truth)
- `docs/decisions/active/D-011-thin-agent-core-boundary.md` (CLI owns SIGINT)
- `build.zig` `attachCurl` / `sigint_process_tests.link_libc = true`
- Live source: `packages/zag-cli/src/sigint.zig` (`sys` block)
- Zig 0.16 std: `std.posix.system` / `std.posix.errno` /
  `std.os.linux.errno` / `std.c.errno`

# path

## Docs (contract + closeout)

- `docs/plan/tasks/ci-hang-sigint-linux-errno-001.md` — this task
- `docs/modules/cli-interaction.md` — binding errno + drain contract extension
- status truth only: `docs/plan/README.md`, `docs/modules/README.md`,
  `docs/roadmap.md` (M0 follow-on note; no maturity raise)

## Implementation (`packages/zag-cli/src/sigint.zig`)

- `packages/zag-cli/src/sigint.zig` only for product errno decode + comment fix
  and unit regressions under `builtin.is_test` (or adjacent focused test
  surface already owned by zag-cli)
- **no** switch of Linux product paths to libc wrappers
- **no** Core / coding-agent / provider / headless / session / Trace changes
- **no** `.github/**` workflow edits
- **no** prompt-templates or maturity edits
- **no** unrelated `.gitignore` change
- process fixture may gain **no** softened bounds; optional extra unit
  evidence is preferred over process-fixture rewrites

# contract

The module doc is authoritative. Summary of binding rules for this node:

## 1. Ownership

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-cli` (`sigint.zig`) | SIGINT handler, self-pipe, interruptible stdin read, raw Linux syscall shims, process exit UX | Agent cancel semantics beyond binding a `*Flag`; HTTP backends |
| `zag-agent-core` | atomic `CancelFlag` only | signal handlers, self-pipe, exit codes |
| SDK / coding-agent | product run surfaces | process signal installation by mere Agent construction |
| Test-only process fixture | host-native libc process control (`waitpid`/`kill`) | product Linux non-libc claim |

Ownership, one-shot install, idle exit `0`, second pending exit `130`, backend
truth, and build-runner boundary from `cli-sigint-001` / module remain
unchanged.

## 2. API / lifetimes (unchanged surface)

- Public surface stays `Guard.install` / `deinit` / `pendingInterrupt` /
  `acknowledgeCancel`, `readInterruptibleLine`, `LineBuffer`, `IdleRead`.
- Self-pipe remains process-lifetime, NONBLOCK + CLOEXEC both ends, never
  closed by `deinit`.
- Handler remains async-signal-safe (atomics + optional `Flag.request` + raw
  one-byte write + raw hard exit). No allocation, logging, formatting, or
  buffered I/O in the handler.
- `testing.resetForTesting` remains test-only and `@compileError` in product.

## 3. Defaults

- Product Linux path: raw `std.os.linux` syscalls (no product `link_libc`
  forced by this module).
- Product macOS/BSD path: libc (`std.c`) return + errno semantics.
- Curl backend may link libc via `attachCurl`; errno decode on raw Linux
  results must still be correct when that flag is true.
- Defaults for permission (`ask`), workspace jail, and shell protect are
  unchanged and out of path.

## 4. Transaction order (errno decode)

For **every** raw `std.os.linux` call in the local `sys` block that previously
passed its `usize` result to `std.posix.errno`:

1. Invoke `std.os.linux.<syscall>(...)`.
2. Decode with **`std.os.linux.errno(rc)`** (kernel signed-window semantics:
   values in `(-4096, 0)` are errno; otherwise success payload).
3. **Never** pass that raw `usize` to `std.posix.errno` / `std.c.errno` when
   the call was raw Linux, regardless of `builtin.link_libc`.
4. Libc/macOS/BSD branches keep libc return conventions (`c_int` / `-1` +
   thread errno, or existing `std.c` patterns already in file).

### Exact audit list (must all use kernel decode on Linux)

| Site | Syscall | Success | Would-block / retry | Failure |
|------|---------|---------|---------------------|---------|
| `sys.pipe` | `pipe2` | `.SUCCESS` → return fds | n/a | else → `error.PipeFailed` |
| `sys.read` | `read` | `.SUCCESS` → return `@intCast(rc)` **only after SUCCESS** | `.INTR` → loop; `.AGAIN` → return `0` | else → `error.ReadFailed` |
| `sys.setCloexec` | `fcntl` GETFD/SETFD | `.SUCCESS` | n/a | any non-SUCCESS → fail `true` |
| `sys.setFlagStatus` | `fcntl` GETFL/SETFL | `.SUCCESS` | n/a | any non-SUCCESS → fail `true` |

`write` / `close` / `exit_group` remain fire-and-forget or noreturn; no errno
branch required beyond existing intentional ignore.

## 5. Errors

| Condition | Result |
|-----------|--------|
| Nonblocking empty read (`EAGAIN` / `EWOULDBLOCK` as Linux `E.AGAIN`) | `sys.read` returns `0` (not success byte count, not `ReadFailed`) |
| `EINTR` on read | internal retry loop (no recursion) |
| Unexpected read errno | typed `error.ReadFailed` |
| pipe2 / fcntl failure | existing `PipeFailed` / bool fail paths |
| Idle SIGINT path | `IdleRead.interrupted` → process exit `0`; never surface `ReadFailed` stack for expected wake |
| Second pending SIGINT | hard exit `130` |

`drainWake` must terminate when the wake pipe is empty: loop while
`sys.read` returns `> 0`; stop on `0` or `ReadFailed` (current catch-return
shape preserved: drain is best-effort).

## 6. Safety

- No relaxation of ask / workspace jail / shell protect.
- No secret/path leakage in fixtures.
- No reintroduce of teardown→reinstall ABA; one-shot install stays.
- Handler stays async-signal-safe.
- Do not route Linux product signal machinery through libc solely to paper
  over the errno mismatch.

## 7. Budgets

- Wake drain buffer remains small fixed stack buffer (current 64-byte class).
- No new unbounded heap in signal path.
- Unit regressions must be bounded and deterministic (no multi-second sleeps
  as sole correctness proof).

## 8. Compatibility

- Preserve std vs curl backend truth (std cooperative-only at documented
  boundaries; curl may actively cancel).
- Preserve headless cancelled exit `11` on observed cooperative cancel;
  hard second interrupt remains `130` without protocol terminal promise.
- Preserve Linux non-libc product claim: product `sigint.zig` does not force
  `link_libc`; only host-native process fixture links libc explicitly for
  process control.
- Zig 0.16 API names as above; no maturity row change.

## 9. Non-goals

- Fixing/hiding/softening the separately tracked idle process-fixture timeout.
- CI workflow timeout, concurrency, or runner changes (`.github/**`).
- Switching Linux product paths to libc `read`/`pipe`/`fcntl`.
- Mid-flight Tool/shell preemption; std HTTP active cancellation redesign.
- Prompt Templates, TUI, maturity raise, schema/Trace/headless field changes.
- Unrelated `.gitignore` or packaging refactors.
- Claiming build-runner process-group normalization.
- Closing broader Linux reliability without process-idle, CI fuses, and a
  fresh post-fix remote Linux dual-backend Gate.

## 10. Executable fixtures (implementation Gate)

| # | Fixture | Binding assertion |
|---|---------|-------------------|
| F1 | Pure raw-Linux errno decode unit | A synthetic raw `usize` encoding of kernel `-EAGAIN` (and at least one other negative errno if convenient) decodes via the **same helper/path product code uses** as `.AGAIN` / non-SUCCESS **with the test artifact both std-linked and curl-linked** (`link_libc` true and false). Must not depend on host `errno` thread state. Runnable in both `-Dhttp_backend=std` and `-Dhttp_backend=curl` test artifacts. |
| F2 | Empty nonblocking wake-pipe drain | On Linux (or Linux-semantics unit path), a NONBLOCK pipe with no data: `drainWake` / `sys.read` returns promptly with `0` / terminates the drain loop; no hang within a tight bound. |
| F3 | Pending-interrupt regression retained | Existing unit: first signal → pending + wake; `readInterruptibleLine` returns `.interrupted`; acknowledge restores idle; second-signal predicate remains handler state not programmatic flag alone. |
| F4 | Focused zag-cli SIGINT tests | Existing install/one-shot/nested-reject/line-retain/pending-wins-over-retained tests remain green. |
| F5 | Full dual-backend root Gate | `zig build test -Dhttp_backend=std --summary all` and `zig build test -Dhttp_backend=curl --summary all` pass for this node's implementation closeout. Pre-existing idle process-fixture timeout, if still red, is reported as **separate** and not marked fixed here. |
| F6 | Docs Gate | `zig build docs-lint`; `git diff --check` on committed range; no maturity inflation. |

F1 is the primary regression against the curl-linked hang class. F2 proves
`drainWake` cannot spin on empty NONBLOCK. F3–F4 protect lifecycle truth.
F5 is full suite honesty without hiding fixture debt.

# verification

## Docs Gate (complete)

- [x] Binding module extension + task authored before production code
- [x] Independent contract review (reconciled at closeout)
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] `git diff --check`
- [x] Explicit `git add` of intended docs files only
- [x] One local docs commit on `task/ci-hang-001` (closeout)

## Implementation Gate (complete)

- [x] F1 pure raw-Linux errno regression green under std **and** curl test artifacts
- [x] F2 empty nonblocking drain terminates
- [x] F3–F4 pending-interrupt + focused SIGINT suite green
- [x] F5 full std + curl `zig build test --summary all` (candidate + merged-main local macOS host)
- [x] False `posix.errno` normalization comment removed/corrected
- [x] Every audited Linux raw site uses `std.os.linux.errno` via `linuxRawErrno` only
- [x] No Linux product path switched to libc; no CI workflow edit; no maturity raise
- [x] Independent code review + ff-only merge + merged-main local Gate before `done`

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | `docs/modules/cli-interaction.md`; candidate contract commit `b56b238db19116899f78af9bb71cf78844084fe9` |
| Task | this file `done` at `bc737025` (+ docs closeout) |
| Implementation | `packages/zag-cli/src/sigint.zig` — `linuxRawErrno` on pipe2/read/fcntl sites; tip `bc737025b4ce733e83de9c13f7afede7e6e2a3e6` |
| Fixtures F1–F4 | F1 + F2 unit tests in `sigint.zig`; pure raw-Linux decoder regression ran in both std and curl-linked test artifacts; F3–F4 retained suite green |
| Review | independent review-fix **PASS**, zero blockers |
| Candidate Gate | std **611/611**; curl **610/610**; docs lint + score readability **91** / security **72**; committed-range diff clean |
| Merge | coordinator ff-only advanced local main `3cd0837` → `bc737025` while preserving unrelated canonical `.gitignore`; **no push** |
| Merged-main Gate (local macOS) | std **40/40 steps, 611/611 tests**; curl **42/42 steps, 610/610 tests**; OpenAPI **287/287**; catalog **40**; docs lint; readability **91**; security **72**; committed-range diff clean |
| Maturity | **unchanged** — no L2/L3 claim added |
| Not claimed | fresh post-fix remote Linux runner; process-idle fixture; CI fuses; broader Linux reliability close |

# non-goals (task boundary)

See §9. No CI workflow, process-fixture bound softening, or maturity raise.
Broader Linux reliability and prompt-templates remain outside this node.

# closeout

- Contract candidate: `b56b238db19116899f78af9bb71cf78844084fe9`.
- Implementation tip: `bc737025b4ce733e83de9c13f7afede7e6e2a3e6`
  (`linuxRawErrno` / `std.os.linux.errno` on audited pipe2/read/fcntl sites;
  F1/F2 unit fixtures).
- Independent review-fix: **PASS**, zero blockers.
- Candidate dual-backend Gate: std **611/611**, curl **610/610**, docs
  lint + score **91/72**, committed-range diff clean.
- Coordinator ff-only advanced local main `3cd0837` → `bc737025` while
  preserving unrelated canonical `.gitignore`. **No push** occurred.
- Merged-main local macOS Gate again passed: std **40/40 steps · 611/611**,
  curl **42/42 steps · 610/610**, OpenAPI **287/287**, catalog **40**, docs
  lint, readability **91**, security **72**, committed-range diff clean.
- Pure raw-Linux decoder regression ran in both std and curl-linked test
  artifacts; local host gates passed.
- **Not closed by this node:** no fresh post-fix remote Linux runner was run
  in the closeout session. Separately planned `ci-hang-sigint-process-idle-001`,
  `ci-hang-ci-fuses-001` (idle fixture and CI fuses remain unimplemented /
  planned; task files not yet authored — no links), and the final merged-path
  Linux dual-backend Gate remain **required** before prompt-templates work.
- Maturity unchanged. No `.github`, source, `.gitignore`, quality-score body,
  or prompt-template edits in this closeout.
