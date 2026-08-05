---
id: session-item-001
scope: types+context/session-item
status: contract-draft
priority: P1
depends-on:
  - post-tui-remote-dual-backend-gate-001
---

# objective

Introduce the **session-item semantics slice** for the conversation model:
`prompt_index` turn accounting, `synthetic` message markers (Pi `syntheticReason`
family: interjection / task-completed / auto-continue / system-reminder), a
`reasoning` carrier so model thinking survives the wire (OpenAI
`reasoning_content`, Anthropic `thinking`/`redacted_thinking`), unified
**token estimation** (truncating `len/4`, image fixed estimate), a **tolerant
dangling-tool-call repair** pass, and a **token-budget truncate-for-prompt**
replacing the character-count trim stage — while the D-011 `ContextView` gate,
`validateBodyHistory` fail-closed rejection, Session v1 schema, and Trace v1
remain byte-identical.

Design reference (behavior, not parity): pi's synthetic-message semantics
(`packages/coding-agent` in `earendil-works/pi`) and the Rust port's
conversation model (`xai-grok-sampling-types` conversation.rs — exact porting
spec at `/tmp/conversation_model_spec.md`).

**Binding specification:** [session-item.md](../../modules/session-item.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **draft** — pending independent architecture + safety re-reviews |
| Implementation | not started |
| Maturity | **unchanged** — no row add/raise (enrichment, per roadmap C5/C4 precedent) |
| Session v1 / Trace v1 / headless-v1 / Core D-011 seams | **unchanged** by contract law |
| post-tui-remote-dual-backend-gate-001 | orthogonal — no interference |

# context

- Current transcript: flat `[]message.Message` over a run-lifetime arena
  (`packages/zag-agent-core/src/transcript.zig:23-26`), no prompt_index /
  synthetic / reasoning fields (recon: `ZagInternalsRecon`).
- D-011 gate: `ContextView.view()` (context_view.zig:38-67) → loop validates via
  `protocol_history.validateViewBody` (loop.zig:231) → `error.InvalidContext`.
  Hostile tests: loop.zig:2075/2125/2189/2260.
- Compaction: `packages/zag-coding-agent/src/context.zig` — transcript is
  authoritative; compaction only shapes the model view (`viewForModel` :251-367);
  budget is **character-based** (`estimateChars`), no token estimator exists
  (`estimateTokens ((len+3)/4)` from the historical port is not in this tree).
- Adapters drop reasoning today: openai_compat.zig:698 reads only `msg.content`;
  anthropic_messages.zig:701-728 ignores thinking blocks; nothing re-sent or
  persisted.
- Tool flow: serial call-list-order execution (loop.zig:316-331); dangling
  bundles are fail-closed rejected by `validateBodyHistory`
  (protocol_history.zig:28-56); no tolerant repair path exists.
- Hostile ContextView tests: loop.zig:2125 (orphan tool row), :2189 (leading
  system + incomplete bundle), :2260 (compaction fact + malformed body) —
  loop.zig:2075 is the positive identity test, not hostile.
- Session storage: JSONL v1 (`session_store.zig`), row = role + optional
  tool_calls/tool_call_id/content_parts (content_parts dropped on load).

# path

| Path | Role |
|------|------|
| `packages/zag-types/src/root.zig` | Message/AssistantTurn additive fields |
| `packages/zag-agent-core/src/session_item.zig` | NEW pure module: estimateTokens, assignPromptIndices, repairDanglingToolCalls, truncateForPrompt (Core-owned per D-011 bundle-legality single source) |
| `packages/zag-agent-core/src/transcript.zig` | appendAssistantTurn forwards reasoning; appendSyntheticReason |
| `packages/zag-coding-agent/src/context.zig` | viewForModel: repair pass + token-budget truncate |
| `packages/zag-coding-agent/src/session_store.zig` | persist/load reasoning/synthetic/prompt_index (backward compatible) |
| `packages/zag-ai/src/openai_compat.zig` | capture `reasoning_content` |
| `packages/zag-ai/src/anthropic_messages.zig` | capture `thinking`/`redacted_thinking` |
| Forbidden | Core loop semantics, D-011 View contract, validateBodyHistory rejection behavior, Session v1 header/schema, Trace v1, chapters |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Type carrier | additive optional fields on `Message` (`reasoning: ?[]const u8 = null`, `synthetic: bool = false`, `prompt_index: ?u32 = null`) and `AssistantTurn.reasoning`; NO new item-union/enum, NO parallel item list (transcript stays `[]Message`) |
| Token estimate | truncating `len / 4` (zag-defined v1; explicit divergence from the historical `(len+3)/4` round-up); image fixed `765`; `Message.estimateTokens()` convenience; `estimateChars` behavior for existing inputs unchanged (additive: counts reasoning when set) |
| prompt_index | **pinned algorithm**: turn counter increments ONLY at rows that start a turn (`.user` rows, and synthetic rows with `prompt_index == null`), and only when a stamp is applied; turn-start rows receive the new (post-increment) index, all other rows receive the current index (assistant/tool rows share their turn's index); resume passes the persisted max as `next` (first new `.user` row lands on `max + 1`); `appendSyntheticReason` takes the index from the caller (Core supplies it from its running counter) |
| Synthetic markers | `synthetic: bool` + optional `reasoning` text; no enum vocabulary in v1 (Pi's SyntheticReason taxonomy deferred; the bool + optional text is the v1 carrier) |
| Reasoning | plain text only (no signature/encrypted blocks); carried transcript-side; never replayed to a provider; NOT claimed in headless-v1 output (schema unchanged in v1) |
| Repair | tolerant pass runs in the product ContextView layer **before** validation (repair-first): drops unmatched tool-result rows and empty-carrier rows; never invents content; `validateBodyHistory` stays authoritative in the Core/loop path — the three loop hostile tests stay byte-identical; incomplete bundles, out-of-order results, duplicate/empty call ids, and leading-system-without-tail still `InvalidContext`; orphan/empty-carrier-only transcripts are intentionally rescued by the product layer (deterministic view; transcript untouched) |
| Truncate | token-budget `truncateForPrompt` runs as the **first budget stage** (before the count cap); the historical count cap (`max_tail_messages`) and the soft char-trim under summary cost are retained; budget derived from the existing char budget (`max_chars / 4`, `effectiveTokenBudget`), no new config option; `budget_tokens = 0` with `min_tail = 0` → empty view + compaction event; `min_tail > 0` → tail rows kept (soft budget) |
| Serialization | session rows gain optional `reasoning`/`synthetic`/`prompt_index`; schema_version stays 1; missing fields default (null/false) |
| Redaction | `writeMessageRedacted` redacts `reasoning` through the same per-field redact path as content; fixture proves secrets inside reasoning are hidden in redacted saves |
| Divergence from Rust | no BackendToolCall, no Compaction/Codex encrypted item, no ReasoningModelIdentity replay gating, no Kimi dialect, no doom-loop, no cache breakpoints in this slice (grok/xAI-specific; zag has no such route) |
| Ownership | `session_item.zig` lives in **zag-agent-core** (pure module; `protocol_history.zig` precedent — Core is the single authoritative source for bundle-legality logic per D-011); L0 (`zag-types`) gains only the additive fields; product layer owns repair/truncate composition |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| Estimate | `estimateTokens`: `len/4` truncation edges (0/3/4/5 bytes), image 765, CJK bytes counted as bytes; `Message.estimateTokens()` sums content+parts+tool fields |
| Repair | unmatched tool-result dropped; empty-carrier row dropped; legal bundle untouched (byte-identical view); mixed legal+orphan keeps legal bundle; orphan/empty-carrier-only transcript rescued to a deterministic valid view |
| Fail-closed | loop hostile tests (2125/2189/2260) byte-identical (repair not in loop path); incomplete-bundle and leading-system-without-tail transcripts still `InvalidContext`; repair never runs on the transcript (view-only) |
| Truncate | token budget boundary; bundle atomicity (assistant+results kept together via alignToLegalStart); min_tail honored; budget=0 + min_tail=0 → empty + compaction event; budget=0 + min_tail>0 → tail kept |
| prompt_index | monotone across appends; synthetic rows share current turn index; resume assigns next after persisted max; mid-turn synthetic fixture |
| Reasoning capture | OpenAI `reasoning_content` → AssistantTurn.reasoning; Anthropic `thinking` + `redacted_thinking` → reasoning (text joined; signature-only redacted blocks contribute nothing); absent → null |
| Persistence | save/load round-trip with reasoning/synthetic/prompt_index; old rows (missing fields) load as null/false; redacted save hides secrets inside reasoning; content_parts behavior unchanged |
| Regression | loop hostile suite (3), protocol_history suite, context.zig suite, session_store suite, agent.zig compaction suite — all green; std/curl dual-backend matrix |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (std + curl
  matrices); **no** maturity raise; **no** remote claim; **no** push without
  Gate.

# non-goals

- Turn-boundary enum / session-item union type
- Pi SyntheticReason taxonomy (bool + text only in v1)
- Reasoning replay to providers, KV-cache provenance, endpoint fingerprinting
- BackendToolCall / Compaction / doom-loop / Kimi dialect / cache breakpoints
- Changing `validateBodyHistory` rejection behavior or the D-011 View contract
- Session v1 schema version bump; Trace v1 changes
- Maturity raise

# related

- [session-item.md](../../modules/session-item.md) (binding)
- [roadmap](../../roadmap.md) C5 Context · M3 slice
- [tui-minimal-001](./tui-minimal-001.md) · [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md)
- [core-boundary.md](../../modules/core-boundary.md) (D-011)
- pi synthetic-message semantics: `earendil-works/pi` packages/coding-agent
- Rust reference: `xai-grok-sampling-types` conversation.rs (spec at `/tmp/conversation_model_spec.md`)
