---
id: h-edit-integrity-001
scope: phase-h/edit-integrity
status: ready
priority: P0
depends-on: [h-tool-runtime-001, h-workspace-001, h-session-001, h-trace-001, h-redact-001]
---

# objective

Close the Phase H data-preservation blocker in `write_file` and `search_replace`. An approved single-file mutation must stage complete bytes away from the destination and publish them only through one same-filesystem atomic replacement after write and flush succeed.

A failed parent-create, temp-create, write, flush, containment recheck, or replace must preserve the prior target bytes or prior target absence and return a stable, recoverable Tool result. The current behavior of a contained final file symlink must remain explicit: mutate its contained resolved target while leaving the symlink object and link text intact.

This task closes single-file edit integrity only. It does not mark Phase H, SDK-ready, headless-ready, or C4 edit sharpness complete.

# contract

The owning contract is [`docs/modules/tools-edit.md`](../../modules/tools-edit.md), with containment and final-symlink behavior cross-checked against [`docs/modules/workspace-sandbox.md`](../../modules/workspace-sandbox.md).

## commit boundary

- Build the complete replacement bytes before opening a commit temporary.
- Create the temporary in the selected target's parent, write all bytes, flush the Zig file writer, re-run containment immediately before commit, then atomically replace the selected target.
- Existing ordinary files and contained final-symlink targets keep exact prior bytes on any pre-commit or replace failure.
- A previously absent `write_file` target remains absent on failure.
- An uncommitted temporary is cleaned on every ordinary error path; no temporary name is exposed in Tool output.
- Success exposes the complete requested/replaced bytes. No allocation or optional diff enrichment after commit may turn a completed mutation into a reported hard failure.
- `flush` here is the Zig writer flush before rename. This task does not claim file `fsync`, parent-directory `fsync`, power-loss durability, or protection from a hostile concurrent filesystem actor.

## contained final symlinks

- Atomic replacement of a requested symlink path must not replace the symlink directory entry.
- A contained final file symlink resolves to its contained real target; commit applies to that target.
- On success and failure, the final link remains a symlink with the same link text.
- Escaping, dangling, looping, or unresolvable final symlinks remain `jail_deny`.
- Contained directory symlinks retain their existing create/write behavior.

## narrow parent-directory partial success

`search_replace` does not create parent directories. `write_file` may leave newly created parent directories after a later failure; rollback is forbidden because it can race unrelated workspace activity. The target must still remain absent/preserved, no temporary file may remain, and the Tool result must report that parent directories may remain. This is the only partial-success behavior authorized by this task.

## stable failure result

Expected edit I/O failures use this first-line shape:

```text
error: code=edit_io_failed format=edit-v1 operation=<write_file|search_replace> stage=<parent_create|temp_create|write|flush|replace> target=preserved parent_dirs=<unchanged|may_remain>
```

- `target=preserved` means exact prior bytes or prior absence.
- `parent_dirs=may_remain` is valid only for `write_file` after missing-parent creation may have started.
- The line omits raw OS errors, temporary names, absolute paths, and file contents and fits `trace.cap_tool_result_body`.
- `OutOfMemory` remains a typed host error before commit. The implementation must make the post-commit success path non-failing.
- Existing `anchor_not_found`, `ambiguous_anchor`, `too_large`, `jail_deny`, invalid-argument, and permission results keep their meanings. A failed final containment recheck returns `jail_deny`, not `edit_io_failed`, and still preserves the target.
- The code remains handler-local; core Tool error and trace schemas do not expand.

## permission remember boundary

For Phase H, remember keys are exact lexical request-path strings, not canonical filesystem-object authorizations. Aliases re-prompt; remembered approval never bypasses the execution-time Guard; jail-denied aliases do not gain executable authorization. Same-string retargeting remains inside the documented trusted-host/check-time TOCTOU boundary. Canonical path/domain authorization remains post-H.

# deterministic evidence

Use private test-only seams through the production commit helper. Do not widen Tool JSON, `Agent.Options`, `tool.Context`, CLI flags, provider ABI, session schema, trace schema, or production descriptors.

Fixtures must cover:

1. failure after a non-zero temporary write prefix;
2. failure while flushing complete temporary bytes;
3. failure at the final containment recheck;
4. failure at atomic replace;
5. existing ordinary target, absent target, and contained final-symlink target for both handlers where applicable;
6. exact prior bytes/absence, unchanged symlink text, and no temporary artifact after every failure;
7. missing-parent `write_file` failure with only the declared directory residue;
8. stale/missing/ambiguous/oversize `search_replace` remains non-mutating;
9. post-commit success reporting cannot fail ambiguously;
10. lexical remember aliases re-prompt and remembered approval cannot bypass jail.

Add one real coding-product Agent fixture for a recoverable injected edit failure: preserve the original Tool-call ID in transcript and persisted/resumed session, retain the exact `edit-v1` body, project the matching Tool events into parsed trace using schema-true correlation, preserve the target, clean the temporary, and end in one truthful recovered `completed` terminal.

# remains post-H

- hashline/apply_patch-grade edit selection and improved stale recovery;
- hunk accept/reject and change-review UI;
- post-edit project verification;
- multi-file transactions, rollback, or partial-success orchestration;
- compare-and-swap against external writers;
- inode/hard-link/xattr/ACL/general metadata fidelity;
- power-loss durability and OS sandboxing.

# context

- `docs/modules/tools-edit.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/permissions.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`
- Zig 0.16 local `std.Io.Dir.createFileAtomic` and `std.Io.File.Atomic`

# path

- `packages/zag-coding-agent/src/runtime/edit_tools.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-agent-core/src/workspace.zig` only if contained-target resolution needs a reusable helper
- `packages/zag-agent-core/src/permissions.zig` tests only for the lexical remember contract
- `docs/modules/tools-edit.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md` only if containment wording changes
- `docs/quality/evals.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/plan/tasks/h-edit-integrity-001.md`
- `chapters/01-edit-permissions/README.md`
- `chapters/H-harden/README.md`
- `SECURITY.md` if the trusted-host wording needs synchronization

# verification

- both handlers share the atomic commit path and contain no in-place truncate write;
- every deterministic fault satisfies the target, symlink, parent-residue, and temporary-cleanup contract;
- the exact `edit-v1` stage survives the Agent transcript/session/resume/trace chain with one recovered terminal;
- existing containment, anchor, diff-enrichment, permission, session, and trace fixtures do not regress;
- focused core/coding-agent tests pass under applicable backends;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- independent worktree review and merged-main std/curl Gate pass;
- only then may this task become `done`; final Phase H audit remains separate.
