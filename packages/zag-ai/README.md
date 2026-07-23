# zag-ai

Monorepo AI package for Zag — agent-facing OpenAI Chat Completions layer over **openai-zig**.

Auth is env + JSON config only (no OAuth).

## Layout

| Module | Role |
|--------|------|
| `types` | Message / ToolCall / StreamEvent |
| `presets` | ProviderSpec table |
| `catalog` | Known model ids + context windows |
| `registry` | Resolve provider from env |
| `auth_env` | API key from env vars |
| `config_file` | `.zag/config.json` / `zag.json` |
| `openai_compat` | Non-streaming chat (**via openai-zig**) |
| `stream` | SSE streaming chat (**via openai-zig**) |
| `openai_zig` | Re-export of the full SDK |

## Dependency

```
zag → zag-ai → openai-zig
```

`Client.sdkClient()` returns `*openai_zig.Client` for models/files/responses/etc.

## Config file example

```json
{
  "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "stream": true
}
```
