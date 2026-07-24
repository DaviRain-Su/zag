---
status: complete
id: D-005
title: Outbound HTTP stays on std.http by default; curl opt-in via facade (not httpz)
date: 2026-07-24
---

# D-005 — Outbound HTTP: std.http default + zig-curl opt-in (not httpz)

## Decision

1. **Zag does not vendor or depend on [karlseguin/http.zig](https://github.com/karlseguin/http.zig)** (`httpz`). That package is an **HTTP/1.1 server**, not a client.
2. **Default outbound** provider calls use Zig **`std.http.Client`**, wrapped by:
   - `packages/zag-ai/src/http.zig` → `http_std.zig` / `http_curl.zig`
   - `packages/openai-zig/src/transport/http.zig` → same flag
3. **Opt-in production backend:** `-Dhttp_backend=curl` (zig-curl / system libcurl) for the whole Model plane.
4. Wrappers absorb API churn and app-level retry — they are **not** a from-scratch HTTP stack.

## Why not httpz

| Need | httpz | Zag transport |
|------|-------|---------------|
| Role | Listen + route + middleware | POST/SSE to provider APIs |
| Fit | Product shell / local ACP later (maybe) | Model plane today |

Using a server library as a client is a category error. HTTP **server** choice (e.g. C9) is a separate decision later.

## Honest note on `std.http.Client`

Upstream remains awkward on 0.16 (TLS/hang/timeout sharp edges). Zag mitigations: `keep_alive = false`, retries, SSE vs buffered paths, status → `wire.Error`.

**Phase 3 bake-off confirmed:** `timeout_ms` is stored on the std path but **not enforced**; curl honors `CURLOPT_TIMEOUT_MS` (~1.5s abort on `/delay/5`). See [http-backend-bakeoff.md](../../quality/http-backend-bakeoff.md).

## Libcurl route — closed

```text
Phase 0  ✅  Evaluate zig-curl; reject httpz (server)
Phase 1  ✅  zag-ai facade + -Dhttp_backend=curl
Phase 2  ✅  openai-zig Transport shares same flag
Phase 3  ✅  Live bake-off; default stays std; recommend curl for deadlines
Phase 4  ⏸  Optional packages/zag-http dedupe — deferred (not blocking)
```

### Build

```bash
zig build test                          # default std.http
zig build test -Dhttp_backend=curl      # system libcurl
zig build http-bakeoff -Dhttp_backend=curl -- https://httpbingo.org
./scripts/http_backend_bakeoff.sh
```

Dependency: URL in `build.zig.zon` → [zig-curl v0.5.0](https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.5.0.tar.gz), `link_vendor=false`.

If local `zig fetch` cannot reach GitHub:

```bash
curl -fsSL -o /tmp/zig-curl-0.5.0.tar.gz \
  https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.5.0.tar.gz
zig fetch file:///tmp/zig-curl-0.5.0.tar.gz
```

### Stance (post Phase 3)

| Audience | Backend |
|----------|---------|
| Tutorial / default CI | **`std`** |
| Production reliability (timeouts) | **`-Dhttp_backend=curl`** |
| Flip default to curl | Only if we accept libc+curl as baseline, or std deadlines land |

Mid-stream SSE cancel remains open for **both** backends (H6). Proxy: std richer parse on openai-zig; curl uses `CURLOPT_PROXY` string.

## Consequences

- Spec: [zag-ai-provider.md](../../modules/zag-ai-provider.md), [architecture.md](../../architecture.md)
- Reject httpz for Model plane PRs
- Preferred client escape hatch: zig-curl behind the existing facade
- Branch closed → resume Phase H mainline at **H4 Context / Session**
