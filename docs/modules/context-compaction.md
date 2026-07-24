# Module: context-compaction

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/context.zig`; `zag-coding-agent/src/project.zig`; session sink in `agent.zig` |
| Current maturity | **L2** — final-view accounting, ID-exact tool bundles, lineage, shared cap (h-context-001) |
| Target | L3 repo map/intelligent selection (C5) |
| Reference | Pi session/compaction; Aider repo map; Hyper compaction |

## Purpose and boundary

Transcript is authoritative. Context view is a per-provider-call projection assembled from stable prompt layers and selected transcript history. Compaction shapes the view; it does not delete transcript rows.

## Invariants

1. **Transcript ≠ view.** Loop never truncates authoritative transcript to satisfy a model budget.
2. system/project instructions remain reachable after compaction.
3. Tool call/result **bundles** remain valid in every selected tail (exact IDs, call order).
4. A `CompactionEvent` describes the **final returned view**, not an intermediate trim.
5. `event.dropped` equals the number of non-system body messages excluded by that projection.
6. The summary (with prior-session lineage when applicable) accounts for the same omitted set; on the **success path**, session and trace receive the same final event bytes.
7. Soft `max_chars` may still be exceeded when further legal trim would violate `min_tail_messages`; accounting still matches the returned view.
8. Malformed history is **fail-closed** (`error.InvalidContext`) before any provider call.

## Four prompt layers

| Layer | Content | Lifetime |
|-------|---------|----------|
| system | identity, safety, Tool policy | process/config |
| project | AGENTS.md/project rules | workspace |
| session | compaction summary/session context | session |
| ephemeral | turn-only hints/doctor/Oracle advice | one turn |

## Tool-bundle policy (fail-closed)

Body history (after leading transcript systems) is validated before trim:

- For every assistant message with nonempty `tool_calls`:
  - each call ID is **nonempty** and **unique** within the bundle;
  - the next messages are **exactly one** contiguous `tool` result per call;
  - results appear in **deterministic call-list order** (same order as `tool_calls`);
  - each result `tool_call_id` equals the corresponding call ID.
- Orphan `tool` rows, unknown/duplicate/missing/empty IDs, out-of-order results, and incomplete bundles → `InvalidContext`.

### Legal boundaries

- If a count-trim start lands **inside** results, align **back** to the carrier assistant.
- Further trim advances by an **atomic unit**: assistant + all of its results, or a single non-bundle message. Never splits a bundle.

## L2 compaction algorithm (fixed-point)

1. Validate body tool bundles (fail closed).
2. Count-trim + legal align.
3. Soft char-trim by atomic units under current layer cost.
4. Build UTF-8 summary for omitted prefix (lineage first, then highlights).
5. Re-cost layers with that summary as session layer.
6. If still over budget, advance by a legal unit and rebuild until stable.
7. Emit one final `CompactionEvent`.

### Shared summary cap

| Constant | Value |
|----------|-------|
| `context.summary_cap` | **800** |
| `Options.summary_max_chars` | clamped via `effectiveSummaryMax` / `clampSummaryBudget` |
| `trace.cap_compaction_summary` | alias of `context.summary_cap` |
| `summaryFloor(dropped, prior_session)` | minimum reserved bytes (always ≤ 800) |

- Request `0` → use full cap.
- Request `> 800` → clamp to 800.
- Tiny requests raise to `summaryFloor`: complete dropped-count header **plus**, when a prior session summary exists, a minimal truncated lineage record (`prior_bytes`, `kept_bytes=0`, full `wyhash64` 16-hex digest, `[LINEAGE_TRUNCATED]`).
- Floor uses **sanitized** prior UTF-8 length (U+FFFD expansion via `utf8SanitizedByteLen`), matching the `prior_bytes` field and digest input — not raw length (raw/sanitized decimal width can differ).
- Construction stays in-budget; ReleaseFast never relies on debug asserts for the cap.
- Built events always have `summary.len <= summary_cap` and valid UTF-8.

### Lineage

| Case | Behavior |
|------|----------|
| Valid UTF-8 prior fits | Exact prior under `Prior session context:` (subtractive capacity check) |
| Invalid UTF-8 prior (any size) or valid prior does not fit | Explicit record: `prior_bytes` = **sanitized** length, `kept_bytes` (may be 0), `digest=wyhash64` over sanitized bytes (16 hex), optional kept prefix, `[LINEAGE_TRUNCATED]` |

Never silently truncate prior summary bytes without the marker/digest record. Tiny `summary_max_chars` (e.g. 1 or 8) with a large or invalid-UTF-8 prior still keeps full `prior_bytes` + full digest + marker.

### Invalid UTF-8

Message content with invalid UTF-8 is **sanitized to U+FFFD** in the summary path (not `OutOfMemory`). Truncation is codepoint-safe on valid UTF-8.

### Complexity

Iteration ≤ `body.len + 1`. Each iteration may rescan remaining tail estimates and rebuild a summary over the omitted prefix → **bounded O(n²)** worst case in body length (not unbounded restart).

### Generation

`Session.compaction_gen` increments **once per successfully accepted** final event (`noteCompaction` success). Unchanged on OOM. Chaining: each new summary embeds prior session text (exact or truncated lineage record).

### Session vs trace equality

- **Success path:** session sink then `trace.emitCompactionEvent`; both carry the same `dropped` + summary bytes.
- Sink OOM → no compaction line; gen/summary unchanged; run `OutOfMemory`.
- Note succeeds + later mid-run **trace emit** fails → visible run failure; in-memory session may already hold the new gen (not claimed transactional across that failure).

Terminal category for malformed history: `invalid_context` (not `provider_error`).

## L2 acceptance

- [x] four layers assembled; project rules re-injected per turn.
- [x] authoritative transcript unchanged (deep tool-id snapshot fixtures).
- [x] two-stage trim: final `dropped` **>** intermediate; summary names final set.
- [x] summary/lineage covers every stage; truncated prior has marker+digest.
- [x] Tool bundles ID/order valid; atomic align/advance; malformed → `InvalidContext`.
- [x] shared cap; session/trace/provider session layer byte-equal on success.
- [x] generation/lineage/save-resume documented and tested.
- [x] soft-budget / min-tail honest terminate; sink OOM Agent terminal.

## L3 (C5)

- repo map and task-aware file selection;
- session fork/branch;
- optional LLM summary with quality fixtures;
- default-off Memory Repo injection through a defined layer.

## Non-goals for H

- Perfect semantic compression
- Cross-session Memory Repo
- Cloud knowledge store
