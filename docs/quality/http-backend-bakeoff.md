# HTTP backend bake-off (D-005 Phase 3)

Live comparison of `-Dhttp_backend=std|curl` via `zig build http-bakeoff` /
`scripts/http_backend_bakeoff.sh`. Not part of `zig build test` (needs network).

## How to re-run

```bash
# one backend
zig build http-bakeoff -Dhttp_backend=std -- https://httpbingo.org
zig build http-bakeoff -Dhttp_backend=curl -- https://httpbingo.org

# both + summary table
./scripts/http_backend_bakeoff.sh
# optional: ZAG_BAKEOFF_BASE_URL=https://httpbingo.org
```

Needs system **libcurl** for the curl backend (`brew install curl` / `libcurl4-openssl-dev`).

## Results (2026-07-24, macOS aarch64, Zig 0.16.0)

Host: `https://httpbingo.org`

| backend | case | result | ms | notes |
|---------|------|--------|----|-------|
| std | post_ok | ok | ~800 | POST `/post` → 200 |
| std | timeout | **timeout_ignored** | ~5700 | `timeout_ms=1500` stored but **not applied** to `std.http.Client`; `/delay/5` completed |
| curl | post_ok | ok | ~2300 | POST `/post` → 200 |
| curl | timeout | **timeout** | ~1530 | `CURLOPT_TIMEOUT_MS` honored; maps to `error.Timeout` |

## Code-review gaps (not live-exercised)

| Topic | std | curl | Verdict |
|-------|-----|------|---------|
| End-to-end deadline | Config field only | Enforced | curl wins for production reliability |
| SSE / stream body | Writer path | `WRITEFUNCTION` | Both work for Anthropic stream |
| Mid-stream cancel | No cooperative cancel on Easy/Client | Same (need Multi / interrupt) | Still H6 work for both |
| Proxy | openai-zig parses URL → `std.http.Client.Proxy` | `CURLOPT_PROXY` string | Both usable; std richer parse on OpenAI path |
| Tutorial / CI deps | std only | libc + system libcurl | Keep **default=std** |

## Phase 3 decision

1. **Default stays `std`** — tutorial lightness + no curl dependency for everyday `zig build test`.
2. **Production / reliability: prefer `-Dhttp_backend=curl`** — especially where `timeout_ms` must mean something.
3. **Do not flip default** until we either wire deadlines into std wrappers or accept curl as the documented production build.
4. **Phase 4** (`packages/zag-http` dedupe) — deferred; not required to close this branch.

Authoritative decision: [D-005](../decisions/complete/D-005-outbound-http-std-not-httpz.md).
