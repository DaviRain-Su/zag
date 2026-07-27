---
id: prompt-templates-001
scope: coding-agent/prompt-templates (E1 passive)
status: done
priority: P1
depends-on:
  - skills-001
  - linux-dual-backend-gate-001
---

# objective

Deliver the **minimal passive E1 Prompt Templates** capability as
**product-owned** functionality in `packages/zag-coding-agent` with only **thin
explicit CLI routing** in `packages/zag-cli`:

1. **Docs-first:** freeze the binding contract and obtain independent contract
   PASS **before** production implementation.
2. **Implementation:** deterministic bounded non-recursive Markdown template
   discovery and one-pass expansion **without** moving behavior into
   `zag-agent-core`.

`prompt-templates-001` closed at tip `61326ae7ae8f7bbef3de99377a8c9975d239d6df`
after contract freeze, implementation, review fix, independent correctness /
boundary review (zero remaining blockers), dual-backend candidate + merged-main
local macOS Gates, and this docs-truth closeout. Runtime Extensions remains
**L0** (no maturity raise; no E1 maturity row).

**Owner:** `zag-coding-agent` only. Do **not** change Core, session schema v1,
Trace v1, `headless-v1`, `project.zig`, or `--no-project` semantics.

Binding specification: [Prompt Templates (E1 passive)](../../modules/prompt-templates.md).

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
  - `tests/sdk-consumer-fixture/` (public surface smoke)

# path

## Docs (contract track — complete)

- `docs/modules/prompt-templates.md` — binding contract
- `docs/plan/tasks/prompt-templates-001.md` — this task
- status links: `docs/plan/README.md`, `docs/modules/README.md`,
  `docs/modules/extensions.md`, `docs/phases/C8-extensions.md`,
  `docs/roadmap.md`, `docs/maturity.md` (L0 truth, no raise), and related
  current-status wording

## Implementation (complete)

- `packages/zag-coding-agent/src/prompt_templates.zig`
- `packages/zag-coding-agent/src/prompt_templates_tests.zig` — §11 fixtures
- `packages/zag-coding-agent/src/agent.zig` — start/fork/deinit catalog
- `packages/zag-coding-agent/src/root.zig` — public parse/expand export
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

## Docs Gate (contract track — complete)

- [x] Binding module + task authored before implementation
- [x] Independent review of contract **PASS** before production code
      (contract tip `e00255b16d98200bff167412bc6237b2fb252cfb`)
- [x] `zig build docs-lint` / `python3 scripts/lint_docs.py`
- [x] `git diff --check`
- [x] Explicit `git add` of intended docs files only
- [x] Contract docs commit on `task/prompt-templates-001` (`e00255b`); this
      file’s closeout commit is docs-only after merged-main Gate

## Implementation Gate (**complete**)

Must pass every fixture in
[prompt-templates.md §11](../../modules/prompt-templates.md#11-verification--exact-fixture-matrix)
items **1–17**, plus:

- [x] Focused coding-agent tests green (`prompt_templates_tests.zig` §11 rows
      1–17; rows 7–8 combined in one test; plus unit tests in
      `prompt_templates.zig`)
- [x] External SDK public-surface smoke (`tests/sdk-consumer-fixture`
      `prompt-templates-001` test; current fixture **23/23**)
- [x] Root std + curl candidate Gates (at tip `61326ae`: std **40/40 steps,
      633/633 tests**; curl **42/42 steps, 632/632 tests**; docs lint/score;
      `git diff --check`; clean worktree)
- [x] No Core / schema v1 / Trace v1 / headless-v1 / `project.zig` behavior change
- [x] Runtime Extensions maturity remains **L0**
- [x] Independent correctness/boundary review **PASS** (zero remaining blockers)
      on implementation `5487c4be3e17b2fa49fe718ac2c9b97f7c9e574f` + review
      fix/candidate `61326ae7ae8f7bbef3de99377a8c9975d239d6df`
- [x] ff-only local main advance + merged-main local macOS Gate before `done`

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | `docs/modules/prompt-templates.md` @ `e00255b16d98200bff167412bc6237b2fb252cfb`; independent contract review **PASS** before product code |
| Task | this file `done` at tip `61326ae` (+ docs closeout) |
| Implementation | `5487c4be3e17b2fa49fe718ac2c9b97f7c9e574f` — `packages/zag-coding-agent/src/prompt_templates.zig` + Session/CLI/SDK wiring + §11 fixtures |
| Review fix / candidate | `61326ae7ae8f7bbef3de99377a8c9975d239d6df` — exact 24 KiB files under limited read |
| Fixtures 1–17 | `packages/zag-coding-agent/src/prompt_templates_tests.zig` (16 focused tests covering matrix rows 1–17; §11.7–8 combined) + unit tests in `prompt_templates.zig` |
| SDK smoke | `tests/sdk-consumer-fixture/src/root.zig` `prompt-templates-001` public options + expand + no implicit reply parse; current fixture **23/23** |
| Review | independent correctness/boundary review **PASS**, zero remaining blockers, at candidate `61326ae` |
| Merge | coordinator ff-only advanced local main `4fcfb31e992e268b3481e8fd9a752fd5a80741f3` → `61326ae7ae8f7bbef3de99377a8c9975d239d6df` while preserving an unrelated existing canonical `.gitignore` edit; **no push** |
| Candidate Gate @ `61326ae` | std **40/40 steps, 633/633 tests**; curl **42/42 steps, 632/632 tests**; docs lint/score; `git diff --check`; clean state |
| Merged-main Gate @ `61326ae` | local macOS dual-backend: std **40/40 steps, 633/633 tests**; curl **42/42 steps, 632/632 tests**; OpenAPI **287/287**; catalog **40**; docs lint; readability **91/100** across **54** files; security **73/100** across **54** files; `git diff --check` pass. Generated quality reports changed timestamps only and were restored. |
| Remote / Linux | **Not claimed** for this Prompt Templates tip — no push and no fresh remote/Linux evidence |
| Maturity | Runtime Extensions **L0** (E1 Prompt Templates slice implemented; maturity not raised; no E2/E3/scripts/hooks/MCP/WASM/TUI/edit claim) |

# non-goals (task boundary)

See module §10. Out of scope for this task’s implementation series: raising
Runtime Extensions maturity, E2/E3, scripts/hooks/MCP/WASM, edit sharpness, TUI,
shared generic “resource loader” package extraction beyond what this slice needs,
quality score body hand-edits, `.gitignore` product changes, and merge/push of
shared remotes from this closeout.

# closeout

- Contract frozen at `e00255b16d98200bff167412bc6237b2fb252cfb` with independent
  contract review **PASS** before production code.
- Implementation landed at `5487c4be3e17b2fa49fe718ac2c9b97f7c9e574f`; review fix
  and candidate tip `61326ae7ae8f7bbef3de99377a8c9975d239d6df` passed independent
  correctness/boundary review with **zero remaining blockers**.
- Candidate Gate at `61326ae`: std **40/40 · 633/633**, curl **42/42 · 632/632**,
  docs lint/score, diff check, clean state.
- Coordinator ff-only advanced local main `4fcfb31` → `61326ae` while preserving
  an unrelated existing canonical `.gitignore` edit (**no push**).
- Merged-main local macOS Gate at exact `61326ae`: std **40/40 · 633/633**, curl
  **42/42 · 632/632**, OpenAPI **287/287**, catalog **40**, docs lint, readability
  **91/100** (54 files), security **73/100** (54 files), diff check pass.
  Timestamp-only quality-report churn restored. **No** fresh remote/Linux Gate
  claimed for this tip.
- Product shape: minimal passive E1 slice owned by `zag-coding-agent` with thin
  CLI routing. Core, session schema v1, Trace v1, `headless-v1`, `project.zig`,
  `--no-project`, default ask + workspace jail + shell protect, and every existing
  L2 row remain unchanged. Runtime Extensions stays **L0**. This task does **not**
  claim an E1 maturity raise or E2/E3/scripts/hooks/MCP/WASM/TUI/edit capability.
- Docs-only closeout date **2026-07-28** reconciles current-status wording after
  the merged-main Gate; it does not change product behavior.
