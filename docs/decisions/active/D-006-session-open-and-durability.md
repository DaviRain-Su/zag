---
status: active
id: D-006
title: Session open modes and durability fail closed
date: 2026-07-24
---

# D-006 — Session open modes and durability fail closed

## Decision

1. Session creation and resume are distinct operations:
   - `create_new`: fails if the target already exists.
   - `resume_existing`: fails if the target is missing, unreadable, invalid, or uses an unsupported schema.
   - A convenience `open_or_create` may create only after a typed **not-found** result; it must not recover from parse/schema/general I/O errors.
2. A failed load never seeds a new transcript on the same path and never authorizes a later overwrite.
3. Save uses a temporary file plus atomic replacement so a software crash during serialization/write preserves the prior good file. Power-loss durability/fsync is a separate capability.
4. L2 supports one active writer per persisted session. A second writer fails with a typed busy/conflict error; last-writer-wins is not acceptable.
5. A configured persistence failure is returned to the caller. Verbose-only warnings are insufficient.
6. Physical append-only storage is optional. Snapshot, journal, or a hybrid may be used if they satisfy the behavior above.

## Why

The current `continue_existing` facade maps `IoFailed`, `InvalidSession`, and `UnsupportedSchema` to a fresh transcript while retaining the original path. A later truncate save can destroy the only recoverable copy. Atomic rename alone would prevent partial files but not concurrent lost updates.

## Consequences

- Session errors need stable typed variants such as not-found, already-exists, invalid, unsupported, busy/conflict, and I/O failure.
- `Agent.reply`/headless flows must expose save failure.
- Session lifecycle owns and releases the writer lease/lock.
- Schema migration must preserve the source file until the replacement is complete.
- C5 fork/tree work builds on this contract rather than redefining it.

## Required tests

- create-existing fails and leaves bytes unchanged.
- resume-missing, invalid, and unsupported schema are distinguishable failures.
- fault-injected save leaves the prior file readable and reports failure.
- two active writers cannot both commit.
- legacy v1/no-header loading continues according to the documented migration policy.

## Related

- [assessment](../../plan/analysis/2026-07-24-production-floor-assessment.md)
- [session-store module](../../modules/session-store.md)
- [task h-session-001](../../plan/tasks/h-session-001.md)
