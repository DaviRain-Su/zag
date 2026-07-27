---
id: prompt-templates-001
scope: coding-agent/prompt-templates (E1 passive)
status: in-progress
priority: P1
depends-on:
  - skills-001
  - linux-dual-backend-gate-001
---

# objective

Deliver the **minimal passive E1 Prompt Templates** capability as
**product-owned** functionality in `packages/zag-coding-agent` with only **thin
explicit CLI routing** in `packages/zag-cli`:

1. **Docs-first (this track):** freeze the binding contract and obtain independent
   contract PASS **before** any production implementation.
2. **Implementation (later track):** deterministic bounded non-recursive Markdown
   template discovery and one-pass expansion **without** moving behavior into
   `zag-agent-core`.

Preserve ask + workspace jail + shell protect, all closed schemas, existing raw
unknown-slash behavior, and maturity truth. Do **not** co-deliver scripts, hooks,
MCP, WASM, network/provider registration, dynamic ABI, edit sharpness, or TUI
work. Do **not** modify `.gitignore`, merge, push, or change shared state in this
docs commit series.

**Owner:** `zag-coding-agent` only. Do **not** change Core, session schema v1,
Trace v1, `headless-v1`, `project.zig`, or `--no-project` semantics.

Binding specification: [Prompt Templates (E1 passive)](../../modules/prompt-templates.md).

Runtime Extensions maturity remains **L0**.

# context

- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-010-extension-tiers-and-process-protocol.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/prompt-templates.md` (**binding truth**)
- `docs/modules/skills.md` (precedence peer; reserved name `skill`)
- `docs/modules/extensions.md`
- `docs/modules/session-store.md`
- `docs/modules/session-fork.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/cli-interaction.md`
- `docs/modules/headless-contract.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/tools-shell.md`
- `docs/phases/C8-extensions.md`
- `docs/plan/analysis/2026-07-26-pi-feature-correspondence.md`
- `docs/roadmap.md` · `docs/maturity.md`
- Live sources (read for seams; do **not** invent Core template APIs):
  - `packages/zag-coding-agent/src/agent.zig` (`Session.start`, `fork`, layers)
  - `packages/zag-coding-agent/src/skills.zig` (catalog/lifetime/routing patterns)
  - `packages/zag-coding-agent/src/project.zig` (unchanged AGENTS.md only)
  - `packages/zag-cli/src/cli.zig` (flags, one-shot/REPL/headless skill routing)
  - `tests/sdk-consumer-fixture/` (public surface smoke when implementing)

# path

## Docs (contract track — this commit)

- `docs/modules/prompt-templates.md` — binding contract
- `docs/plan/tasks/prompt-templates-001.md` — this task
- status links only: `docs/plan/README.md`, `docs/modules/README.md`,
  `docs/modules/extensions.md`, `docs/phases/C8-extensions.md`,
  `docs/roadmap.md`, `docs/maturity.md` (L0 truth, no raise), `docs/INDEX.md`,
  and minimal plan-status wording where `prompt-templates-001` was “unblocked /
  not authored”

## Implementation (later; not this docs commit)

- `packages/zag-coding-agent/src/prompt_templates.zig` (or split under coding-agent)
- `packages/zag-coding-agent/src/agent.zig` — start/fork/deinit catalog
- `packages/zag-coding-agent/src/root.zig` — public parse/expand export
- coding-agent tests covering module §11 fixtures **1–17**
- `packages/zag-cli/src/cli.zig` — enable/trust flags, HOME → user root, thin
  routing with `/skill:` precedence then known `/name`
- `tests/sdk-consumer-fixture/` — public options + parse/expand smoke (no
  implicit reply parse)
- **no** Core template module; **no** schema/Trace/headless field additions

# contract

The module doc is authoritative. Summary of binding product laws:

1. **Ownership:** coding-agent only. Core receives no template ports or parsing.
   Session v1, Trace v1, headless-v1, `project.zig`, `--no-project` unchanged.
2. **Roots:** discover **direct files only**, non-recursively, byte-sorted, from
   user `$HOME/.agents/prompts/*.md` and trusted project
   `<workspace>/.agents/prompts/*.md`. CLI resolves HOME; SDK takes explicit
   host-owned user-root (never implicit env).
3. **Enable / trust:** template enablement and project-template trust are
   independent; independent of Skills knobs; `--no-project` remains independent.
   Default: templates **on**, project **untrusted**.
4. **Format:** plain valid UTF-8 Markdown; lower-kebab **filename stem** is the
   command name; reject invalid or reserved ambiguous names such as `skill`; no
   executable frontmatter, metadata runtime, loader execution, or model summary.
5. **Collision:** after valid parsing, **project overrides user** for the exact
   same name. Explicitly reconciles/replaces earlier first-wins sketches in
   extension notes.
6. **Substitution:** only exact `$ARGUMENTS`; `$$` emits one literal `$`; one
   deterministic left-to-right pass; inserted arguments never rescanned; empty
   arguments allowed; when non-empty args have no unescaped `$ARGUMENTS`, append
   `\n\n` then args. No positional vars, shell expansion, quoting language, code,
   or expressions.
7. **Budgets:** name ≤64 bytes; file ≤24 KiB; ≤64 entries/root; aggregate accepted
   source ≤256 KiB; args ≤8 KiB; final expansion ≤32 KiB.
8. **OOM / invalids:** OOM is hard failure before durable Session creation;
   invalid candidates soft-skip with bounded path/body-free diagnostics.
9. **Lifecycle:** Session owns in-memory catalog; discovery completes before
   durable create; resume re-discovers; fork deep-copies catalog; expansion never
   re-reads filesystem; catalogs not persisted; expanded text is ordinary user
   message only.
10. **Routing precedence:** exact `/skill:` routes first; known `/name`
    optionally followed by whitespace + rest expands once; unknown slash preserves
    current raw-user-text behavior; `Agent.reply` never implicitly parses.
11. **CLI routes:** one-shot, REPL, and headless must explicitly use the public
    coding-agent parse/expand API.
12. **No catalog Tool / no hidden provider:** no catalog/read Tool; no provider
    call on local expansion failure; no hidden provider call for expansion.
13. **Safety:** induced later Tool calls still pass ask + workspace jail + shell
    protect + redaction.
14. **Non-goals:** scripts/hooks/MCP/WASM/network registration/dynamic ABI/edit
    sharpness/TUI; Core ports; schema raises; maturity raise.
15. **Verification:** module §11 fixtures **1–17** + SDK smoke + Gates on
    implementation; docs track requires docs-lint + diff --check + independent
    contract PASS before code.

# verification

## Docs Gate (contract track)

- [x] Binding module + task authored before implementation
- [ ] Independent review of contract **PASS** (required before production code)
- [x] `zig build docs-lint`
- [x] `git diff --check`
- [x] Explicit `git add` of intended docs files only
- [ ] One local docs commit on `task/prompt-templates-001`

## Implementation Gate (blocked until contract PASS)

Must pass every fixture in
[prompt-templates.md §11](../../modules/prompt-templates.md#11-verification--exact-fixture-matrix)
items **1–17**, plus:

- [ ] Focused coding-agent tests green
- [ ] External SDK public-surface smoke
- [ ] Root std + curl candidate Gates as required by plan closeout
- [ ] No Core / schema v1 / Trace v1 / headless-v1 / `project.zig` behavior change
- [ ] Runtime Extensions maturity remains **L0**
- [ ] Independent code review + ff-only merge + merged-main Gate before `done`

# non-goals (task boundary)

See module §10. Additionally out of scope for the docs PR: production code,
maturity raise, quality score body hand-edits, `.gitignore` changes, merge/push,
and any co-delivery of edit/TUI/scripts/hooks/MCP/WASM.

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | `docs/modules/prompt-templates.md` |
| Task | this file `in-progress` (docs contract freeze) |
| Implementation | **not started** (blocked on independent contract PASS) |
| Maturity | Runtime Extensions **L0** (no raise) |

# closeout criteria

- Docs contract frozen; independent contract review PASS; docs-lint clean.
- Implementation later lands fixtures 1–17 without Core/schema/maturity changes.
- Status → `done` only after implementation merged-main Gate; not after docs alone.
