---
status: active
scope: coding-agent E1 passive Agent Skills (M2 / C8)
task: skills-001
---

# Agent Skills (E1 passive)

This module is the **binding contract** for `skills-001`: Zig-native, passive
Agent Skills discovery and use. It defines bounded deterministic `SKILL.md`
discovery, explicit project trust, model-visible summaries with on-demand body
loading, manual activation, and ordinary downstream safety Gates.

**Implementation status:** contract only. No production code is claimed here.
Runtime Extensions maturity remains **L0**; this document records only the
closed **E1 Skills** product slice that implementers must satisfy. Delivery does
not raise the Runtime Extensions maturity row.

Prerequisite contracts (unchanged by this slice):

- [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md) Pi semantics
  without parity/schema fork
- [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) E0–E3
  tiers; E1 is passive resources only
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) thin Core;
  product state stays in coding-agent
- [extensions](./extensions.md) feature × carrier map
- [session-store](./session-store.md) schema **v1** create/resume (unchanged)
- [session-fork](./session-fork.md) live catalog deep-copy rules (this slice adds
  catalog/summary ownership to fork; no schema change)
- [context-compaction](./context-compaction.md) four prompt layers; Skills block
  is **view-only**, never transcript/compaction payload
- [tool-runtime](./tool-runtime.md) D-007 `validateTools` / `buildTool`
- [permissions](./permissions.md) · [workspace-sandbox](./workspace-sandbox.md) ·
  [tools-shell](./tools-shell.md) ordinary Tool gates
- [sdk-contract](./sdk-contract.md) · [cli-interaction](./cli-interaction.md) ·
  [headless-contract](./headless-contract.md)

## 1. Boundary

```text
host (CLI / SDK)
  │
  │  resolve roots + trust + enable flags
  │  (CLI: HOME + flags; SDK: host-owned user-root option)
  ▼
zag-coding-agent only
  · discover SKILL.md at Session.start (before durable create)
  · Session-owned catalog + summary (process memory only)
  · view-only Skills system layer (model-invocable summaries)
  · dynamic read_skill Tool append (per reply)
  · public parse/expand activation API
          │
          ▼
zag-agent-core
  · Message / Transcript / Tool / Loop only
  · NO Skill types, NO Skill ports, NO discovery, NO catalog

unchanged:
  session schema v1 · Trace v1 · headless-v1 · project.zig · --no-project
```

| Layer | Owns | Must not own |
|-------|------|--------------|
| `zag-coding-agent` | discovery, catalog, summary, `read_skill`, activation API, CLI flag mapping | Core Skill APIs; durable skill persistence |
| `zag-cli` | resolve `$HOME`, parse `--no-skills` / `--trust-project-skills`, route `/skill:` | discovery I/O beyond forwarding options; model File Tools outside jail |
| `zag-agent-core` | generic Tool validation + loop gates | Skill roots, frontmatter, catalog, activation |
| `project.zig` | AGENTS.md candidates only | skill roots or trust |
| Model File Tools | workspace-jailed path I/O | user-root bytes outside workspace |

**Owner package is coding-agent only.** `zag-agent-core`, session schema v1,
Trace v1, `headless-v1`, `project.zig`, and `--no-project` semantics stay
**byte/behavior unchanged**.

## 2. Defaults and host options

| Knob | Default | Meaning |
|------|---------|---------|
| Skills enabled | **on** | Discover user root (when resolved) + optional project root |
| Project skills trust | **off** | Project root is **not** scanned unless host opts in |
| `--no-skills` (CLI) / SDK disable | off | Disables **both** user and project roots; no Skills block; no `read_skill` |
| `--trust-project-skills` (CLI) / SDK `trusted` enum | off | Project root may be discovered when skills enabled |
| `--no-project` | unchanged | Still only skips AGENTS.md / project instructions; **does not** imply skill trust or skill disable |

### 2.1 Roots (Agent Skills v1)

When skills are enabled:

| Root | Path shape | Authority |
|------|------------|-----------|
| User | `$HOME/.agents/skills/<name>/SKILL.md` | CLI resolves `HOME`. SDK accepts an **explicit host-owned user-root option** and **must not** implicitly read process env. |
| Project | `<workspace>/.agents/skills/<name>/SKILL.md` | Only with CLI `--trust-project-skills` or SDK trusted enum. |

- User-root bytes may live **outside** the workspace **only** through this fixed
  host loader authority.
- Model File Tools remain **workspace-jailed** and never gain user-root access.
- Missing roots are soft-skipped (no hard fail).

### 2.2 SDK options (binding shape)

Exact Zig field names may match package style; behavior is binding:

```zig
// coding-agent SessionStartOptions (or adjacent Skills options struct) — conceptual
pub const ProjectSkillsTrust = enum { untrusted, trusted };

// When skills_enabled == false: no discovery, no catalog, no Skills layer, no read_skill.
// When project_skills_trust == .untrusted: project root not scanned.
// user_skills_root: optional host-provided absolute or host-owned path; SDK never getenv("HOME").
// CLI maps: HOME → user_skills_root; --no-skills → skills_enabled=false;
//           --trust-project-skills → project_skills_trust=.trusted.
```

`load_project_instructions` / `--no-project` remain independent of skill trust.

## 3. Discovery algorithm (deterministic)

Discovery runs during **`Session.start`**, **before any durable create** (and
before writer lease acquisition on create paths), after control-queue
preallocation and redactor ownership match existing start discipline.

### 3.1 Walk rules

1. Resolve at most two roots (user, project) per §2.
2. For each resolved root that exists as a directory after containment checks:
   - list **direct child directories only** (no recursive walk);
   - sort child directory names by **byte-sort** (unsigned byte order);
   - for each child name, require exactly `SKILL.md` at
     `<root>/<name>/SKILL.md` (case-sensitive on case-sensitive FS);
   - cap at **64 direct entries per root** (extra entries soft-skip with
     deterministic diagnostics; discovery still succeeds).
3. Each resolved root and each candidate path must **realpath-contain** under
   its own authority root. Project root must **also** remain inside the
   workspace realpath. Symlink escapes → soft-skip that candidate/root (no
   outside bytes enter catalog).
4. **Project overrides user by exact skill `name`** after successful parse.
   Deterministic: same name → project entry wins; user entry is dropped with a
   typed conflict diagnostic (path-free).
5. Invalid candidates soft-skip; valid ones enter the catalog.

### 3.2 Frontmatter and body (supported subset)

Line-oriented frontmatter only (not full YAML):

```text
---
name: lower-kebab-id
description: non-empty description
disable-model-invocation: true   # optional exact boolean
# unknown well-formed keys ignored
---

<body markdown; non-empty>
```

| Rule | Contract |
|------|----------|
| Required | `name` and non-empty `description` |
| Optional | exact boolean `disable-model-invocation` (`true`/`false` only) |
| Unknown keys | ignored when well-formed `key: value` lines |
| Reject (soft) | duplicate required keys; malformed required keys; invalid UTF-8; `name` ≠ directory name; empty body; unsupported structure (no closing `---`, nested maps/lists, multiline YAML, etc.) |
| Soft diagnostic | **path-free** and **body-free** typed reason codes only |

### 3.3 Bind constants (hard budgets)

| Constant | Bound |
|----------|------:|
| `name` | ≤ **64** bytes; lower-kebab identifier (`[a-z0-9]+(-[a-z0-9]+)*`) |
| `description` | ≤ **1024** bytes |
| one `SKILL.md` total | ≤ **24 KiB** |
| max direct entries per root | **64** |
| model summary aggregate | ≤ **4096** bytes |
| catalog body aggregate | ≤ **256 KiB** |

Aggregate overflow: exclude later candidates in discovery order with soft
diagnostics until within budget (deterministic; never hard-fail for soft
validation). **OOM is hard fail.**

### 3.4 Soft-skip vs hard fail

| Condition | Effect |
|-----------|--------|
| Missing root, invalid candidate, I/O failure on candidate, containment failure | Soft-skip; typed diagnostic; no absolute path; no body |
| Frontmatter/body validation failure | Soft-skip; typed diagnostic |
| Aggregate budget exceeded for next candidate | Soft-skip that candidate (and continue) |
| **Out of memory** during discovery/catalog allocation | **Hard fail** `error.OutOfMemory`; no durable create; no held lease |

Diagnostics are process-local (doctor/log/test hooks as product chooses) and
must not leak absolute paths or skill bodies into Trace, session JSONL,
headless envelopes, or compaction metadata.

## 4. Session-owned catalog and lifetimes

### 4.1 When

```text
Session.start:
  1. arena + DualQueues prealloc (existing)
  2. redactor ownership (existing)
  3. *** skills discovery + catalog + summary (this slice) ***
  4. durable create / resume / ephemeral seed (existing)
  5. finish Session
```

Create-time OOM (including skills OOM) commits **no** child/session file and
holds **no** lease — same transaction honesty as control-queue prealloc.

### 4.2 Storage

- Session owns a **bounded full-body catalog** of accepted skills (name,
  description, disable-model-invocation, body bytes, origin user|project).
- Session owns a derived **model summary** of model-invocable entries only
  (`disable-model-invocation != true`).
- Catalog is **never persisted** (not session schema v1, not Trace, not
  compaction meta, not headless).
- **Resume re-discovers** from live roots with current trust/enable options;
  prior process catalog is discarded.
- **`Session.fork`** deep-copies the live catalog and summary into the child
  arena/gpa ownership with **parent immutability** (same discipline as
  transcript/layers); child does not re-scan filesystem at fork time.
- Invocation-time filesystem re-read is **forbidden** (eliminates TOCTOU for
  catalog bodies).

### 4.3 Model-visible summary

- Only model-invocable `name` + `description` enter a **view-only Skills
  system layer** (assembled into the model view; not a transcript system row).
- No skill summary or body is written to transcript rows or compaction metadata.
- Disabled skills / `--no-skills` / empty invocable set → **no Skills block** and
  **no `read_skill` Tool**.

Suggested view bytes (exact wording may be tightened in implementation PR if
fixtures freeze it; budgets and presence rules are binding):

```text
# Skills
- name: <name>
  description: <description>
Use read_skill with {"name":"<name>"} to load a skill body when needed.
```

Truncation/exclusion for the 4096-byte summary aggregate is deterministic by
discovery order after project-override merge (byte-sorted within each root,
user then project merge with project win).

## 5. `read_skill` Tool

### 5.1 Descriptor (binding capabilities)

| Field | Value |
|-------|-------|
| name | `read_skill` (**reserved**) |
| risk | `read` |
| workspace | `none` |
| shell | `none` |
| cancellation | `none` |
| parameters | closed schema: required string `name` only |

- Queries the **in-memory catalog only**; never accepts paths; never opens FS.
- Manual-only entries (`disable-model-invocation: true`) are **absent** from the
  summary and **denied** to `read_skill` (stable soft tool-result error; no body).
- Unknown name → stable soft tool-result error; no body; no path echo.
- Success returns the bounded catalog body for that name (already UTF-8 validated
  at discovery).

### 5.2 Dynamic toolset composition (per reply)

```text
base toolset = caller custom toolset  OR  default Phase1Storage
if skills enabled AND ≥1 model-invocable catalog entry:
  allocate ephemeral tool slice: base… + read_skill
  validateTools (duplicate reserved name → InvalidToolset before provider)
else:
  use base toolset unchanged (no read_skill)
```

Binding rules:

1. **No fixed-size `[8]`** (or any fixed array) that forces resizing the durable
   default tool storage for skills.
2. **Session address remains stable** during reply (existing steering rule).
3. Allocation is per-reply (or equivalent scoped lifetime) so the Session type
   does not embed a fixed expanded tool array.
4. If the caller custom toolset already contains `read_skill`, composition
   **fails closed** through `validateTools` → `error.InvalidToolset` before any
   provider call (duplicate reserved name).
5. Product default path never registers a second `read_skill`.

## 6. Manual activation API

### 6.1 Public coding-agent API

```zig
// Exact names may match package style; behavior is binding.
pub const SkillActivation = struct {
    /// Expanded ordinary user message text (skill body + optional rest).
    user_text: []const u8, // arena/gpa owned per API docs in impl
    /// Skill name that was activated (for diagnostics/tests).
    name: []const u8,
};

pub const SkillActivationError = error{
    UnknownSkill,
    InvalidSyntax, // optional if parser separates "not a skill command"
    OutOfMemory,
};

/// Parse exact `/skill:<name>` with optional rest. Unrelated slash-prefixed text
/// is not a skill command (caller treats as raw user text).
pub fn parseSkillCommand(input: []const u8) ?struct { name: []const u8, rest: []const u8 };

/// Expand a catalog skill into one ordinary user message. Manual-only skills
/// are allowed. Unknown name → UnknownSkill. Does not call the provider.
pub fn expandSkillActivation(session: *const Session, name: []const u8, rest: []const u8)
    SkillActivationError!SkillActivation;
```

### 6.2 CLI / REPL / headless routing

- One-shot, REPL, and headless routes exact `/skill:<name> [rest]` through the
  public API **before** `Agent.reply`.
- Expansion once → ordinary user message → existing transcript / session save /
  Trace paths (no new schema or event kinds).
- Unknown syntactically valid `/skill:<name>` → **stable local error**, **no
  provider call**.
- Unrelated slash-prefixed text (e.g. `/help`, `/skill` without colon form, or
  non-matching shapes) remains **raw** user text.
- **`Agent.reply` never parses `/skill:` implicitly.** SDK callers must use the
  public parse/expand API explicitly.

### 6.3 Expansion shape (binding intent)

Expansion produces a single user message that includes the skill body and any
trailing rest text (separator deterministic; exact template frozen by fixtures).
It does **not** inject skill bytes into system/project layers, does **not**
mutate the catalog, and does **not** bypass permissions for subsequent Tool use.

## 7. Safety

| Surface | Rule |
|---------|------|
| Loader | No execute privilege; no env injection; no network; no provider/hook/UI |
| User root | Host loader only; File Tools cannot read it |
| Project root | Explicit trust; realpath inside workspace |
| Symlink escape | Soft-skip; zero outside bytes in catalog |
| Induced Tools | Skill text may tell the model to write/shell/path; those calls still pass **ask** + workspace jail + shell **protect** + redaction |
| Secrets | Diagnostics/path-free; bodies not in Trace/session/headless |
| OS sandbox / DLP | **Not claimed** |

## 8. Compatibility freeze

| Surface | skills-001 |
|---------|------------|
| Core types/ports | **unchanged** — no Skill types in Core |
| session schema v1 | **unchanged** — catalog not serialized |
| Trace v1 | **unchanged** — no new kinds; no skill body/summary fields |
| headless-v1 | **unchanged** — no new events; activation is ordinary user text |
| `project.zig` / `--no-project` | **unchanged** |
| Permission default **ask** | preserved |
| Workspace jail | preserved for File Tools |
| Shell default **protect** | preserved |
| Runtime Extensions maturity | remains **L0**; only E1 Skills slice is specified |

## 9. Errors and diagnostics (typed)

Discovery soft diagnostics (non-exhaustive codes; must stay path/body free):

| Code (conceptual) | When |
|-------------------|------|
| `root_missing` | root path absent |
| `root_escape` | root fails containment |
| `entry_limit` | >64 direct children |
| `candidate_io` | read/stat failure |
| `candidate_escape` | symlink/realpath escape |
| `invalid_utf8` | body or frontmatter |
| `invalid_frontmatter` | structure/duplicate/malformed |
| `name_mismatch` | frontmatter name ≠ directory |
| `name_invalid` | charset/length |
| `description_empty` / `description_too_long` | description rules |
| `body_empty` / `file_too_large` | body/file bounds |
| `summary_budget` / `body_budget` | aggregate exclusion |
| `project_override` | project replaced user same name |

Hard errors:

| Error | When |
|-------|------|
| `error.OutOfMemory` | any catalog/summary/toolset alloc OOM at start or reply composition |
| `error.InvalidToolset` | duplicate `read_skill` after append / validateTools |
| activation `UnknownSkill` | `/skill:` name not in catalog (or not present after disable) |

## 10. Non-goals

- Full YAML / multi-document YAML
- Pi / npm / package marketplace / path parity
- Prompt Templates (separate `prompt-templates-001`)
- E2 process / E3 WASM / remote install / loader execution
- Auto-trusted project skills
- Core Skill types or ports
- New Trace / headless / session schema fields
- Recursive slash expansion / nested `/skill:` inside bodies
- TUI / autocomplete
- OS sandbox or DLP claims
- Changing `project.zig` candidates or `--no-project` meaning
- Raising Runtime Extensions maturity above L0

## 11. Verification — exact fixture matrix (~14)

Implementers must land focused tests covering **all** rows. IDs are stable for
review cross-reference.

| # | Fixture | Expect |
|---|---------|--------|
| 1 | **User discovery + disable neutrality** | Valid user-root skill discovered when enabled; `--no-skills` / SDK disable → empty catalog, no Skills layer, no `read_skill`, behavior matches pre-skills baseline for non-skill prompts |
| 2 | **Project trust off/on** | Untrusted: project root ignored even if present; trusted: project skill appears; trust independent of `--no-project` |
| 3 | **Project override / conflict determinism** | Same name in user+project → project wins; byte-sorted children; override diagnostic path-free |
| 4 | **Both-root symlink escape** | Symlink leaving user authority or leaving workspace (project) → soft-skip; **no outside bytes** in catalog/summary/`read_skill` |
| 5 | **Validation / UTF-8 / name / body bounds** | Invalid UTF-8, name≠dir, empty body, oversize file, bad name charset, overlong description soft-skip; valid lower-kebab accepted |
| 6 | **Manual-only summary/tool deny + manual activation** | `disable-model-invocation: true` absent from summary; `read_skill` denies; `/skill:name` expand once to ordinary user message allowed |
| 7 | **Summary/body aggregate bounds** | >4096 summary aggregate and >256 KiB body aggregate exclude later entries deterministically; remaining entries still work |
| 8 | **Start OOM before create** | Fault inject alloc during discovery/catalog → `OutOfMemory`; **no** session file created; **no** lock lease held |
| 9 | **Fork deep ownership / parent immutability** | Child catalog/summary deep-copied; parent catalog bytes/pointers unchanged; child deinit does not free parent |
| 10 | **Resume rediscovery / schema v1 freeze** | Resume re-scans live roots; session JSONL has no skill catalog fields; schema version remains v1 |
| 11 | **`read_skill` bounded success / unknown** | Invocable name returns body; unknown/manual-only soft error; never path arg; workspace/shell none |
| 12 | **Custom toolset append / duplicate fail-closed** | Default and custom bases append `read_skill` when invocable skills exist; pre-existing `read_skill` in custom set → `InvalidToolset` before provider |
| 13 | **Skill-induced write/shell/path still gated** | After body load or manual activation, model-driven `write_file` / `run_shell` / path tools still hit ask + jail + protect + redaction (composition fixture) |
| 14 | **CLI one-shot + REPL + headless activation** | Exact `/skill:name rest` expands; unknown name local error no provider; headless/Trace/session event schemas unchanged; unrelated `/foo` stays raw |

### 11.1 External SDK smoke (mandatory with implementation)

- Public surface: options for enable/trust/user-root, activation parse/expand,
  and that `Agent.reply` does not implicit-parse `/skill:`.
- No schema/event change claims.

### 11.2 Gates (implementation track)

- Focused coding-agent skill tests for §11 rows 1–14
- Root `zig build test` std and curl candidate Gates as required by delivery plan
- `zig build docs-lint` on docs commits
- Do **not** raise Runtime Extensions maturity on happy-path alone

## 12. Ownership checklist (implementation map)

| Concern | Path (expected) |
|---------|-----------------|
| Discovery + parse | `packages/zag-coding-agent/src/skills.zig` (or split modules under coding-agent) |
| Catalog on Session | `packages/zag-coding-agent/src/agent.zig` (`Session.start`, `fork`, `deinit`) |
| `read_skill` handler | coding-agent runtime/tool registration (not Core) |
| Activation API | coding-agent public root export |
| CLI flags + HOME | `packages/zag-cli/src/cli.zig` |
| Core | **no Skill files** |

## 13. Doc maintenance

When behavior lands:

- keep this module as binding truth;
- update [extensions.md](./extensions.md) E1 Skills acceptance checkboxes;
- update [plan/tasks/skills-001.md](../plan/tasks/skills-001.md) delivery evidence;
- leave Runtime Extensions at **L0** unless a separate maturity Gate explicitly
  raises a scoped E1 row (not this task).
