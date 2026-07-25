---
id: cli-repl-001
scope: product-cli/repl-input
status: ready
priority: P1
depends-on: []
---

# objective

Fix the interactive `zag` REPL so one newline-submitted question does not cause the next iteration to observe the same delimiter as an empty line and exit. One `coding.Session` must accept multiple non-empty user turns until the user submits an empty/whitespace-only line or stdin reaches EOF.

This is a product-CLI input-boundary correction. It does not change Agent/Provider/session schemas, permission defaults, headless/SDK contracts, or Phase H file-surface status.

# root cause and contract

Zig 0.16 `std.Io.Reader.takeDelimiterExclusive('\n')` advances only through bytes before the delimiter and deliberately leaves `\n` buffered. The current persistent REPL reader therefore returns the first line, then returns an empty line for the same delimiter on the next iteration. That empty line triggers the documented exit path.

The REPL line reader must consume exactly one submitted newline. Use the Zig 0.16 API whose contract consumes the delimiter (`takeDelimiter`) or an equivalently explicit implementation; do not manually discard an unknown buffered byte after an error.

## input semantics

- `first\nsecond\n\n` submits `first`, then `second`, then exits on the explicit empty line.
- EOF before any bytes exits normally after the already printed prompt and emits the existing cleanup newline.
- Non-empty final bytes followed by EOF are submitted once, matching Zig `takeDelimiter` and the prior exclusive-reader end-of-stream behavior; the next read observes EOF and exits.
- Leading/trailing spaces, tabs, and `\r` remain trimmed. A whitespace-only or CRLF-empty line exits.
- Input longer than the existing reader capacity remains a visible `StreamTooLong`/read error; it is not treated as EOF or an empty line.
- Reply failures keep the existing behavior: log the failure and reprompt rather than terminating the REPL.
- All turns reuse the one `coding.Session` created by `runRepl`.

## scope boundary

The direct bug is the persistent CLI REPL reader. Do not redesign permission prompting or introduce a shared-console subsystem in this task. A separate ask-mode stdin owner may be planned later if a deterministic competing-reader counterexample is demonstrated.

# deterministic evidence

At minimum add a no-network regression around an injected/fixed `std.Io.Reader` that proves:

1. two non-empty newline-delimited inputs are returned in order before the explicit empty-line exit;
2. the newline is consumed—no synthetic empty line appears between turns;
3. CRLF/whitespace normalization remains stable;
4. immediate EOF and final unterminated non-empty bytes follow the contract above;
5. the existing 4096-byte bound remains visible.

Prefer a small CLI-local line-classification helper so tests exercise the exact production input API without constructing a provider. If an offline loop/Agent fixture is added, it must use a mock provider and no API key/network. Do not add a test-only provider flag to the product binary.

# context

- `packages/zag-cli/src/cli.zig`
- Zig 0.16 local `std/Io/Reader.zig` delimiter API and tests
- `README.md`
- `chapters/00-loop/README.md`
- `docs/packaging.md`

# path

- `packages/zag-cli/src/cli.zig`
- `packages/zag-cli/src/repl.zig` only if extraction materially improves deterministic testing
- `packages/zag-cli/src/root.zig` only if a new internal module must be imported
- package/root build files only if an offline process fixture is justified
- `README.md`
- `chapters/00-loop/README.md`
- `docs/plan/README.md`
- `docs/plan/tasks/cli-repl-001.md`

# verification

- the production REPL consumes submitted delimiters and no longer exits after one answer;
- fixed-reader tests cover two turns, empty line, EOF, CRLF/trim, unterminated final bytes, and line limit;
- existing one-shot, doctor, permission, session, and CLI tests do not regress;
- `cd packages/zag-cli && zig build test --summary all`;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score and `git diff --check` pass;
- independent review and merged-main default/curl Gate pass before status becomes `done`.
