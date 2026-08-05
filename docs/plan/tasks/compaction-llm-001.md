---
id: compaction-llm-001
scope: context/compaction
status: implementation-complete
priority: P1
depends-on:
  - session-item-001
  - chat-state-prune-001
---

# objective

Add **LLM-generated compaction summaries** to the existing heuristic
compaction, following pi (TS) behavior: a structured context-checkpoint
summary (`## Goal / Constraints / Progress / Key Decisions / Next Steps /
Critical Context`) generated from the dropped prefix, with iterative UPDATE
when a prior summary exists, serialized conversation input (tool results
truncated), Rust-style summary cleaning + degenerate detection, a retry
ladder, and a provider seam injected by the product layer. The existing
heuristic `buildSummary` remains the **default fallback** — without a
configured summarizer, behavior is byte-identical to today (h-context-001
untouched).

**Binding specification:** [compaction-llm.md](../../modules/compaction-llm.md)

# status truth

| Track | Status |
|-------|--------|
| Contract | **PASS** — close-out re-review (two revision rounds closed R1-B1/B2/B3 + R2-B4; zero blockers) |
| Implementation | **complete** — std 749/749, curl 748/748 (baseline 712/711 → +37 tests) |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 / Core D-011 seams | **unchanged** (loop.zig, context_view.zig, protocol_history.zig untouched) |
| session-item-001 / chat-state-prune-001 | closed — this slice builds on them |

# context

- zag compaction today: `viewForModel` (context.zig) drops a prefix under
  budget, then `buildSummary` (heuristic: dropped header + highlights +
  lineage) in a fixed-point loop; `Session.noteCompaction` records gen +
  summary (persisted in session header, schema v1); h-context-001 L2 covers
  OOM atomicity, lineage digests, UTF-8, resume parity.
- pi (TS) reference (extracted): `compaction.enabled/reserveTokens/
  keepRecentTokens` (defaults true/16384/20000, absolute-token threshold);
  `prepareCompaction` → LLM summarize (current session model, streaming,
  `maxTokens = 0.8 * reserveTokens`) → append compaction row → rebuild view
  (transcript keeps ALL rows); summary format = structured checkpoint;
  UPDATE prompt when prior summary exists; serializeConversation with tool
  results truncated at 2000 chars; retry per settings (max 3, 2s/4s/8s);
  degenerate summaries NOT checked in pi (Rust adds
  `is_degenerate_summary < 500 chars`).
- Rust (architecture reference): `sample_summary_with_retries` (max 3,
  delay 3s, deterministic-vs-transient classification,
  degenerate/empty → transient retry); `format_compact_summary` (strip
  `<analysis>`, neutralize control tokens, collapse newlines);
  `CompactionSampler` trait = the seam model.

# path

| Path | Role |
|------|------|
| `packages/zag-types/src/root.zig` | NEW seam types (CompactionSummarizer + SummaryRequest/Result/ErrorKind — L0, neutral provider-facing) |
| `packages/zag-agent-core/src/session_item.zig` | NEW pure fns: `serializeConversationForSummary`, `formatCompactSummary`, `isDegenerateSummary`, `buildSummaryPrompts`, `summarizeWithRetry` (Core-owned) |
| `packages/zag-coding-agent/src/context.zig` | `Options.summarizer` field; viewForModel post-convergence single call + OOM catch + fallback |
| `packages/zag-coding-agent/src/agent.zig` | product implementation of `CompactionSummarizer` over the existing provider |
| Forbidden | loop.zig, context_view.zig, protocol_history.zig, Session v1 schema, Trace v1, chapters |

# contract summary

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Summarizer seam | seam types (`CompactionSummarizer` vtable + `SummaryRequest`/`SummaryResult`/`SummaryErrorKind`) live in **zag-types (L0)** (neutral provider-facing types: ChatError/RequestControl precedent); `summarizeWithRetry` + the pure helpers live in **Core** (`session_item.zig`) — Core defines the port, product implements (mirror of D-011 ContextView pattern); no Core→product import |
| Fallback law | summarizer absent OR any failure (after retries) → existing heuristic `buildSummary`; the view/event/trace/session bytes are identical to today in all fallback paths (h-context-001 regression suite must stay green unchanged) |
| Trigger | unchanged budget machinery (effectiveTokenBudget); the summary provider is only consulted when dropped > 0 (a compaction is happening anyway) |
| **Call timing (fixed-point composition)** | the LLM summarizer is called **ONCE, after the fixed-point loop converges** (final `dropped` set), NOT inside the loop; the convergence loop keeps using the heuristic summary for re-costing (convergence + "summary describes that set" invariant preserved); on success the LLM text replaces the heuristic text in the final compaction event only; the LLM text's true length is naturally costed by the NEXT turn's layers — no divergence, no extra loop iterations, at most 1 call × 3 attempts |
| max_tokens | `min(0.8 * effectiveTokenBudget(), 256)` computed with u32-saturating arithmetic (unlimited-budget config → 256); summary_cap = 800 chars still clamps the final text; no new user-facing config |
| Serialization | `serializeConversationForSummary(items)` — pi semantics: role-tagged flat text `[User]/[Assistant]/[Assistant tool calls]/[Tool result]`; tool results truncated at 2000 chars with `[... N more characters truncated]`; reasoning included as `[Assistant thinking]` when present |
| Prompts | pi INITIAL prompt (structured checkpoint format) + UPDATE prompt (prior summary in `<previous-summary>` tags); system prompt = pi SUMMARIZATION_SYSTEM_PROMPT |
| Cleaning | Rust `formatCompactSummary` semantics: strip leading `<analysis>` blocks, convert `<summary>` wrapper to `Summary:`, neutralize control tokens (`<` → `\u{200B}<` in summary/analysis tags), collapse 3+ newlines, trim; `isDegenerateSummary(text) = cleaned visible chars < 500` |
| Retry ladder | per attempt: degenerate/empty → transient retry; `err.kind == .deterministic` → abort immediately; `.timeout`/`.transient` → retry with delay; `.context_overflow` → abort (v1: no input ladder — heuristic fallback). max_attempts 3, delay 3s. On final failure → heuristic fallback |
| Injection | the summary replaces the heuristic summary at the same point (compaction event + session layer + trace) — event shape unchanged; on LLM success the event summary is **mechanically composed** = cleaned LLM text + `\n` + the structured lineage section (existing `writeLineage` semantics: exact prior or prior_bytes/kept_bytes/digest/[LINEAGE_TRUNCATED]), budgeted against summary_cap exactly like the heuristic path — lineage-chain preserved in both paths |
| Prior summary | when `layers.session` (prior compaction summary) is non-empty, use the UPDATE prompt and carry it in `<previous-summary>`; lineage markers preserved per h-context-001 (via the composition above) |
| Skip guard | when `4 * max_tokens < MIN_SUMMARY_SEED_CHARS` (effective budget < ~157 tokens can never produce a non-degenerate summary) → skip the LLM path entirely, heuristic stands (no wasted attempts/sleeps) |
| Prompt assembly | the CALLER (viewForModel) concatenates: serialized conversation (single user message content) + `\n\n` + INITIAL/UPDATE template (pi order: conversation first, then instructions); system prompt = pi SUMMARIZATION_SYSTEM_PROMPT |
| OOM semantics | `summarizeWithRetry` propagates `error.OutOfMemory` (does NOT return null); the replacement point in viewForModel catches it and falls back to the heuristic path (turn continues) — the existing h-context-001 OOM atomicity of noteCompaction is untouched |
| Divergence from pi | no `/compact` command, no extension hooks, no turn-prefix split summarization, no streaming UI, no custom instructions in v1; no firstKeptEntryId persistence (schema v1 frozen — view shaping already budget-driven); max_tokens capped at 256 (pi: ~13107) |

# verification (implementation track)

### Fixture classes (must all appear)

| Class | Intent |
|-------|--------|
| Serialization | role tags; tool result truncation at 2000 chars with marker; reasoning tag; empty input |
| Prompts | INITIAL prompt contains the exact format skeleton; UPDATE prompt contains previous-summary tags and prior summary text; system prompt matches pi |
| Cleaning | strips `<analysis>`; converts `<summary>` wrapper; neutralizes control tokens; collapses newlines; degenerate (<500 cleaned chars) vs healthy |
| Summarizer seam | fake summarizer injected: success path uses LLM text in event/session/trace; deterministic err → immediate heuristic fallback; transient err ×3 → heuristic fallback; degenerate ×3 → heuristic fallback; success after 2 transient retries → LLM text used |
| Fallback identity | summarizer = null: every h-context-001 compaction test byte-identical (existing suite green unchanged) |
| Fixed-point composition | convergence loop runs with heuristic cost (identical iterations with/without summarizer when LLM text differs in length); LLM called exactly ONCE on the final dropped set; event summary = LLM text while the loop saw heuristic length; next-turn layers cost the LLM text's real length |
| Prior summary | second compaction with non-empty layers.session uses UPDATE prompt + carries prior text; lineage markers present |
| Lineage composition | LLM success event summary = LLM text + lineage section (same writeLineage semantics as heuristic); lineage bytes present in session + trace; budgeted under summary_cap |
| Clamps | LLM text > summary_cap clamped on UTF-8 boundary; invalid UTF-8 → U+FFFD (same machinery as heuristic) |
| Skip guard | tiny budget (4*max_tokens < 500) → LLM path skipped, heuristic stands, summarizer never called |
| OOM | summarizeWithRetry OOM → caught at replacement point → heuristic fallback; noteCompaction OOM atomicity unchanged |
| Regression | session-item-001, chat-state-prune-001, h-context-001 suites green; std/curl dual-backend matrix |

### Gate

- develop ≠ verify; task Gate (fixtures above) + merged-main Gate (std + curl
  matrices); **no** maturity raise; **no** remote claim.

# non-goals

- `/compact` slash command and custom instructions
- Extension hooks (session_before_compact)
- Turn-prefix split summarization
- Streaming compaction UI / status indicator
- Input ladder (verbatim → fitted → lossy) on context_overflow
- firstKeptEntryId persistence or Session v1 schema change
- Changing the heuristic path when no summarizer is configured
- Maturity raise

# related

- [compaction-llm.md](../../modules/compaction-llm.md) (binding)
- [session-item-001](./session-item-001.md) · [chat-state-prune-001](./chat-state-prune-001.md)
- [roadmap](../../roadmap.md) C5 Context · M3 slice
- pi reference: `packages/coding-agent/src/core/compaction/compaction.ts`
  (prompts :467-537, serialize utils.ts:88-150) + `agent-session.ts:1781-2192`
- Rust reference: `xai-grok-compaction/src/code_compaction/{summary,sample}.rs`
