# zag-ai

Monorepo AI package for Zag — agent-facing OpenAI Chat Completions layer over **openai-zig**.

Auth is env + JSON config only (no OAuth).

## Layout

| Module | Role |
|--------|------|
| `types` | Message / ToolCall / Usage / ChatOptions / StreamEvent |
| `presets` | ProviderSpec table |
| `catalog` | Known model ids + context windows |
| `registry` | Resolve provider from env |
| `auth_env` | API key from env vars |
| `config_file` | `.zag/config.json` / `zag.json` |
| `openai_compat` | Non-streaming chat (**via openai-zig**) |
| `stream` | SSE streaming chat (**via openai-zig**) |
| `contract_tests` | Wire-shape tests (no network) |
| `openai_zig` | Re-export of the full SDK |

## Dependency

```
zag → zag-ai → openai-zig
```

## Agent-facing API

```zig
var client = ai.Client.init(gpa, io, .{
    .base_url = "https://api.deepseek.com/v1",
    .api_key = key,
    .model = "deepseek-v4-flash",
    .max_retries = 2,
});
defer client.deinit();

const turn = try client.chatWithOptions(arena, messages, tools, .{
    .temperature = 0.2,
    .max_tokens = 2048,
    .tool_choice = .auto,
});
// turn.content / turn.tool_calls / turn.usage
```

Stream: `stream.chatStream` / `chatStreamWithOptions`.

`Client.sdkClient()` returns `*openai_zig.Client` for models/files/responses/etc.

## Errors

| Error | Typical cause | Retry? |
|-------|---------------|--------|
| `AuthenticationFailed` | bad key | no |
| `RateLimited` | 429 | yes |
| `Timeout` | network/timeout | yes |
| `ServerError` | 5xx | yes |
| `BadRequest` | 4xx schema | no |
| `InvalidResponse` | bad JSON | no |

`ai.isRetryableError(err)` for policy.

## Config file example

```json
{
  "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "stream": true
}
```

## Tests

```bash
cd packages/zag-ai && zig build test
# or monorepo root:
zig build test
```
