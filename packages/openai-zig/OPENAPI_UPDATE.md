# OpenAPI regeneration notes (2026-07-24)

## Source
- Spec: `spec/openapi.documented.yml` (latest openai-openapi snapshot)
- Generator: `python3 tools/generate.py`
- Outputs:
  - `generated/ir.json` — **287** operations, **1385** schemas
  - `src/generated/types.zig` — Zig type outlines + compatibility aliases

## Generator improvements
- Resolves `allOf` by merging properties
- Prefer first `$ref` in `oneOf` array items (typed tool_calls)
- Content-like unions that include `string` map to `[]const u8`
- Required slices default to `&.{}`; scalars get zero defaults
- Complex required objects become optional for partial init / JSON parse
- `FunctionParameters` kept as schema/raw union helper
- Compatibility aliases for renamed OpenAPI schemas (EvalObject→Eval, etc.)

## Chat Completions (latest fields present)
- `moderation`, `n`, `prompt_cache_options`, `verbosity`, `web_search_options`, …

## New surface available as types (resource wrappers still partial)
- Skills, video characters/edits/extensions, org spend/alerts, beta responses helpers, …

## Rebuild
```sh
cd packages/openai-zig
python3 tools/generate.py
zig build test
zig build examples -Dexamples=true
```

## Resource wrappers (2026-07-24)

| Module | Client access | Coverage |
|--------|---------------|----------|
| `resources/skills.zig` | `client.skills()` | list/create/get/delete, default version, versions CRUD, content download |
| `resources/spend.zig` | `client.spend()` / `spend_alerts()` / `data_retention()` | org+project spend limit/alerts, data retention, hosted tool + model permissions |
| `resources/videos.zig` | `client.videos()` | + characters, edits, extensions (JSON + multipart) |
| `resources/responses.zig` | `client.responses()` | + beta path variants (`?beta=true`) for create/get/delete/cancel/input_items/compact/input_tokens |

Example: `zig build run-skills_list -Dexamples=true`
