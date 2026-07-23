# zag-ai

Multi-wire LLM package for Zag: **canonical messages** + **pluggable WireAdapters**.

Auth is env + JSON config only (no OAuth).

## Layout

| Module | Role |
|--------|------|
| `types` | Canonical Message / ToolCall / Usage / ChatOptions / StreamEvent |
| `config` | Shared `Config` (base_url / key / model / retries) |
| `wire` | `WireAdapter` vtable, `ApiStyle`, shared `Error` |
| `http` | Neutral `std.http` client (Bearer or header auth) |
| `factory` | `createWire(style)` — vendor-neutral |
| `stream` | Re-export stream **types** only (no vendor impl) |
| `openai_compat` | OpenAI Chat Completions + SSE (**only** openai-zig consumer for chat) |
| `anthropic_messages` | Anthropic Messages + SSE (http only) |
| `presets` / `catalog` / `registry` | Resolve + model tables |
| `config_file` | `.zag/config.json` |
| `contract_tests` | Wire-shape tests (no network) |

## Dependency

```
agent-core / coding-agent / cli
        → zag-ai  (wire + factory + adapters)
              ├─ openai_compat → openai-zig
              └─ anthropic_messages → std.http only
```

## Preferred API

```zig
// Multi-style entry
var w = try ai.createWire(gpa, io, config, .openai_compat);
// or .anthropic_messages
defer w.deinit();
const turn = try w.chat(arena, messages, tools, opts);
_ = try w.chatStream(arena, messages, tools, handler, ctx, opts);

// Resolve then wire
var rr = try ai.resolve(gpa, io, env, null);
defer rr.deinit(gpa);
var w2 = try rr.resolved.createWire(gpa, io);
defer w2.deinit();
```

OpenAI-only helpers (when you need embeddings / full SDK):

```zig
var client = ai.OpenAiClient.init(gpa, io, config);
defer client.deinit();
const emb = try client.embed(arena, &.{"hi"}, .{});
// client.sdkClient() → *openai_zig.Client
```

`ai.Client` remains an alias of `OpenAiClient` for back-compat.

## Wire styles

| Style | How to select | Endpoint |
|-------|----------------|----------|
| `openai_compat` | default presets, `ZAG_API_STYLE=openai` | `/chat/completions` |
| `anthropic_messages` | `ZAG_PROVIDER=anthropic` or `ZAG_API_STYLE=anthropic` | `/v1/messages` |

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export ZAG_PROVIDER=anthropic
zig build run -- --stream -v "hello"
```

## Errors

Shared `wire.Error` / `ai.WireError`.  
`openai_compat.mapSdkError` maps **openai-zig** names only.

`ai.isRetryableError(err)` for loop policy.

## Tests

```bash
cd packages/zag-ai && zig build test
# or monorepo:
zig build test
```
