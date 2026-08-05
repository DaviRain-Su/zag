# Session-item semantics (M3.1 binding)

> Binding spec for `session-item-001` ([task](../plan/tasks/session-item-001.md)).
> Adds turn accounting, synthetic markers, a reasoning carrier, unified token
> estimation, tolerant dangling-call repair, and token-budget truncation to the
> existing flat `[]Message` transcript — without changing the D-011 gate,
> fail-closed validation, Session v1, or Trace v1.

## 1. Principles

1. **Transcript is authoritative** (D-011 / existing compaction law): compaction
   and truncation only shape the model view, never delete rows.
2. **Additive fields only**: `Message` and `AssistantTurn` gain optional fields;
   no new item union, no parallel list. Every existing consumer keeps compiling
   and behaving identically when the new fields are absent.
3. **Core is dumb, product composes**: Core (`zag-agent-core`) only forwards
   fields and assigns indices; the tolerant repair pass and the token-budget
   truncate are composed in the product ContextView layer
   (`zag-coding-agent/src/context.zig`).
4. **Fail-closed is preserved at the gate**: `validateBodyHistory` remains the
   authoritative Core/loop gate (byte-identical; the three loop hostile tests
   are untouched). The product layer may *rescue* orphan/empty-carrier views
   deterministically by dropping rows before validation — an intentional
   product-semantics improvement that never runs on the transcript and never
   invents content. Incomplete bundles and leading-system-without-tail remain
   `InvalidContext` everywhere.
5. **No provider replay of reasoning**: thinking content is a user-visible
   audit artifact, never re-sent to a provider.

## 2. Types (packages/zag-types/src/root.zig)

### Message (additive)

| field | type | default | meaning |
|---|---|---|---|
| `reasoning` | `?[]const u8` | `null` | model thinking carried from the wire into the transcript; never replayed |
| `synthetic` | `bool` | `false` | row was runtime-injected (interjection, auto-continue, task-completed, system-reminder), not typed by the user |
| `prompt_index` | `?u32` | `null` | monotone prompt-turn index this row belongs to; `null` = pre-existing/preamble/unknown |

`estimateChars()` (existing) counts `reasoning` when set.

### AssistantTurn (additive)

| field | type | default | meaning |
|---|---|---|---|
| `reasoning` | `?[]const u8` | `null` | adapter-captured thinking for this assistant turn |

## 3. Pure module (packages/zag-agent-core/src/session_item.zig)

Core-owned pure module (D-011: Core is the single authoritative source for
bundle-legality logic, `protocol_history.zig` precedent). Zero I/O; all
functions pure, allocator-parameterized. Exported for the product layer.

### `estimateTokens(len: usize) usize`

Truncating `len / 4` (bytes → tokens) — zag-defined v1, explicit divergence
from the historical `(len + 3) / 4` round-up. `IMAGE_TOKENS = 765` fixed
estimate per image part.

### `Message.estimateTokens() usize`

Sum over content, content_parts (image → 765, text → estimateTokens), tool_call
id/name/arguments, tool_call_id, reasoning.

### `assignPromptIndices(items: []Message, next: u32) u32` — pinned algorithm

- The turn counter increments **only at rows that start a turn**: `.user` rows,
  and synthetic rows with `prompt_index == null`.
- Turn-start rows receive the new (post-increment) index; all other rows
  receive the current index, so assistant/tool rows share their turn's index.
- Increments happen only when a stamp is applied (a persisted row with a
  non-null index does not bump the counter).
- Resume enters with `next = persisted_max` (the first new `.user` row lands
  on `max + 1`).
- Returns the next counter value for the caller to persist.

### `repairDanglingToolCalls(items: []const Message, allocator) ?[]const Message`

Tolerant pre-gate pass (product calls it before validation):
- drops `tool` rows whose `tool_call_id` has no preceding assistant `tool_calls`
  entry with the same id;
- drops `tool` rows with empty content and empty tool_call_id;
- leaves every legal bundle byte-identical;
- never creates or reorders content.

`null` when nothing was dropped (caller reuses the input slice); an owned slice
otherwise. The Core/loop path does NOT use this pass — `validateBodyHistory`
there stays authoritative.

### `truncateForPrompt(items: []const Message, budget_tokens: usize, min_tail: usize) TruncateResult`

```zig
pub const TruncateResult = struct {
    kept: []const Message,
    dropped: usize,
    dropped_chars: usize,
};
```

Token-budget truncate from the front, preserving:
- bundle legality (assistant-with-tool-calls + its contiguous tool results
  stay together — reuses `protocol_history.alignToLegalStart`/`unitEnd`
  directly, same Core package, no mirrored logic);
- `min_tail` most recent rows (soft budget — `min_tail > 0` rows are always
  kept);
- `budget_tokens = 0` with `min_tail = 0` → empty kept + full dropped count.

## 4. Core forwarding (packages/zag-agent-core/src/transcript.zig)

- `appendAssistantTurn(turn)` forwards `turn.reasoning` into the message.
- NEW `appendSyntheticReason(content: []const u8, prompt_index: ?u32)` appends
  `Message{ .role = .assistant, .content = content, .synthetic = true,
  .prompt_index = prompt_index }` — the caller (Core loop or product) supplies
  the index from its running turn counter (per the pinned assignPromptIndices
  rule: a null-index synthetic row starts a new turn; `null` defers to
  `assignPromptIndices`).
- No other Core change. `ContextView`/`View` types and the loop gate stay
  byte-identical.

## 5. Product composition (packages/zag-coding-agent/src/context.zig)

`viewForModel` pipeline becomes:

```text
repairDanglingToolCalls                      ← NEW stage 1 (tolerant, drop-only, view-only)
validate body (unchanged)                    ← stage 2, fail-closed
token-budget truncateForPrompt              ← NEW stage 3 (first budget stage)
count-trim (unchanged)                       ← stage 4, Stage A max_tail_messages
soft char-trim (unchanged)                   ← stage 5, under current summary cost
summary + layers + fixed-point (unchanged)   ← stages 6+ (re-costing keeps char accounting)
```

Repair runs on the *view* (scratch), never on the transcript. Incomplete
bundles, out-of-order results, duplicate/empty call ids, and
leading-system-without-tail still fail closed at stage 2. The token budget is
derived from the existing character budget (`max_chars / 4`,
`effectiveTokenBudget`), no new config option; the char-trim and fixed-point
machinery are retained unchanged.

## 6. Persistence (packages/zag-coding-agent/src/session_store.zig)

- `writeMessageRaw`: assistant rows gain optional `reasoning`; all rows gain
  optional `synthetic` and `prompt_index` (omitted when default).
- `appendMessageFromObject`: missing fields → null/false; schema_version stays 1.
- Header unchanged.
- **Redaction**: `writeMessageRedacted` gains `reasoning` redaction through the
  same per-field redact path as content (fixture: secrets inside reasoning are
  hidden in redacted saves; round-trip load of a redacted save yields the
  redacted text).

## 7. Adapters (packages/zag-ai)

- `openai_compat.zig` `turnFromResponse`: capture `reasoning_content` (string)
  into `AssistantTurn.reasoning`; stream path ignores reasoning deltas (v1) —
  the captured field covers non-stream turn assembly.
- `anthropic_messages.zig` `turnFromAnthropicValue`: capture
  `thinking`/`redacted_thinking` blocks (text joined `"\n"`) into
  `AssistantTurn.reasoning`. Signature-only redacted blocks (no text) contribute
  nothing.
- No re-emission to providers in v1.

## 8. Diagnostics & budgets

- Reasoning text is subject to existing redaction, size, and UTF-8 rules.
- No new diagnostics surface; no new config options in v1.
