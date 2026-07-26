---
id: session-fork-001
scope: coding-agent/session-fork
status: in-progress
priority: P1
depends-on:
  - harness-steering-001
---

# objective

Define and later implement **safe idle-only session fork** on coding-agent
`Session`: parent remains fully unchanged; child is a new durable session at a
distinct lexical path with independent arena, deep-copied transcript (including
live `content_parts`), independent redactor, empty control queues, exclusive
`create_new` + redaction, and no Core fork API/state.

This commit is **docs-first contract only**. Status `in-progress` means the
binding contract is authored; code implementation is a subsequent step on this
task. **No maturity row may be raised** by docs or by implementation happy paths.

Binding specification: [Session fork](../../modules/session-fork.md).

# context

- `docs/decisions/active/D-006-session-open-and-durability.md`
- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/session-fork.md` (**binding truth**)
- `docs/modules/session-store.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/harness-steering.md`
- `docs/modules/context-compaction.md`
- `docs/modules/core-boundary.md`
- `docs/phases/C5-context.md`
- `docs/roadmap.md` · `docs/maturity.md`
- Live sources (read for field enumeration; do not invent Core APIs):
  - `packages/zag-coding-agent/src/agent.zig` (`Session`)
  - `packages/zag-coding-agent/src/session_store.zig`
  - `packages/zag-coding-agent/src/redact.zig`
  - `packages/zag-coding-agent/src/control_queue.zig`
  - `packages/zag-coding-agent/src/context.zig`
  - `packages/zag-agent-core/src/{message,transcript}.zig`
  - `packages/zag-types/src/root.zig` (`Message` / `ContentPart` / `ToolCall`)

# path

## Implementation (future code step — not this docs commit)

- `packages/zag-coding-agent/src/agent.zig` (Session.fork + ownership)
- `packages/zag-coding-agent/src/session_store.zig` (reuse createNewWithRedactor only)
- `packages/zag-coding-agent/src/root.zig` (export if needed)
- coding-agent tests / golden fixtures
- `tests/sdk-consumer-fixture/` (SDK consumer Gate)
- **no** Core fork module; Core remains Message/Transcript only

## Docs (this step)

- `docs/modules/session-fork.md`
- `docs/plan/tasks/session-fork-001.md`
- status links only: `docs/modules/README.md`, `docs/modules/session-store.md`,
  `docs/modules/sdk-contract.md`, `docs/phases/C5-context.md`,
  `docs/plan/README.md`, `docs/roadmap.md`, `docs/maturity.md`,
  `docs/INDEX.md` if required for discoverability

# contract

The module doc is authoritative. Summary of binding rules:

1. **API surface:** coding-agent `Session` only; idle-only host call; Core has no
   fork state/API; parent success/failure leaves all parent fields, file bytes,
   lease, and queues unchanged.
2. **Child open mode:** lexical relative **distinct** path; exclusive
   `createNewWithRedactor` / create_new only. Forbidden: `open_or_create`,
   resume-as-fork, product `*Unredacted` for fork. Schema v1 / Trace v1 /
   headless-v1 unchanged.
3. **Arena:** `arena_impl` via `gpa.create(ArenaAllocator)` like `Session.start`;
   by-value Session return keeps pointer stable.
4. **Deep ownership:** deep-copy all transcript nested slices (`content`,
   tool_calls `id`/`name`/`arguments`, `tool_call_id` including parent
   same-arena aliases, live `content_parts`) plus `base_system` / `project_body`
   / `compaction_summary`; value-copy `compaction_gen`. Full field table and
   content_parts load boundary in module §3–§4. **JSONL roundtrip is not a valid
   deep-copy implementation** (load drops `content_parts`).
5. **Paths:** `Session.path = gpa.dupe(child_path)`; same bytes as `Writer.path`,
   different pointer/ownership; independent free; no double-free. Child path
   non-null ⇒ lifecycle `session_configured=true`; Trace writes
   `session="configured"` only (no raw path).
6. **Redactor / queues:** `Redactor.clone(gpa)`; `DualQueues.init` empty — do not
   copy parent pending steering/follow-up.
7. **Strict transaction:** all fallible alloc/clone/deep-copy/meta/path prep
   before persist; `createNewWithRedactor` is the sole and last fallible durable
   step; success then only infallible Session assembly. Create failure: no child
   `.jsonl`, no held lock FD; stale `{path}.lock` sidecar may remain and is
   D-006-reusable; do not claim `Writer.deinit` unlinks the lock.
8. **Errors:** typed fail-closed (`InvalidPath` / `SessionAlreadyExists` /
   `SessionBusy` / `IoFailed` / `OutOfMemory` / …); errdefer cleans prep only;
   default ask + jail + protect preserved.
9. **Verification:** exact fixture list in module §8 (parent equality all faults,
   non-alias nested/layers/path, non-empty layers+summary, post-compaction fork
   reply, parent-first/child-first deinit, queue isolation, redaction, child
   resume, path/lock conflicts, alloc/I/O/create failure absent jsonl + lock
   retry, lifecycle/Trace configured truth, Core no export, SDK consumer, dual
   backend Gate, no maturity change).
10. **Non-goals:** schema v2 / parent_id / tree / journal / UI / RPC / CLI,
    mid-reply fork, fsync/symlink containment, Graph/subagents/Memory, L3 claim.

# verification

## Docs Gate (this step)

- [x] Binding module + task authored (`status: in-progress`)
- [ ] `zig build docs-lint`
- [ ] `git diff --check`
- [ ] Explicit `git add` of intended docs only; commit message documents contract

## Implementation Gate (future — module §8 is binding)

Must pass every fixture in [session-fork.md §8](../../modules/session-fork.md#8-verification-exact-fixture-list), including:

- parent file/field equality on success **and** all faults;
- nested / layers / path pointer non-alias; non-empty layers + summary;
- post-compaction fork → child reply/context;
- parent-first and child-first deinit;
- queue isolation; redaction; child resume;
- path/lock conflicts; allocation/I/O/create failure ⇒ absent jsonl + lock
  releasable/stale sidecar retry;
- lifecycle/Trace configured truth; Core no export; SDK consumer;
- dual backend Gate; **no maturity change**.

# non-goals

- schema v2, parent_id, tree UI, journal storage, CLI/RPC fork surface;
- mid-reply fork; fsync; symlink session containment;
- Graph, subagents, Oracle, Memory;
- Core fork API; durable pending control copy;
- elevating Session/Context/SDK maturity to L3 or any other row.

# closeout

- Docs-first contract: **in-progress** (this file + `docs/modules/session-fork.md`).
- Code delivery, independent review, ff-only merge, and merged-main Gate remain
  open. Closeout must reaffirm **no maturity elevation**.
