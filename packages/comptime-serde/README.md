# comptime-serde (JSON library mirror)

Upstream: [jiacai2050/comptime-serde](https://github.com/jiacai2050/comptime-serde) **v0.2.0** (MIT).

Zag mirrors **JSON** sources only (`src/root.zig`, `formats/common.zig`, `formats/json.zig`). Upstream TOML/YAML/Protobuf and the `serde-gen` / `zigcli` CLI are omitted so builds stay offline-friendly.

Used by `zag-ai` (`catalog_serde.zig`) to serialize/deserialize model catalog JSON. The compile-time model **table** remains frozen via `generate_catalog.py` → `catalog_data.zig`.

Bump: refresh `formats/common.zig` + `formats/json.zig` from the tagged upstream release; keep this README’s version in sync.
