# Round 1 findings — Pi Custom Model & Custom Provider

> Research plan: `2026-07-26-pi-feature-correspondence.md`
> Scope: Pi **Custom Model** + **Custom Provider** only.
> Mode: read-only research. No code executed. No files changed outside this analysis.
> Pi source = `.references/pi` @ `5bc1c2c` (verified snapshot per plan).
> Pi docs = `https://pi.dev/docs/latest/{models,custom-provider,providers,environment-variables}` fetched 2026-07-26.
> Round 1 of 2 minimum. A fresh verifier has not yet returned PASS.

This document separates three Pi capabilities that the plan demands be distinguished:

- **(a) Custom Model** — data-only model catalog entries for an *already-supported* API/provider shape (`models.json`).
- **(b) Custom Provider (executable)** — custom transport, streaming, auth/OAuth, or model discovery behavior (extension `registerProvider` with `streamSimple` / `oauth` / `refreshModels`).
- **(c) Extension API lifecycle** — the `pi.registerProvider` / `pi.unregisterProvider` registration lifecycle and its trust boundary (distinct from the *content* of (a)/(b)).

Each conclusion cites a Pi doc URL and/or a Pi/Zag source `file:line`. Items I could not directly confirm against source are tagged `[UNVERIFIED]`.

---

## 1. Pi user-facing contract (from official docs)

### 1a. Custom Model — `~/.pi/agent/models.json` (data-only)

Source of truth for the user contract: <https://pi.dev/docs/latest/models>.

- Mechanism: a JSON file at `~/.pi/agent/models.json` with a top-level `providers` map. Each provider entry has `baseUrl`, `api` (one of `openai-completions` / `openai-responses` / `anthropic-messages` / `google-generative-ai`), optional `apiKey`, `headers`, `authHeader`, `oauth`, `compat`, `models`, and `modelOverrides`. (<https://pi.dev/docs/latest/models#provider-configuration>, `#model-configuration>)
- Per-model fields: `id` (required), `name`, `api`, `reasoning`, `thinkingLevelMap`, `input` (`["text"]` default, `["text","image"]`), `contextWindow` (default 128000), `maxTokens` (default 16384), `cost` (with optional `tiers`), `compat`, `headers`. (<https://pi.dev/docs/latest/models#model-configuration>)
- Semantics the docs make explicit:
  - The file **reloads each time `/model` is opened**; no restart needed. (<https://pi.dev/docs/latest/models#full-example>)
  - Custom models are **upserted by `id` within a provider**; a matching id replaces the built-in model, a new id is added alongside built-ins. (<https://pi.dev/docs/latest/models#overriding-built-in-providers>)
  - `modelOverrides` patches built-in / extension-registered models *without* replacing the provider's full list; unknown IDs are ignored. (<https://pi.dev/docs/latest/models#per-model-overrides>)
  - Auth is independent: models load from the file even without auth; they stay unavailable in `/model` and `--list-models` until auth is configured via `/login`/`auth.json`, CLI `--api-key`, or provider `apiKey`. (<https://pi.dev/docs/latest/models#provider-configuration>)
- Value-resolution syntax for `apiKey`/`headers`: `!command` (shell, resolved at request time), `$ENV_VAR` / `${ENV_VAR}` (interpolation), `$$` / `$!` escapes, plain literals. (<https://pi.dev/docs/latest/models#value-resolution>)
- `compat` is the per-provider/per-model capability-metadata knob: OpenAI-compat fields (`supportsDeveloperRole`, `supportsReasoningEffort`, `maxTokensField`, `thinkingFormat`, `cacheControlFormat`, `supportsStrictMode`, `supportsOpenAIGrammarTools`, `openRouterRouting`, `vercelGatewayRouting`, …) and Anthropic-compat fields (`supportsEagerToolInputStreaming`, `forceAdaptiveThinking`, `allowEmptySignature`, `supportsStrictTools`, …). (<https://pi.dev/docs/latest/models#anthropic-messages-compatibility>, `#openai-compatibility>)

**This is data, not executable code.** No `streamSimple`, no `oauth.login`, no process. It is exactly category (a).

### 1b. Custom Provider — executable (extension `registerProvider`)

Source of truth: <https://pi.dev/docs/latest/custom-provider>.

- Two registration forms:
  1. **Complete `Provider`** via `createProvider({...})` from `@earendil-works/pi-ai` — preferred when custom auth/filtering/refresh/streaming is required. (<https://pi.dev/docs/latest/custom-provider#quick-reference>)
  2. **Legacy provider-config form** — `pi.registerProvider("name", { baseUrl, apiKey, api, models, ... })`, structurally the same shape as a `models.json` provider entry. (<https://pi.dev/docs/latest/custom-provider#quick-reference>)
- Executable surfaces unique to (b), not expressible in (a):
  - `streamSimple(model, context, options) → AssistantMessageEventStream` — a custom streaming implementation for non-standard APIs. (<https://pi.dev/docs/latest/custom-provider#custom-streaming-api>)
  - `oauth.login / refreshToken / getApiKey` — provider-owned OAuth/SSO flow integrated with `/login`, with UI-neutral `OAuthLoginCallbacks` (`onAuth`, `onDeviceCode`, `onPrompt`, `onSelect`, `onProgress`). (<https://pi.dev/docs/latest/custom-provider#oauth-support>, `#oauthlogincallbacks>)
  - `refreshModels(context)` — dynamic model discovery (e.g. `fetch("http://localhost:1234/v1/models")` in an async factory). (<https://pi.dev/docs/latest/custom-provider#register-new-provider>)
  - An async extension factory; pi waits for the factory before startup continues, so discovered models are available to interactive startup and `pi --list-models`. (<https://pi.dev/docs/latest/custom-provider#register-new-provider>)
- `api` selects which built-in streaming impl is used *when `streamSimple` is absent*: `anthropic-messages`, `openai-completions`, `openai-responses`, `azure-openai-responses`, `openai-codex-responses`, `mistral-conversations`, `google-generative-ai`, `google-vertex`, `bedrock-converse-stream`. (<https://pi.dev/docs/latest/custom-provider#api-types>)
- Context-overflow normalization: a `message_end` handler in the same extension can rewrite `errorMessage` so pi recognizes provider-specific overflow and triggers compaction+retry. (<https://pi.dev/docs/latest/custom-provider#context-overflow-errors>)
- Config/auth value syntax (`!command`, `$ENV`, `$$`, `$!`) is shared with `models.json`. (<https://pi.dev/docs/latest/custom-provider#register-new-provider>)

**This is executable behavior owned by an extension process/module.** Category (b).

### 1c. Extension API lifecycle (`registerProvider`/`unregisterProvider`)

- `pi.registerProvider(name, config)` and `pi.unregisterProvider(name)` are extension-runtime API calls, distinct from the *content* they register. (<https://pi.dev/docs/latest/custom-provider#register-new-provider>, `#unregister-provider>)
- Lifecycle timing (from docs): "Calls made after the initial extension load phase are applied immediately, so no `/reload` is required." (<https://pi.dev/docs/latest/custom-provider#unregister-provider>)
- Unregister removes "that provider's dynamic models, API key fallback, OAuth provider registration, and custom stream handler registrations. Any built-in models or provider behavior that were overridden are restored." (<https://pi.dev/docs/latest/custom-provider#unregister-provider>)
- Extension factory may be `async`; dynamic model discovery happens in the factory, *not* in `session_start`. (<https://pi.dev/docs/latest/custom-provider#register-new-provider>)
- `pi.registerProvider("anthropic", { baseUrl, headers })` with only `baseUrl`/`headers` **overrides** an existing provider without replacing its models. (<https://pi.dev/docs/latest/custom-provider#override-existing-provider>)
- When `models` is provided, it **replaces** all existing models for that provider. (<https://pi.dev/docs/latest/custom-provider#register-new-provider>)
- Composition order (docs-implicit, confirmed in source §2): `models.json` overrides sit "above" registered native providers. (<https://pi.dev/docs/latest/custom-provider#quick-reference>: "Pi composes `models.json` overrides above registered native providers.")

Category (c).

### 1d. Auth/secret surface (providers doc)

Source: <https://pi.dev/docs/latest/providers>.

- Subscription OAuth providers via `/login`: Codex, Claude Pro/Max, GitHub Copilot, xAI, OpenRouter (PKCE → minted API key), Radius. Tokens in `~/.pi/agent/auth.json`, auto-refresh. (<https://pi.dev/docs/latest/providers#subscriptions>)
- API-key providers via env var or `auth.json` (table of ~35 providers → env var → `auth.json` key). `auth.json` created with `0600`. Auth file **takes priority over env vars**. (<https://pi.dev/docs/latest/providers#environment-variables-or-auth-file>, `#auth-file>)
- Resolution order: CLI `--api-key` → `auth.json` → env var → custom provider keys from `models.json`. (<https://pi.dev/docs/latest/providers#resolution-order>)
- Cloud-provider ambient creds: AWS (profile/IAM/bearer/ECS/IRSA), Vertex ADC, Cloudflare account/gateway, Azure. (<https://pi.dev/docs/latest/providers#cloud-providers>)
- Credential `key` supports the same `!command` / `$ENV` / literal syntax; shell commands are "cached for process lifetime" in `auth.json` (contrast: `models.json` shell commands resolve at request time). (<https://pi.dev/docs/latest/providers#key-resolution>)
- Credential-scoped `env` object: per-credential env values used before process env for key/headers/account IDs/proxy. (<https://pi.dev/docs/latest/providers#auth-file>)
- `/docs/latest/environment-variables`: provider API-key vars are documented separately in /providers; Pi process vars (`PI_OFFLINE`, `PI_CODING_AGENT`, `PI_CACHE_RETENTION`, `HTTP_PROXY`/`HTTPS_PROXY`, etc.) and bash-tool session env (`PI_PROVIDER`, `PI_MODEL`, `PI_REASONING_LEVEL`, …) are distinct. (<https://pi.dev/docs/latest/environment-variables>)

---

## 2. Pi source behavior (`.references/pi` @ 5bc1c2c)

### 2.1 Composition layer — `packages/coding-agent/src/core/provider-composer.ts`

This is the single source of truth for how (a) `models.json`, (b) extension `ProviderConfigInput`, and built-ins merge.

- `ProviderConfigInput` (the extension `registerProvider` input type) carries `streamSimple`, `oauth`, `refreshModels`, `headers`, `authHeader`, `models`. (`provider-composer.ts:42-69`)
- `composeModelProvider(providerId, base, modelConfig, extension)` builds a composed `Provider`:
  - `getModels` = `applyModelOverride(applyExtension(applyModelsJson(base.models, config), extension), config.modelOverrides)`. I.e. layering order is **built-in → models.json custom models (upsert) → extension models (replace when present) → models.json `modelOverrides` (patch)**. (`provider-composer.ts:427-443`)
  - When `extension.models` is present, it **replaces** (not upserts) — `applyExtension` maps `config.models` directly. (`provider-composer.ts:206-228`) This matches the docs ("`models` replaces all existing models").
  - When `extension.models` is absent and `extension.baseUrl` is set, base models are kept with baseUrl overridden. (`provider-composer.ts:207-209`) This matches "override existing provider".
  - `models.json` custom models use `modelFromJson`, which **upserts by id** (`existingIndex >= 0` replaces, else push). (`provider-composer.ts:193-198`)
  - `models.json` `modelOverrides` are applied *last*, after extension replacement and OAuth projection. (`provider-composer.ts:434-440`)
- Auth composition: `composeApiKeyAuth` and `composeOAuthAuth` merge built-in + `models.json` + extension auth; `authHeader: true` injects `Authorization: Bearer <resolved key>`. (`provider-composer.ts:294-384`)
- Stream dispatch: `streamWith` prefers `extension.streamSimple` when `model.api === extension.api`, then `base.stream(Simple)` for supported base APIs, then `getApiProvider(model.api)` (the API registry). (`provider-composer.ts:447-466`)
- Validation: `validateExtensionProvider` requires `api` when `streamSimple` is set; eagerly calls `getModels()` so structural errors surface at registration. (`provider-composer.ts:399-409`, `443`)
- `ExtensionOAuthConfig.modifyModels` lets OAuth projection reshape models after credential refresh. (`provider-composer.ts:32-39`, `432-436`)
- `configuredRequestAuthStatus` classifies the auth source: `stored` / `runtime` / `environment` / `fallback` / `models_json_key` / `models_json_command`. (`provider-composer.ts:533-548`)

### 2.2 Extension API lifecycle — `packages/coding-agent/src/core/extensions/runner.ts` + `model-registry.ts`

- `ModelRegistry` (the extension-facing facade) exposes both overloads: `registerProvider(Provider)` (native) and `registerProvider(name, ProviderConfigInput)` (legacy/config); `unregisterProvider(name)`; plus `getRegisteredProviderConfig`, `getRegisteredNativeProvider`, `getRegisteredProviderIds`. (`model-registry.ts:117-143`)
- `ExtensionRunner.bindCore` flushes `runtime.pendingProviderRegistrations` and `pendingNativeProviderRegistrations` queued during extension loading, then reassigns `runtime.registerProvider`/`registerNativeProvider`/`unregisterProvider` to call `providerActions` (or `modelRegistry`) **immediately** — confirming the docs' "applied immediately, no `/reload`". (`runner.ts:347-404`)
- Errors during flush are emitted as `ExtensionError` with `event: "register_provider"`. (`runner.ts:357-364`, `375-379`)
- The runtime is `invalidate()`-able after session replacement/reload; captured `pi`/ctx becomes stale. (`runner.ts:536-552`)

### 2.3 Env-key discovery — `packages/ai/src/env-api-keys.ts`

- `getApiKeyEnvVars(provider)` is a hard-coded `envMap` of ~35 provider → env-var entries (e.g. `"openai": "OPENAI_API_KEY"`, `"anthropic"` special-cased to 3 vars, `google-vertex`, `amazon-bedrock` ambient sources). (`env-api-keys.ts:72-119`)
- `findEnvKeys` reports availability; `getEnvApiKey` returns the key, special-casing Vertex ADC and Bedrock ambient creds to `"<authenticated>"`. (`env-api-keys.ts:122-183`)
- This is the table the `/providers` doc references. [UNVERIFIED] I did not diff every entry against the doc table, but the structure and the providers I sampled match.

### 2.4 Capability metadata (`compat`)

- `mergeCompat` deep-merges nested `openRouterRouting`, `vercelGatewayRouting`, `chatTemplateKwargs`. (`provider-composer.ts:78-98`)
- `Model["compat"]` and `Model["thinkingLevelMap"]` are first-class model fields carried through composition. (`provider-composer.ts:100-127`)
- The `compat` surface is large and API-specific (OpenAI-compat vs Anthropic-compat field sets, see /models doc §1a). This is **model capability metadata**, not executable code.

### 2.5 OAuth types

- `packages/ai/src/oauth.ts` is a type-only re-export from `./compat/extension-oauth-types.ts`. (`oauth.ts:1-10`) [UNVERIFIED] I did not open `compat/extension-oauth-types.ts`; the `OAuthLoginCallbacks` / `OAuthCredentials` shapes are documented in /custom-provider and used in `adaptOAuth` (`provider-composer.ts:230-247`).

---

## 3. Zag current state (Zig-native)

### 3.1 Pure Provider port — `packages/zag-agent-core/src/provider.zig`

- `Provider` is a type-erased vtable port with a single `chat(arena, messages, tools, control) → AssistantTurn`. (`provider.zig:12-45`)
- Core never imports wire clients; `WireProvider` (in `zag-coding-agent`) binds a `zag-ai.WireAdapter` to this port. (`zag-coding-agent/src/wire_provider.zig`)
- This is the **E0 / SDK composition** carrier for "custom Provider": a consumer implements the vtable in Zig. Confirmed as an SDK-ready capability in `D-008` ("stateful custom Tool, custom Provider, Observer, policy, cancellation, and session integration"). (`docs/decisions/active/D-008-sdk-and-process-boundaries.md:46-48`)
- **There is no `streamSimple`/`oauth`/`refreshModels` equivalent at this port.** The port is chat-only (plus `embed` on `WireAdapter`). Streaming is a `WireAdapter` concern, not a `Provider` concern.

### 3.2 Wire adapter / factory — `packages/zag-ai`

- `factory.createWire(gpa, io, config, style)` switches on `wire.ApiStyle` → `openai_compat` or `anthropic_messages`. (`factory.zig:16-27`)
- `wire.ApiStyle` has exactly two variants. Adding a wire protocol = new `ApiStyle` + adapter module; the comment explicitly forbids branching in Agent Core. (`presets.zig:1-9`)
- `presets.builtin` is a table of `ProviderSpec { id, name, base_url, env_keys, default_model, api_style }`. "Adding a vendor that speaks an existing wire: append one `ProviderSpec`." (`presets.zig:11-22`) — this is the E0 table-driven equivalent of Pi's built-in provider list.
- `registry.resolveFromEnv` resolves: `ZAG_PROVIDER=<id>` → preset; `ZAG_API_KEY` + `ZAG_BASE_URL` → "custom"; else first preset with a set env key. Overrides: `ZAG_BASE_URL`, `ZAG_MODEL`, `ZAG_API_STYLE`. (`registry.zig:43-138`)
- **No `models.json` equivalent.** `config_file.zig` (`FileConfig`) parses `.zag/config.json` / `zag.json` but only single-provider knobs: `provider`, `model`, `base_url`, `api_key_env`, transport retry/timeout, chat options, context limits. (`config_file.zig:13-45`) There is no `providers` map, no per-provider `models` array, no `modelOverrides`, no `compat`, no `headers`, no `authHeader`, no `oauth`.

### 3.3 Model catalog — `packages/zag-ai` (data, E0)

- Source of truth: `data/models/<provider>.json`; generated to `src/catalog_data.zig` (comptime `[]const ModelInfo`). (`data/README.md:1-19`, `catalog.zig:13-18`)
- `ModelInfo { id, name, provider, context_window, max_output_tokens, reasoning, vision, cost: ?CostRates }`. (`catalog_data.zig:12-26`)
- `catalog.contextBudgetChars` / `suggestedMaxOutputTokens` consume the table. (`catalog.zig:55-73`)
- "Unknown model ids still work on the wire; the catalog is for budgets, flags, and cost estimates." (`catalog.zig:41-47`, `data/README.md:58`) — i.e. the catalog is **advisory metadata**, not a gate.
- **No `compat` equivalent.** No `thinkingLevelMap`, no `input` types beyond `vision` bool, no per-model `headers`, no `cost.tiers`, no `thinkingFormat`, no `cacheControlFormat`, no strict-tool/grammar-tool flags. The capability-metadata surface is far narrower than Pi's.
- The generator can import from a local Pi tree: `generate_catalog.py --from-pi /path/to/pi/packages/ai`. (`data/README.md:46-50`) [UNVERIFIED] I did not run the generator or inspect its Pi-parsing logic.

### 3.4 Secrets / redaction / network — Gate state

- Redactor contract: applied **before** outward surfaces (verbose/trace JSONL/session persistence); copies configured secrets (at minimum the resolved provider API key) at `addSecret` time; pattern-based for common key shapes; fail-closed on OOM. (`packages/zag-agent-core/src/redact.zig:1-48`)
- Maturity confirms: "fake configured key 不出现在 verbose、trace、session fixtures; `.zag/` 仍标敏感; 无 zeroization/DLP 声称." (`docs/maturity.md:46`)
- Provider diagnostics: "HTTP/openai-zig 诊断仅 status+body length，不 log Authorization/body." (`docs/modules/zag-ai-provider.md:76`)
- Network is `std.http` (default) or curl (`-Dhttp_backend=curl`); deadline/active-cancel is backend-capability-truth (curl enforces, std fails closed with `UnsupportedControl`). (`docs/modules/zag-ai-provider.md:131-148`)
- **No OS sandbox / network egress policy.** "OS sandbox/network/process-tree enforcement is C7, not Phase H." (`docs/gaps/03-safety.md:29`)

### 3.5 Extension system — `docs/modules/extensions.md` (L0 stub)

- Status: **L0 / not implemented**. (`extensions.md:3-5`)
- Invariant: "Extensions do not import provider wire types into Kernel." (`docs/phases/C8-extensions.md:33`) — matches the existing `Provider` port discipline.
- "Process protocol is preferred; no stable Zig dynamic plugin ABI is required." (`extensions.md:27`, `C8-extensions.md:35`)
- Acceptance for executable extensions includes "executable child cancel/output/process ownership is tested." (`extensions.md:35`)
- **The extensions module doc does not mention `registerProvider`/`unregisterProvider` or custom providers at all.** It lists Skills, Hooks, MCP Tool servers, and Package directory as the surfaces. (`extensions.md:19-24`)

---

## 4. Correspondence: Pi → Zig-native Zag carrier

The plan's carrier/trust tiers: **E0 static Zig** / E1 passive resource / **E2 supervised process** / **E3 WASM Component** / host built-in.

### (a) Custom Model — data-only catalog entries

| Pi behavior | Zag carrier | Current Zag | Gap |
|---|---|---|---|
| `~/.pi/agent/models.json` `providers` map with per-provider `models`/`modelOverrides`/`compat`/`headers`/`authHeader`/`oauth` | **E0 static Zig** (comptime catalog) + **E1 passive resource** (runtime JSON) | E0 exists (`catalog_data.zig`); E1 absent (`config_file.zig` is single-provider only) | No `models.json` parser, no providers map, no upsert/override semantics |
| Per-model `compat` capability metadata | E0 (in `ModelInfo`) | `reasoning`/`vision`/`cost` only | No `thinkingLevelMap`, no `thinkingFormat`, no `cacheControlFormat`, no strict-tool/grammar-tool flags, no `input` array (only `vision` bool), no per-model `headers`, no `cost.tiers` |
| File reloads each `/model` open, no restart | E1 (runtime parse) | n/a | No runtime model-file parse at all (catalog is comptime) |
| `apiKey`/`headers` `!command`/`$ENV` resolution at request time | E1 + E2 (shell command = executable) | env-only (`auth_env.zig`); no `!command`, no shell-resolution | Shell-command secret resolution is an **executable** behavior → E2/supervised process, not E0/E1 |
| Upsert-by-id over built-ins; `modelOverrides` patch | E0 (comptime merge) or E1 (runtime merge) | comptime table, no merge | No merge layer |
| Auth-independent model loading (load now, available when auth configured) | E1 | models are always "available" (catalog is advisory) | Different model: Zag catalog doesn't gate on auth |

**Applicable carriers:** E0 for the curated built-in catalog (already done); **E1 passive resource** for a user `models.json`-equivalent (not done). E2 is *not* required for pure data entries, **except** for `!command`/shell secret resolution, which is executable and must be E2 (or omitted). E3 WASM is **not applicable** — passive data must not be forced into WASM (plan criterion: "WASM remains the planned preferred portable executable extension carrier, without forcing passive assets or OS integrations into WASM").

**Required Gate (secrets):** any `!command` resolution must go through the existing Redactor and must not appear in verbose/trace/session; network egress for `refreshModels`-style discovery is a separate E2 concern (see (b)).

### (b) Custom Provider — executable transport/stream/auth/discovery

| Pi behavior | Zag carrier | Current Zag | Gap |
|---|---|---|---|
| `streamSimple` custom streaming for non-standard APIs | **E0** (Zig impl of `WireAdapter` vtable) for in-process consumers; **E3 WASM** for portable third-party executable providers | E0 exists (`WireAdapter` vtable, `factory.createWire`); two built-in styles | No third-party executable provider carrier; no `streamSimple`-equivalent registration API |
| `api` selector (9 API types) | E0 (new `ApiStyle` + adapter module) | 2 of 9 (`openai_compat`, `anthropic_messages`) | Responses/Mistral-native/Google/Vertex/Bedrock explicitly deferred (`presets.zig:7-8`, `zag-ai-provider.md:65`) |
| `oauth.login/refreshToken/getApiKey` + `OAuthLoginCallbacks` | **E2 supervised process** (browser/device-code flows, token persistence) or host built-in | "H 不做 OAuth" (`zag-ai-provider.md:82`) | OAuth explicitly out of H scope; any OAuth is post-H and must be E2/host |
| `refreshModels` dynamic discovery (HTTP fetch in async factory) | **E2 supervised process** (network egress + JSON parse + registration) | no equivalent | No runtime model discovery; catalog is comptime |
| `authHeader: true` → `Authorization: Bearer` | E0 (transport header) | no equivalent | Minor; transport-level |
| `headers` with `!command`/`$ENV` values | E0 (env) + E2 (shell) | env only | Shell-command header values = executable |
| Context-overflow normalization via `message_end` handler | E0 (event hook) or E2 | no extension events | Requires extension event system (L0) |
| `adaptOAuth` / `modifyModels` OAuth projection | E2 | n/a | OAuth-dependent model reshaping |

**Applicable carriers:**
- **E0 static Zig** — a Zag consumer (or the product) implementing a new `WireAdapter` in Zig and registering it via `factory.createWire` / the `Provider` vtable. This is already an SDK-ready capability (`D-008`). This is the Zig-native analogue of "extension registers a complete `Provider`" — **but without a runtime registration API**: the consumer compiles against the vtable.
- **E2 supervised process** — for third-party executable providers (non-Zig, or untrusted Zig) that need custom transport/auth/discovery. This aligns with the existing process-supervisor direction for MCP/extension processes (`extensions.md:25-27`, `C8-extensions.md:25-31`). Network egress, child lifecycle, cancel/reap ownership, and permission/sandbox policy apply exactly as for built-in tools.
- **E3 WASM Component** — the plan's preferred *portable* executable carrier. Applicable for third-party `streamSimple`-equivalent logic that must be sandboxed portably. **Not applicable** for OAuth browser flows, OS keychain access, or ambient cloud creds — those are host/E2 concerns, not WASM.

**Required Gates:**
- **Secrets:** any provider that resolves secrets (env, `!command`, OAuth token) must register resolved keys with the Redactor; diagnostics must remain status+body-length only (`zag-ai-provider.md:76`).
- **Network:** provider egress is subject to `HTTP_PROXY`/`HTTPS_PROXY` and the backend-capability deadline/cancel contract (`zag-ai-provider.md:131-148`). E2 provider processes must be owned/cancelled/reaped by the process supervisor (`extensions.md:25`).
- **Auth:** OAuth is post-H; any OAuth carrier is E2/host and must not be claimed at L2 (`maturity.md` Provider row L3 direction: "fallback/multi-key/third protocol on demand").
- **Capability metadata:** a custom provider must declare its `api`/`api_style` so the loop/wire can classify errors and retry correctly. Missing capability metadata fails closed (existing invariant `zag-ai-provider.md:82-86`).

### (c) Extension API lifecycle (`registerProvider`/`unregisterProvider`)

| Pi behavior | Zag carrier | Current Zag | Gap |
|---|---|---|---|
| `pi.registerProvider(name, config)` / `registerProvider(Provider)` overload | **E0** (compile-time registration via `factory`/vtable) for Zig consumers; **E2/E3** (runtime registration protocol) for process/WASM extensions | E0 only (no runtime registry) | No runtime `registerProvider` API; no extension runtime at all (L0) |
| `pi.unregisterProvider(name)` + restore built-ins | E2/E3 (runtime) | n/a | No runtime unregistration |
| Flush pending registrations after load; immediate thereafter | E2 (extension load phase) | n/a | Depends on extension runtime (L0) |
| Async factory; pi waits before startup | E2 (supervised process startup) | n/a | n/a |
| Composition: built-in → models.json → extension → modelOverrides | E0 (comptime) + E1 (models.json) + E2 (extension) | E0 comptime only | No multi-layer composition |
| `invalidate()` after session replace/reload | E2 | n/a | n/a |

**Applicable carriers:** The *lifecycle API* is an **E2 (process) / E3 (WASM)** concern — it is a runtime registration protocol, not static Zig. The E0 equivalent is "the consumer compiles a `WireAdapter` and passes it to `Agent.init`," which Zag already supports. **A runtime `registerProvider`/`unregisterProvider` protocol is only meaningful once E2/E3 extension carriers exist** (C8, post-H). It must not be invented as an E0 dynamic plugin ABI — `D-008` explicitly disclaims a stable Zig dynamic plugin ABI / C ABI (`D-008:20-28`).

**Required Gate:** runtime provider registration must respect the same fail-closed capability-metadata invariant as tools (`extensions.md:21`: "Missing capability metadata fails closed"); registration errors must be structured and must not corrupt session/trace terminal state (`C8-extensions.md:33`).

---

## 5. Zag docs gaps (specific to this scope)

These are concrete omissions in the current Zag docs relative to the Pi correspondence, listed for the Round 2 verifier and the eventual docs update:

1. **`docs/modules/extensions.md` does not mention custom providers at all.** It lists Skills/Hooks/MCP/Package but not `registerProvider`/`unregisterProvider` or the custom-provider surface. The Pi (b)/(c) correspondence is absent. (`extensions.md:19-24`)
2. **No `models.json`-equivalent is documented anywhere.** `docs/modules/zag-ai-provider.md` documents presets/catalog/env resolution but no user-editable per-provider model catalog, no upsert/override semantics, no `compat`. (`zag-ai-provider.md:55-70`)
3. **Capability metadata (`compat` / `thinkingLevelMap`) is undocumented.** `catalog_data.zig` has only `reasoning`/`vision`/`cost`; the module doc does not acknowledge the gap vs. Pi's rich `compat` surface. (`zag-ai-provider.md:55-70`, `catalog_data.zig:12-26`)
4. **`!command` / shell secret resolution is undocumented and unsupported.** Pi supports it in both `models.json` and `auth.json`; Zag's `auth_env.zig`/`config_file.zig` have no equivalent, and the docs do not state this as a deliberate divergence. (`zag-ai-provider.md:82`: "Auth：env + 配置文件；H 不做 OAuth" mentions OAuth but not shell-command secrets.)
5. **OAuth carrier is not mapped to E2/host.** `zag-ai-provider.md:82` says "H 不做 OAuth（可后置）" but does not state which carrier (E2 supervised process / host built-in) would carry it, nor that browser/device-code flows are host/E2 not E3/WASM. (`zag-ai-provider.md:82`, `maturity.md` Provider row)
6. **Dynamic model discovery (`refreshModels`) is not mentioned.** No doc notes that runtime model discovery (Pi's async factory `fetch("/v1/models")`) is an E2/network capability absent from Zag. (`zag-ai-provider.md:65-70` lists deferred protocols but not discovery.)
7. **The E0 "custom Provider via `WireAdapter` vtable" SDK capability is under-advertised.** `D-008:46-48` lists "custom Provider" as SDK-ready, but `docs/modules/zag-ai-provider.md` does not cross-reference this as the Zig-native (a)/(b) E0 carrier. The correspondence between Pi's `createProvider({...})` and Zag's `WireAdapter` vtable is unstated.
8. **Composition/layering order is undocumented.** Pi's explicit order (built-in → models.json custom → extension → modelOverrides) has no Zag analogue or stated divergence. (`zag-ai-provider.md` has no composition section.)
9. **Per-provider `headers` / `authHeader` are absent.** No doc states this as a gap or deliberate cut. (`config_file.zig` has no headers field.)
10. **`modelOverrides` (patch without replace) has no Zag equivalent** and is not called out. (n/a in docs.)
11. **Cloud ambient creds (AWS/Vertex/Cloudflare/Azure) are not mapped.** `zag-ai-provider.md:65-70` says "绑死单一云" is a non-goal but does not distinguish ambient-credential providers (which need E2/host OS integration) from API-key providers. (`env-api-keys.ts:155-183` shows Pi's ambient handling; Zag has none.)
12. **Auth resolution order is not documented.** Pi has an explicit 4-step order (CLI → auth.json → env → models.json keys). Zag's `registry.zig:43-64` has a resolve order but it is not surfaced in the module doc as a contract.

---

## 6. Honest maturity / non-overstatement

- Zag Provider/zag-ai is **L2 (single-user, trusted-host)** for two wire styles, canonical retry/error/usage/cost, strict stream/tool terminal, curl deadline/cancel, redacted diagnostics. (`maturity.md` Provider row, `zag-ai-provider.md:170-182`)
- Zag **does not** claim: OAuth, third wire protocol, provider fallback/multi-key, dynamic model discovery, `models.json`, `compat` metadata, shell-command secrets, cloud ambient creds. These are L3/post-H or absent. (`maturity.md` Provider row L3 direction; `zag-ai-provider.md:65-70`, `:82`)
- Extensions are **L0**. (`maturity.md` Extensions row; `extensions.md:3-5`)
- No OS sandbox / network egress policy. (`gaps/03-safety.md:29`)
- E0 custom-provider composition via the `WireAdapter`/`Provider` vtable **is** SDK-ready (`D-008:46-48`), but this is compile-time Zig composition, **not** a runtime `registerProvider` API. Conflating the two would overstate the current state.

---

## 7. Open questions for Round 2

1. Verify `packages/ai/src/compat/extension-oauth-types.ts` `OAuthLoginCallbacks`/`OAuthCredentials` shapes match the /custom-provider doc (only the re-export in `oauth.ts` was read). [UNVERIFIED]
2. Diff the full `env-api-keys.ts` `envMap` against the /providers doc table entry-by-entry (sampled only). [UNVERIFIED]
3. Confirm whether `generate_catalog.py --from-pi` parses Pi's `compat`/`thinkingLevelMap` or only the narrow Zag `ModelInfo` fields (generator not inspected). [UNVERIFIED]
4. Check whether any Pi extension example (`examples/extensions/custom-provider-*`) demonstrates `refreshModels` + `streamSimple` together, to anchor the E2/E3 boundary concretely. [UNVERIFIED]
5. Confirm the `pi-mono-zig` historical Zig design (`.references/pi-mono-zig/zig/src/ai/model_registry.zig`, `model_discovery.zig`) is *historical archive only* and not a current Zag dependency — it appears under `.references`, not `packages/`, so this is likely, but the plan treats `pi-mono-zig` as a separate fixed source. [UNVERIFIED]

---

## 8. Source anchors

Pi docs:
- <https://pi.dev/docs/latest/models>
- <https://pi.dev/docs/latest/custom-provider>
- <https://pi.dev/docs/latest/providers>
- <https://pi.dev/docs/latest/environment-variables>

Pi source (`.references/pi` @ 5bc1c2c):
- `packages/coding-agent/src/core/provider-composer.ts:42-69` (ProviderConfigInput), `:78-127` (mergeCompat/applyModelOverride), `:130-198` (modelFromJson/applyModelsJson upsert), `:206-228` (applyExtension replace), `:230-247` (adaptOAuth), `:294-384` (auth composition), `:399-409` (validateExtensionProvider), `:419-498` (composeModelProvider, stream dispatch, layering)
- `packages/coding-agent/src/core/model-registry.ts:117-143` (registerProvider overloads, unregister)
- `packages/coding-agent/src/core/extensions/runner.ts:319-404` (bindCore flush + immediate registration), `:536-552` (invalidate)
- `packages/coding-agent/src/core/extensions/types.ts:1-1000` (ExtensionAPI event/tool/UI types; `ProviderConfig` referenced)
- `packages/ai/src/env-api-keys.ts:72-119` (envMap), `:122-183` (findEnvKeys/getEnvApiKey ambient)
- `packages/ai/src/oauth.ts:1-10` (type-only re-export) [UNVERIFIED for underlying `compat/extension-oauth-types.ts`]

Zag source:
- `packages/zag-agent-core/src/provider.zig:12-45` (Provider vtable port)
- `packages/zag-coding-agent/src/wire_provider.zig:1-90` (WireProvider bridge)
- `packages/zag-ai/src/factory.zig:16-27` (createWire switch)
- `packages/zag-ai/src/presets.zig:11-22` (ProviderSpec table), `:1-9` (scope comment)
- `packages/zag-ai/src/registry.zig:43-138` (resolveFromEnv order)
- `packages/zag-ai/src/config_file.zig:13-45` (FileConfig single-provider)
- `packages/zag-ai/src/catalog.zig:13-73`, `catalog_data.zig:12-26` (ModelInfo)
- `packages/zag-ai/data/README.md:1-58` (catalog schema + generator)
- `packages/zag-agent-core/src/redact.zig:1-48` (redaction contract)

Zag docs:
- `docs/modules/zag-ai-provider.md:55-70` (wire boundary / deferred), `:76` (diagnostics), `:82-86` (auth invariants), `:131-148` (deadline/cancel capability truth), `:170-182` (L2 acceptance)
- `docs/modules/extensions.md:3-35` (L0 stub, surfaces, acceptance)
- `docs/phases/C8-extensions.md:25-35` (executable extension carrier/invariants)
- `docs/decisions/active/D-008-sdk-and-process-boundaries.md:20-28` (no dynamic ABI), `:46-48` (SDK-ready custom Provider)
- `docs/maturity.md` (Provider row L2/L3; Extensions L0; Phase H exit secrets §6)
- `docs/gaps/03-safety.md:29` (OS sandbox is C7)
- `docs/modules/permissions.md:20-28` (descriptor-derived risk gate)

Historical Zig archive (`.references/pi-mono-zig`, *not* a Zag dependency):
- `zig/src/ai/model_registry.zig:1-90` (ProviderConfig/ModelDefinition with compat/thinking_level_map/headers)
- `zig/src/ai/model_discovery.zig:1-60` (discoverAndRegister via HTTP; OpenAI/Ollama kinds)