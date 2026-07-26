---
status: in-progress
scope: coding-agent session fork (M1 / C5.2)
task: session-fork-001
---

# Session fork

This module is the **binding contract** for `session-fork-001`. It defines safe,
idle-only durable fork of a coding-agent `Session` into a **new** child session
file. Implementation must obey every section below. Local code may land under
review while status remains **in-progress**; this does **not** claim Gate closeout
or any maturity raise.

**Create-body fault strategy (implementation):** **A** —
`session_store.testing.setFailNextCreateBody` (test-only; production-impossible).
Fires inside the final `createNewWithRedactor` / `createNewImpl` body after lease
acquisition, before atomic link of the child `.jsonl`.

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
  │ Session.fork(child_path)     // coding-agent only; *const Session
  ▼
zag-coding-agent Session
  · deep-copy transcript + layers into new arena
  · clone redactor via const-safe field path; empty DualQueues
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
                                           // (+ InvalidSession | UnsupportedSchema only if
                                           //   a mapped resume-style path is ever hit; create
                                           //   path must not seed on those)

/// Idle-only. Parent is unchanged on every success and every failure path.
/// `child_path` is a distinct lexical relative-workspace path (not absolute, no `..`).
/// Receiver is `*const Session`: fork must not mutate parent and must not const-cast.
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
| durable file bytes | unchanged (if parent was durable) | new redacted JSONL at `child_path` |
| writer lease / lock FD | unchanged | exclusive lease on `{child_path}.lock` |
| control queues | unchanged (pending retained) | **empty** new DualQueues |
| redactor | unchanged | independent `Redactor.clone` |
| `compaction_gen` / summary | unchanged | value/deep-copied at fork time |
| live `base_system` / `project_body` | unchanged | deep-copied at fork time (live child only) |
| schema / Trace / headless | unchanged | schema **v1**; Trace/headless versions unchanged |

There is **no** durable parent→child edge in schema v1. Lineage is host/process
knowledge (caller chose `child_path`), not a stored `parent_id`.

### Parent invariant under every target error (binding)

For same-path, invalid path, racy/busy lock, already-exists, prep OOM, and create-body
faults, the typed error is one of
`SessionAlreadyExists | InvalidPath | SessionBusy | OutOfMemory | IoFailed`
(as mapped in §6). **Regardless of which typed result is returned**, fork must
**never** replace, truncate, or mutate parent durable bytes, parent live fields,
parent lease, or parent queues.

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
| `base_system` | **deep-copy** | `child_arena.dupe` parent bytes (empty string allowed). Live child only — see §7 resume honesty |
| `project_body` | **deep-copy** | `child_arena.dupe` parent bytes. Live child only — see §7 resume honesty |
| `project_source` | **static rebind / borrowed-safe** | Points at `project.candidates` static names (`AGENTS.md`, …). Rebind same static pointer; do **not** free; do **not** arena-dupe unless implementation chooses owned copy for uniformity (either is correct if deinit never frees static) |
| `compaction_gen` | **value-copy** | Exact parent `u32` at fork time |
| `compaction_summary` | **deep-copy** | If parent `null`, child `null`; else `child_arena.dupe` summary bytes |
| `zag_version` | **borrowed-safe rebind** | Parent holds static default or borrowed Agent version slice; child rebinds the same pointer bytes. Not arena-owned; child deinit must not free it |
| `owned_redactor` | **independent init** | Const-safe clone of parent's owned policy (see §3.1). Fail-closed before create. Never share secret buffers with parent |
| `control_queues` | **independent init** | `DualQueues.init(gpa)` — **empty**. Do **not** copy parent pending steering/follow-up. Preallocate 32 KiB text backing before create I/O (same OOM-before-lease discipline as `Session.start`) |
| `fail_next_note_compaction` (test-only) | **independent init** | Child starts `false`; never inherit parent's fault inject arm |

### 3.1 Redactor clone under `*const Session` (binding)

Current product code exposes `Session.activeRedactor(self: *Session)` (mutable
receiver). `fork(self: *const Session, …)` **must not** const-cast parent to call it.

Binding clone strategy (implementation may pick either; both are const-safe):

1. **Field clone (preferred):** if `self.owned_redactor != null`, call
   `self.owned_redactor.?.clone(gpa)` (or `clone` on a `*const Redactor` obtained
   via `&self.owned_redactor.?` without casting away const on `Session`).
2. **Const accessor:** add / use a `*const Session` (or `*const Redactor`) read
   path whose only job is to return a borrowed `*const Redactor` for clone; still
   no mutation of parent.

**Null product redactor:** after a successful product `Session.start`,
`owned_redactor` is always set (start builds or clones policy before create/resume).
Fork on a product Session with `owned_redactor == null` is a programming / corrupt
state:

- Debug: `unreachable` or assert failure is acceptable evidence;
- Release / typed path: **fail-closed** before any durable create (e.g.
  `error.OutOfMemory` matching existing product “missing redactor” save mapping,
  or a dedicated typed error if introduced) — **never** call
  `createNewUnredacted` / null-redactor create.

Fixtures must prove: successful product start → fork clones independent secrets;
null-redactor Session (test-constructed) does not create child jsonl.

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

Honest limits (binding):

1. After child is saved and later **resumed** through session-v1 load,
   `content_parts` are **discarded** by the existing load path (not a fork bug;
   not fixed by this task). Schema v1 is unchanged.
2. **Positive live fixture is mandatory** (see §8 item 6): parent message with
   both `.text` and `.image_url` (including optional `detail`) must deep-copy with
   **byte-equal** nested strings and **all** nested pointers non-aliasing.
3. Implementation evidence must not treat JSONL roundtrip equality as proof of
   deep-copy (that path cannot preserve parts).

### Compaction and layers (live child)

- Copy `compaction_gen` and deep-copy `compaction_summary` as above.
- Immediately after successful fork, live child `Session.layers()` must observe the
  same system/project/session layer **bytes** as parent at fork time (via
  deep-copied `base_system` / `project_body` / summary). Ephemeral layer remains
  empty string as today.
- Fork does not run compaction and does not increment gen.
- **Resume of the child file does not restore fork-time layers** — see §7.

## 5. Create transaction (strict)

Binding order. **All** fallible prep completes **before** any durable child create.
`createNewWithRedactor` is the **only** and **last** fallible step that may create
child durable state or hold a child lock FD.

```text
1. validate child_path (lexical relative; InvalidPath)
2. same-as-parent durable path (if parent.path non-null and equal) →
   SessionAlreadyExists | InvalidPath — must not truncate/replace parent
3. gpa.create(ArenaAllocator) + init          [errdefer destroy]
4. DualQueues.init(gpa)                       [errdefer deinit]  // empty
5. const-safe Redactor.clone from parent      [errdefer deinit]
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
- Parent file bytes (if any), every parent field, parent queues, and parent lease are
  byte/pointer-stable relative to pre-fork observation (no mutation by fork).
- Parent remains a valid product Session: a subsequent `Agent.reply` on parent must
  still work (see §8 item 11).

### 5.1 Create-body fault strategy (deterministic, binding)

Gate fixtures that claim “create I/O / body fault” **must** be deterministic.
Allowed strategies (pick one; document which in the implementation PR):

| Strategy | Requirement |
|----------|-------------|
| **A. Test-only create failpoint** | A `session_store.testing` (or equivalent) arm that forces the **final** `createNewWithRedactor` / `createNewImpl` body to fail **after** lease acquisition path has begun or would begin, returning a typed error (`IoFailed` or `OutOfMemory`). Must compile out or be unreachable in production (`builtin.is_test` only; **no production enablement path**, same honesty as existing Writer `fail_before_replace`). |
| **B. Proven in-create seam** | Fault injection via a test allocator or FS seam that is **provably** only exercised inside the final `createNewWithRedactor` call (not during prep deep-copy). Proof = stack/control flow or a create-local counter; prep OOM fixtures alone do **not** satisfy create-body coverage. |

Required observations on that fault (all of):

- parent field + durable file equality;
- **no committed** child `.jsonl` at the target path;
- **no held** child lock FD after the error returns to the caller;
- a later successful create/fork against the same path may proceed when no holder
  remains (**stale lock sidecar retry** per D-006);
- intermediate parent directories created by `ensureParentDir` **may** remain
  (honest residual; not a contract violation) — see failure matrix.

### Failure matrix

| # | Failure | Child committed `.jsonl` | Held child lock FD after return | May remain on disk | Parent |
|---|---------|--------------------------|---------------------------------|--------------------|--------|
| F-a | `InvalidPath` (absolute / `..` / non-lexical) | absent | none | nothing required | unchanged |
| F-b | prep OOM (arena/queues/clone/deep-copy/path) | absent | none | nothing required | unchanged |
| F-c | `SessionAlreadyExists` (target file present, including same as parent path) | absent; existing target bytes untouched | none | existing target | unchanged (never replaced) |
| F-d | `SessionBusy` (active lock holder on child) | absent | none | lock held by **other** | unchanged |
| F-e | create-body fault inside final `createNewWithRedactor` (§5.1) | **absent** committed target | **none** | **may**: intermediate dirs from `ensureParentDir`; **may**: reusable stale `{path}.lock` sidecar | unchanged |
| F-f | null product redactor (§3.1) | absent | none | nothing required | unchanged |

Notes:

- “Absent committed jsonl” means the durable session **target** is not a successful
  schema-v1 session file created by this call. Atomic create must not leave a
  half-applied target that resume would treat as valid new child state.
- Failed create **may** leave intermediate directories and a stale lock sidecar; it
  must **not** leave a held lock FD or claim `Writer.deinit` unlinks the sidecar.
- **errdefer** cleans **prep state only** (arena, queues, redactor clone, path dupe,
  partial message allocs). It must not unlink parent files.

Default product safety remains **ask + workspace jail + shell protect**. Fork does
not change permission mode, jail, or shell policy.

## 6. Errors (fail-closed)

Map to existing `session_store.Error` vocabulary where possible:

| Condition | Error |
|-----------|-------|
| absolute / `..` / non-lexical child path | `InvalidPath` |
| child session file already exists (incl. same as parent durable path) | `SessionAlreadyExists` (or `InvalidPath` if implementation chooses that mapping for same-path — either typed result is allowed; **parent never replaced**) |
| active writer holds `{child}.lock` | `SessionBusy` |
| allocation failure in prep or create | `OutOfMemory` |
| filesystem / create-body failures on create/lock | `IoFailed` |
| null product redactor | fail-closed before create (§3.1) |
| (resume of child later) missing/invalid/unsupported | existing resume errors — not fork create |

No silent fallback to open_or_create, no overwrite, no unredacted product path.

## 7. Lifecycle / Trace / schema / resume honesty

| Surface | Fork impact |
|---------|-------------|
| session schema | remains **v1**; no `parent_id`, no tree block |
| Trace schema | remains twelve kinds; `session` field still `"configured"` or null — **never** raw path |
| lifecycle `run_start.session_configured` | `true` when `Session.path != null` (child always true after success) |
| headless-v1 | unchanged; no fork wire opcode |
| control queues | child empty; parent pending untouched; still process-only / not in schema |
| redaction | child create and later saves use child redactor; in-memory transcript may remain raw |

### Resume does not restore fork-time layers (binding)

Session schema v1 persists: header (`schema_version`, optional `zag_version`,
`compaction_gen`, `compaction_summary`) + message rows (`role` / plain `content` /
`tool_calls` / `tool_call_id`). It does **not** persist fork-time live
`base_system` or `project_body` as independent Session fields.

Therefore after `Session.start(... open_mode = .resume_existing, path = child_path)`:

| Restored | Not restored from file |
|----------|------------------------|
| message rows (within load boundary; **no** `content_parts`) | live `base_system` from fork-time parent |
| `compaction_gen` + `compaction_summary` from header | live `project_body` / `project_source` from fork-time parent |
| empty control queues | pending steering/follow-up (process-only) |

`base_system` on resume comes from **host `SessionStartOptions.base_system`**.
`project_body` comes from **host opts + project reload** when
`load_project_instructions` is true (existing `Session.start` resume path). Fork
Gate fixtures that resume a child must assert rows + compaction meta; they must
**not** claim that resume reconstructs the exact fork-time layer fields unless the
host opts/reload are set to reproduce them.

## 8. Verification (exact fixture list)

Implementation Gate **must** include each numbered item. Items are binding, not
examples. Numbering is stable for task cross-reference.

### Parent integrity

1. **Parent file byte-equal** after successful fork (read parent durable path
   before/after when parent is durable).
2. **Parent file byte-equal** after every fault in the failure matrix
   (F-a…F-f / InvalidPath, AlreadyExists, Busy, prep OOM, create-body fault,
   null redactor).
3. **Parent field equality** on success: `compaction_gen`, summary bytes,
   base_system, project_body, transcript message count/roles/contents/tool_calls/
   tool_call_id/content_parts (when present), queue pending counts, path pointer
   and writer lock still valid for parent.
4. **Parent field equality** on all faults (no partial parent mutation).

### Ownership / non-alias / content_parts

5. Child `arena_impl` is heap-allocated (`gpa.create`) and remains valid after
   Session is returned/moved by value.
6. **Positive content_parts live fixture (mandatory):** parent transcript contains
   at least one message whose `content_parts` includes both a `.text` part and an
   `.image_url` part with non-null `detail`. After fork, child parts are
   **byte-equal** for text/url/detail and **every** nested pointer (parts slice,
   text, url, detail) is **non-aliasing** vs parent. Parent parts unchanged.
7. Nested string pointers (content, tool id/name/arguments, tool_call_id,
   content_parts text/url/detail, base_system, project_body, compaction_summary)
   **do not alias** parent live pointers (covers non-parts messages too).
8. `Session.path.ptr != Writer.path.ptr` while bytes equal; parent/child path frees
   are independent (no double-free): parent-first deinit then child, and
   **child-first then parent**.
9. Layers non-empty case on **live** child: parent with non-empty system, project,
   and session summary ⇒ child `layers()` equal by content; summary deep-copied.

### Compaction / product reply chains

10. **Post-compaction fork:** parent with `compaction_gen >= 1` and non-null
    summary; child preserves gen/summary; subsequent **child** `Agent.reply`
    builds context with that session layer and remains protocol-legal.
11. **Parent continues after successful fork:** after fork returns child, host
    runs a real product `Agent.reply` on the **parent** Session; reply completes
    with truthful terminal; parent durable bytes advance only via normal save
    (child file unchanged by parent reply).
12. **Ephemeral parent → durable child:** parent started with `path == null`;
    fork to a lexical child path succeeds; child `path != null`,
    `session_configured == true` on child reply; parent remains ephemeral
    (`path == null`, no parent file invented).
13. Tool-bundle transcript fork: assistant+tool rows with nested calls; child
    live or resumed reply keeps ID pairing under load rules.

### Queues / redaction / resume honesty

14. **Queue isolation:** parent has pending steering and/or follow-up; child
    `steeringPending()==0` and `followUpPending()==0`; parent counts unchanged.
15. **Redaction:** configured secret in parent live transcript; child durable file
    contains marker / redacted form, not raw secret; parent file still redacted as
    before; child in-memory may retain raw (same product rule as Session.start).
16. **Child resume (rows + compaction only):** deinit child;
    `Session.start(... resume_existing, child_path)` loads expected **message
    rows** and **compaction_gen/summary**; queues empty. Fixture documents that
    `base_system`/`project_body` follow host opts/project reload, not fork-time
    live fields, and that **content_parts are absent** after resume (session-v1
    load boundary).

### Path / lock / create faults

17. Child path `InvalidPath` (absolute / `..`).
18. Child path `SessionAlreadyExists` leaves pre-existing bytes unchanged.
19. Child path `SessionBusy` when another process/holder owns lock.
20. Same-as-parent durable path: typed `SessionAlreadyExists | InvalidPath`;
    parent bytes never replaced/truncated.
21. Prep allocation failure: no child jsonl; no held lock FD; parent unchanged.
22. **Create-body fault (§5.1 strategy A or B):** deterministic failure inside
    final `createNewWithRedactor`; no committed child jsonl; no held lock FD;
    parent equality; intermediate dirs **may** remain; stale lock sidecar (if any)
    is releasable/reusable for a later successful create (D-006 retry).
23. Null product redactor: fail-closed; no child jsonl; no held lock FD.

### Lifecycle / Core / SDK / backends / maturity

24. Child reply lifecycle: `session_configured == true`; Trace
    `session="configured"` only (fixture asserts absence of raw child path string
    in trace output).
25. **Core no export:** Core root/source scan — no fork symbol/API/state.
26. **SDK consumer (mandatory):** external `tests/sdk-consumer-fixture/` imports
    coding-agent by module name only; exercises public `Session.fork` **and** a
    durable smoke (child path create + at least one save/resume or reply that
    touches durable state). **No deferred / optional escape hatch** — this item
    is required for Gate close. Must not invent Core fork imports.
27. **Dual backend Gate:** root std and curl suites green after implementation.
28. **No maturity change:** Session/Context/SDK/Headless/Phase H rows remain
    **L2**; no L3 claim for fork/tree/journal.

### Explicit non-mechanisms

29. Regression or review evidence that a **JSONL save/load roundtrip is not** used
    as the deep-copy implementation (pairs with item 6; load drops
    `content_parts`).

## 9. Non-goals

- schema v2, `parent_id`, session tree index, append journal
- UI, CLI flag, RPC/headless fork opcode
- mid-reply / mid-Tool fork
- fsync / power-loss durability; symlink containment of session paths
- Graph, subagents, Oracle, Memory Repo
- Core fork state or durable pending control queues
- product unredacted create path for fork
- restoring `base_system`/`project_body`/`content_parts` via session-v1 resume
- **L3 maturity claim** or any elevation of existing L2 rows

## 10. Related

- Task: [session-fork-001](../plan/tasks/session-fork-001.md)
- [session-store](./session-store.md) · [context-compaction](./context-compaction.md)
- [sdk-contract](./sdk-contract.md) · [harness-steering](./harness-steering.md)
- [C5 context](../phases/C5-context.md) · [roadmap](../roadmap.md)
- D-006 · D-009 · D-011
