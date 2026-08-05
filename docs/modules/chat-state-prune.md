# Chat-state dedup + rewind cut (M3.2 binding)

> Binding spec for `chat-state-prune-001`
> ([task](../plan/tasks/chat-state-prune-001.md)). Adds carrier-scoped
> duplicate tool-result dedup and a `prompt_index`-aware rewind cut to the
> session-item layer. NO pruning stage: `truncateForPrompt` already performs
> whole-bundle head trims under the token budget, so a separate prune pass
> would be behaviorally identical (reviewed and rejected).

## 1. Principles

1. **Drop-only, view-only**: dedup deletes rows from the scratch view; it
   never creates, reorders, or rewrites content, and never touches the
   transcript.
2. **Carrier scoping**: tool-result ids are only meaningful within the
   carrier bundle that declared them; cross-carrier id reuse is legal.
3. **Pre-gate composition**: dedup + repair form ONE combined stage before
   `validateBodyHistory`; incomplete/out-of-order/dup-call-id/empty-call-id
   bundles still fail closed at the gate.
4. **No config surface**: no new options in v1.

## 2. Pure functions (packages/zag-agent-core/src/session_item.zig)

### `dedupDuplicateToolResults(items: []const Message, allocator) ?[]const Message`

- **Carrier-scoped**: the seen-set resets at each assistant-with-tool-calls
  row. Within one carrier's contiguous result run, a `tool_call_id` seen more
  than once keeps the LAST occurrence and drops earlier ones.
- Cross-carrier id reuse is legal and untouched (validateCallIds enforces
  uniqueness only within one bundle).
- Interleaved within-run repeats (`r(c1), r(c2), r(c1)`) are NOT rescued —
  the result order would no longer match the call list; the gate rejects them
  as today.
- Rows with empty id follow the existing repair rules (empty-carrier drop).
- Returns `null` when nothing dropped; owned slice otherwise.
- Never reorders; never touches assistant rows.

### `truncateToPromptIndex(items: []const Message, target_prompt_index: u32, next_counter: u32) TruncateToPromptResult`

```zig
pub const TruncateToPromptResult = struct {
    kept: []const Message,
    dropped: usize,
};
```

- The cut lands on the row that **starts** turn `target_prompt_index`.
  Turn-start rows = `.user` rows and null-index synthetic rows (the
  assignPromptIndices rule).
- Index resolution:
  - stamped rows open a cut when their stamp equals the target;
  - unstamped rows are counted in transcript order — first user = turn 1
    (**no preamble concept in zag**), null-index synthetics count as turn
    starts;
  - mixed mode: pre-marker unstamped rows by legacy order; stamped rows by
    stamp; post-marker unstamped rows never open a cut (mid-turn phantoms
    like bash/permission follow-ups are not turns).
- Cut never lands inside a bundle (turn-start rows are never tool results).
- Target beyond the last turn → keep everything (dropped = 0).
- v1: API + fixtures only; not wired into the loop.

## 3. Product composition (packages/zag-coding-agent/src/context.zig)

`viewForModel` stage order (unchanged stages marked):

```text
repair + dedup (combined pre-gate)          ← NEW (repairDanglingToolCalls then dedupDuplicateToolResults)
validate body (unchanged)                    ← fail-closed
token-budget truncateForPrompt (unchanged)   ← first budget stage
count-trim (unchanged)                       ← max_tail_messages
soft char-trim (unchanged)                   ← under summary cost
summary + layers + fixed-point (unchanged)
```

## 4. Diagnostics & budgets

- No new diagnostics surface; no new config options.
- Dedup is silent (view-only rescue); no event in v1.
