---
status: in-progress
scope: coding-agent session fork (M1 / C5.2)
task: session-fork-001
---

# Session fork

This module is the **binding contract** for `session-fork-001`. It defines safe,
idle-only durable fork of a coding-agent `Session` into a **new** child session
file. Implementation must obey every section below; docs-first status does **not**
claim code delivery or any maturity raise.

Prerequisite contracts (unchanged):

- [D-006](../decisions/active/D-006-session-open-and-durability.md) open modes,
  atomic save, one active writer, typed errors, reusable stale lock sidecar
- [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md) Pi semantics
  without parity/schema fork
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) thin Core; durable
  session is coding-agent product state
- [session-store](./session-store.md) schema v1, create/resume, redaction, lock
- [context-compaction](./context-compaction.md) layers, gen/summary, final-view
- [harness-steering](./harness-steering.md) Session-owned empty-on-resume queues
- [sdk-contract](./sdk-contract.md) ownership/lifetime/error surface

## 1. Boundary

```text
host (idle Session)
  │
  │ Session.fork(child_path)     // coding-agent only
  ▼
zag-coding-agent Session
  · deep-copy transcript + layers into new arena
  · clone redactor; empty DualQueues
  · exclusive createNewWithRedactor(child_path)
  · return independent child Session
          │
          ▼
session_store (product)
  · create_new only — never open_or_create / resume-as-fork
  · redacted initial bytes; advisory lock on {child}.lock
          │
          ▼
zag-agent-core
  · Message / Transcript types only
  · NO fork API, NO fork state, NO parent/child graph
```

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent.Session` | public fork API, ownership table, create transaction, child lifecycle | Core imports of product fork |
| `session_store` | exclusive create + writer lease + redacted save | fork semantics / parent identity |
| `zag-agent-core` | in-memory `Transcript` / `Message` | fork API, path, writer, redactor, queues, schema |

## 2. Product API

```zig
// coding-agent Session only (exact name may match package style; behavior is binding)
pub const ForkError = session_store.Error; // at least InvalidPath | SessionAlreadyExists
                                           // | SessionBusy | IoFailed | OutOfMemory
                                           // | InvalidSession | UnsupportedSchema as mapped

/// Idle-only. Parent is unchanged on every success and every failure path.
/// `child_path` is a distinct lexical relative-workspace path (not absolute, no `..`).
pub fn fork(self: *const Session, child_path: []const u8) ForkError!Session;
```

### Call-site rules

1. **Idle-only.** Host must not call `fork` while any `Agent.reply` / control
   enqueue consumer / clear / deinit is in flight on the parent. Concurrent fork
   during those operations is unsupported (data race). Address stability rules
   for Session match steering: parent address may move only while idle.
2. **No Core API.** Core root and sources export no fork entry, no parent_id, no
   tree type, and no durable session path API (D-011 / core-session-ownership).
3. **No Agent-owned fork.** Fork is conversation state; it lives on `Session`, not
   `Agent`, so Session A cannot be forked through a cached pointer belonging to B.
4. **Child path required.** Ephemeral parent (`path == null`) may still fork **to**
   a durable child path. Child `path` is always non-null after success.
5. **Open mode fixed.** Child creation is exclusive **`create_new`** via product
   `session_store.createNewWithRedactor` only.
6. **Forbidden paths:**
   - `open_or_create` as the fork create step;
   - “resume existing file as fork”;
   - product `createNewUnredacted` / `*Unredacted` for fork persistence;
   - schema v2, `parent_id` header field, tree index, journal, UI, RPC, CLI flag
     for this task.

### Parent / child identity

| Property | Parent (after fork) | Child (on success) |
|----------|---------------------|--------------------|
| transcript bytes in memory | unchanged | independent deep copy |
| durable file bytes | unchanged | new redacted JSONL at `child_path` |
| writer lease / lock FD | unchanged | exclusive lease on `{child_path}.lock` |
| control queues | unchanged (pending retained) | **empty** new DualQueues |
| redactor | unchanged | independent `Redactor.clone` |
| `compaction_gen` / summary | unchanged | value/deep-copied at fork time |
| schema / Trace / headless | unchanged | schema **v1**; Trace/headless versions unchanged |

There is **no** durable parent→child edge in schema v1. Lineage is host/process
knowledge (caller chose `child_path`), not a stored `parent_id`.

## 3. Session field ownership table

Every field of coding-agent `Session` (`packages/zag-coding-agent/src/agent.zig`)
must be classified. Omission is a contract bug.

| Field | Classification | Fork rule |
|-------|----------------|-----------|
| `gpa` | value-copy / rebind | Same allocator as parent (or explicit same-gpa rule); no ownership transfer |
| `io` | value-copy / rebind | Same `Io` as parent |
| `arena_impl` | **independent init** | **Must** `gpa.create(ArenaAllocator)` then `.* = .init(gpa)` exactly like `Session.start`. Returning Session **by value** keeps `arena_impl` pointer stable. Stack `ArenaAllocator` that is later moved/copied is forbidden |
| `transcript` | **deep-copy** | New `Transcript.init(child_arena)`; deep-copy every message (see §4) |
| `path` | **independent init** | `gpa.dupe(child_path)`; non-null. Same UTF-8 bytes as `Writer.path` but **different pointer and ownership**; freed only by child `Session.deinit`, not by Writer, and not shared with parent |
| `writer` | **independent init** | Sole durable create: `createNewWithRedactor(...)` as **last** fallible step; move-only Writer lease |
| `base_system` | **deep-copy** | `child_arena.dupe` parent bytes (empty string allowed) |
| `project_body` | **deep-copy** | `child_arena.dupe` parent bytes |
| `project_source` | **static rebind / borrowed-safe** | Points at `project.candidates` static names (`AGENTS.md`, …). Rebind same static pointer; do **not** free; do **not** arena-dupe unless implementation chooses owned copy for uniformity (either is correct if deinit never frees static) |
| `compaction_gen` | **value-copy** | Exact parent `u32` at fork time |
| `compaction_summary` | **deep-copy** | If parent `null`, child `null`; else `child_arena.dupe` summary bytes |
| `zag_version` | **borrowed-safe rebind** | Parent holds static default or borrowed Agent version slice; child rebinds the same pointer bytes. Not arena-owned; child deinit must not free it |
| `owned_redactor` | **independent init** | `parent.activeRedactor().clone(gpa)` (or equivalent independent clone of parent's owned policy). Fail-closed OOM before create. Never share secret buffers with parent |
| `control_queues` | **independent init** | `DualQueues.init(gpa)` — **empty**. Do **not** copy parent pending steering/follow-up. Preallocate 32 KiB text backing before create I/O (same OOM-before-lease discipline as `Session.start`) |
| `fail_next_note_compaction` (test-only) | **independent init** | Child starts `false`; never inherit parent's fault inject arm |

### Path / Writer dual ownership (binding)

```text
Session.path  ──► gpa-owned []u8  (child path)
Writer.path   ──► gpa-owned []u8  (same bytes, distinct allocation)
Writer.lock_path / lock_file ──► child-only lease

deinit child:
  control_queues.deinit(gpa)
  writer.deinit()     // closes lock FD; frees Writer.path + lock_path; does NOT unlink .lock
  gpa.free(Session.path)
  owned_redactor.deinit()
  arena_impl.deinit(); gpa.destroy(arena_impl)
```

`Writer.deinit` **must not** be claimed to unlink `{path}.lock`. D-006 allows a
**stale** lock sidecar to be reused when no holder exists; an active holder is
`SessionBusy`.

## 4. Transcript deep-copy (live memory)

Fork copies the **live in-memory** parent transcript. It is **not** permitted to
implement deep-copy solely by “save parent → load into child” JSONL roundtrip
(see §4.1).

### Per-message nested ownership

For each `message.Message` in parent order:

| Nested field | Rule |
|--------------|------|
| `role` | value-copy |
| `content` | deep-copy into child arena (including empty) |
| `tool_calls` | if non-null: allocate new slice in child arena; for **each** call deep-copy `id`, `name`, `arguments` |
| `tool_call_id` | if non-null: **always** deep-copy into child arena — including when parent live path **aliases** the id from an earlier assistant `tool_calls[i].id` in the same arena (`Transcript.appendToolResult` currently reuses the call-id pointer) |
| `content_parts` | if non-null: deep-copy the parts slice; for each part deep-copy `text` or `image_url.url` and optional `detail` (live-copy; see load boundary) |

Pointer non-aliasing after success:

- child message list storage ≠ parent list storage;
- every owned nested string/slice pointer is in the child arena (or child gpa for
  non-arena Session fields), never equal to the corresponding parent live pointer
  for deep-copied fields;
- `Session.path` pointer ≠ `Writer.path` pointer even when bytes equal;
- child `arena_impl` pointer ≠ parent `arena_impl`;
- child redactor secret buffers ≠ parent secret buffers.

### 4.1 content_parts: live-copy vs session-v1 load boundary

| Surface | content_parts |
|---------|----------------|
| Live `Message` / provider multimodal path | May carry `content_parts` |
| Product **save** (`session_store`) | Redacts and serializes `content_parts` when present |
| Product **load** (`appendMessageFromObject` / resume) | Reconstructs only `role` + plain `content` + `tool_calls` + `tool_call_id` via `Transcript.append*`. **Does not** restore `content_parts` |
| **Fork (this contract)** | **Live deep-copy** must preserve parent `content_parts` when present on live messages |
| JSONL roundtrip as fork implementation | **Forbidden** as the sole deep-copy mechanism: it would silently drop live `content_parts` and is not a correct ownership copy |

Honest limit: after child is saved and later **resumed** through session-v1 load,
`content_parts` follow the existing load boundary (may be absent). Fork itself
must not lose live parts at the moment of fork. Schema v1 is unchanged; this task
does not add load support for multimodal parts.

### Compaction and layers

- Copy `compaction_gen` and deep-copy `compaction_summary` as above.
- `Session.layers()` on child must observe the same system/project/session layer
  **bytes** as parent at fork time (via deep-copied `base_system` / `project_body` /
  summary). Ephemeral layer remains empty string as today.
- Fork does not run compaction and does not increment gen.

## 5. Create transaction (strict)

Binding order. **All** fallible prep completes **before** any durable child create.
`createNewWithRedactor` is the **only** and **last** fallible step that may create
child durable state or hold a child lock FD.

```text
1. validate child_path (lexical relative; InvalidPath)
2. reject non-distinct path policy if documented (same path as parent durable path
   → AlreadyExists or InvalidPath — must not truncate parent)
3. gpa.create(ArenaAllocator) + init          [errdefer destroy]
4. DualQueues.init(gpa)                       [errdefer deinit]  // empty
5. Redactor.clone from parent                 [errdefer deinit]
6. deep-copy transcript + base_system + project_body + compaction_summary
7. gpa.dupe(child_path) for Session.path      [errdefer free]
8. build SessionMeta (schema v1, gen, summary, zag_version borrow)
9. createNewWithRedactor(gpa, io, cwd, child_path, child_messages, meta, &child_redactor)
     ── sole durable fallible step ──
10. infallible Session struct assembly + return
```

### Success post-conditions

- Child `.jsonl` exists with redacted snapshot of the forked transcript + meta.
- Child holds exclusive writer lease; parent lease unchanged.
- Child `path != null` ⇒ lifecycle `run_start.session_configured == true` and Trace
  `run_start.session == "configured"` (never raw path) on subsequent child replies
  that use the normal Agent facade (existing `session.path != null` truth).
- Parent file bytes, every parent field, parent queues, and parent lease are
  byte/pointer-stable relative to pre-fork observation (no mutation by fork).

### Failure matrix

| Failure | Child `.jsonl` | Held child lock FD | Stale `{path}.lock` sidecar | Parent |
|---------|----------------|--------------------|-----------------------------|--------|
| InvalidPath (before create) | absent | none | unchanged | unchanged |
| prep OOM (arena/queues/clone/deep-copy/path) | absent | none | unchanged | unchanged |
| SessionAlreadyExists | absent (existing bytes untouched) | none | unchanged | unchanged |
| SessionBusy (active lock holder) | absent | none | may exist (held by other) | unchanged |
| create I/O / save fault inside createNew* | **absent** target (atomic create must not leave a committed child file); no held FD after return | none | **may** remain; reusable per D-006 when no holder | unchanged |
| UnsupportedSchema / InvalidSession | N/A for create path; must not be used to seed child | none | — | unchanged |

**errdefer** cleans **prep state only** (arena, queues, redactor clone, path dupe,
partial message allocs). It must not unlink parent files or claim Writer.deinit
removes lock sidecars.

Default product safety remains **ask + workspace jail + shell protect**. Fork does
not change permission mode, jail, or shell policy.

## 6. Errors (fail-closed)

Map to existing `session_store.Error` vocabulary where possible:

| Condition | Error |
|-----------|-------|
| absolute / `..` / non-lexical child path | `InvalidPath` |
| child session file already exists | `SessionAlreadyExists` |
| active writer holds `{child}.lock` | `SessionBusy` |
| allocation failure in prep or create | `OutOfMemory` |
| filesystem failures on create/lock | `IoFailed` |
| (resume of child later) missing/invalid/unsupported | existing resume errors — not fork create |

No silent fallback to open_or_create, no overwrite, no unredacted product path.

## 7. Lifecycle / Trace / schema compatibility

| Surface | Fork impact |
|---------|-------------|
| session schema | remains **v1**; no `parent_id`, no tree block |
| Trace schema | remains twelve kinds; `session` field still `"configured"` or null — **never** raw path |
| lifecycle `run_start.session_configured` | `true` when `Session.path != null` (child always true) |
| headless-v1 | unchanged; no fork wire opcode |
| control queues | child empty; parent pending untouched; still process-only / not in schema |
| redaction | child create and later saves use child redactor; in-memory transcript may remain raw |

## 8. Verification (exact fixture list)

Implementation Gate **must** include each item. Items are binding, not examples.

### Parent integrity

1. **Parent file byte-equal** after successful fork (read parent path before/after).
2. **Parent file byte-equal** after every fault in the failure matrix (InvalidPath,
   AlreadyExists, Busy, prep OOM, create I/O fault).
3. **Parent field equality** on success: `compaction_gen`, summary bytes, base_system,
   project_body, transcript message count/roles/contents/tool_calls/tool_call_id,
   queue pending counts, path pointer and writer lock still valid for parent.
4. **Parent field equality** on all faults (no partial parent mutation).

### Ownership / non-alias

5. Child `arena_impl` is heap-allocated (`gpa.create`) and remains valid after Session
   is returned/moved by value.
6. Nested string pointers (content, tool id/name/arguments, tool_call_id,
   content_parts text/url/detail, base_system, project_body, compaction_summary)
   **do not alias** parent live pointers.
7. `Session.path.ptr != Writer.path.ptr` while bytes equal; parent/child path frees
   are independent (no double-free): parent-first deinit then child, and
   **child-first then parent**.
8. Layers non-empty case: parent with non-empty system, project, and session summary
   ⇒ child `layers()` equal by content; summary deep-copied.

### Compaction / reply

9. **Post-compaction fork:** parent with `compaction_gen >= 1` and non-null summary;
   child preserves gen/summary; subsequent child `Agent.reply` builds context with
   that session layer and remains protocol-legal.
10. Tool-bundle transcript fork: assistant+tool rows with nested calls; child resume
    or live reply keeps ID pairing.

### Queues / redaction / resume

11. **Queue isolation:** parent has pending steering and/or follow-up; child
    `steeringPending()==0` and `followUpPending()==0`; parent counts unchanged.
12. **Redaction:** configured secret in parent live transcript; child durable file
    contains marker / redacted form, not raw secret; parent file still redacted as
    before; child in-memory may retain raw (same product rule as Session.start).
13. **Child resume:** deinit child; `Session.start(... resume_existing, child_path)`
    loads expected rows/meta/gen; queues empty on resume.

### Path / lock / create faults

14. Child path InvalidPath (absolute / `..`).
15. Child path AlreadyExists leaves pre-existing bytes unchanged.
16. Child path SessionBusy when another process/holder owns lock.
17. Prep allocation failure: no child jsonl; no held lock FD; parent unchanged.
18. Create I/O / injected create fault: no committed child jsonl; no held lock FD;
    stale lock sidecar (if any) is releasable/reusable for a later successful create
    (D-006 stale sidecar retry).
19. Distinct-path rule: forking onto the parent's own path must not truncate or
    replace parent (AlreadyExists or InvalidPath).

### Lifecycle / Core / SDK / backends / maturity

20. Child reply lifecycle: `session_configured == true`; Trace `session="configured"`
    only (fixture asserts absence of raw child path string in trace output).
21. **Core no export:** Core root/source scan — no fork symbol/API/state.
22. **SDK consumer:** external fixture imports coding-agent only; exercises fork or
    documents deferred consumer step if Gate stages implementation — must not import
    Core fork (none exists).
23. **Dual backend Gate:** root std and curl suites green after implementation.
24. **No maturity change:** Session/Context/SDK/Headless/Phase H rows remain **L2**;
    no L3 claim for fork/tree/journal.

### Explicit non-mechanisms

25. A regression or comment-level Gate that a **JSONL save/load roundtrip is not**
    used as the deep-copy implementation (content_parts live-copy requirement).

## 9. Non-goals

- schema v2, `parent_id`, session tree index, append journal
- UI, CLI flag, RPC/headless fork opcode
- mid-reply / mid-Tool fork
- fsync / power-loss durability; symlink containment of session paths
- Graph, subagents, Oracle, Memory Repo
- Core fork state or durable pending control queues
- product unredacted create path for fork
- **L3 maturity claim** or any elevation of existing L2 rows

## 10. Related

- Task: [session-fork-001](../plan/tasks/session-fork-001.md)
- [session-store](./session-store.md) · [context-compaction](./context-compaction.md)
- [sdk-contract](./sdk-contract.md) · [harness-steering](./harness-steering.md)
- [C5 context](../phases/C5-context.md) · [roadmap](../roadmap.md)
- D-006 · D-009 · D-011
