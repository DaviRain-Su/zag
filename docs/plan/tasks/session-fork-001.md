---
id: session-fork-001
scope: coding-agent/session-fork
status: done
priority: P1
depends-on:
  - harness-steering-001
---

# objective

Deliver **safe idle-only session fork** on coding-agent `Session`: parent
remains fully unchanged; child is a new durable session at a distinct lexical
path with independent arena, deep-copied transcript (including live
`content_parts`), independent redactor, empty control queues, exclusive
`create_new` + redaction, and no Core fork API/state.

`session-fork-001` closed at `0a3087f` after independent contract/code review,
review follow-ups, ff-only merge, and merged-main dual-backend Gates. This is an
SDK/Session capability enrichment only; **no maturity row is raised**.

Binding specification: [Session fork](../../modules/session-fork.md).

## Delivery evidence

| Item | Evidence |
|------|----------|
| API | `Session.fork(*const Session, child_path) ForkError!Session` in `packages/zag-coding-agent/src/agent.zig` |
| Arena | `gpa.create(ArenaAllocator)` then `.init(gpa)` (heap-stable) |
| Deep-copy | live nested message/`content_parts`/layers; **not** JSONL roundtrip |
| Create | sole durable step `createNewWithRedactor`; §5.1 **strategy A** = `session_store.testing.setFailNextCreateBody` (`builtin.is_test` only) |
| Null redactor | typed `error.OutOfMemory` fail-closed before create (test-constructed) |
| Same-path | `SessionAlreadyExists` (honest; not Busy) |
| Fixtures | `packages/zag-coding-agent/src/session_fork_tests.zig` §8.1–29 |
| SDK | `tests/sdk-consumer-fixture` fork + durable create/resume smoke; current fixture **21/21** |
| Review | independent contract review PASS; independent code review PASS; review follow-up re-review PASS |
| Merge | ff-only to local main at `0a3087f` |
| Merged-main Gate | std **40/40 steps, 579/579 tests**; curl **42/42 steps, 578/578 tests**; Core **89/89**; Coding **309/309**; SDK **21/21**; OpenAPI **287/287**; catalog **40**; readability **91/100**; security **72/100** |
| Maturity | **L2 unchanged**; no new row |

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
  - `packages/zag-coding-agent/src/agent.zig` (`Session`, `activeRedactor(*Session)`)
  - `packages/zag-coding-agent/src/session_store.zig` (`createNewWithRedactor`,
    `ensureParentDir`, test-only Writer failpoints — create-body needs §5.1 strategy)
  - `packages/zag-coding-agent/src/redact.zig` (`Redactor.clone`)
  - `packages/zag-coding-agent/src/control_queue.zig`
  - `packages/zag-coding-agent/src/context.zig`
  - `packages/zag-agent-core/src/{message,transcript}.zig`
  - `packages/zag-types/src/root.zig` (`Message` / `ContentPart` / `ToolCall`)

# path

## Implementation (landed at `0a3087f`)

- `packages/zag-coding-agent/src/agent.zig` (`Session.fork(*const Session, …)` +
  const-safe redactor clone; no parent mutation)
- `packages/zag-coding-agent/src/session_store.zig` (reuse `createNewWithRedactor`
  only; optional test-only create failpoint under `testing`, production-impossible)
- `packages/zag-coding-agent/src/root.zig` (export if needed)
- coding-agent tests / golden fixtures covering module §8 items **1–29**
- `tests/sdk-consumer-fixture/` — **mandatory** fork API + durable smoke
- **no** Core fork module; Core remains Message/Transcript only

## Docs (contract track)

- `docs/modules/session-fork.md`
- `docs/plan/tasks/session-fork-001.md`
- status links only: `docs/modules/README.md`, `docs/modules/session-store.md`,
  `docs/modules/sdk-contract.md`, `docs/phases/C5-context.md`,
  `docs/plan/README.md`, `docs/roadmap.md`, `docs/maturity.md`,
  `docs/INDEX.md` if required for discoverability

# contract

The module doc is authoritative. Summary of binding rules (F1–F9 review
sharpening included):

1. **API surface:** coding-agent `Session.fork(*const Session, child_path)` only;
   idle-only; Core has no fork state/API; parent success/failure leaves all parent
   fields, file bytes, lease, and queues unchanged.
2. **Child open mode:** lexical relative **distinct** path; exclusive
   `createNewWithRedactor` / create_new only. Forbidden: `open_or_create`,
   resume-as-fork, product `*Unredacted` for fork. Schema v1 / Trace v1 /
   headless-v1 unchanged.
3. **Arena:** `arena_impl` via `gpa.create(ArenaAllocator)` like `Session.start`;
   by-value Session return keeps pointer stable.
4. **Deep ownership:** deep-copy all transcript nested slices (`content`,
   tool_calls `id`/`name`/`arguments`, `tool_call_id` including parent
   same-arena aliases, live `content_parts` with text+image_url+detail) plus
   `base_system` / `project_body` / `compaction_summary`; value-copy
   `compaction_gen`. **JSONL roundtrip is not a valid deep-copy** (load drops
   `content_parts`). Positive live parts fixture is mandatory.
5. **Paths:** `Session.path = gpa.dupe(child_path)`; same bytes as `Writer.path`,
   different pointer/ownership; independent free; no double-free. Child path
   non-null ⇒ lifecycle `session_configured=true`; Trace writes
   `session="configured"` only (no raw path).
6. **Redactor / queues:** const-safe field/`*const` clone — **no const-cast** of
   `*const Session` to call mutable `activeRedactor`; null product redactor
   fail-closed before create (Debug unreachable/assert allowed as evidence).
   `DualQueues.init` empty — do not copy parent pending.
7. **Strict transaction:** all fallible alloc/clone/deep-copy/meta/path prep
   before persist; `createNewWithRedactor` is the sole and last fallible durable
   step; success then only infallible Session assembly. Create failure: no
   committed child `.jsonl`, no held lock FD; **may** leave intermediate dirs +
   reusable stale `{path}.lock` sidecar; do not claim `Writer.deinit` unlinks.
   Create-body faults use module §5.1 strategy A (test-only failpoint) or B
   (proven in-create allocator/FS seam).
8. **Errors:** typed fail-closed (`InvalidPath` / `SessionAlreadyExists` /
   `SessionBusy` / `IoFailed` / `OutOfMemory` / …). Same/invalid/racy targets
   return those typed results but **never** replace/mutate parent.
9. **Resume honesty:** resume restores rows + compaction meta only; does **not**
   restore fork-time `base_system`/`project_body` (host opts/project reload);
   resume drops `content_parts` per session-v1 load.
10. **Product chains:** parent continues `Agent.reply` after successful fork;
    ephemeral parent → durable child is a required fixture.
11. **SDK consumer:** mandatory fork API + durable smoke; no deferred escape hatch.
12. **Verification:** exact fixture list module §8 items **1–29** (aligned with
    failure matrix F-a…F-f).
13. **Non-goals:** schema v2 / parent_id / tree / journal / UI / RPC / CLI,
    mid-reply fork, fsync/symlink containment, Graph/subagents/Memory, L3 claim.

# verification

## Docs Gate (contract track — complete)

- [x] Binding module + task authored before implementation
- [x] Independent-review F1–F9 folded into module + task
- [x] `zig build docs-lint` (docs-only commits)
- [x] `git diff --check` (docs-only commits)
- [x] Explicit `git add` of intended docs/quality files only

## Implementation Gate (**complete**)

Must pass every fixture in
[session-fork.md §8](../../modules/session-fork.md#8-verification-exact-fixture-list)
items **1–29**, aligned with failure matrix **F-a…F-f**:

| Items | Focus | Local |
|------:|-------|:-----:|
| 1–4 | Parent file/field equality on success **and** all faults | yes |
| 5–9 | Arena heap stability; **positive content_parts** live copy; nested non-alias; path dual-own deinit orders; live layers | yes |
| 10–13 | Post-compaction child reply; **parent reply after fork**; **ephemeral→durable**; tool-bundle pairing | yes |
| 14–16 | Queue isolation; redaction; child resume rows+compaction only (no layers/parts claim) | yes |
| 17–23 | InvalidPath; AlreadyExists; Busy; same-path typed result; prep OOM; **§5.1 create-body**; null redactor | yes |
| 24–28 | Lifecycle/Trace configured truth; Core no export; **mandatory SDK fork+durable smoke**; dual backend; **no maturity change** | yes |
| 29 | JSONL roundtrip is not deep-copy evidence | yes |

Merged-main evidence: std **579/579**, curl **578/578**, Coding **309/309**,
Core **89/89**, SDK **21/21**, with docs/OpenAPI/catalog Gates green.

Additional implementation checklist:

- [x] §5.1 create-body **strategy A** landed and fixture-proven (`setFailNextCreateBody`)
- [x] const-safe redactor clone (`activeRedactorConst` / field path); no `*const` → `*Session` cast
- [x] intermediate dirs + stale lock honesty documented in test comments
- [x] SDK consumer fork + durable smoke green
- [x] root std + curl Gates green on merged main (579/579 and 578/578)
- [x] maturity rows unchanged at closeout (still L2; no claim raised)

# non-goals

- schema v2, parent_id, tree UI, journal storage, CLI/RPC fork surface;
- mid-reply fork; fsync; symlink session containment;
- Graph, subagents, Oracle, Memory;
- Core fork API; durable pending control copy;
- elevating Session/Context/SDK maturity to L3 or any other row;
- using session-v1 resume to reconstruct fork-time layers or content_parts.

# closeout

- Four read-only Workflow planning/review rounds closed ownership and transaction
  gaps before implementation; the final plan verdict was PASS with no blockers.
- Docs contract landed at `5c62452`; review sharpening at `eb8a681`; implementation
  at `4faa930`; final code-review follow-ups closed at `0a3087f`.
- Independent contract and code reviews passed with all ship-quality follow-ups
  fixed. The task was fast-forwarded to local main.
- Merged-main Gate passed std **40/40 · 579/579**, curl **42/42 · 578/578**,
  Core **89/89**, Coding **309/309**, SDK **21/21**, OpenAPI **287/287**,
  catalog **40**, readability **91/100**, and security **72/100**.
- Session schema v1, Trace v1, `headless-v1`, default ask+jail+protect, and every
  existing L2 row remain unchanged. Tree/journal/UI/RPC/fsync/symlink containment
  and mid-reply fork remain excluded.
