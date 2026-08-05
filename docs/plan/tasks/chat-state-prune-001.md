---
id: chat-state-prune-001
scope: types+context/chat-state
status: implementation-complete
priority: P1
depends-on:
  - session-item-001
---

# objective

Add the **chat-state sharpness slice**: duplicate tool-result dedup
(`dedupDuplicateToolResults`, carrier-scoped rescue) and the
`prompt_index`-aware `truncateToPromptIndex` rewind cut. Token estimation,
dangling repair, and token-budget truncate already landed in
`session-item-001`; the truncate stage already performs whole-bundle head
trims under the token budget, so NO separate pruning stage is introduced
(reviewed and rejected: it would be behaviorally identical to
`truncateForPrompt`). This slice adds the remaining request-assembly
sharpness from the reference (xai-chat-state repair_history dedup) without
changing the D-011 gate, fail-closed validation, Session v1, or Trace v1.

**Binding specification:** [chat-state-prune.md](../../modules/chat-state-prune.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — final re-review (two revision rounds closed all blockers; prune stage removed as behaviorally redundant) |
| Implementation | **complete** — std 711/711, curl 710/710 (std 694→711, curl 693→710, +17 tests) |
| Evidence refresh | **PASS** — implementation is present in `31523b6`; isolated coding-agent integration binary passed 406/406 tests and OpenAPI adapter suite passed 25/25 |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 / Core D-011 seams | **unchanged** (loop.zig, context_view.zig, protocol_history.zig untouched) |
| session-item-001 | closed (std 694/694, curl 693/693) — this slice builds on it |

# context

- `session_item.zig` (zag-agent-core) now owns: estimateTokens (L0 arithmetic),
  assignPromptIndices, repairDanglingToolCalls, truncateForPrompt — all pure,
  view-only, drop-only; reuses `protocol_history.alignToLegalStart`/`unitEnd`.
- `context.zig` `viewForModel` pipeline: repair → validate → token truncate →
  count cap → char-trim → summary fixed-point.
- Long tool-heavy sessions today have only two context controls: count cap
  (`max_tail_messages`) and full compaction (summary). Old tool results stay
  in the view until the whole bundle is trimmed — no graduated pruning.
- No duplicate-result handling exists: a repeated `tool_call_id` result row
  passes `repairDanglingToolCalls` (id is known) and must be rejected or
  deduped; today `validateBodyHistory` behavior on duplicates is undefined by
  contract (fail-closed by default).
- `prompt_index` (session-item-001) enables turn-boundary cuts; no rewind
  truncation uses it yet.

# path

| Path | Role |
|------|------|
| `packages/zag-agent-core/src/session_item.zig` | NEW `dedupDuplicateToolResults`, `truncateToPromptIndex` (pure, view-only) |
| `packages/zag-coding-agent/src/context.zig` | `viewForModel` integrates dedup into the combined pre-gate stage |
| Forbidden | loop.zig, context_view.zig, protocol_history.zig validation behavior, Session v1 header/schema, Trace v1, chapters |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Scope | dedup + truncateToPromptIndex ONLY — no pruning stage (behaviorally identical to `truncateForPrompt`; rejected in review) |
| Dedup | `dedupDuplicateToolResults`: **carrier-scoped** — the seen-set resets at each assistant-with-tool-calls row; within one carrier's contiguous result run, a repeated `tool_call_id` keeps the LAST occurrence and drops earlier ones. Cross-carrier id reuse is legal and untouched. Interleaved repeats (`r(c1), r(c2), r(c1)`) are NOT rescued (the result order would no longer match the call list; the gate rejects them as today). Runs as part of the repair stage (before validate) |
| Dedup + repair order | dedup runs INSIDE the repair pass composition (repair first drops unknowns, then dedup collapses repeats) — one combined pre-gate stage in `viewForModel` |
| truncateToPromptIndex | `truncateToPromptIndex(items, target_prompt_index, next_counter) -> {kept, dropped}` — cut lands on the row that starts turn `target_prompt_index`. Turn-start rows = `.user` rows and null-index synthetic rows (assignPromptIndices rule). Index resolution: a stamped row opens a cut when its stamp equals the target; unstamped rows are counted in transcript order (first user = turn 1 — **no preamble concept in zag**); mixed mode counts stamped rows by stamp and unstamped rows by legacy order. Cut never lands inside a bundle (turn-start rows are never tool results). NOT wired into the loop in v1 (API + fixtures only) |
| Fail-closed | unchanged: incomplete bundles, out-of-order, dup/empty call ids, leading-system-without-tail still `InvalidContext`; loop hostile tests byte-identical; dedup never creates or reorders content |
| Config | no new user-facing config |
| Divergence from reference | no pruning stage; no hard-clear mode; no mid-view text rewriting; no global-id dedup (carrier-scoped) |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| Dedup | repeated id within one carrier keeps last occurrence; order of other rows preserved; single-occurrence view untouched; cross-carrier id reuse legal pre/post dedup; interleaved within-run repeats still `InvalidContext`; dedup+repair combined pass on mixed orphan+dup input |
| Fail-closed | incomplete/out-of-order/dup-call-id/empty-call-id still `InvalidContext` (validate after repair+dedup); loop hostile tests unchanged |
| truncateToPromptIndex | stamped mode (contiguous indices), legacy mode (first user = turn 1), mixed mode; cut lands on the turn-start row; returns correct dropped count; target beyond last turn → keep all |
| Regression | session-item-001 suite, context.zig suite, protocol_history suite, loop hostile suite — all green; std/curl dual-backend matrix |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (std + curl
  matrices); **no** maturity raise; **no** remote claim.

# non-goals

- Any pruning stage (reviewed and rejected: behaviorally identical to
  `truncateForPrompt` under drop-only law)
- Hard-clear / drop-all-results mode
- Rewriting assistant rows into text-only form
- Wiring `truncateToPromptIndex` into the loop (v1 is API + fixtures)
- `transform_conversation_cwd` (fork cwd rewriting)
- Changing `validateBodyHistory` rejection behavior
- Session v1 schema change; Trace v1 changes; maturity raise

# related

- [chat-state-prune.md](../../modules/chat-state-prune.md) (binding)
- [session-item-001](./session-item-001.md) · [session-item.md](../../modules/session-item.md)
- [roadmap](../../roadmap.md) C5 Context · M3 slice
- Reference: xai-chat-state `actor/request_builder.rs` pruning +
  `compaction_utils.rs` repair_history (behavior direction only, not parity)
