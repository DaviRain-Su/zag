---
id: tui-streaming-001
scope: loop/tui streaming
status: implementation-complete
priority: P1
depends-on:
  - tui-minimal-001
---

# objective

Deliver **streaming assistant output** to the host TUI (Grok-Build-style:
text appears incrementally while the model generates, instead of after the
full turn). Recon verified the wire layer already emits per-SSE-chunk
`content_delta` events and the TUI already has a thread-safe progressive
card mechanism; the gap is one vertical seam: the Core `Provider` port +
loop collapse deltas into a single complete `assistant_message`. This slice
threads content deltas from provider → loop → facade events → TUI
progressive card.

**Binding specification:** [tui-streaming.md](../../modules/tui-streaming.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — close-out re-review (two rounds closed 8 blockers + 2 suggestion fixtures; zero blockers) |
| Implementation | **complete** — std 764/764, curl 763/763, TUI std 825/825, TUI curl 824/824; streaming is the default transport |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 | **unchanged** (delta events UI-only; usage parity kept; headless wire unchanged) |
| tui-minimal-001 | closed — this slice builds on it |

# context

- Wire layer emits per-chunk deltas today: `openai_compat.zig:382-393`
  (`content_delta`), `anthropic_messages.zig:382-387`; the ONLY consumer is
  CLI verbose logging (`cli.zig:434-437`).
- Core `Provider` port (`provider.zig:21-29`) has a single `chat` vtable slot
  with no handler parameter — deltas die there (`loop.zig:618` gets one
  complete turn; `loop.zig:268-271` emits one complete `assistant_message`).
- Facade events (`LoopEvent` loop_event.zig:22-80; `Observer` observer.zig:
  12-27; `LifecycleObserver` lifecycle.zig:42-114) all carry complete-turn
  events only.
- TUI: worker thread already publishes lifecycle/observer cards
  (`app.zig:244-335`); `CardRing` is spin-mutex-guarded with locked
  snapshots (`cards.zig:73,216-241`); progressive body replacement exists
  (`replaceNewestOrdinaryTitlePrefix` cards.zig:124-160); render + wake
  already handle partial cards (`render.zig:93-99`, `app.zig:232-234`).
- Reference: hyper `agent_view/render.rs` streaming blocks + `Present`
  batching — architecture direction only, not parity.

# path

| Path | Role |
|------|------|
| `packages/zag-agent-core/src/provider.zig` | NEW optional vtable slot `chat_stream` (= null default), fallback to `chat` when absent |
| `packages/zag-agent-core/src/loop_event.zig` | NEW variants `assistant_delta: []const u8`, `assistant_delta_clear` |
| `packages/zag-agent-core/src/loop.zig` | `chatWithRetry` uses `chat_stream` when present; forwards deltas; sink-error latch; emits `assistant_delta_clear` on any failed attempt |
| `packages/zag-coding-agent/src/wire_provider.zig` | implement `chat_stream` (reuse `chatImpl` body; chain existing `on_event` first; forward content deltas) |
| `packages/zag-ai/src/openai_compat.zig` | SSE path captures usage (final chunk / `stream_options.include_usage`) — usage parity with the non-stream path |
| `packages/zag-coding-agent/src/observer.zig` + `lifecycle.zig` + `agent.zig` | new `assistant_delta`/`assistant_delta_clear` variants + bridge forwarding |
| `packages/zag-cli/src/headless_writer.zig` | explicit skip cases for the delta variants (headless-v1 protocol output unchanged — the dispatch switch is exhaustive) |
| `packages/zag-tui/src/app.zig` | accumulate deltas into the progressive assistant card (prefix "assistant progressive" only); clear on `assistant_delta_clear` / complete `assistant_message` / `run_terminal` |
| Forbidden | Session v1 schema, Trace v1 **wire schema** (content parity still required — usage lines unchanged), headless-v1 **wire protocol** (dispatch switch may add skips), chapters, docs (except this task's own docs) |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Provider port | `Provider` gains optional `chat_stream` slot with **explicit `= null` default** (Zig optional struct fields get no implicit default — without it 60+ existing construction sites fail to compile): `chat_stream: ?*const fn(ptr, arena, messages, tools, control, handler, handler_ctx) ChatError!AssistantTurn = null` — the slot carries the SAME per-call parameters as `chat` (the wire adapter needs arena/messages/tools/control); `chat` stays; loop falls back to `chat` when `chat_stream` is absent |
| Delta scope | content deltas ONLY (`content_delta`); tool_call_delta / finish_reason remain inside the wire adapter's stream state machine (already accumulated into the returned `AssistantTurn`) — NOT forwarded in v1 |
| Loop emission | deltas stream during EVERY attempt; on ANY failed attempt (incl. Cancelled/Timeout/UnsupportedControl), emission order is pinned: `assistant_delta_clear` → `provider_retry` → sleep/terminal; complete `assistant_message` + transcript behavior unchanged |
| Sink errors | delta handler **latches the first SinkError** into its handler ctx (never `catch {}` silently — D-011 never-swallow); `chatWithRetry` checks the latch immediately after `chat_stream` returns and maps it via `mapSinkEmit` (sink error wins over both a returned turn and a provider error) |
| Facade | `assistant_delta`/`assistant_delta_clear` forwarded Observer-first then lifecycle (same order as `assistant_message`); verbose-log formatting skips deltas (too chatty) |
| TUI | `onObserver` accumulates deltas into an App-owned buffer (≤ `card_body_max_bytes` = 4096, **UTF-8-boundary truncation** via the `utf8Prefix` pattern — a mid-sequence cut would make `presentInto` mark the whole body invalid); delta replaces match prefix `"assistant progressive"` ONLY (freeze card identity: a new turn's first delta publishes a fresh progressive card, the finalized `"assistant turn=N"` card stays intact); complete `assistant_message` → reset buffer + existing retitle path; `assistant_delta_clear` → reset buffer; `run_terminal` → reset buffer (belt-and-braces for the sink-failure edge); title prefixes are named constants in one place; redaction per replace via the existing whole-body path |
| Retry semantics | deltas from a failed attempt are visible until the clear event arrives (sub-poll-latency), then vanish — honest, no cross-attempt accumulation |
| Stream config | **streaming becomes the default transport**: `stream` default flips false → true (root.zig ProviderOptions + config_file default); explicit config/env/flag `stream: false` still disables it (chatStreamImpl falls back to `wire.chat`, semantics unchanged); the loop uses `chat_stream` whenever present; `wire_provider.chat_stream` **chains the pre-existing wire `on_event` first** (CLI `--stream --verbose` diagnostics keep firing), then forwards content deltas to the Core handler; TUI does NOT set `wire_prov.on_event` directly; headless/CLI output byte-identical (loop returns the complete turn either way) |
| Usage integrity | the always-stream path must keep usage accounting identical to today: the openai_compat SSE path must capture usage (final chunk / `stream_options.include_usage`) so Observer usage events, ledger/cost, Trace usage lines, `Result.usage`, and TUI run_terminal p/c/t stay intact (gate fixture: usage survives the always-stream path); Trace v1 schema unchanged, content parity kept |
| Divergence from reference | no tool-delta streaming, no per-chunk redaction, no ThinkingBlock streaming, no render checkpointing in v1 |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| Provider fallback | provider without `chat_stream` → loop behaves byte-identical (existing loop suite green unchanged) |
| Delta forwarding | streaming provider: N deltas arrive in order before the complete `assistant_message`; borrowed slices valid during emit |
| Retry clear | attempt 1 streams 3 deltas then fails → `assistant_delta_clear` emitted, then `provider_retry`, then sleep; attempt 2 streams 2 deltas + success → final transcript/`assistant_message` complete and correct; no delta after terminal; Cancelled/Timeout attempt with partial deltas → clear emitted (no partial text under run_terminal) |
| Usage parity | always-stream path: Observer usage event + ledger/cost + Trace usage line + Result.usage + TUI run_terminal p/c/t identical to the non-stream path (SSE usage captured) |
| Card identity | turn-1 finalized card ("assistant turn=1") survives turn-2 streaming unchanged; turn-2 first delta creates a fresh "assistant progressive" card |
| UTF-8 cap | accumulator truncation at 4096 lands on a codepoint boundary; fixture asserts truncated body content renders (not the invalid_utf8 marker) |
| Sink error | delta emit SinkError latched → chatWithRetry returns the sink error (sink wins over provider result) |
| on_event chaining | `wire_prov.on_event` set + loop streaming: BOTH the wire diagnostics consumer and the Core handler receive deltas |
| Facade order | Observer receives deltas before lifecycle; complete message after deltas; clear before attempt-2 deltas |
| TUI accumulation | delta sequence → progressive card body grows in order; clear → body reset; complete message → accumulator reset; body cap 4096 truncates |
| TUI no-crash | deltas arriving between `assistant_message` and next turn start reset correctly (turn boundary) |
| Redaction | delta body containing a configured secret → redacted in the card (existing redactor path) |
| Regression | default + curl matrices, TUI matrix, SDK fixture — all green; headless-v1 unchanged (no delta in headless output) |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (default +
  TUI matrices, std + curl); **no** maturity raise; **no** remote `-Dtui`
  claim.

# non-goals

- tool_call_delta / finish_reason / ThinkingBlock streaming
- Per-chunk redaction (whole-body replace per chunk is fine)
- Render checkpointing / streaming markdown parsing
- Persisting deltas (Session v1 / Trace v1 / headless-v1 unchanged)
- Changes outside the listed paths
- Maturity raise

# related

- [tui-streaming.md](../../modules/tui-streaming.md) (binding)
- [tui-minimal-001](./tui-minimal-001.md) · [tui-layout-001](./tui-layout-001.md)
- [C9-product-shell.md](../../phases/C9-product-shell.md)
- Reference: hyper `agent_view/render.rs` streaming blocks + `StreamingMarkdownRenderer` checkpoints — direction only
