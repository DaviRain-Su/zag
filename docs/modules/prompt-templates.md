---
status: active
scope: coding-agent E1 passive Prompt Templates (M2 / C8)
task: prompt-templates-001
---

# Prompt Templates (E1 passive)

This module is the **binding contract** for `prompt-templates-001`: Zig-native,
passive Prompt Templates discovery and one-pass slash expansion. It freezes
product ownership, roots/trust, format, collision, substitution, budgets,
lifecycle, routing precedence, errors, safety, compatibility, non-goals, and
executable fixtures.

**Implementation status:** E1 passive slice landed in `zag-coding-agent` /
`zag-cli` (`prompt-templates-001` **done** at
`61326ae7ae8f7bbef3de99377a8c9975d239d6df`). Production code owns discovery,
Session catalog/lifetime, public parse/one-pass expand, and thin CLI routing
(`prompt_templates.zig`, `--no-prompt-templates` / `--trust-project-templates`).
Runtime Extensions maturity remains **L0**; this slice does **not** raise
maturity and does not move behavior into `zag-agent-core`.

Prerequisite contracts (unchanged by this slice):

- [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md) Pi semantics
  without parity/schema fork
- [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) E0–E3
  tiers; E1 is passive resources only
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) thin Core;
  product state stays in coding-agent
- [extensions](./extensions.md) feature × carrier map
- [skills](./skills.md) E1 Skills (`/skill:` routing precedence; reserved name)
- [session-store](./session-store.md) schema **v1** create/resume (unchanged)
- [session-fork](./session-fork.md) live catalog deep-copy rules (this slice adds
  template-catalog ownership to fork; no schema change)
- [sdk-contract](./sdk-contract.md) · [cli-interaction](./cli-interaction.md) ·
  [headless-contract](./headless-contract.md)
- [permissions](./permissions.md) · [workspace-sandbox](./workspace-sandbox.md) ·
  [tools-shell](./tools-shell.md) ordinary Tool gates for induced calls

## 1. Boundary

```text
host (CLI / SDK)
  │
  │  resolve roots + trust + enable flags
  │  (CLI: HOME + flags; SDK: host-owned user-root option)
  ▼
zag-coding-agent only
  · discover *.md at Session.start (before durable create)
  · Session-owned in-memory template catalog
  · public parse / one-pass expand API
  · NO model summary layer; NO catalog/read Tool
          │
          ▼
zag-agent-core
  · Message / Transcript / Tool / Loop only
  · NO template types, NO template ports, NO discovery, NO parsing

zag-cli (thin)
  · resolve HOME, parse enable/trust flags
  · one-shot / REPL / headless: explicit route through public API
  · precedence: /skill: first, then known /name expand, else raw

unchanged:
  session schema v1 · Trace v1 · headless-v1 · project.zig · --no-project
  ask + workspace jail + shell protect · existing raw unknown-slash behavior
```

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent` | discovery, catalog, parse/expand API, Session lifetimes | Core template APIs; durable template persistence; model summary; catalog Tool |
| `zag-cli` | resolve `$HOME`, parse enable/trust flags, explicit one-shot/REPL/headless routing | discovery I/O beyond forwarding options; implicit `Agent.reply` parsing |
| `zag-agent-core` | generic Message / Loop / Tool validation only | template roots, parsing, substitution, catalog |
| `project.zig` | AGENTS.md candidates only | prompt roots or trust |
| Model File Tools | workspace-jailed path I/O | user-root bytes outside workspace |

**Owner package is coding-agent only.** `zag-agent-core` receives **no** template
ports, types, or parsing. Session schema v1, Trace v1, `headless-v1`,
`project.zig`, and `--no-project` semantics stay **byte/behavior unchanged**.

## 2. Defaults and host options

| Knob | Default | Meaning |
|------|---------|---------|
| Prompt Templates enabled | **on** | Discover user root (when resolved) + optional project root |
| Project template trust | **off** | Project root is **not** scanned unless host opts in |
| `--no-prompt-templates` (CLI) / SDK disable | off | Disables **both** user and project roots; empty catalog; no expansion |
| `--trust-project-templates` (CLI) / SDK `trusted` enum | off | Project root may be discovered when templates enabled |
| `--no-project` | unchanged | Still only skips AGENTS.md / project instructions; **does not** imply template trust or template disable |
| Skills enable/trust | independent | Skills knobs do not control templates; templates knobs do not control skills |

Template enablement and project-template trust are **independent** of each other
and of Skills enable/trust and of `--no-project`.

### 2.1 Roots (Prompt Templates v1)

When templates are enabled:

| Root | Path shape | Authority |
|------|------------|-----------|
| User | `$HOME/.agents/prompts/*.md` | CLI resolves `HOME`. SDK accepts an **explicit host-owned user-root option** and **must not** implicitly read process env. |
| Project | `<workspace>/.agents/prompts/*.md` | Only with CLI `--trust-project-templates` or SDK trusted enum. |

- Discovery lists **direct files only** under each root (non-recursive).
- User-root bytes may live **outside** the workspace **only** through this fixed
  host loader authority.
- Model File Tools remain **workspace-jailed** and never gain user-root access.
- Missing roots are soft-skipped (no hard fail).

### 2.2 SDK options (binding shape)

Exact Zig field names may match package style; behavior is binding:

```zig
// coding-agent SessionStartOptions (or adjacent templates options) — conceptual
pub const ProjectTemplatesTrust = enum { untrusted, trusted };

// When templates_enabled == false: no discovery, no catalog, no expansion.
// When project_templates_trust == .untrusted: project root not scanned.
// user_templates_root: optional host-provided path; SDK never getenv("HOME").
// CLI maps: HOME → user_templates_root; --no-prompt-templates → enabled=false;
//           --trust-project-templates → project_templates_trust=.trusted.
```

`load_project_instructions` / `--no-project` remain independent of template trust.

## 3. Discovery algorithm (deterministic)

Discovery runs during **`Session.start`**, **before any durable create** (and
before writer lease acquisition on create paths), after control-queue
preallocation and redactor ownership match existing start discipline. When both
Skills and Templates are enabled, order relative to each other is product-local
as long as **both complete before durable create** and OOM on either is a hard
fail with no durable commit.

### 3.1 Walk rules

1. Resolve at most two roots (user, project) per §2.
2. For each resolved root that exists as a directory after containment checks:
   - list **direct child files only** (no recursive walk; no subdirectories
     opened for discovery);
   - consider only names ending in exact suffix `.md` (case-sensitive on
     case-sensitive FS); non-`.md` entries are ignored (not soft-diagnostics
     noise);
   - sort candidate file basenames by **byte-sort** (unsigned byte order);
   - cap at **64 direct entries per root** among all direct children counted
     toward the entry budget (extra entries soft-skip with deterministic
     diagnostics; discovery still succeeds).
3. Each resolved root and each candidate path must **realpath-contain** under
   its own authority root. Project root must **also** remain inside the
   workspace realpath. Symlink escapes → soft-skip that candidate/root (no
   outside bytes enter catalog).
4. Parse each candidate per §3.2. Invalid candidates soft-skip.
5. **Collision after valid parsing:** a **project** template **overrides** a
   **user** template with the **exact same command name**. This **replaces** any
   earlier first-wins sketch in extension notes. Deterministic: same name →
   project entry wins; user entry is dropped with a typed conflict diagnostic
   (path-free). Within a single root, a later byte-sorted valid duplicate name
   (should not occur for unique basenames) soft-skips with conflict diagnostic;
   first accepted name in discovery order wins **within that root only**.

### 3.2 Format and name (plain Markdown)

| Rule | Contract |
|------|----------|
| Format | Plain **valid UTF-8** Markdown body. **No** required frontmatter. |
| Command name | Lower-kebab **filename stem** (basename without trailing `.md`). |
| Name charset | `[a-z0-9]+(-[a-z0-9]+)*` only; length ≤ **64** bytes. |
| Reserved / ambiguous | Reject (soft-skip) name `skill` (collides with `/skill:` routing). No other reserved names in this slice unless fixtures freeze more. |
| Executable metadata | **Forbidden:** executable frontmatter, metadata runtime, loader execution, model-visible summary surface. |
| Body | Non-empty after UTF-8 validation; entire file is the template source. |
| Reject (soft) | invalid UTF-8; empty body; oversize file; invalid/reserved name; non-file after resolve; containment failure; I/O failure |

Soft diagnostics are **path-free** and **body-free** typed reason codes only.

### 3.3 Bind constants (hard budgets)

| Constant | Bound |
|----------|------:|
| command `name` (stem) | ≤ **64** bytes; lower-kebab |
| one template file | ≤ **24 KiB** |
| max direct entries per root | **64** |
| aggregate accepted source (all catalog bodies) | ≤ **256 KiB** |
| expansion `arguments` input | ≤ **8 KiB** |
| final expanded user text | ≤ **32 KiB** |

Aggregate overflow: exclude later candidates in discovery order with soft
diagnostics until within budget (deterministic; never hard-fail for soft
validation). **OOM is hard fail.** Args over 8 KiB at expansion time → typed
local expansion error (no provider). Final expansion over 32 KiB → typed local
expansion error (no provider); do not truncate silently into the provider path.

### 3.4 Soft-skip vs hard fail

| Condition | Effect |
|-----------|--------|
| Missing root, invalid candidate, I/O failure, containment failure | Soft-skip; typed diagnostic; no absolute path; no body |
| Invalid/reserved name, empty body, oversize file, invalid UTF-8 | Soft-skip; typed diagnostic |
| Aggregate source budget exceeded for next candidate | Soft-skip that candidate (and continue) |
| **Out of memory** during discovery/catalog allocation | **Hard fail** `error.OutOfMemory`; no durable create; no held lease |
| Expansion-time args/final size/OOM | Local typed error; **no provider call**; no durable schema mutation beyond ordinary failure paths already defined for start vs reply |

Diagnostics are process-local (doctor/log/test hooks as product chooses) and
must not leak absolute paths or template bodies into Trace, session JSONL,
headless envelopes, or compaction metadata. Intentional body exposure after
successful expansion uses the ordinary **user message** content path only (§5).

## 4. Session-owned catalog and lifetimes

### 4.1 Transaction order

```text
Session.start:
  1. arena + DualQueues prealloc (existing)
  2. redactor ownership (existing)
  3. skills discovery (if enabled; existing skills-001)
  4. *** prompt-templates discovery + catalog (this slice) ***
  5. durable create / resume / ephemeral seed (existing)
  6. finish Session
```

Create-time OOM (including templates OOM) commits **no** child/session file and
holds **no** lease — same transaction honesty as control-queue prealloc and
Skills discovery.

### 4.2 Storage and lifecycle

- Session owns a **bounded in-memory catalog** of accepted templates (name, body
  bytes, origin `user|project`).
- Catalog structure is **never persisted** (not session schema v1 keys, not Trace
  fields, not compaction meta, not headless events).
- **Resume re-discovers** from live roots with current trust/enable options;
  prior process catalog is discarded.
- **`Session.fork`** deep-copies the live catalog into the child arena/gpa
  ownership with **parent immutability** (same discipline as Skills catalog /
  transcript/layers); child does not re-scan filesystem at fork time.
- **Expansion never re-reads the filesystem** (eliminates TOCTOU for catalog
  bodies).
- Expanded text is an **ordinary user message only** — no system/project layer
  injection, no new message kinds, no template-specific Trace/headless fields.

### 4.3 No model summary / no catalog Tool

- Templates do **not** contribute a model-visible summary system layer.
- There is **no** `read_template` / catalog Tool in this slice.
- Bodies reach transcript / session / Trace / headless **only** via ordinary
  user-message text after successful host-routed expansion.

## 5. Substitution language (one-pass, non-recursive)

Support **only**:

| Token | Meaning |
|-------|---------|
| exact `$ARGUMENTS` | Replace with the raw arguments string (may be empty) |
| `$$` | Emit one literal `$` |

### 5.1 Algorithm (binding)

Perform **one deterministic left-to-right pass** over the template body:

1. Scan body from index 0.
2. On `$$`: append one `$`; advance by 2. Do **not** treat the emitted `$` as
   starting a new scan token.
3. On exact `$ARGUMENTS` (ASCII, case-sensitive): append the **arguments** bytes;
   advance by `len("$ARGUMENTS")`. **Inserted arguments are never rescanned**
   (even if they contain `$ARGUMENTS` or `$$`).
4. On a single `$` that is not the start of `$$` or `$ARGUMENTS`: append `$`;
   advance by 1. No other `$NAME` / positional / expression forms exist.
5. All other bytes copy through unchanged.

Additional rules:

- **Empty arguments are allowed** (`$ARGUMENTS` → empty string).
- When arguments are **non-empty** and the body contains **no** unescaped
  `$ARGUMENTS` placeholder (i.e. no substitution of type 3 occurred), **append**
  two newlines (`\n\n`) then the arguments to the expansion result.
- When arguments are empty and there is no placeholder, do **not** append.
- No positional variables (`$1`), no shell expansion, no quoting language, no
  code/expressions, no nested/recursive expansion of the result.

### 5.2 Budgets at expansion

| Check | Failure |
|-------|---------|
| `arguments.len > 8 KiB` | typed local error; no provider |
| final expanded text `> 32 KiB` | typed local error; no provider |
| OOM during expansion alloc | `error.OutOfMemory`; no provider |

## 6. Public parse / expand API and routing

### 6.1 Public coding-agent API

```zig
// Exact names may match package style; behavior is binding.
pub const TemplateExpansion = struct {
    /// Expanded ordinary user message text.
    user_text: []const u8, // allocator ownership per API docs in impl
    /// Command name that was expanded (for diagnostics/tests).
    name: []const u8,
};

pub const TemplateExpansionError = error{
    UnknownTemplate, // reserved for explicit expand-by-name; CLI unknown slash stays raw
    ArgumentsTooLarge,
    ExpansionTooLarge,
    OutOfMemory,
};

/// If input is exactly `/<name>` or `/<name>` + whitespace + rest, and `<name>`
/// is a valid lower-kebab token, return name + rest. Does **not** consult the
/// catalog. Unrelated shapes (no leading `/`, `/skill:…` form handled by skills
/// parser first at the host, bare text) → null.
pub fn parseTemplateCommand(input: []const u8) ?struct { name: []const u8, rest: []const u8 };

/// Expand a catalog template once. Unknown name → UnknownTemplate.
/// Does not call the provider. Does not re-read the filesystem.
pub fn expandTemplate(
    allocator: Allocator,
    session: *const Session,
    name: []const u8,
    arguments: []const u8,
) TemplateExpansionError!TemplateExpansion;
```

Allocator ownership: expansion result `user_text` is owned by the caller’s
allocator (gpa/arena per package style, frozen by implementation fixtures);
callers free on owned path. Catalog body bytes remain Session-owned.

### 6.2 Routing precedence (CLI one-shot, REPL, headless)

Host routes **must** use the public coding-agent APIs explicitly. Binding order:

```text
1. exact /skill: form (skills parse) → skill expand or UnknownSkill local error
2. else parseTemplateCommand + name ∈ catalog → expand once → ordinary user text
3. else → preserve current raw-user-text behavior (including unknown slash commands)
```

| Input class | Behavior |
|-------------|----------|
| exact `/skill:<name> [rest]` | Skills path (§skills.md); unknown skill → stable local error, **no provider** |
| known `/name` or `/name` + whitespace + rest | one-pass expand; rest is `$ARGUMENTS` input (trim policy: rest is everything after first whitespace run following name; leading `/name` shape only) |
| unknown `/something` not `/skill:` | **raw user text** (preserve pre-templates unknown-slash compatibility) |
| non-slash text | raw user text |
| `Agent.reply` | **never** implicitly parses `/skill:` or `/name` |

SDK product composition: external consumers that want slash expansion must call
the public parse/expand APIs; constructing `Agent` / calling `reply` alone must
not expand.

### 6.3 Local failure → no provider

Any of: unknown skill (skill path), expansion OOM, arguments too large, expansion
too large, or other typed expansion errors on an attempted known-template expand
→ **stable local error**, **no provider call**, **no hidden provider call**, and
**no catalog/read Tool**. Unknown slash that never selects a catalog name is not
an error — it remains raw user text (may still call provider if the host sends
it as a normal reply).

## 7. Safety

| Surface | Rule |
|---------|------|
| Loader | No execute privilege; no env injection; no network; no provider/hook/UI |
| User root | Host loader only; File Tools cannot read it |
| Project root | Explicit trust; realpath inside workspace |
| Symlink escape | Soft-skip; zero outside bytes in catalog |
| Induced Tools | Expanded text may tell the model to write/shell/path; those calls still pass **ask** + workspace jail + shell **protect** + redaction |
| Secrets | Diagnostics path-free **and** body-free; catalog not serialized; bodies appear only as ordinary user-message text after successful expansion under existing redaction/caps |
| OS sandbox / DLP | **Not claimed** |

Preserve ask + workspace jail + shell protect as product defaults. Do not
weaken closed schemas.

## 8. Compatibility freeze

| Surface | prompt-templates-001 |
|---------|----------------------|
| Core types/ports | **unchanged** — no template types in Core |
| session schema v1 | **unchanged** — catalog not serialized |
| Trace v1 | **unchanged** — no new kinds; no template body fields |
| headless-v1 | **unchanged** — no new events; expansion is ordinary user text |
| `project.zig` / `--no-project` | **unchanged** |
| Skills routing `/skill:` | **preserved** and **first** in precedence |
| Unknown slash raw-user-text | **preserved** when name not in template catalog |
| Permission default **ask** | preserved |
| Workspace jail | preserved for File Tools |
| Shell default **protect** | preserved |
| Runtime Extensions maturity | remains **L0**; only E1 Prompt Templates contract is specified |

## 9. Errors and diagnostics (typed)

Discovery soft diagnostics (non-exhaustive; must stay path/body free):

| Code (conceptual) | When |
|-------------------|------|
| `root_missing` | root path absent |
| `root_escape` | root fails containment |
| `entry_limit` | >64 direct children budget |
| `candidate_io` | read/stat failure |
| `candidate_escape` | symlink/realpath escape |
| `invalid_utf8` | file bytes |
| `name_invalid` | charset/length |
| `name_reserved` | e.g. `skill` |
| `body_empty` / `file_too_large` | body/file bounds |
| `source_budget` | aggregate exclusion |
| `project_override` | project replaced user same name |

Hard / local expansion errors:

| Error | When |
|-------|------|
| `error.OutOfMemory` | catalog alloc at start, or expansion alloc |
| `ArgumentsTooLarge` | arguments > 8 KiB |
| `ExpansionTooLarge` | final text > 32 KiB |
| `UnknownTemplate` | explicit expand-by-name for missing catalog entry |

## 10. Non-goals

- Scripts, hooks, MCP, WASM, network/provider registration, dynamic ABI
- Edit sharpness, TUI, autocomplete
- Executable frontmatter / metadata runtime / loader execution
- Model-visible template summary or catalog/read Tool
- Positional variables, shell expansion, quoting language, expressions
- Recursive / multi-pass rescan of inserted arguments or expansion result
- Pi / npm marketplace parity or accidental first-wins collision (project
  override is binding)
- Core template types or ports
- New Trace / headless / session schema fields
- Changing `project.zig` candidates or `--no-project` meaning
- Auto-trusted project templates
- Raising Runtime Extensions maturity above L0
- Shared generic “resource loader” package extraction beyond what this slice needs
- Co-delivery of unrelated M2 nodes

## 11. Verification — exact fixture matrix

Implementers must land focused tests covering **all** rows. IDs are stable for
review cross-reference. Docs track freezes the matrix; implementation track
executes it.

| # | Fixture | Expect |
|---|---------|--------|
| 1 | **Roots + enable neutrality** | Valid user-root `*.md` discovered when enabled; `--no-prompt-templates` / SDK disable → empty catalog; non-template prompts match pre-templates baseline |
| 2 | **Project trust off/on** | Untrusted: project root ignored even if present; trusted: project template appears; trust independent of `--no-project` and of Skills trust |
| 3 | **Containment / symlink escape** | Symlink leaving user authority or leaving workspace (project) → soft-skip; **no outside bytes** in catalog or expansion |
| 4 | **Non-recursive direct files + byte-sort** | Only direct `*.md` files; nested dirs ignored; catalog order deterministic by byte-sorted basenames per root then project-override merge |
| 5 | **Name validation + reserved `skill`** | Invalid charset/length/empty stem soft-skip; `skill.md` reserved soft-skip; valid lower-kebab accepted as `/name` |
| 6 | **Project overrides user collision** | Same name in user+project → project body wins; path-free override diagnostic; **not** first-wins across roots |
| 7 | **Substitution `$ARGUMENTS` / `$$` / no rescan** | `$ARGUMENTS` replaced once; `$$` → one `$`; args containing `$ARGUMENTS` or `$$` not rescanned; bare `$` copies through |
| 8 | **Empty args + append rule** | Empty args allowed; non-empty args with no unescaped `$ARGUMENTS` → append `\n\n` + args; empty args with no placeholder → no append |
| 9 | **Budgets** | file >24 KiB soft-skip; >64 entries/root soft-skip extras; aggregate source >256 KiB excludes later; args >8 KiB local error; final >32 KiB local error |
| 10 | **Start OOM before create** | Fault inject alloc during discovery/catalog → `OutOfMemory`; **no** session file created; **no** lock lease held |
| 11 | **Resume rediscovery / schema freeze** | Resume re-scans live roots; session JSONL has no template catalog fields; schema version remains v1 |
| 12 | **Fork deep-copy / parent immutability** | Child catalog deep-copied; parent catalog bytes/pointers unchanged; child deinit does not free parent; no FS re-read at fork |
| 13 | **Routing precedence + unknown slash** | `/skill:` handled first; known `/name rest` expands once; unknown `/foo` stays raw; `Agent.reply` does not implicit-parse |
| 14 | **Local failure no provider** | Expansion size/OOM errors and skill-unknown path produce local errors with **zero** provider calls; no catalog Tool invoked |
| 15 | **CLI one-shot + REPL + headless** | Explicit public API routing on all three; Trace/session/headless schemas unchanged; expanded text is ordinary user message |
| 16 | **SDK/product composition** | Public enable/trust/user-root options + parse/expand exports; SDK consumer does not get implicit reply parsing |
| 17 | **Security composition** | After expansion, model-driven write/shell/path Tools still hit ask + jail + protect + redaction (composition fixture) |

### 11.1 External SDK smoke (mandatory with implementation)

- Public surface: options for enable/trust/user-root, parse/expand API, and that
  `Agent.reply` does not implicit-parse template slash commands.
- No schema/event change claims.

### 11.2 Gates

**Docs track (complete):**

- Binding module + task authored
- Independent contract review PASS at `e00255b` before production implementation
- `zig build docs-lint` / `python3 scripts/lint_docs.py`
- `git diff --check`
- Explicit `git add` of intended docs files only
- Contract and closeout docs commits on `task/prompt-templates-001`

**Implementation track (complete at `61326ae`):**

- Focused coding-agent tests for §11 rows 1–17 (`prompt_templates_tests.zig`;
  rows 7–8 combined) + unit tests in `prompt_templates.zig`
- External SDK public-surface smoke (`tests/sdk-consumer-fixture`; current
  fixture **23/23** including `prompt-templates-001`)
- Root std + curl candidate Gates: std **40/40 · 633/633**, curl
  **42/42 · 632/632**
- No Core / schema v1 / Trace v1 / headless-v1 / `project.zig` behavior change
- Runtime Extensions maturity remains **L0**
- Independent correctness/boundary review PASS (zero remaining blockers) +
  ff-only local main `4fcfb31` → `61326ae` + merged-main local macOS Gate
  (std/curl as above; OpenAPI **287/287**; catalog **40**; docs **91/73**).
  **No push**; no fresh remote/Linux evidence claimed for this tip.

## 12. Ownership checklist (implementation map)

| Concern | Path (expected) |
|---------|-----------------|
| Discovery + parse + expand | `packages/zag-coding-agent/src/prompt_templates.zig` (or split under coding-agent only) |
| Catalog on Session | `packages/zag-coding-agent/src/agent.zig` (`Session.start`, `fork`, `deinit`) |
| Public API export | `packages/zag-coding-agent/src/root.zig` |
| CLI flags + HOME + routing | `packages/zag-cli/src/cli.zig` (thin explicit routes only) |
| Focused tests | coding-agent template tests covering §11 |
| Core | **no template files / ports** |

## 13. Doc maintenance

Contract and implementation are closed (`prompt-templates-001` **done** at
`61326ae`, docs closeout **2026-07-28**):

- keep this module as binding truth;
- [extensions.md](./extensions.md) and [C8](../phases/C8-extensions.md) record
  project-override collision (not first-wins) and E1 Prompt Templates acceptance;
- task [prompt-templates-001](../plan/tasks/prompt-templates-001.md) is **done**;
- Runtime Extensions remains **L0** — no E1 maturity raise without a separate
  maturity Gate;
- exclusions remain explicit: no E2/E3, scripts/hooks/MCP/WASM, edit, or TUI
  claims from this slice.
