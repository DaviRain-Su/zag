# Review: lsp-001 — safety / lifecycle (closeout)

- Task: [lsp-001](../tasks/lsp-001.md)
- Binding: [lsp.md](../../modules/lsp.md)
- Track: Wave 2 closeout (safety)
- Result: **PASS**

## What holds

- Guard containment before any server interaction.
- Read budget 4 MiB (`too_large`); result body ≤ 64 KiB; hover 32 KiB;
  definition ≤ 16 locations; references ≤ 50 hits.
- Missing server / unresolved root / empty answer → exact body `null`
  (designed fallback, not an error).
- Teardown: SIGTERM → bounded wait → SIGKILL → reap (Zig 0.16 has no
  `Child.terminate`).
- Invalid args (unknown op, negative line/col) → `invalid_arguments`.
- Descriptor: risk=read, path_field set, cancellation=none, shell=none.

## Non-blocking

- **N1 (P3).** Inherited parent env (see architecture review). Do not
  claim credential isolation for the zls child.
- **N2 (P3).** No process-tree ownership. Grandchildren of zls are out
  of v1.

## Decision

**PASS** — closeout. Workspace / Shell rows stay L2. No sandbox claim.
