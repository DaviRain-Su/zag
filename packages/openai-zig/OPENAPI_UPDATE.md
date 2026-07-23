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
