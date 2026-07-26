# Round 2 closure — Pi Custom Model & Custom Provider

> Companion to `2026-07-26-pi-feature-correspondence-round1-model-provider.md`.
> Round 2/2. Read-only. No code executed. No project files changed outside this analysis.
> This document closes the five `[UNVERIFIED]` items from Round 1 and re-checks the E3 narrow host-mediated network/secrets boundary vs. E2/host-only OAuth/keychain/cloud creds.

Each item below states **VERIFIED** or **still UNVERIFIED** with precise evidence (URL and/or `file:line`).

---

## Item 1 — OAuth underlying types (`compat/extension-oauth-types.ts`) — VERIFIED

Read `packages/ai/src/compat/extension-oauth-types.ts` (`.references/pi` @ 5bc1c2c) and the canonical `packages/ai/src/auth/types.ts` it re-exports from.

- `extension-oauth-types.ts:1-42` defines the **legacy extension compatibility** surface:
  - `OAuthPrompt { message, placeholder?, allowEmpty? }` (`:2-9`)
  - `OAuthAuthInfo { url, instructions? }` (`:11-16`)
  - `OAuthDeviceCodeInfo { userCode, verificationUri, intervalSeconds?, expiresInSeconds? }` (`:18-26`)
  - `OAuthSelectOption { id, label }` (`:28-31`), `OAuthSelectPrompt { message, options }` (`:33-36`)
  - `OAuthLoginCallbacks { onAuth, onDeviceCode, onPrompt, onProgress?, onManualCodeInput?, onSelect, signal? }` (`:38-42`)
  - `OAuthCredentials` is re-exported from `../auth/types.ts` (`:44`).
- The canonical `packages/ai/src/auth/types.ts:14-27` defines `OAuthCredentials { refresh: string, access: string, expires: number, [key: string]: unknown }`. Note the **index signature `[key: string]: unknown`** — the stored shape is extensible; the doc's narrow `{ refresh, access, expires }` is the contract minimum.
- Cross-check vs. `/custom-provider` doc: the doc's `OAuthLoginCallbacks` (`onAuth`, `onDeviceCode`, `onProgress?`, `onPrompt`, `onSelect`) and `OAuthCredentials { refresh, access, expires }` match the source. The source adds `onManualCodeInput?()` and `signal?` which the doc omits — a doc-under-reporting, not a behavior gap. The `adaptOAuth` adapter in `provider-composer.ts:230-247` maps these legacy callbacks to the canonical `AuthInteraction`/`AuthEvent` shapes (`onAuth→notify{type:"auth_url"}`, `onDeviceCode→notify{type:"device_code"}`, `onPrompt→prompt{type:"text"}`, `onSelect→prompt{type:"select"}`).
- Canonical `OAuthAuth` (`auth/types.ts:188-210`) is richer than the extension surface: `loginLabel?`, `login(AuthInteraction)`, `refresh(credential, signal?)`, `toAuth(credential)→ModelAuth`. The extension `oauth` config (`ProviderConfigInput.oauth`) is the *legacy* adapter; the canonical path is app-owned.

**Conclusion:** The /custom-provider doc's OAuth shapes are accurate but under-report `onManualCodeInput`/`signal` on callbacks and the `[key:string]:unknown` extensibility of `OAuthCredentials`. Round 1's [UNVERIFIED] → **VERIFIED**.

---

## Item 2 — env API key map vs. /providers doc (substantive differences) — VERIFIED

Cross-checked `packages/ai/src/env-api-keys.ts:72-119` (the `envMap` plus the `github-copilot` and `anthropic` special cases at `:66-78`) against the `/providers#environment-variables-or-auth-file` table (fetched Round 1).

Substantive differences (source is the truth for behavior; doc is the user contract):

1. **`google-vertex: GOOGLE_CLOUD_API_KEY` is in source (`env-api-keys.ts:89`) but NOT in the doc's API-key table.** The doc lists Google Vertex AI only under *Cloud Providers → Google Vertex AI* with Application Default Credentials (`gcloud auth application-default login`), `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `GOOGLE_APPLICATION_CREDENTIALS` — no `GOOGLE_CLOUD_API_KEY` row. Source `getEnvApiKey` (`:149-167`) accepts either an explicit `GOOGLE_CLOUD_API_KEY` **or** ADC (`hasVertexAdcCredentials` + project + location). **Doc under-reports the explicit-key path.**
2. **`github-copilot: COPILOT_GITHUB_TOKEN` is in source (`env-api-keys.ts:67-69`) but NOT in the doc's API-key table.** The doc lists GitHub Copilot under *Subscriptions* (OAuth via `/login`). Source supports a `COPILOT_GITHUB_TOKEN` env var for API-key-style use. **Doc under-reports the env-token path.**
3. **`moonshotai: MOONSHOT_API_KEY` and `moonshotai-cn: MOONSHOT_API_KEY` (same env var, `env-api-keys.ts:99-100`) are NOT in the doc's API-key table at all.** The doc table has no Moonshot row. Source supports Moonshot via env. **Doc omits Moonshot entirely from the API-key table.**
4. **`anthropic` special case:** source returns three vars `[ANTHROPIC_AUTH_TOKEN, ANTHROPIC_OAUTH_TOKEN, ANTHROPIC_API_KEY]` (`env-api-keys.ts:71-74`); `getEnvApiKey` skips `ANTHROPIC_AUTH_TOKEN` for the actual key (requests pass it as `Authorization: Bearer`). The doc table lists only `ANTHROPIC_API_KEY`. Source comment documents the AUTH_TOKEN/OAUTH_TOKEN behavior; the table does not. **Doc under-reports the multi-var discovery.** (The doc's env-var reference link points to this file, so the omission is a table simplification, not a contract lie.)
5. **`amazon-bedrock` is in the doc table (`AWS_BEARER_TOKEN_BEDROCK`) but NOT in source's `envMap`.** Source handles Bedrock entirely via ambient-credential special case in `getEnvApiKey` (`:169-183`: AWS_PROFILE / IAM keys / bearer / ECS / IRSA → `"<authenticated>"`). The bearer-token env var is one of several ambient sources. **Consistent: Bedrock is ambient, not a single env-key row in envMap.** The doc table's `AWS_BEARER_TOKEN_BEDROCK` is one of the ambient sources the source checks.
6. All other ~30 entries (ant-ling, qwen-token-plan[-cn], openai, azure-openai-responses, nvidia, deepseek, google/gemini, groq, cerebras, xai, radius, openrouter, vercel-ai-gateway, zai[-coding-cn], mistral, minimax[-cn], huggingface/HF_TOKEN, fireworks, together, opencode[-go], kimi-coding, cloudflare-workers-ai/ai-gateway, xiaomi[-token-plan-cn/ams/sgp]) **match exactly** between source and doc table.

**Conclusion:** Four substantive doc-under-reporting differences (#1–#4: google-vertex explicit key, github-copilot env token, moonshotai entirely, anthropic multi-var). One structural consistency (#5 Bedrock ambient). Round 1's [UNVERIFIED] → **VERIFIED** (differences reported above; not a doc-vs-source behavior contradiction for the entries that matter to Zag's scope, since Zag has none of these).

---

## Item 3 — `generate_catalog.py` import of `compat`/`thinkingLevelMap` — VERIFIED (it does NOT import them)

Read `packages/zag-ai/scripts/generate_catalog.py` fully (`.references`-independent; this is Zag's own generator).

- `load_provider_file` (`:60-95`) flattens each Zag model JSON to exactly: `id, name, provider, context_window, max_output_tokens, reasoning, vision, cost{input,output,cache_read,cache_write}`. `REQUIRED_MODEL_KEYS = ("id","name","context_window","max_output_tokens")` (`:24`).
- `flatten_pi_catalog` (the `--from-pi` importer, `:243-307`) flattens Pi models to the **same narrow schema**: `id, name, provider, context_window, max_output_tokens, reasoning, vision` + `cost`. It reads `context_window`/`contextWindow`, `max_output_tokens`/`maxTokens`, `input` (only to derive `vision = "image" in input`), `cost` (with `cache_read`/`cacheRead` + `cache_write`/`cacheWrite` aliases).
- **The generator explicitly drops:** `compat`, `thinkingLevelMap`, `headers`, `authHeader`, `api`, `baseUrl`, `oauth`, `modelOverrides`, `cost.tiers`, per-model `headers`, and every `compat.*` field (thinkingFormat, cacheControlFormat, supportsStrictMode, supportsDeveloperRole, …). None of these survive into `catalog_data.zig` / `catalog.json`.
- `render_zig` (`:127-186`) emits the `ModelInfo` struct with only `id, name, provider, context_window, max_output_tokens, reasoning, vision, cost: ?CostRates` — matching `catalog_data.zig:12-26`.

**Conclusion:** The Zag generator's `--from-pi` path is a **narrow-field projection**: it imports only the subset Zag's `ModelInfo` carries. Pi's `compat`/`thinkingLevelMap`/`headers`/`cost.tiers`/`authHeader`/`api`/`oauth` are **not parsed, not preserved, not emitted**. This confirms Round 1's gap claim: Zag's catalog cannot represent Pi's capability metadata even when seeded from Pi. Round 1's [UNVERIFIED] → **VERIFIED**.

---

## Item 4 — Pi custom-provider examples combining `refreshModels` + `streamSimple` — VERIFIED (neither example combines them)

Read both examples:

- `examples/extensions/custom-provider-anthropic/index.ts`: registers `pi.registerProvider("custom-anthropic", { … streamSimple: streamCustomAnthropic, oauth: {login, refreshToken, getApiKey}, models: [2 hard-coded] })` (`:569-605`). It uses `streamSimple` + `oauth` + static `models`. **No `refreshModels`.** The factory is synchronous `function (pi)`. Models are hard-coded constants.
- `examples/extensions/custom-provider-gitlab-duo/index.ts`: registers `pi.registerProvider("gitlab-duo", { … streamSimple: streamGitLabDuo, oauth: {login, refreshToken, getApiKey}, models: MODELS.map(...) })` (`:383-406`). It uses `streamSimple` + `oauth` + static `models` (with `thinkingLevelMap: { xhigh: "max" }` on Anthropic models, `:68-122`). The `streamGitLabDuo` impl does a **runtime `fetch` to GitLab's direct-access endpoint** inside the stream call (`getDirectAccessToken`, `:188-206`) — but this is **request-time auth-token fetch, not `refreshModels` discovery**. The model list is static. **No `refreshModels`.**

**No Pi example combines `refreshModels` + `streamSimple`.** The dynamic-discovery pattern shown in the /custom-provider doc (`fetch("http://localhost:1234/v1/models")` in an async factory) is documented but **not present in the two custom-provider examples**. The two examples demonstrate `streamSimple`+`oauth`+static-models; dynamic discovery is only in the doc's `Register New Provider` async-factory snippet.

**Conclusion:** Round 1's [UNVERIFIED] → **VERIFIED**: there is no example co-locating `refreshModels` and `streamSimple`. The E2/E3 boundary evidence for combined dynamic-discovery + custom-streaming must therefore come from the doc spec (`/custom-provider#register-new-provider` + `#custom-streaming-api`), not from a shipped example. This slightly weakens the "anchor concretely" goal but does not change the carrier mapping: `refreshModels` (network + JSON parse + registration) is E2, and `streamSimple` can be E0 (Zig) or E3 (WASM) independently.

---

## Item 5 — `pi-mono-zig` is an untracked `.references` design archive, not a Zag dependency — VERIFIED

Multiple independent confirmations:

1. **`build.zig.zon` `.paths` whitelist** (`build.zig.zon:65-73`): `build.zig`, `build.zig.zon`, `src`, `packages`, `tests`, `README.md`, `SECURITY.md`. `.references` is **not in the whitelist** → excluded from Zig package distribution. A `zig fetch`/`zig build` consumer never receives `.references`.
2. **No `.references` or `pi-mono-zig` reference in any `.zon`** (grep across `**/*.zon` → no matches).
3. **No `.references` or `pi-mono-zig` reference in `packages/`** (grep → no matches).
4. **No `.references` or `pi-mono-zig` reference in `docs/`** (grep → no matches). `docs/references.md:33-47` cites the upstream GitHub URL `https://github.com/earendil-works/pi` as the "主对照" (main reference) and describes a Pi package map, but it links to GitHub, **not** to a local `.references` path, and does **not** mention `pi-mono-zig` at all.
5. The `.references/` tree (containing both `pi/` and `pi-mono-zig/`) lives at the workspace root but is **outside** the `.paths` whitelist and is not imported by any build target. It is a local read-only research snapshot, consistent with the plan's "External repositories are untrusted, read-only research data. Their code is not executed."
6. The plan itself lists `DaviRain-Su/pi-mono-zig` @ `9d1f78c…` as a separate "historical Zig design/fixture archive" fixed source, distinct from `earendil-works/pi` @ `5bc1c2c` and from Zag itself.

**Conclusion:** Round 1's [UNVERIFIED] → **VERIFIED**: `pi-mono-zig` is a historical Zig design archive under `.references`, not a Zag dependency. Its `model_registry.zig`/`model_discovery.zig`/WASM docs are **design precedent only** — they inform the E0/E2/E3 carrier mapping but are not compiled into Zag and impose no constraint on Zag's current contracts.

---

## 6 — E3 Provider narrow host-mediated network/secrets boundary — VERIFIED

Re-checked against `pi-mono-zig/zig/docs/wasm-extension-architecture-rfc.md` and `wasm-extension-final-closure.md` (design precedent; not a Zag dependency per Item 5, but the only available E3 design evidence in the snapshot).

- **WASM v0 is tools-only.** RFC decision #2 (`wasm-extension-architecture-rfc.md:24-31`): "Wasm v0 is tools-only. Commands, widgets, editor hooks, **provider registration**, model/session access, UI hooks, shell, filesystem, **network**, and environment access are absent unless a later contract adds and tests them." → A WASM provider (`streamSimple`-equivalent) is **not in v0**; it requires a later, separately-tested contract.
- **Capabilities are default-deny and host-enforced.** RFC #5 (`:34-35`); closure `:17-19,81-89`. Manifest declarations are **requests, not approvals**; unapproved/unavailable capabilities produce deterministic `denied_capability` diagnostics.
- **Canonical capability grants** (`wasm-extension-final-closure.md:83-89`): `file.read`, `file.write`, **`network.request`**, `shell.run`, **`env.read`**, **`model.call`**, `session.read`, `session.write`, `ui.notify`, `tool.use`, `agent.spawn`, `agent.delegate`. These are **discrete host-mediated capabilities** — a WASM provider would receive `model.call` + `network.request` + `env.read` as host-mediated, audited, deny-by-default grants, **not** raw socket/keychain access.
- **Browser harness denies shell and local filesystem** in both manifest-request and runtime/import modes (`:90-91`). This confirms the host-mediated boundary: even when a capability is granted, the host can refuse it by environment.

### E3 narrow boundary (host-mediated network/secrets) — confirmed
- A WASM Component provider may, under a future tested contract, receive **`network.request`** (host-mediated, deny-by-default, audited) and **`env.read`** (host-mediated; the host decides which env vars are exposed — secrets are **not** handed raw to the guest; the host can resolve a secret and pass a derived value or withhold it).
- Secrets handling: the host resolves/owns secrets; the WASM guest receives at most a host-mediated capability to use a secret (e.g. `model.call` with the host injecting the `Authorization` header), not the secret bytes. This matches Zag's existing redaction invariant (`packages/zag-agent-core/src/redact.zig:1-48`: configured secrets copied at `addSecret`, never logged in diagnostics) and the provider-plane discipline (`wire_provider.zig`: only `ToolDefinition` crosses to the wire, never capabilities/instances).

### E2/host-only (NOT E3) — confirmed
- **OAuth browser/device-code flows** (e.g. `custom-provider-anthropic/index.ts:79-122` PKCE + `callbacks.onAuth`/`onPrompt`; `custom-provider-gitlab-duo/index.ts:223-269` PKCE + redirect URI `http://127.0.0.1:8080/callback`): require a browser opening, a callback server / manual code paste, and token persistence in `~/.pi/agent/auth.json`. These are **host/E2** concerns — a WASM guest cannot open a browser, bind a callback port, or write to `auth.json` under the v0 capability set. The `OAuthLoginCallbacks` surface (`onAuth`, `onDeviceCode`, `onPrompt`, `onSelect`) is inherently host UI.
- **OS keychain / `!command` secret resolution** (e.g. `!security find-generic-password`, `!op read`): require host process spawning and OS credential-store access. **E2/host-only.** A WASM guest has no `shell.run`-by-default and no keychain access; the host resolves the secret and exposes it via `env.read` or injects it into `model.call`.
- **Ambient cloud credentials** (AWS profile/IAM/bearer/ECS/IRSA, Vertex ADC, Cloudflare account/gateway, Azure): require reading host filesystem (`~/.aws/credentials`, `~/.config/gcloud/…`) and ambient env. Source `env-api-keys.ts:149-183` shows these are host-resolved to `"<authenticated>"`. **E2/host-only.** A WASM guest does not read these directly.

### Carrier boundary table (final, with evidence)

| Capability | E0 static Zig | E2 supervised process / host | E3 WASM Component | Evidence |
|---|---|---|---|---|
| Data-only custom model entry (`models.json`) | ✅ (comptime catalog done) | n/a | ❌ (passive asset, not WASM) | plan criterion; `catalog_data.zig` |
| `!command`/shell secret resolution | ❌ | ✅ host/E2 | ❌ (no shell by default) | `env-api-keys.ts`; WASM RFC #2 |
| `streamSimple` custom streaming (in-process Zig) | ✅ (`WireAdapter` vtable) | n/a | n/a | `provider.zig:12-45`, `D-008:46-48` |
| `streamSimple` custom streaming (3rd-party portable) | ❌ | ✅ (fallback) | ✅ future (`model.call`+`network.request` host-mediated) | WASM RFC #2; closure `:83-89` |
| OAuth browser/device-code flow | ❌ | ✅ host/E2 only | ❌ (no browser/callback port in v0) | `custom-provider-anthropic/index.ts:79-122`; WASM RFC #2 |
| OS keychain / `!op`/`!security` | ❌ | ✅ host/E2 only | ❌ | WASM RFC #2 (`shell`/`filesystem` absent in v0) |
| Ambient cloud creds (AWS/Vertex/Cloudflare/Azure) | ❌ | ✅ host/E2 only | ❌ (no host FS/env-by-default) | `env-api-keys.ts:149-183`; WASM closure `:90-91` |
| `refreshModels` dynamic discovery (HTTP fetch) | ❌ | ✅ E2 (network + parse + register) | ✅ future (`network.request` host-mediated) | WASM closure `:83-89` |
| Runtime `registerProvider`/`unregisterProvider` lifecycle | ❌ (no dynamic ABI, `D-008:20-28`) | ✅ E2 extension runtime | ✅ future (post-v0 contract) | `D-008`; WASM RFC #2 (provider registration absent in v0) |
| `compat`/`thinkingLevelMap` capability metadata | ✅ E0 (in `ModelInfo`, currently narrow) | n/a | n/a | `catalog_data.zig:12-26`; Item 3 |

---

## 7 — Round 2 status

All five Round 1 `[UNVERIFIED]` items are now **VERIFIED** with file:line / URL evidence:

| # | Item | Status |
|---|---|---|
| 1 | OAuth underlying types | **VERIFIED** (`extension-oauth-types.ts:1-42`, `auth/types.ts:14-27`) |
| 2 | env API key map vs. /providers doc | **VERIFIED** (4 substantive doc-under-reports: google-vertex, github-copilot, moonshotai, anthropic multi-var) |
| 3 | `generate_catalog.py` imports `compat`/`thinkingLevelMap` | **VERIFIED** — it does **not**; narrow-field projection only (`generate_catalog.py:60-95, 243-307`) |
| 4 | Pi examples combining `refreshModels`+`streamSimple` | **VERIFIED** — no such example; both examples use static models + `streamSimple`+`oauth` |
| 5 | `pi-mono-zig` is untracked `.references` archive, not a Zag dependency | **VERIFIED** (`build.zig.zon:65-73` `.paths` whitelist; no reference in `packages/`/`docs/`/`.zon`) |

E3 narrow host-mediated network/secrets boundary and E2/host-only OAuth/keychain/cloud-creds split: **VERIFIED** with evidence from the WASM RFC/closure (design precedent) and Pi OAuth example source.

No `[UNVERIFIED]` items remain in scope. No files outside this analysis were modified. No external code was executed.

---

## 8 — Source anchors added in Round 2

Pi source (`.references/pi` @ 5bc1c2c):
- `packages/ai/src/compat/extension-oauth-types.ts:1-42`
- `packages/ai/src/auth/types.ts:14-27` (`OAuthCredentials`), `:60-88` (`CredentialStore`), `:110-150` (`AuthPrompt`/`AuthEvent`/`AuthInteraction`), `:188-210` (`OAuthAuth`), `:212-224` (`ProviderAuth`)
- `packages/ai/src/env-api-keys.ts:66-119` (envMap + special cases)
- `packages/coding-agent/examples/extensions/custom-provider-anthropic/index.ts:569-605` (registration), `:79-122` (OAuth PKCE), `:335-560` (streamSimple)
- `packages/coding-agent/examples/extensions/custom-provider-gitlab-duo/index.ts:383-406` (registration), `:188-206` (direct-access fetch), `:223-269` (OAuth PKCE), `:308-377` (streamSimple)

Zag source:
- `packages/zag-ai/scripts/generate_catalog.py:24` (REQUIRED_MODEL_KEYS), `:60-95` (load_provider_file), `:127-186` (render_zig), `:243-307` (flatten_pi_catalog), `:327-358` (--from-pi merge)
- `build.zig.zon:65-73` (`.paths` whitelist excludes `.references`)
- `packages/zag-agent-core/src/redact.zig:1-48` (secret redaction contract)
- `docs/references.md:33-47` (upstream GitHub URL, no local `.references` path)

E3 design precedent (`.references/pi-mono-zig/zig/docs`, historical archive, NOT a Zag dependency):
- `wasm-extension-architecture-rfc.md:24-31` (WASM v0 tools-only; provider registration/network/filesystem/env absent), `:34-35` (default-deny host-enforced)
- `wasm-extension-final-closure.md:17-19` (default-deny), `:81-91` (canonical capability grants incl. `network.request`/`env.read`/`model.call`; browser denies shell+FS), `:104-108` (lifecycle diagnostics)

Pi docs:
- <https://pi.dev/docs/latest/custom-provider#register-new-provider> (async factory + `refreshModels` dynamic discovery — documented but no shipped example, per Item 4)
- <https://pi.dev/docs/latest/providers#environment-variables-or-auth-file> (API-key table; differences in Item 2)