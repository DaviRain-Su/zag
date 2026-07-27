---
id: skills-001
scope: coding-agent/skills (E1 passive)
status: done
priority: P1
depends-on:
  - session-fork-001
---

# objective

Deliver the first **Zig-native E1 passive Agent Skills** slice:

- bounded, deterministic `SKILL.md` discovery;
- explicit project trust;
- model-visible summaries with on-demand body loading;
- manual activation;
- ordinary downstream safety Gates (ask + workspace jail + shell protect + redaction).

`skills-001` closed at `caafef5` after implementation, review-fix fixtures, dual-backend
merged-main Gates, and docs-truth closeout. Runtime Extensions remains **L0** (no maturity raise).

**Owner:** `zag-coding-agent` only. Do **not** change Core, session schema v1,
Trace v1, `headless-v1`, `project.zig`, or `--no-project` semantics.

Binding specification: [Agent Skills (E1 passive)](../../modules/skills.md).

Binding contract remains [skills.md](../../modules/skills.md). Runtime Extensions
maturity remains **L0**.

# context

- `docs/decisions/active/D-009-pi-semantics-not-parity-fork.md`
- `docs/decisions/active/D-010-extension-tiers-and-process-protocol.md`
- `docs/decisions/active/D-011-thin-agent-core-boundary.md`
- `docs/modules/skills.md` (**binding truth**)
- `docs/modules/extensions.md`
- `docs/modules/session-store.md`
- `docs/modules/session-fork.md`
- `docs/modules/context-compaction.md`
- `docs/modules/tool-runtime.md`
- `docs/modules/permissions.md`
- `docs/modules/workspace-sandbox.md`
- `docs/modules/tools-shell.md`
- `docs/modules/sdk-contract.md`
- `docs/modules/cli-interaction.md`
- `docs/modules/headless-contract.md`
- `docs/phases/C8-extensions.md`
- `docs/plan/analysis/2026-07-26-pi-feature-correspondence.md`
- `docs/roadmap.md` · `docs/maturity.md`
- Live sources (read for seams; do not invent Core Skill APIs):
  - `packages/zag-coding-agent/src/agent.zig` (`Session.start`, `fork`, `layers`, `Agent.reply`, toolset)
  - `packages/zag-coding-agent/src/project.zig` (unchanged AGENTS.md only)
  - `packages/zag-coding-agent/src/toolset.zig` / `context.zig`
  - `packages/zag-agent-core/src/tool.zig` (`validateTools`, `buildTool`)
  - `packages/zag-cli/src/cli.zig` (flags, one-shot/REPL/headless)
  - `tests/sdk-consumer-fixture/` (public surface smoke when implementing)

# path

## Docs (contract track)

- `docs/modules/skills.md` — binding contract
- `docs/plan/tasks/skills-001.md` — this task
- status links only: `docs/plan/README.md`, `docs/modules/README.md`,
  `docs/modules/extensions.md`, `docs/phases/C8-extensions.md`,
  `docs/roadmap.md`, `docs/maturity.md`, `docs/INDEX.md` if discoverability needs it,
  `docs/plan/backlog.md` note resolution as appropriate

## Implementation (landed at `caafef5`)

- `packages/zag-coding-agent/src/skills.zig` (or split modules) — discovery, parse, catalog
- `packages/zag-coding-agent/src/agent.zig` — start/fork/deinit catalog; reply tool append; layers
- `packages/zag-coding-agent/src/root.zig` — public activation export
- coding-agent skill tests covering module §11 fixtures **1–14**
- `packages/zag-cli/src/cli.zig` — `--no-skills`, `--trust-project-skills`, HOME → user root, `/skill:` routing
- `tests/sdk-consumer-fixture/` — public options + activation smoke (no implicit reply parse)
- **no** Core Skill module; **no** schema/Trace/headless field additions

# contract

The module doc is authoritative. Summary of binding rules:

1. **Ownership:** coding-agent only. Core, session v1, Trace v1, headless-v1,
   `project.zig`, `--no-project` unchanged.
2. **Roots:** user `$HOME/.agents/skills/<name>/SKILL.md` when skills enabled;
   project `<workspace>/.agents/skills/<name>/SKILL.md` only with
   `--trust-project-skills` / SDK trusted enum. Default: skills **on**, project
   **untrusted**. `--no-skills` disables both. CLI resolves HOME; SDK takes
   explicit host-owned user-root (never implicit env).
3. **Containment:** each root/candidate realpath-contained under its authority;
   project also inside workspace. Symlink escape soft-skips; no outside catalog
   bytes. User-root bytes only via host loader; File Tools stay workspace-jailed.
4. **Walk:** direct children only; byte-sorted names; max 64 entries/root; no
   recursion. Project overrides user by exact name.
5. **Frontmatter subset:** required `name` + non-empty `description`; optional
   exact boolean `disable-model-invocation`; ignore unknown well-formed keys;
   soft-skip duplicates/malformed/invalid UTF-8/name≠dir/empty body/unsupported
   structure with **path-free** diagnostics.
6. **Budgets:** name ≤64 lower-kebab; description ≤1024; file ≤24 KiB; summary
   aggregate ≤4096; body aggregate ≤256 KiB; OOM hard-fail.
7. **Lifecycle:** discover in `Session.start` before durable create; store full
   bodies in Session catalog; no invocation-time FS; catalog never persisted;
   resume re-discovers; fork deep-copies catalog/summary with parent immutability;
   create OOM commits no file and holds no lease.
8. **Model surface:** invocable name+description only in view-only Skills system
   layer (not a transcript row; not compaction metadata; not skill schema
   fields). Catalog stays process memory only. Bodies reach transcript/session/
   Trace/headless **only** via ordinary user-message (manual activation) or
   ordinary `tool_result` (`read_skill` success) — never dedicated skill fields
   or soft-skip diagnostics. Disabled/no-skill → no Skills block, no `read_skill`.
9. **`read_skill`:** risk read, workspace none, shell none, cancel none; catalog
   only; no paths; manual-only denied; success body is ordinary `tool_result`
   content on existing save/Trace/headless paths. Per reply dynamically append to
   default or custom toolset (no fixed `[8]`); Session address stable; duplicate
   reserved name → `validateTools` fail-closed before provider.
10. **Activation:** public parse/expand API; CLI one-shot/REPL/headless route exact
    `/skill:<name> [rest]`; manual-only allowed; expands once to ordinary user
    message (body + rest) on existing transcript/session/trace paths; unknown
    name stable local error, no provider; unrelated slash text raw; `Agent.reply`
    never implicit-parses.
11. **Safety:** loader no-execute; induced write/shell/path still ask+jail+protect+redact.
12. **Non-goals:** full YAML, Pi/npm marketplace parity, Prompt Templates, E2/E3/WASM,
    remote install, auto-trust project, Core Skill types, new schemas, recursive
    expansion, TUI/autocomplete, OS sandbox/DLP, maturity raise.
13. **Verification:** module §11 fixtures **1–14** + SDK public-surface smoke +
    focused tests and root std/curl Gates on implementation.

# verification

## Docs Gate (contract track — complete)

- [x] Binding module + task authored before implementation
- [x] Independent review of contract (status truth reconciled at closeout)
- [x] `zig build docs-lint`
- [x] `git diff --check`
- [x] Explicit `git add` of intended docs files only
- [x] One local docs commit on `task/skills-001` (body-path contract fix)

## Implementation Gate (**complete**)

Must pass every fixture in
[skills.md §11](../../modules/skills.md#11-verification--exact-fixture-matrix-14)
items **1–14**, plus:

- [x] Focused coding-agent tests green (`skills_tests.zig` §11.1–14)
- [x] External SDK public-surface smoke (`tests/sdk-consumer-fixture`)
- [x] Root std + curl candidate Gates as required by plan closeout
- [x] No Core / schema v1 / Trace v1 / headless-v1 / `project.zig` behavior change
- [x] Runtime Extensions maturity remains **L0**
- [x] Independent code review + ff-only merge + merged-main Gate before `done`

# delivery evidence

| Item | Evidence |
|------|----------|
| Contract | `docs/modules/skills.md` |
| Task | this file `done` at `caafef5` (+ docs closeout) |
| Implementation | `packages/zag-coding-agent/src/skills.zig` + `agent.zig` / `root.zig` / `cli.zig` |
| Fixtures 1–14 | `packages/zag-coding-agent/src/skills_tests.zig` |
| SDK smoke | `tests/sdk-consumer-fixture/src/root.zig` skills-001 test; fixture **22/22** |
| Review | contract/status truth closeout; implementation + review-fix fixtures at tip `caafef5` |
| Merge | local main already at `caafef5` (same tip as `task/skills-001`) |
| Merged-main Gate | std **40/40 steps, 609/609 tests**; curl **42/42 steps, 608/608 tests**; Core **89/89**; Coding **337/337**; CLI **30/30**; SDK **22/22**; OpenAPI **287/287**; catalog **40**; readability **91/100**; security **72/100** |
| Maturity | Runtime Extensions **L0** (E1 Skills slice implemented; maturity not raised) |

# non-goals (task boundary)

See module §10. Additionally out of scope for this task's implementation PR series:
raising maturity, Prompt Templates, shared generic “resource loader” package
extraction beyond what Skills needs, and CLI TUI autocomplete.

# closeout

- Docs contract landed at `875562a` / body-path reconcile `1d93084`; implementation
  `c74e80c` through review-fix/fixture commits `fa7786d`–`caafef5`.
- Local main and `task/skills-001` share tip `caafef5` (ff-equivalent land on main).
- Merged-main dual-backend Gate: std **40/40 · 609/609**, curl **42/42 · 608/608**,
  Core **89/89**, Coding **337/337**, CLI **30/30**, SDK **22/22**, OpenAPI **287/287**,
  catalog **40**, readability **91/100**, security **72/100**.
- Core, session schema v1, Trace v1, `headless-v1`, `project.zig`, default ask +
  jail + shell protect, and every existing L2 row remain unchanged. Runtime Extensions
  stays **L0**. Prompt Templates, E2/E3, remote install, and maturity raise remain excluded.
