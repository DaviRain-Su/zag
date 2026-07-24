# Module: session-store

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{session_store,transcript}.zig`; facade in coding-agent `agent.zig` |
| Current maturity | **L2** — explicit open modes, atomic save, visible errors, one active writer |
| Target | L3 fork/tree (C5) |
| Decision | [D-006](../decisions/active/D-006-session-open-and-durability.md) |

## Purpose and state boundary

Transcript is authoritative conversation state in memory. A configured session file is its recoverable persisted representation. Context view/compaction never silently mutates transcript history.

The Session owner holds transcript memory, path, metadata, and the active-writer lease for its lifetime.

## Invariants

1. Schema version is mandatory; unknown versions fail explicitly.
2. Create, resume, and optional open-or-create have distinct semantics.
3. Missing, invalid, unsupported, busy, and general I/O failures are not interchangeable.
4. A failed load never authorizes overwriting the same path with a fresh transcript.
5. A failed save preserves the previous good file and is visible to the caller.
6. L2 has at most one active writer per persisted session; last-writer-wins is forbidden.
7. Session files may contain code, command output, and secrets; `.zag/` remains sensitive local state.
8. Session paths are **lexical** relative-workspace paths only (absolute/`..` rejected). This is not symlink containment.

## Schema v1 (current format)

JSONL header plus message lines:

| Field | Meaning |
|-------|---------|
| `schema_version` | Integer, current `1` (legacy `v` accepted; float rejected; required on typed header) |
| `type` | Exact string `zag_session` (only first content line may be a header) |
| `zag_version` | Optional writer package version |
| `compaction_gen` | Compaction generation |
| `compaction_summary` | Optional latest summary |
| message row | `role`, `content`, `tool_calls`, `tool_call_id`, … |

Header-less legacy files load as v1. `schema_version != 1` returns `UnsupportedSchema`; it must not seed a new session on that path.

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
7. Public `save` / `saveWithMeta` take the same advisory lock for the call; they cannot bypass single-writer.

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

- `createNew` / `resumeExisting` / `openOrCreate` live in `session_store.zig` and are surfaced through `coding.OpenMode`.
- **Writer ownership:** move-only by convention — obtain only from create/resume/open_or_create and `deinit` once. Do not copy or forge a Writer; Zig cannot enforce this against hostile callers (not a lock-contract guarantee).
- The active writer holds an exclusive advisory lock on `{path}.lock` for its lifetime; the session file itself is not locked.
- Save serializes to a same-filesystem temporary file and atomically replaces the target via `createFileAtomic`. Test builds may inject a per-Writer before-replace fault via `session_store.testing` (absent as an enablement path in production); failure leaves the prior bytes intact and loadable.
- Typed header lines require integer `schema_version` and/or legacy `v` (missing both → `InvalidSession`); header-less message files still load as implied v1.
- Final read `FileNotFound` maps to `SessionNotFound`; other read/access failures map to `IoFailed` (e.g. path component is a regular file).
- `Session.save` errors propagate through `Agent.reply` and `Agent.complete`; the CLI exits with a non-zero status and a logged error.
- `Session.start` releases a partially acquired writer on error (`errdefer`) and only treats a successful resume as `resumed` for project-layer reload.

## L2 acceptance

- [x] v1 header, legacy `v`, header-less legacy, and unsupported-schema parsing tests exist.
- [x] Strict header tests: float version, missing version on typed header, conflicting v/schema_version, mid-stream/duplicate header, content not misclassified.
- [x] create-existing fails without modifying bytes.
- [x] resume missing/invalid/unsupported/general I/O (path-component file) are stable and distinct; openOrCreate does not create on IoFailed.
- [x] per-Writer test fault before replace preserves prior bytes and returns failure; prior file remains loadable.
- [x] a second active writer receives busy/conflict; public save also respects the lock (bounded cross-process holder).
- [x] stale lock sidecar is reusable after release.
- [x] `Agent.reply` returns `IoFailed` on save fault with prior session bytes unchanged (facade fixture).
- [x] cancel/tool-pair roundtrip remains resume-safe under the new persistence path.
- [x] session path lexical validation rejects absolute/`..`.
- [x] CLI `selectOpenMode`: continue → resume_existing; else create_new.

## L3 (C5)

- branch/fork/session tree;
- append journal or snapshots when justified by measured session size;
- subagent transcript indexing.

## Non-goals for H

- Cloud sync
- Mandatory SQLite
- Power-loss durability claim
- Symlink containment of session paths (workspace tool jail is a separate module)
- Branch/fork UI
