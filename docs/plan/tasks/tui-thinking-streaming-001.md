---
id: tui-thinking-streaming-001
scope: thinking/streaming
status: implemented
priority: P1
depends-on:
  - tui-streaming-001
---

# objective

Stream the model's reasoning/thinking text live into the TUI (currently
turn-granular: reasoning appears only when the assistant turn completes).
OpenAI `reasoning_content` deltas and Anthropic `thinking` deltas flow
wire → Core `thinking_delta` event → lifecycle → progressive `· thinking`
card (gated by the existing Ctrl+T toggle).

# status truth

| Track | Status |
|-------|--------|
| Contract | **contract-approved** — independent review approve-with-fixes findings absorbed (review #1-#8) |
| Implementation | **implemented** — wire fixtures (OpenAI reasoning_content / Anthropic thinking), Core 't'-tag ordering fixtures, coding-agent lifecycle forwarding, TUI progressive/final/multi-turn/toggle fixtures; 4 matrices green, PTY 13/13 |
| Session v1 / Trace v1 / headless-v1 | unchanged (thinking_delta is UI-visible only, same discipline as assistant_delta) |
| Default transport | streaming stays default; non-stream fallback emits no deltas (thinking arrives via assistant_message.reasoning as today) |

# context

- OpenAI: `packages/openai-zig/src/generated/types.zig:3205-3214`
  `ChatCompletionStreamResponseDelta` has NO `reasoning_content` (the
  non-stream message type at :3180-3181 does). Must be added to the
  generated type + the wire chunk parser.
- Anthropic: `anthropic_messages.zig` stream path (handleSseEvent
  335-464) silently drops `thinking_delta`/`thinking_block` events; the
  non-stream path already captures thinking (713-720).
- Core: `loop.zig` deltaHandler (601-613) emits `assistant_delta` per
  content chunk; `loop_event.zig` has `assistant_delta` /
  `assistant_delta_clear`. Turn reasoning already flows through
  `assistant_message.reasoning` (loop.zig:271).
- TUI: `show_thinking` toggle (Ctrl+T) publishes a `· thinking` card on
  `assistant_message.reasoning` (app.zig onLifecycle).

# path

| Path | Role |
|------|------|
| `packages/openai-zig/src/generated/types.zig` | add `reasoning_content: ?[]const u8` to ChatCompletionStreamResponseDelta |
| `packages/zag-types/src/root.zig` | `StreamEvent` union (root.zig:555-565) gains `reasoning_delta: []const u8` variant (the handler is an event-switch, not a fn-ptr — review #1) |
| `packages/zag-ai/src/openai_compat.zig` | OpenAiStreamState reasoning buffer; onOpenAiSdkEvent: `choice.delta.reasoning_content` → guard len>0 → append + emit `.{ .reasoning_delta = chunk }`; finish() returns `.reasoning = null` when buffer empty (review #6) |
| `packages/zag-ai/src/anthropic_messages.zig` | StreamState reasoning buffer; handleSseEvent: content_block_start type=thinking (field `thinking`) + type=redacted_thinking (field `data`) (review #4) + content_block_delta thinking_delta; join rule: `\n` before block-initial text when buffer non-empty, deltas appended raw, block stop no-op (review #5) |
| `packages/zag-agent-core/src/provider.zig` | DeltaHandler gains optional `reasoning_delta` slot (nil → no thinking events) |
| `packages/zag-agent-core/src/loop_event.zig` | `thinking_delta: []const u8` variant (borrowed, in-order); NO separate clear (assistant_delta_clear clears both, TUI resets) |
| `packages/zag-agent-core/src/loop.zig` | deltaHandler forwards reasoning_delta from the handler ctx; RecordingSink gains thinking_deltas counter + 't' tag (review #7) |
| `packages/zag-coding-agent/src/wire_provider.zig` | StreamShim forwards reasoning_delta into the Core loop event stream |
| `packages/zag-coding-agent/src/agent.zig` + `lifecycle.zig` | forward `thinking_delta` to lifecycle only (observer/headless byte-identity — review #1) |
| `packages/zag-cli/src/cli.zig` | formatter switch: thinking_delta ignored (stream stdout path unchanged — lifecycle-only) |
| `packages/zag-tui/src/app.zig` | `TITLE_THINKING_PROGRESSIVE = "thinking progressive"` (keeps the "thinking" prefix for render body painting; distinct from the final title so turn N+1 deltas never clobber turn N's final card — review #2); onObserver handles thinking_delta (progressive card), onLifecycle.assistant_message does the final replace (review #8) |
| `packages/zag-tui/src/render.zig` | no change needed (thinking card already renders title + body) |
| Forbidden | Session schema, Trace schema, headless envelopes, transcript serialization |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Wire delta | `StreamEvent.reasoning_delta: []const u8` (borrowed, per chunk) — parallel to content_delta; empty chunks never emitted (guard len>0) |
| OpenAI | patch the generated delta type with `reasoning_content: ?[]const u8` (JSON `reasoning_content` string; absent → null); stream state accumulates a reasoning buffer joined per chunk (no separator — provider emits complete segments); final turn `.reasoning` from the buffer |
| Anthropic | handle `thinking_delta` (content_block_delta type=thinking_delta, field `delta`/`thinking`), `content_block_start` type=thinking (field `thinking` initial text), `content_block_stop` for thinking blocks; accumulate joined with `\n` between blocks (mirrors non-stream appendReasoningLine) |
| Core | `thinking_delta: []const u8` emitted in order between assistant_deltas; attempt failure → existing `assistant_delta_clear` clears BOTH content and thinking UI text (single clear event, TUI resets both) |
| TUI | `show_thinking` on → `thinking_delta` updates a progressive card titled `thinking progressive` (replace newest "thinking"-prefixed card, publish if none); final replace rule (review #3): progressive card exists → replace + retitle to `thinking`; else reasoning non-empty → publish fresh (non-stream fallback path); reasoning null/empty → drop the progressive card if present; toggle off → deltas ignored |
| Compaction | thinking text already serialized (`[Assistant thinking]: ...`) — unchanged |
| Divergence | no streaming checkpoint/throttle in v1 (deltas are small; md benchmark ≈1ms/4KB) |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| OpenAI wire | chunk with reasoning_content accumulates; finish yields turn.reasoning; absent field → null; non-stream turnFromResponse unchanged |
| Anthropic wire | thinking_delta / thinking start / stop assemble reasoning joined by \n; text deltas unaffected; ordering with tool_use preserved |
| Core | thinking_delta emitted in order with assistant_delta; retry attempt failure emits ONE clear (TUI resets both); non-stream fallback emits no thinking_delta; turn reasoning still on assistant_message |
| Coding-agent | lifecycle forwards thinking_delta; recorder owns/frees |
| TUI | toggle on: thinking_delta builds progressive card; assistant_message replaces it (no duplicates); toggle off: no card; multi-turn: turn-2 thinking replaces only turn-2 progressive (prefix rule) |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Streaming checkpoints / throttling
- Session/Trace schema changes
- OpenAI non-stream path changes (already captures reasoning)

# related

- [tui-streaming-001](./tui-streaming-001.md) · [tui-markdown-001](./tui-markdown-001.md)

# closeout

- Commit: `22b8980` (zag-tui: stream thinking deltas into a progressive card (Ctrl+T)) — combined-tree commit also carrying m4-sampler-resilience-001 and session-resume-tui-001 code; task-doc closeout lines land as doc-only follow-ups.
