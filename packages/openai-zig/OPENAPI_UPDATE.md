# OpenAPI update notes (2026-07-23)

Source: [openai/openai-openapi](https://github.com/openai/openai-openapi) `openapi.yaml`
(mirrored into `spec/openapi.documented.yml`).

## Diff vs previous vendored snapshot

### Paths
- **+31** endpoints (org spend/alerts/data-retention, skills, video characters/edits/extensions,
  beta responses helpers, realtime translations secrets, …)
- **-1** path rename: `api_keys/{key_id}` → `api_keys/{api_key_id}`

### Chat Completions (`CreateChatCompletionRequest`)
New request fields relative to previous snapshot:
- `moderation` → `ModerationParam`
- `n` (completions count; already supported in hand-written client)
- Shared model props: `prompt_cache_options` (`PromptCacheOptionsParam`)
- Voice id ref: `VoiceIdsShared` → `VoiceIdsOrCustomVoice`

### Hand-written client (`src/resources/chat.zig`)
Added optional JSON fields on `CreateChatCompletionRequest`:
- `moderation`
- `prompt_cache_options`
- `verbosity`
- `web_search_options`

### Not yet regenerated
`src/generated/types.zig` is **not** fully regenerated in this pass (large surface;
skills/videos/org admin resources still need resource wrappers). Use
`tools/generate.py` + IR refresh when adding those resources.

### Notable new operation groups
- Skills: Create/Get/List/Delete skill + versions + content
- Videos: characters, edits, extensions
- Organization: spend_limit, spend_alerts, data_retention, hosted_tool_permissions, model_permissions
- Beta responses: compact, input_tokens, cancel, input_items variants
