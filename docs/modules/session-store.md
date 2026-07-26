# Module: session-store

| Item | Content |
|------|---------|
| Current code | `packages/zag-coding-agent/src/session_store.zig` (durable store/writer/schema); Core `transcript.zig` (in-memory authority); facade in coding-agent `agent.zig` |
| D-011 target | Transcript remains Core; durable session store/writer/schema moved to coding-agent |
| Current maturity | **L2** — explicit open modes, atomic save, visible errors, one active writer |
| Target | L3 fork/tree (C5) |
| Decision | [D-006](../decisions/active/D-006-session-open-and-durability.md) |

## Purpose and state boundary

Transcript is authoritative conversation state in memory. A configured session file is its recoverable persisted representation. Context view/compaction never silently mutates transcript history.

The Session owner holds transcript memory, path, metadata, the active-writer lease, and conversation-scoped transient control queues for its lifetime. The bounded control surface closed in `harness-steering-001` at `a5ff2b7`.

## Invariants

1. Schema version is mandatory; unknown versions fail explicitly.
2. Create, resume, and optional open-or-create have distinct semantics.
3. Missing, invalid, unsupported, busy, and general I/O failures are not interchangeable.
4. A failed load never authorizes overwriting the same path with a fresh transcript.
5. A failed save preserves the previous good file and is visible to the caller.
6. L2 has at most one active writer per persisted session; last-writer-wins is forbidden.
7. Session files may contain code, command output, and residual secrets; `.zag/` remains sensitive local state even after redaction.
8. Session paths are **lexical** relative-workspace paths only (absolute/`..` rejected). This is not symlink containment.
9. **Redaction (h-redact-001):** product `Writer.save` requires a `*const Redactor` (borrowed for the call only — not retained). Every arbitrary string field is redacted into temporary buffers **before** atomic serialize. Secret-bearing tool-call IDs map to collision-safe `zag-rtid-<n>` (skips IDs already present, including prior resume). In-memory transcript is not mutated. Redaction OOM → `OutOfMemory` with prior file bytes preserved. Product Agent/CLI always bind a redactor. Explicit low-level unredacted bypasses: `createNewUnredacted` / `openOrCreateUnredacted` / `saveUnredacted` / `saveWithMetaUnredacted` / `Writer.saveUnredacted` (also: `Observer.stderrLogUnredacted()`, Trace `redactor=null`).

## Schema v1 (current format)

JSONL header plus message lines:

| Field | Meaning |
|-------|---------|
| `schema_version` | Integer, current `1` (legacy `v` accepted; float rejected; required on typed header) |
| `type` | Exact string `zag_session` (only first content line may be a header) |
| `zag_version` | Optional writer package version |
| `compaction_gen` | Compaction generation: +1 per successfully applied final `CompactionEvent` (h-context-001) |
| `compaction_summary` | Optional latest final summary (includes prior-session lineage when re-compacting) |
| message row | `role`, `content`, `tool_calls`, `tool_call_id`, … |

Header-less legacy files load as v1. `schema_version != 1` returns `UnsupportedSchema`; it must not seed a new session on that path.

### Interactive-control state (`harness-steering-001`, closed at `a5ff2b7`)

A Session also owns two bounded process-memory queues for steering/follow-up. `Session.start` preallocates their fixed
32 KiB text backing **before** create/resume I/O or writer-lease acquisition; OOM cannot create a file or retain a lease,
and errdefer releases the queues on every later start failure. Pending slots are intentionally absent from schema v1 and
resume empty after process restart. Only successfully applied
control becomes an ordinary user message row and follows the existing redacted atomic save contract.

Cancel/error/max-turn terminals do not clear pending slots. They remain associated with the same in-memory Session until
successful apply, explicit idle clear, or deinit. This transient retention does not weaken the durable writer/path/schema
contract and must never leak a queue from Session A into Session B.

Strict parser rules:

- Header `type` must equal `zag_session` exactly; ordinary message content that merely mentions the string is not a header.
- Header only on the first non-empty line; mid-stream or duplicate headers → `InvalidSession`.
- Version fields are integers only; conflicting `schema_version` vs `v` → `InvalidSession`.

## Open contract (L2)

| Operation | Required behavior |
|-----------|-------------------|
| `create_new(path)` | Acquire writer ownership and create only if absent; existing path → typed already-exists error |
| `resume_existing(path)` | Missing → not-found; invalid → invalid-session; unknown schema → unsupported-schema; busy → busy/conflict |
| `open_or_create(path)` (SDK convenience) | Create only after typed not-found; every other load failure propagates |
| ephemeral session | No path, no persistence claim |

CLI mapping:

- `-s PATH` → `create_new`
- `-c` / `--continue` → `resume_existing` (default path `.zag/sessions/default.jsonl`)
- `open_or_create` is **not** selected by CLI flags; it is SDK-only

## Save/durability contract (L2)

1. Serialize complete bytes away from the target.
2. Write a same-filesystem temporary file.
3. Atomically replace the target only after successful serialization/write.
4. Release/clean temporary state on failure while preserving the prior target.
5. Return persistence errors through `Agent.reply` and headless structured output.
6. Prevent a second active writer with an exclusive advisory lock on `{path}.lock`.
7. Module-level redacted/unredacted save helpers take the same advisory lock for the call; they cannot bypass single-writer.

This is a **software-crash preservation** contract. Power-loss/fsync durability is **not** claimed by L2.

Physical append-only storage is optional. Snapshot, append journal, or hybrid implementations are acceptable if they satisfy the observable contract.

## Migration

- Additive v1 fields may remain compatible.
- Breaking format changes require a new schema and migration or explicit refusal.
- Migration writes a replacement atomically and keeps the source recoverable until commit.
- Unknown future fields/variants follow the documented compatibility policy; they are never silently normalized into empty state.

## Current gap

None for the D-006 L2 contract. Honest limits that remain out of scope:

- No fsync / power-loss durability claim.
- Session path check is lexical only (not symlink-aware workspace containment).
- Advisory lock is process-level (`flock`); same-process multi-handle behavior is OS-dependent.
- Stale `{path}.lock` sidecars are reusable when no holder exists; an active holder returns `SessionBusy`.

Implementation notes:

- `createNew` / `resumeExisting` / `openOrCreate` live in `packages/zag-coding-agent/src/session_store.zig` and are surfaced through `coding.OpenMode`. Core owns only the authoritative in-memory `Transcript`; no durable session path/writer/schema API remains in `zag-agent-core`.
- **Writer ownership:** move-only by convention — obtain only from create/resume/open_or_create and `deinit` once. Do not copy or forge a Writer; Zig cannot enforce this against hostile callers (not a lock-contract guarantee).
- The active writer holds an exclusive advisory lock on `{path}.lock` for its lifetime; the session file itself is not locked.
- Save serializes to a same-filesystem temporary file and atomically replaces the target via `createFileAtomic`. Test builds may inject a per-Writer before-replace fault via `session_store.testing` (absent as an enablement path in production); failure leaves the prior bytes intact and loadable.
- The D-006 strict parser, writer conflict, fault preservation, OOM allocation sweep, redaction, schema, and create/resume/open-or-create tests run from the `zag-coding-agent` package test binary via `root.zig` `refAllDecls`. `session_store.zig` imports `message`, `transcript`, `workspace`, and `redact` through the public `zag-agent-core` module; Core never imports `zag-coding-agent`.
- Typed header lines require integer `schema_version` and/or legacy `v` (missing both → `InvalidSession`); header-less message files still load as implied v1.
- Final read `FileNotFound` maps to `SessionNotFound`; other read/access failures map to `IoFailed` (fixture: session path is a directory so open/read fails as general I/O).
- `Session.save` errors propagate through `Agent.reply` and `Agent.complete`; the CLI exits with a non-zero status and a logged error.
- `Session.start` releases a partially acquired writer on error (`errdefer`) and only treats a successful resume as `resumed` for project-layer reload.

## L2 acceptance

- [x] v1 header, legacy `v`, header-less legacy, and unsupported-schema parsing tests exist.
- [x] Strict header tests: float version, missing version on typed header, conflicting v/schema_version, mid-stream/duplicate header, content not misclassified.
- [x] create-existing fails without modifying bytes.
- [x] resume missing/invalid/unsupported/general I/O (session path is a directory) are stable and distinct; openOrCreate does not create on IoFailed.
- [x] per-Writer test fault before replace preserves prior bytes and returns failure; prior file remains loadable.
- [x] a second active writer receives busy/conflict; public save also respects the lock (bounded cross-process holder).
- [x] stale lock sidecar is reusable after release.
- [x] `Agent.reply` returns `IoFailed` on save fault with prior session bytes unchanged (facade fixture).
- [x] cancel/tool-pair roundtrip remains resume-safe under the new persistence path.
- [x] session path lexical validation rejects absolute/`..`.
- [x] CLI `selectOpenMode`: continue → resume_existing; else create_new.

## L3 (C5)

- branch/fork/session tree (binding docs for the first durable fork slice:
  [session-fork](./session-fork.md), task [session-fork-001](../plan/tasks/session-fork-001.md);
  **not implemented**; does **not** raise this row above L2);
- append journal or snapshots when justified by measured session size;
- subagent transcript indexing.

Fork must reuse this module’s exclusive `create_new` / `createNewWithRedactor`,
typed errors, redaction, advisory lock, and schema v1 without `open_or_create`,
resume-as-fork, product `*Unredacted`, or schema fallback. JSONL load remains the
resume path; it is **not** a substitute for live transcript deep-copy (see
session-fork content_parts boundary).

## Non-goals for H

- Cloud sync
- Mandatory SQLite
- Power-loss durability claim
- Symlink containment of session paths (workspace tool jail is a separate module)
- Branch/fork UI
