# Module: session-store

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{session_store,transcript}.zig`; facade in coding-agent `agent.zig` |
| Current maturity | **L1+** — schema/roundtrip exist; safe open/durability contract is P0 |
| Target | L2 (H) → L3 fork/tree (C5) |
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

## Schema v1 (current format)

JSONL header plus message lines:

| Field | Meaning |
|-------|---------|
| `schema_version` | Integer, current `1` (legacy `v` accepted) |
| `type` | `zag_session` |
| `zag_version` | Optional writer package version |
| `compaction_gen` | Compaction generation |
| `compaction_summary` | Optional latest summary |
| message row | `role`, `content`, `tool_calls`, `tool_call_id`, … |

Header-less legacy files load as v1. `schema_version != 1` returns `UnsupportedSchema`; it must not seed a new session on that path.

## Open contract (L2 target)

| Operation | Required behavior |
|-----------|-------------------|
| `create_new(path)` | Acquire writer ownership and create only if absent; existing path → typed already-exists error |
| `resume_existing(path)` | Missing → not-found; invalid → invalid-session; unknown schema → unsupported-schema; busy → busy/conflict |
| `open_or_create(path)` (optional) | Create only after typed not-found; every other load failure propagates |
| ephemeral session | No path, no persistence claim |

Names may follow Zig conventions, but these behaviors may not be collapsed into a catch-all fallback.

## Save/durability contract (L2 target)

1. Serialize complete bytes away from the target.
2. Write a same-filesystem temporary file.
3. Atomically replace the target only after successful serialization/write.
4. Release/clean temporary state on failure while preserving the prior target.
5. Return persistence errors through `Agent.reply` and headless structured output.
6. Prevent a second active writer with an explicit lease/lock or an equivalent conflict mechanism.

This is a **software-crash preservation** contract. Power-loss/fsync durability is not claimed by L2.

Physical append-only storage is optional. Snapshot, append journal, or hybrid implementations are acceptable if they satisfy the observable contract.

## Migration

- Additive v1 fields may remain compatible.
- Breaking format changes require a new schema and migration or explicit refusal.
- Migration writes a replacement atomically and keeps the source recoverable until commit.
- Unknown future fields/variants follow the documented compatibility policy; they are never silently normalized into empty state.

## Current gap

Current facade resume catches `IoFailed`, `InvalidSession`, and `UnsupportedSchema`, seeds a new transcript, and retains the path. Current save truncates the destination directly, and `Agent.reply` logs save failure only in verbose mode. Therefore schema presence alone does not satisfy L2.

## L2 acceptance

- [x] v1 header, legacy `v`, header-less legacy, and unsupported-schema parsing tests exist.
- [ ] create-existing fails without modifying bytes.
- [ ] resume missing/invalid/unsupported/general I/O failures are stable and distinct.
- [ ] fault-injected save preserves prior bytes and returns failure.
- [ ] a second active writer receives busy/conflict.
- [ ] facade/headless never reports unqualified success after a requested save fails.
- [ ] cancel/tool-pair roundtrip remains resume-safe under the new persistence path.

## L3 (C5)

- branch/fork/session tree;
- append journal or snapshots when justified by measured session size;
- subagent transcript indexing.

## Non-goals for H

- Cloud sync
- Mandatory SQLite
- Power-loss durability claim
- Branch/fork UI
