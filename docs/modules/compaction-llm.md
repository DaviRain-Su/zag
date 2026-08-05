# LLM compaction summaries (M3.3 binding)

> Binding spec for `compaction-llm-001`
> ([task](../plan/tasks/compaction-llm-001.md)). Adds an optional
> LLM-generated compaction summary behind a provider seam, with pure
> serialization/prompt/cleaning helpers, a retry ladder, and unconditional
> fallback to the existing heuristic — h-context-001 behavior is
> byte-identical when no summarizer is configured.

## 1. Principles

1. **Heuristic is the floor**: the existing `buildSummary` path is the
   default; LLM summaries are an opt-in improvement that can never make a
   compaction worse (fallback on any failure).
2. **Pure layer, injected seam**: serialization, prompt building, cleaning,
   and retry policy are pure logic in Core (`session_item.zig`); the provider
   call arrives via a vtable injected by the product layer — Core never talks
   to a provider.
3. **Event shape frozen**: the compaction event (dropped count + summary
   text) and its session/trace propagation are unchanged; only the summary
   text source differs.
4. **Schema frozen**: Session v1 unchanged; no firstKeptEntryId in v1.

## 2. Pure functions (packages/zag-agent-core/src/session_item.zig)

### `serializeConversationForSummary(items: []const Message, allocator) ![]u8`

Pi semantics, role-tagged flat text (not JSON):

```text
[User]: {content}
[Assistant thinking]: {reasoning}
[Assistant]: {content}
[Assistant tool calls]: {name}({id}, {arguments})
[Tool result]: {content truncated at 2000 chars}
```

- Tool results truncated at `TOOL_RESULT_MAX_CHARS = 2000` with suffix
  `[... N more characters truncated]`.
- `reasoning` emitted as `[Assistant thinking]` when set.
- Content parts: text parts joined `\n`; images as `[image: {url}]`.
- System rows: `[System]: {content}`.

### `buildSummaryPrompts(allocator, options) SummaryPrompts`

```zig
pub const SummaryPrompts = struct {
    system: []u8,   // pi SUMMARIZATION_SYSTEM_PROMPT
    prompt: []u8,   // INITIAL or UPDATE
};
```

- INITIAL prompt = pi `SUMMARIZATION_PROMPT` (structured checkpoint skeleton:
  `## Goal / ## Constraints & Preferences / ## Progress (Done/In Progress/
  Blocked) / ## Key Decisions / ## Next Steps / ## Critical Context`).
- UPDATE prompt = pi `UPDATE_SUMMARIZATION_PROMPT` when a prior summary is
  supplied; prior text embedded in `<previous-summary>…</previous-summary>`.
- Serialized conversation is prepended by the caller as the message content
  (single user message).

### `formatCompactSummary(allocator, raw: []const u8) ![]u8`

Rust semantics:
- strip leading `<analysis>…</analysis>` blocks (loop; unclosed → drop to
  next `<summary>` or end);
- convert outer `<summary>…</summary>` to `Summary:\n{inner}`;
- neutralize control tokens: insert U+200B after `<` in
  `<summary>/</summary>/<analysis>/</analysis>/<summary_request>/
  <summary_request>`;
- collapse 3+ newlines to 2; trim.

### `isDegenerateSummary(cleaned: []const u8) bool`

`visible char count < MIN_SUMMARY_SEED_CHARS = 500` (whitespace-stripped).

### `summarizeWithRetry(allocator, summarizer: CompactionSummarizer, request, max_attempts = 3, delay_ms = 3000) !?[]u8`

- Per attempt: call the seam; `ok` → clean + degenerate check (degenerate →
  transient retry); `err.kind == .deterministic` or `.context_overflow` →
  abort; `.timeout`/`.transient` → retry after delay.
- Returns `null` after final failure (caller falls back to heuristic).
- `max_tokens = @max(1, @min(0.8 * effectiveTokenBudget(), 256))` — usize
  arithmetic, overflow-safe (min with 256 bounds every cast); unlimited-budget
  config → 256. summary_cap (800 chars) still clamps the final composed text.
- **Propagates `error.OutOfMemory`** (does not return null); the caller's
  replacement point catches OOM and falls back to the heuristic path.

## 3. Seam (types in L0, port consumed by Core)

Seam types live in `packages/zag-types/src/root.zig` (neutral provider-facing
types — ChatError/RequestControl precedent; L0 keeps Core→product imports
impossible):

```zig
pub const SummaryRequest = struct {
    prompt: []const u8,     // serialized conversation (user content)
    system: []const u8,     // summarization system prompt
    max_tokens: u32,
};

pub const SummaryErrorKind = enum { timeout, deterministic, transient, context_overflow };

pub const SummaryResult = union(enum) {
    ok: struct { text: []const u8 },
    err: struct { kind: SummaryErrorKind, message: []const u8 },
};

pub const CompactionSummarizer = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        summarize: *const fn (ptr: *anyopaque, request: SummaryRequest) SummaryResult,
    },
};
```

Core (`session_item.zig`) defines `summarizeWithRetry` over the port (mirror
of D-011 ContextView: Core defines, product implements); product `Options`
gains `summarizer: ?CompactionSummarizer = null`; no new user-facing config.

## 4. Composition (viewForModel)

**After** the fixed-point loop converges (final `dropped` set), when
`dropped > 0` and `opts.summarizer != null` and the skip guard passes:

0. skip guard: `4 * max_tokens < MIN_SUMMARY_SEED_CHARS` (budget < ~157
   tokens) → heuristic stands, summarizer never called;
1. serialize `working[0..dropped]`;
2. build prompts (INITIAL or UPDATE with `layers.session` prior); the caller
   concatenates serialized conversation + `\n\n` + template (conversation
   first, then instructions); system = pi SUMMARIZATION_SYSTEM_PROMPT;
3. `summarizeWithRetry` with `max_tokens = @max(1, @min(0.8 *
   effectiveTokenBudget(), 256))` (usize arithmetic; unlimited-budget config
   → 256);
4. success → **composed event summary** = cleaned LLM text + `\n` + lineage
   section (existing `writeLineage` semantics), clamped to summary_cap on a
   UTF-8 boundary with the existing sanitize machinery; replaces the heuristic
   text in the final compaction event only (convergence loop saw heuristic
   length — next turn's layers cost the real length);
5. failure (`null` after retries) or `error.OutOfMemory` → heuristic summary
   stands (OOM caught at the replacement point; turn continues;
   noteCompaction OOM atomicity unchanged).

The serialized conversation sent to the provider is subject to the product's
existing redaction. The composed summary is arena-owned (event contract).
The convergence loop is byte-identical with or without a summarizer.
With `summarizer == null` the whole path is byte-identical to today.

## 5. Product implementation (packages/zag-coding-agent/src/agent.zig)

`CompactionSummarizer` impl over the existing provider (the same chat path
used for turns): single user message (serialized conversation), system
prompt, `max_tokens` from the request, `RequestControl` with a bounded
deadline; maps provider errors to `SummaryErrorKind` (timeout →
`.timeout`; auth/schema → `.deterministic`; rate-limit/network →
`.transient`; context-length → `.context_overflow`). Wired into
`bridgeContextView` via `a.options.context.summarizer`.

## 6. Diagnostics & budgets

- No new diagnostics; compaction event carries the LLM text (subject to
  existing UTF-8 sanitize + summary_cap clamps).
- No new config options; reserve_tokens derived from the existing effective
  budget derivation.
