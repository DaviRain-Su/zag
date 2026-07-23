# 2026 Harness Landscape → Zag gap map

> **Research freeze:** 2026-07-24.  
> Sources: [earendil-works/pi](https://github.com/earendil-works/pi), X/Twitter, GitHub awesome lists, 2026 harness engineering posts.  
> Implementation target: **Zag** monorepo (`agent → zag-ai → openai-zig`).  
> (If product is referred to elsewhere as “GIGA”, same stack / same gaps.)

---

## 1. Industry consensus

| Theme | Signal | Zag implication |
|-------|--------|-----------------|
| **2026 = year of the harness** | Anthropic/OpenAI eng narrative; LinkedIn “agent harnesses trump model quality” | Vision already correct: model is engine, harness is product |
| **Thin vs thick spectrum** | Claude Code / Pi: thin loop + strong model; LangGraph: graph encodes control | Daily coding agents lean **thin loop + thick constraints** (permission, verify, context)—not DAG-as-default |
| **Loop still core for coding** | “Close the loop / self-verify”; Anthropic long-running: Discover → Isolate → Verify → Persist → Schedule | Phase H (errors, golden, cancel, redact, real edit path) is on the main path |
| **Graph is real for multi-agent topology** | X “loop → graph”; MS Agent Framework; LangGraph | Fan-out, handoff, checkpoints, specialist nodes → **C6+**, not Phase H rewrite |
| **Composable layers** | Harness = 15+ replaceable jobs (policy, tools, memory, obs, routing…) | Monorepo split already matches; don’t re-monolith |
| **Session / compaction** | Pi session trees + compaction; HF session sharing culture | Long-run reliability = session + compaction + resume |
| **Extensions without fork** | Pi packages / skills; Hyper skills; MCP debates | C8; “先插件后内核” |

### Harness ≠ Loop ≠ Graph

| Layer | Meaning | Zag today |
|-------|---------|-----------|
| **Harness** | Machinery around the model: tools, policy, context, obs, lifecycle | Teaching skeleton; deepen in H |
| **Loop** | Repeated work → tool → feedback cycle | `loop.zig` L1 |
| **Graph** | Explicit nodes/edges/joins/state for multi-role workflows | Not built; optional C6+ |

```text
Harness
  └── Loop (coding agent default)     ← now / Phase H
        └── optional Graph (org)      ← C6+ only if needed
```

Even graph systems embed **loops inside nodes**. Graph does not replace the coding tool loop.

---

## 2. Pi (primary reference)

Repo: [earendil-works/pi](https://github.com/earendil-works/pi) (~76k★). Site: [pi.dev](https://pi.dev).

### Packages

| Pi | Role | Zag analogue |
|----|------|--------------|
| `pi-ai` | Multi-provider LLM, tools stream, catalog, cost | `zag-ai` + `openai-zig` (OpenAI-compat only by design) |
| `pi-agent-core` | Stateful agent, tool loop, events, transformContext → convertToLlm | `agent/loop` + `Agent` + Provider port |
| `pi-coding-agent` | CLI: sessions, compaction, extensions, skills, TUI | `main` + session/context/tools (thinner) |
| `pi-tui` / storage / server | Product shells | C9 / later |

### Philosophy (absorb)

- Minimal core; **extend without fork**.
- Core skips MCP, sub-agents, permission popups, plan mode, todos, background bash → extensions / packages / OS (tmux, containers).
- Session is a **tree** (`/tree`, `/fork`), not only linear JSONL.
- **Compaction** first-class: cut point, keep recent tokens, structured summary entry, reload.
- Message path: `AgentMessage[] → transformContext → convertToLlm → LLM` (transcript ≠ wire view).
- Event stream for UI/extensions.

### Pi strengths to copy (behavior)

1. transformContext / convertToLlm boundary → Zag `viewForModel` + H4 four layers.  
2. Real compaction + session entries → H4 (not char-trim only).  
3. Session tree/fork → C5.  
4. Extension API (`registerTool`, lifecycle, block tool_call) → C8.  
5. Rich events → H7 versioned trace.  
6. Package discipline → keep `openai-zig` / `zag-ai` / `agent` / `runtime`.  
7. Skills as README-driven tools (MCP optional) → matches vision.

### Pi skips vs Zag

| Pi skips | Zag |
|----------|-----|
| Built-in permissions | **Keep** ask/yolo + jail + shell_policy; harden H3/H5 |
| Built-in OS sandbox | Honest docs → C7 |
| Sub-agents / MCP in core | Same: later package (C6/C8) |

**Zag posture:** Pi-like modular core **plus** intentional safety gates (Hyper/Codex lean).

---

## 3. Zag gaps (production harness)

Legend: ✅ have · 🟡 partial · ❌ missing

| Capability | Now | Target |
|------------|-----|--------|
| Tool loop | ✅ L1 | H1: machine-readable errors, cancel, golden |
| Provider | 🟡 L1+ | H6: stream cancel, session usage, contract dir |
| Linear session | ✅ | H4: schema version + migration |
| Session tree/fork | ❌ | C5 |
| Compaction (summary + reload) | ❌ trim only | H4 → C5 upgrade |
| Four-layer prompt | 🟡 | H4 |
| Extensions/skills/packages | ❌ | C8 |
| Trace schema | 🟡 usage events | H7 |
| search_replace + grep/glob | ❌ write-only | **H2** (largest day-to-day gap) |
| Permission matrix / remember | 🟡 | H3 |
| Redact / doctor / policy matrix tests | ❌ | H5 |
| Subagents / Oracle / Graph org | ❌ | C6 |
| Memory Repo | ❌ (spec) | C5 opt-in |
| OS sandbox / worktree isolate | ❌ | C7 |
| Golden + security eval CI | ❌ | H + Quality |
| TUI / RPC / SDK | ❌ thin CLI | C9 |

### Priority

```text
P0 Phase H — finish single-agent production floor
  H2 edit/search path
  H1 errors + cancel + golden
  H4 session schema + real compaction   ← deep-read Pi compaction/sessions
  H5 redact + policy tests
  H3 permission matrix
  H6/H7 closeout
  Quality gates

P1 Capability — only after H
  C4 edit sharpness
  C5 repo map + fork + Memory (opt-in)
  C6 graph/subagent if multi-role needed
  C7 sandbox / worktree
  C8 Pi-shaped extensions
  C9 product shell
```

### Graph: do / don’t

| Don’t (now) | Do (design hooks) |
|-------------|-------------------|
| Replace `loop.run` with full DAG engine | Typed tool error codes + recovery policy |
| Multi-agent org before solid tools/session | Session schema as checkpoint primitive (H4) |
| “Everything is a node” framework | Parallel read-only tools as L3 loop spec; subagent nodes in C6 |

---

## 4. Strategy (one line)

> Copy **Pi’s** package discipline, session/compaction depth, and extension philosophy; keep **Zag’s** safety gates; finish a strong **single-agent loop (Phase H)** before any **graph/org multi-agent** layer. Industry “graph” hype maps to **C6+**, not a rewrite of the coding loop.

## Related

- [references.md](../references.md) · [maturity.md](../maturity.md) · [phases/H-harden.md](../phases/H-harden.md)  
- [modules/loop-turn.md](../modules/loop-turn.md) · [modules/memory.md](../modules/memory.md)  
