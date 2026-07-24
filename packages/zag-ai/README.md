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

Embeddings (unified on WireAdapter):

```zig
if (w.supportsEmbed()) {
    const emb = try w.embed(arena, &.{"hello world"}, .{ .model = "text-embedding-3-small" });
    // emb.vectors[0], emb.usage
} else {
    // e.g. anthropic_messages → error.NotSupported
}
```

OpenAI-only helpers (full SDK surface):

```zig
var client = ai.OpenAiClient.init(gpa, io, config);
defer client.deinit();
// client.sdkClient() → *openai_zig.Client
// client.embed(...) still works (same as wire.embed for openai_compat)
```

`ai.Client` remains an alias of `OpenAiClient` for back-compat.

## Wire styles (only two)

| Style | Endpoint | Notes |
|-------|----------|--------|
| `openai_compat` | `/chat/completions` | Default; most hosts |
| `anthropic_messages` | `/v1/messages` | Anthropic + MiniMax / Kimi Coding / Vercel Gateway |

**Not in scope for now:** Google Generative AI, Mistral-native, Bedrock, OAuth, OpenAI Responses (planned), image generation (planned).

```bash
export ANTHROPIC_API_KEY=sk-ant-...
export ZAG_PROVIDER=anthropic
zig build run -- --stream -v "hello"
```

## Built-in providers

Table-driven (`presets.zig`). Auto-detect: first preset whose env key is set wins.  
Same key for regional twins → **global first** (set `ZAG_PROVIDER` for CN).

### openai_compat

| id | Env | Default model |
|----|-----|---------------|
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-v4-flash` |
| `xai` | `XAI_API_KEY` | `grok-4-latest` |
| `openai` | `OPENAI_API_KEY` | `gpt-4o-mini` |
| `openrouter` | `OPENROUTER_API_KEY` | `openai/gpt-4o-mini` |
| `together` | `TOGETHER_API_KEY` | Llama 3.1 8B Turbo |
| `groq` | `GROQ_API_KEY` | `llama-3.3-70b-versatile` |
| `cerebras` | `CEREBRAS_API_KEY` | `llama-3.3-70b` |
| `nvidia` | `NVIDIA_API_KEY` | `meta/llama-3.3-70b-instruct` |
| `fireworks` | `FIREWORKS_API_KEY` | Fireworks Llama 3.3 70B |
| `huggingface` | `HF_TOKEN` | Llama 3.1 8B |
| `moonshotai` | `MOONSHOT_API_KEY` | `kimi-k2.5` |
| `moonshotai-cn` | `MOONSHOT_API_KEY` | `kimi-k2.5` (CN base URL) |
| `zai` | `ZAI_API_KEY` | `glm-4.7` |
| `zai-coding-cn` | `ZAI_CODING_CN_API_KEY` | `glm-4.7` |
| `xiaomi` | `XIAOMI_API_KEY` | `mimo-v2-flash` |

### anthropic_messages

| id | Env | Default model |
|----|-----|---------------|
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-20250514` |
| `kimi-coding` | `KIMI_API_KEY` | `kimi-for-coding` |
| `minimax` | `MINIMAX_API_KEY` | `MiniMax-M2.5` |
| `minimax-cn` | `MINIMAX_CN_API_KEY` | `MiniMax-M2.5` |
| `vercel-ai-gateway` | `AI_GATEWAY_API_KEY` | `anthropic/claude-sonnet-4` |

Custom endpoint: set `ZAG_BASE_URL` + `ZAG_API_KEY` + optional `ZAG_API_STYLE`.

Catalog (`catalog.zig`) is **curated** (context window / max out / vision / reasoning flags) for budgets — not a full vendor dump. Any model id still works if the host accepts it.

## Errors

Shared `wire.Error` / `ai.WireError`.  
`openai_compat.mapSdkError` maps **openai-zig** names only.

`ai.isRetryableError(err)` for loop policy.

## Deferred (not missing by accident)

| Item | Why deferred |
|------|----------------|
| OpenAI Responses wire | Planned next wire; chat completions still covers agent loop |
| Image generation surface | Separate from chat; add when product needs it |
| Google / Mistral-native / Bedrock | Low agent traffic vs OpenAI+Anthropic; skip |
| Full Pi catalog generator | Hundreds of auto-synced model rows; curated table is enough |
| Cost ledger ($/token) | Turn-level `Usage` tokens exist; dollar math not needed yet |
| OAuth (Codex / Copilot) | Explicit non-goal for H |

## Tests

```bash
cd packages/zag-ai && zig build test
# or monorepo:
zig build test
```
