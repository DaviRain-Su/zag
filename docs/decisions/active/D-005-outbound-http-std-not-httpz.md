---
status: active
id: D-005
title: Outbound HTTP stays on std.http.Client; do not adopt httpz
date: 2026-07-24
---

# D-005 — Outbound HTTP: std.http + thin wrappers (not httpz)

## Decision

1. **Zag does not vendor or depend on [karlseguin/http.zig](https://github.com/karlseguin/http.zig)** (`httpz`). That package is an **HTTP/1.1 server**, not a client. Swapping it in would not replace our LLM transport.
2. **Outbound** provider calls keep using Zig **`std.http.Client`**, wrapped by:
   - `packages/zag-ai/src/http.zig` (neutral Bearer / header auth, retry, SSE stream)
   - `packages/openai-zig/src/transport/http.zig` (OpenAI resource transport)
3. We **acknowledge** that `std.http.Client` is immature and has recurring sharp edges; the wrappers exist to absorb API churn and app-level retry — they are **not** a from-scratch HTTP stack.

## Why not httpz

| Need | httpz | Zag transport |
|------|-------|---------------|
| Role | Listen + route + middleware | POST/SSE to provider APIs |
| Surface | `Server` / `Request` / `Response` | `std.http.Client` request/response |
| Fit | Product shell / local ACP later (maybe) | Model plane today |

Using a server library as a client is a category error. If we ever need an HTTP **server** (e.g. C9 local agent endpoint), evaluate httpz **then**, separately from provider transport.

## Honest note on `std.http.Client`

Community and upstream history (0.15→0.16) match the intuition that the official client is **awkward and still buggy**, for example:

- HTTPS / large body hang and TLS write-buffer footguns (e.g. ziglang/zig#25015 and follow-ups)
- 204 / empty-body hang with keep-alive (e.g. #25181)
- Connect timeout options not always respected (e.g. #31305)
- Content-encoding / discard assert paths (e.g. #25619)
- Parser edge cases on the **server** side of std.http as well (chunked length overflow reports around 0.16)

Zag mitigations already in wrappers (keep evolving here, not by swapping packages blindly):

- `keep_alive = false` on our request path (avoids some hang classes)
- App-level `max_retries` / backoff on transport + loop `chat_retries`
- Explicit stream vs buffered body paths for SSE
- Status → `wire.Error` mapping (`RateLimited`, `Timeout`, …)

`timeout_ms` in config is **declared**; treat end-to-end deadline enforcement as an open reliability item (upstream + our wrapper), tracked under provider / H6 — not as “rewrite HTTP.”

## When to revisit

Reopen this decision only if **one** of these is true:

1. Upstream `std.http.Client` is blocked for our workload (streaming cancel, deadlines, proxy) with no workable wrapper fix; **or**
2. A maintained Zig **HTTP client** (not server) is clearly better on 0.16+ and we can isolate it behind the same `http.Client` / transport facade; **or**
3. We need an HTTP **server** product surface — then consider httpz for that plane only.

Do **not** “replace our HTTP” with httpz because the name contains HTTP.

## Candidate if criterion 2 fires: zig-curl

Evaluated 2026-07-24: [jiacai2050/zig-curl](https://github.com/jiacai2050/zig-curl) — **libcurl Zig bindings** (MIT), targets Zig **0.16**, vendored curl 8.19 + zlib + mbedtls (or `link_vendor=false` → system libcurl). Correct category (client), unlike httpz.

| | std.http (today default) | zig-curl |
|--|--------------------------|----------|
| Maturity of stack | Immature / sharp edges | libcurl battle-tested |
| Timeout / proxy / TLS | Weak / partial | Strong (curl knobs; `CURLOPT_TIMEOUT_MS` wired) |
| Deps | Zig std only | **libc** + curl |
| Build / CI | Light | Needs system libcurl (spike) or vendor compile |
| SSE / stream | Our writer path | `WRITEFUNCTION` callback in `http_curl.zig` |
| Fit with tutorial “std-only” story | Strong | Hidden behind facade |

## Libcurl route (phased)

```text
Phase 0  ✅  Evaluate zig-curl; reject httpz (server)
Phase 1  ✅  zag-ai facade + -Dhttp_backend=curl (Anthropic / shared http.Client)
Phase 2  →  openai-zig Transport same flag (OpenAI-compat / DeepSeek / …)
Phase 3     Live bake-off (timeout / SSE cancel / proxy); consider default=curl
Phase 4     Optional: extract packages/zag-http shared engine (dedupe std|curl)
```

**Now:** Phase 2 — one build flag covers the whole Model plane outbound stack.  
**Not yet:** flip default; openai-zig proxy via curl; vendor mbedtls hermetic CI.

### Spike status (landed)

- Build flag: **`-Dhttp_backend=std|curl`** (default **`std`**)
- Facade: `packages/zag-ai/src/http.zig` → `http_std.zig` / `http_curl.zig`
- openai-zig: `packages/openai-zig/src/transport/http.zig` → same flag (`http_std` / `http_curl`)
- Dependency: **URL** in `build.zig.zon` → [zig-curl v0.5.0](https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.5.0.tar.gz)
- Link mode: `link_vendor=false` (system libcurl)

If local `zig fetch` cannot reach GitHub, seed the cache then build:

```bash
curl -fsSL -o /tmp/zig-curl-0.5.0.tar.gz \
  https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.5.0.tar.gz
zig fetch file:///tmp/zig-curl-0.5.0.tar.gz
zig build test -Dhttp_backend=curl
```

**Stance:** default stays **std** until Phase 3 bake-off. Curl is opt-in for the full Model plane once Phase 2 lands.

## Consequences

- Spec links: [modules/zag-ai-provider.md](../../modules/zag-ai-provider.md), [architecture.md](../../architecture.md) (openai-zig / std.http)
- New deps: reject httpz for Model plane PRs; **defer zig-curl** until criterion 1–2; server choice is a separate decision later
- Pain from std.http → fix/harden wrappers + document; optional upstream issue links in PR notes
- Preferred client escape hatch (documented only): zig-curl behind existing facade