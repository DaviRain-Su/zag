# zag-ai model data

**JSON is the source of truth.** Zig uses a **compile-time** table generated from that JSON (no runtime parse).

```text
data/models/*.json   ← edit here
        │
        ▼  python3 packages/zag-ai/scripts/generate_catalog.py
        │
   ┌────┴────┐
   ▼         ▼
catalog.json   src/catalog_data.zig  ← frozen []const ModelInfo
(tooling)      (import by catalog.zig — comptime constants)
```

Why not `@embedFile` + `std.json` at comptime? Zig 0.16 JSON parsing needs an allocator that is not comptime-safe. Generation freezes the same data into pure Zig constants — still compile-time data, JSON remains the maintainable store.

For **serialize / deserialize** of the same shapes (tooling, roundtrip tests), use `catalog_serde.zig` + [comptime-serde](https://github.com/jiacai2050/comptime-serde) (Zag mirrors the library under `packages/third_party/comptime-serde`, no CLI). Type dispatch is comptime; parse still runs with an allocator.

## Schema (`models/<provider>.json`)

```json
{
  "provider": "openai",
  "models": [
    {
      "id": "gpt-4o-mini",
      "name": "GPT-4o mini",
      "context_window": 128000,
      "max_output_tokens": 16384,
      "reasoning": false,
      "vision": true,
      "cost": {
        "input": 0.15,
        "output": 0.6,
        "cache_read": 0.075,
        "cache_write": 0.0
      }
    }
  ]
}
```

`cost` is optional. Units: **USD per 1M tokens**. Used by `zag_ai.cost` ledger.

## Commands

```bash
# after editing data/models/*.json
python3 packages/zag-ai/scripts/generate_catalog.py

# CI: fail if generated files are stale
python3 packages/zag-ai/scripts/generate_catalog.py --check

# optional: import from a local Pi packages/ai tree
python3 packages/zag-ai/scripts/generate_catalog.py \
  --from-pi /path/to/pi/packages/ai \
  --write-providers
```

Unknown model ids still work on the wire; the catalog is for budgets, flags, and cost estimates.
