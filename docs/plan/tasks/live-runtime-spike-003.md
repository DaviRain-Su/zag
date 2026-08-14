---
id: live-runtime-spike-003
scope: spikes/live-runtime (D-013 prototype track)
status: done
priority: P1
depends-on:
  - live-runtime-spike-002
---

# objective

Put a minimal but real agent loop **inside the live Scheme image** and prove
the end-to-end claim of the whole track: **the agent rewrites its own policy
mid-conversation, the conversation continues with the new behavior, the image
is SIGKILLed, and after replay both the conversation and the redefined policy
are alive.**

This is the Autolith-parity moment for the Zig-kernel + live-image
architecture, and the evidence base for the later productization decision
(D-014: live policy layer vs whole loop in the image).

**Binding specifications:**
[analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) ·
[D-013](../../decisions/active/D-013-live-runtime-prototype-track.md) ·
[spike-001](./live-runtime-spike-001.md) · [spike-002](./live-runtime-spike-002.md)

# status truth

| Track | Status |
|-------|--------|
| Design docs | current through spike-002 findings; round-4 findings appended 2026-08-14 |
| Implementation | **done** — 10/10 probes PASS; independent review [live-runtime-spike-003-01](../reviews/live-runtime-spike-003-01.md) **pass** (zero blocking; H2–H5 P3s in [backlog](../backlog.md)) |
| Maturity | **unchanged** — spike exempt; scripted fake provider, no real model |
| Unblocks | D-014 productization decision — evidence base complete |

# architecture (v0, binding for this task)

```text
user input
  │
  ▼
Zig supervisor ──append user entry (fsync)──► .work/conversation.sexp
  │ send turn
  ▼
Scheme image: agent loop (RE-DEFINABLE policy)
  │  system-prompt fn + tool registry + history from store
  │ provider.call ──► Zig fake provider (scripted, deterministic)
  │ tool.invoke   ──► Zig tool shim (fs.read, workspace-jailed)
  │ append entry  ──► Zig appends to conversation.sexp (fsync)
  ▼
assistant reply rendered
```

- **Conversation store** (`.work/conversation.sexp`): Zig-owned append-only
  s-expr entries — `(user ...)` / `(assistant ...)` / `(tool-call ...)`
  / `(tool-result ...)` with seq + ts. User input is appended **before** any
  provider work. Incomplete-tail tolerance per analysis design notes.
- **Fake provider** (`.work/provider-script.sexp`): scripted responses
  consumed in order; `(say "...")` or `(call <tool> (args...))`. Every
  response echoes the system prompt it received, so the transcript proves
  which policy produced each turn.
- **Agent policy lives in tracked bindings**: `system-prompt` and
  `tool-registry` are ordinary kernel-tracked definitions, redefinable via
  `kernel.redefine`, subject to commit/discard/suspect semantics from
  spike-001/002.
- **Recovery**: on respawn the image rebuilds its context from
  `conversation.sexp` (history replay) + journal (policy replay). Partial
  turns: entries are appended per completed step; recovery continues from
  the last completed entry. A turn interrupted mid-provider-call is retried
  from the last durable entry (the fake provider must tolerate a repeated
  call for the same turn — script position is part of durable state).
- **Tool shim**: `fs.read` only, jailed to `.work/workspace/` (path
  containment, no `..` escape), bounded output.

# context

- [analysis](../analysis/2026-08-13-autolith-live-runtime-analysis.md) —
  design rules, round-3 findings (escaping discipline, typed journal).
- spike-001/002 task files + reviews for the machinery being reused.

# path

| Path | Role |
|------|------|
| `spikes/live-runtime/**` | all code + spike-local docs |
| `docs/plan/analysis/2026-08-13-autolith-live-runtime-analysis.md` | findings appended at closeout |
| Forbidden | `packages/`, root `build.zig` / `build.zig.zon`, `.github/`, `docs/maturity.md`, `chapters/` |

# verification (probe checklist)

New `live-probe agent` scripted scenario + interactive-mode agent turns
(bare text = user message; `(...)` = eval). All deterministic via the fake
provider.

All items verified by develop + independent review
([live-runtime-spike-003-01](../reviews/live-runtime-spike-003-01.md)),
including a 12-run external chaos harness and 12 jail-escape attempts.

- [x] Plain turn: user entry appended+fsynced **before** provider call;
      assistant reply appended; transcript shows echoed system prompt
- [x] Tool round: scripted `fs.read` call → Zig executes jailed read →
      result appended → provider continues → final answer; `..` escape
      attempt rejected (12/12 attempts incl. symlink tricks)
- [x] **Policy redefine mid-conversation**: turn 2 uses the redefined
      `system-prompt` (proven by provider echo in transcript, V1→V2 @ entry 11)
- [x] SIGKILL between turns → respawn → history rebuilt from store AND
      pending policy redefine still active → conversation continues
- [x] SIGKILL mid-turn → recovery retries from last durable entry; no
      half-written store entries; no duplicate user entries (12 chaos runs)
- [x] Interactive mode: bare text drives an agent turn; `(kernel.redefine
      'system-prompt ...)` changes subsequent turns live
- [x] Full 9-probe regression suite (spike-001/002) still passes
- [x] Findings appended to the analysis doc (§ Spike findings, round 4)

# non-goals

- Real model/provider, streaming, tokens, credentials handling
- Multiple tools beyond `fs.read`; parallel tool calls
- Input vault / steering during dead image
- Multi-worker; TUI; anything under `packages/` or maturity claims
