# TUI streaming output (binding)

> Binding spec for `tui-streaming-001`
> ([task](../plan/tasks/tui-streaming-001.md)). Threads content deltas from
> the wire layer through the Core provider port, the loop, the facade
> events, and into the TUI's progressive assistant card — Grok-Build-style
> streaming with minimal vertical seams.

## 1. Principles

1. **Deltas flow through the loop, not around it**: the TUI never touches
   `wire_prov.on_event`; all streaming goes through the Core port + loop so
   retry accounting and turn identity stay with the harness.
2. **Borrowed, in-order, synchronous**: `assistant_delta` slices are valid
   only during emit — same discipline as every existing `LoopEvent` variant.
3. **Retry honesty**: a failed attempt's deltas are erased by
   `assistant_delta_clear`; no cross-attempt accumulation.
4. **Transcript truth unchanged**: the loop still appends one complete
   `AssistantTurn`; deltas are UI-visible only.

## 2. Provider port (packages/zag-agent-core/src/provider.zig)

```zig
pub const DeltaHandler = *const fn (ctx: *anyopaque, content_delta: []const u8) void;

// NEW optional slot (must default null — Zig gives optional struct fields no
// implicit default; without it every existing VTable literal breaks):
chat_stream: ?*const fn (
    ctx: *anyopaque,
    arena: std.mem.Allocator,
    messages: []const Message,
    tools: []const ToolDefinition,
    control: RequestControl,
    handler: DeltaHandler,
    handler_ctx: *anyopaque,
) ChatError!AssistantTurn = null,
```

- `chat_stream == null` → loop uses `chat` (existing behavior byte-identical).
- The slot carries the same per-call parameters as `chat` (the wire adapter
  needs arena/messages/tools/control).
- Content deltas are forwarded as they arrive (per SSE chunk).

## 3. Loop (packages/zag-agent-core/src/loop.zig)

`chatWithRetry`:

- when `provider.chat_stream` is present, call it with a delta handler that
  emits `LoopEvent.assistant_delta` per chunk — deltas stream during EVERY
  attempt;
- on ANY failed attempt (error return, Cancelled, Timeout,
  UnsupportedControl), emission order is pinned:
  `assistant_delta_clear` → `provider_retry` → sleep/terminal;
- **sink errors are never swallowed**: the handler latches the first
  SinkError into its handler ctx; `chatWithRetry` checks the latch
  immediately after `chat_stream` returns and maps it via `mapSinkEmit`
  (sink error wins over both a returned turn and a provider error);
- the complete `AssistantTurn` returned still goes through the existing
  append + `assistant_message` path (transcript + trace + lifecycle
  unchanged).

## 4. Usage parity (packages/zag-ai/src/openai_compat.zig)

The always-stream path must keep usage accounting identical to today: the
SSE path captures usage (final chunk / `stream_options.include_usage`) so
Observer usage events, ledger/cost, Trace usage lines, `Result.usage`, and
TUI run_terminal p/c/t stay intact. Trace v1 schema unchanged, content
parity kept. Gate fixture: usage survives the always-stream path.

## 4. Events (loop_event.zig / observer.zig / lifecycle.zig / agent.zig)

```zig
// LoopEvent (Core):
assistant_delta: []const u8,   // borrowed, in-order
assistant_delta_clear,          // attempt boundary: erase accumulated UI text

// Observer + LifecycleObserver (product facade): matching variants.
```

Bridge forwarding order: Observer first, then lifecycle (same as
`assistant_message`). Verbose log formatting: deltas skipped (chatty); the
complete `assistant_message` log line unchanged.

## 5. TUI (packages/zag-tui/src/app.zig)

- App owns a delta accumulator buffer (≤ 4096 bytes = `card_body_max_bytes`),
  truncated on a **UTF-8 codepoint boundary** (utf8Prefix pattern — a
  mid-sequence cut makes `presentInto` mark the whole body invalid).
- `onObserver` `assistant_delta`: append (UTF-8-safe truncation) →
  `replaceNewestOrdinaryTitlePrefix(gpa, red, TITLE_PROGRESSIVE, ...)` →
  `wake()`. Delta replaces match `TITLE_PROGRESSIVE = "assistant
  progressive"` ONLY — **card identity frozen**: the first delta of a new
  turn publishes a fresh progressive card; the finalized
  `TITLE_TURN = "assistant turn={d}"` card is never clobbered by partial
  text (complete-message paths keep the `"assistant"` prefix retitle).
- `assistant_delta_clear`: reset buffer (card body replaced with empty
  state). Reset ownership: observer owns the clear-reset; lifecycle owns
  the complete-message reset; `run_terminal` also resets (sink-failure
  edge). No double-reset ordering bugs: the three resets are idempotent.
- Title prefixes are named constants (`TITLE_PROGRESSIVE`/`TITLE_TURN`) in
  one place so prefix rules stay in lockstep with cards.zig:124.
- Redaction: each replace goes through the existing whole-body redaction
  path (O(n) per chunk, n ≤ 4096 — accepted).

## 5b. Wire on_event chaining (wire_provider.zig)

`wire_provider.chat_stream` invokes the pre-existing `wire.on_event`
consumer FIRST (CLI `--stream --verbose` diagnostics keep firing with
unchanged semantics), then forwards content deltas to the Core handler.
Fixture: both consumers receive deltas when `on_event` is set.

## 6. Tests

- Provider fallback (null slot → existing behavior).
- Delta forwarding order + borrowed-slice validity.
- Retry clear: attempt 1 deltas → clear → attempt 2 deltas → complete;
  Cancelled/Timeout partial deltas → clear, no partial text under
  run_terminal.
- Usage parity: always-stream path usage identical to non-stream (Observer
  + ledger + Trace + Result + TUI p/c/t).
- Card identity: turn-1 finalized card survives turn-2 streaming.
- UTF-8 cap: truncated body renders content (not the invalid marker).
- Sink error: latched error wins over provider result.
- on_event chaining: wire diagnostics + Core handler both receive deltas.
- Facade order (observer before lifecycle).
- Regression: default + curl + TUI matrices, SDK fixture, headless-v1 wire
  unchanged.

## 7. Supersession note

`tui-minimal.md` (:380-393) closed with "no public message_delta, no
token-stream claim" — this binding supersedes that statement for the delta
path. All other tui-minimal-001 contracts stand.

## 8. Diagnostics & budgets

- No new config; no new diagnostics; delta path adds no persisted state.
- Stack/heap: accumulator is App-owned (≤ 4096 B); no per-chunk allocation
  beyond the existing card replace path.
