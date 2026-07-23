# openai-zig

OpenAI-compatible API client for Zig, vendored and maintained inside the **Zag** monorepo.

Originally based on [DaviRain-Su/openai-zig](https://github.com/DaviRain-Su/openai-zig); ported to **Zig 0.16** (`std.Io`, Juicy Main, no global env).

## Status

- Runtime: `src/transport/http.zig` (retries, proxies, DeepSeek `/beta` routing, SSE stream)
- Resources: OpenAPI-generated surface under `src/resources/*.zig`
- Chat streaming: `chat.create_chat_completion_stream`
- Config demos: simple key=value / TOML-like file + env map (no zig-toml dep)

## Zig 0.16 notes

```zig
var client = try openai_zig.initClient(gpa, .{
    .io = io, // required
    .base_url = "https://api.deepseek.com/v1",
    .api_key = key,
});
defer client.deinit();

var chat = try client.chat().create_chat_completion(gpa, .{
    .model = "deepseek-chat",
    .messages = &.{
        .{ .role = "user", .content = "hello" },
    },
});
defer chat.deinit();
```

## In this monorepo

| Package | Role |
|---------|------|
| `packages/openai-zig` | Full OpenAI-compatible SDK |
| `packages/zag-ai` | Agent-facing types, presets, registry; wraps openai-zig for chat/stream |

Root: `zig build` / `zig build test` builds both.

## Standalone package

```sh
cd packages/openai-zig
zig build
zig build test
zig build run   # needs OPENAI_API_KEY or config/config.toml
```

## Config (demos only)

`config/config.toml` (simple key=value):

```toml
api_key = "sk-..."
base_url = "https://api.deepseek.com/v1"
model = "deepseek-chat"
```

Env (via Juicy Main `environ_map`): `OPENAI_API_KEY` / `DEEPSEEK_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_MODEL`, etc.
