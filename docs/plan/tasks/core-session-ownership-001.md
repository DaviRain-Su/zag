---
id: core-session-ownership-001
scope: coding-agent/session-ownership
status: in-progress
priority: P1
depends-on:
  - core-seams-001
---

# objective

Move durable session storage ownership from `zag-agent-core` to `zag-coding-agent` while keeping the authoritative
in-memory `Transcript` in Core. Preserve D-006 open modes, locking, atomic replacement, redaction, schema v1, facade
errors, and headless mappings.

# context

- `docs/decisions/active/D-006-session-open-and-durability.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/core-boundary.md`
- `docs/modules/session-store.md`
- `docs/modules/sdk-contract.md`

# path

- `packages/zag-agent-core/src/session_store.zig`
- `packages/zag-agent-core/src/root.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-coding-agent/src/root.zig`
- destination coding-agent session module(s)
- `packages/zag-cli/src/cli.zig`
- `tests/sdk-consumer-fixture/`
- session/golden integration fixtures
- `docs/modules/core-boundary.md`
- `docs/modules/session-store.md`
- `docs/modules/sdk-contract.md`
- `docs/plan/tasks/core-session-ownership-001.md`
- generated quality reports

# contract

1. Core retains `Transcript` only and has no durable session path/writer/schema API in its final root.
2. Coding-agent owns Session path, writer lease, open modes, load/save, schema, and redacted persistence.
3. Existing `create_new`, `resume_existing`, and SDK-only `open_or_create` semantics remain exact.
4. Atomic failure preserves prior bytes; active-writer conflicts remain visible.
5. Source compatibility changes are documented because there is no semver publication promise; no duplicate
   authoritative implementation remains in Core.
6. Trace/session/context ordering is unchanged.

# verification

- D-006 module tests run from the coding-agent package and cover strict parsing, fault preservation, and writer conflict.
- Agent reply/session save failure and cancel/resume Tool-pair fixtures remain green.
- CLI session-path validation and headless error/exit mapping remain unchanged.
- external SDK fixture imports the product-owned session surface by module name.
- Core root/source scan confirms no durable session implementation/export.
- package tests, root std/curl suites, headless fixture, docs lint, and score checks pass.

# non-goals

- session schema changes, fork/tree, journal storage, fsync claims, or new package creation;
- moving Transcript out of Core;
- changing redaction or Trace ownership in this task.
