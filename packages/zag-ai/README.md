# zag-ai

Monorepo AI package for Zag — agent-facing OpenAI Chat Completions layer over **openai-zig**.

Auth is env + JSON config only (no OAuth).

## Layout

| Module | Role |
|--------|------|
| `types` | Message / ContentPart / ToolCall / Usage / ChatOptions / StreamEvent / StreamHandler |
| `config` | 共享 `Config`（base_url / key / model / retries） |
| `http` | **中立** HTTP（`std.http` only；Bearer 或 header auth；**不**依赖 openai_zig） |
| `wire` | **WireAdapter** + `ApiStyle` + 共享 `Error` |
| `openai_compat` | OpenAI Chat Completions（**唯一**依赖 openai-zig resources 的适配器） |
| `anthropic_messages` | Anthropic Messages + SSE（只用 config/http/wire） |
| `presets` | ProviderSpec table (`api_style`) |
| `catalog` | Known model ids + context windows + budget helpers |
| `registry` | Resolve provider + `createWire` |
| `auth_env` | API key from env vars |
| `config_file` | `.zag/config.json` / `zag.json` (chat + transport knobs) |
| `openai_compat` | Default WireAdapter: chat + stream + embeddings (**via openai-zig**) |
| `stream` | SSE streaming chat (**via openai-zig**) |
| `contract_tests` | Wire-shape tests (no network) |
| `openai_zig` | Re-export of the full SDK |

## Dependency

```
zag → zag-ai → openai-zig
```

## Agent-facing API

```zig
// Preferred: WireAdapter (OpenAI-compat is the only style today)
var w = try ai.createWire(gpa, io, .{
    .base_url = "https://api.deepseek.com/v1",
    .api_key = key,
    .model = "deepseek-v4-flash",
    .max_retries = 2,
}, .openai_compat);
defer w.deinit();

const turn = try w.chat(arena, messages, tools, .{
    .temperature = 0.2,
    .max_tokens = 2048,
    .tool_choice = .auto,
});
// turn.content / turn.tool_calls / turn.usage

// Or Client (same backend) + borrowed wire:
var client = ai.Client.init(gpa, io, config);
defer client.deinit();
_ = ai.openAiCompatFromClient(&client);

// Multimodal user message
const parts = [_]ai.ContentPart{
    .{ .text = "describe this" },
    .{ .image_url = .{ .url = "https://example.com/a.png", .detail = "low" } },
};
const mm = ai.Message.userMultimodal(&parts);

// Embeddings (Client API)
const emb = try client.embed(arena, &.{"hello world"}, .{ .model = "text-embedding-3-small" });
```

Stream: `wire.chatStream` / `Client.chatStreamWithOptions` / `stream.chatStreamWithOptions`.

`Client.sdkClient()` returns `*openai_zig.Client` for models/files/responses/etc.

Wire styles:

| Style | Env / preset | Endpoint |
|-------|----------------|----------|
| `openai_compat` (default) | most presets | `/v1/chat/completions` |
| `anthropic_messages` | `ZAG_PROVIDER=anthropic` or `ZAG_API_STYLE=anthropic` | `/v1/messages` |

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export ZAG_PROVIDER=anthropic
# optional: ZAG_MODEL=claude-sonnet-4-20250514
```

## Resolve (harness entry)

```zig
var rr = try ai.resolve(gpa, io, env_map, config_path);
defer rr.deinit(gpa);
// rr.resolved.config / api_style
// rr.resolved.createWire(gpa, io) → WireAdapter
// rr.chat_options, model_info, chat_retries, stream, …
```

## Errors

| Error | Typical cause | Retry? |
|-------|---------------|--------|
| `AuthenticationFailed` | bad key | no |
| `RateLimited` | 429 | yes |
| `Timeout` | network/timeout | yes |
| `ServerError` | 5xx | yes |
| `BadRequest` | 4xx schema | no |
| `InvalidResponse` | bad JSON | no |

`ai.isRetryableError(err)` for policy. Transport retries live in openai-zig; the agent loop can retry again via `chat_retries`.

## Config file example

```json
{
  "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "stream": true,
  "temperature": 0.2,
  "max_tokens": 4096,
  "max_retries": 3,
  "retry_base_delay_ms": 500,
  "timeout_ms": 60000,
  "chat_retries": 2,
  "max_turns": 20,
  "context_max_chars": 100000,
  "parallel_tool_calls": true,
  "user": "zag-dev"
}
```

Env overrides (when set): `ZAG_TEMPERATURE`, `ZAG_MAX_TOKENS`, `ZAG_MAX_COMPLETION_TOKENS`,
`ZAG_MAX_RETRIES`, `ZAG_TIMEOUT_MS`, `ZAG_CHAT_RETRIES`, `ZAG_STREAM`.

## Catalog context budgets

Known models in `catalog.zig` supply `context_window` / `max_output_tokens`.
`catalog.contextBudgetChars` converts that into a soft char budget for the harness
context view (≈3 chars/token, reserve output, 15% margin). File `context_max_chars`
wins when set.

## Tests

```bash
cd packages/zag-ai && zig build test
# or monorepo root:
zig build test
```
