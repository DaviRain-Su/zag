# Third-party packages

Vendored Zig dependencies that Zag may struggle to `zig fetch` (GitHub flaky /
offline). Prefer **path** deps from here over remote URLs in package `build.zig.zon`.

| Dir | Upstream | Version | Used by |
|-----|----------|---------|---------|
| [comptime-serde/](./comptime-serde/) | [jiacai2050/comptime-serde](https://github.com/jiacai2050/comptime-serde) | 0.2.0 (JSON sources only) | `zag-ai` catalog JSON |
| [zig-curl/](./zig-curl/) | [jiacai2050/zig-curl](https://github.com/jiacai2050/zig-curl) | 0.5.0 | `-Dhttp_backend=curl` |

Bump: replace the directory from the tagged upstream release, keep each package’s own README / LICENSE, and update this table.

Zag still builds curl with `link_vendor=false` (system libcurl). Upstream’s lazy curl/zlib/mbedtls tarballs are only needed if you flip to vendored link mode.
