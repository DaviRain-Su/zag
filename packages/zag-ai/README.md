# zag-ai

Monorepo AI package for Zag — **OpenAI Chat Completions only**, env + JSON config auth (no OAuth).

## Layout

| Module | Role |
|--------|------|
| `types` | Message / ToolCall / StreamEvent |
| `presets` | ProviderSpec table |
| `catalog` | Known model ids + context windows |
| `registry` | Resolve provider from env |
| `auth_env` | API key from env vars |
| `config_file` | `.zag/config.json` / `zag.json` |
| `openai_compat` | Non-streaming chat |
| `stream` | SSE streaming chat |

## Use from Zag

Root `build.zig` depends on `packages/zag-ai` as module `zag-ai`.

## Config file example

```json
{
  "provider": "deepseek",
  "model": "deepseek-v4-flash",
  "stream": true
}
```
