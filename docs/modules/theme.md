---
status: active
scope: host-shell Theme binding + implementation
task: theme-001
prerequisite:
  - tui-minimal-001
---

# Theme (host-shell passive data + host renderer)

This module is the **single authoritative binding** for `theme-001`.

**Contract freeze PASS** @ `9e1b9f9`. **Implementation:** `packages/zag-tui/src/theme.zig`
wires role → `vaxis.Style` in `render.zig`; CLI passes `ThemeHostOptions`
(`user` root `$HOME/.agents/themes`). Fail-closed to built-in `zag-default`.

**Task status:** `theme-001` **done** (canvas track). No maturity raise.

Related truth (do not fork):

| Concern | Authority |
|---------|-----------|
| Minimal host TUI package / dual-thread / redaction / modes | [tui-minimal](./tui-minimal.md) (**done** @ `f8f7f55`; contract PASS @ `c7a8f3a`) |
| E1 passive resource ladder + no E2/E3 raw ANSI | [extensions](./extensions.md) · [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md) |
| Thin Core / product ownership | [D-011](../decisions/active/D-011-thin-agent-core-boundary.md) · [core-boundary](./core-boundary.md) |
| Pi semantics without parity | [D-009](../decisions/active/D-009-pi-semantics-not-parity-fork.md) |
| C9 shell phase | [C9-product-shell](../phases/C9-product-shell.md) |
| Packaging / `-Dtui` lazy graph | [packaging](../packaging.md) · [tui-minimal](./tui-minimal.md) §1.2 |
| Post-TUI **default-path** remote Gate (orthogonal) | [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) — Phase A **in-progress**; TARGET `f352b60…`; **no** Phase B grant/run/green; **no** remote `-Dtui` |
| Maturity truth | [maturity](../maturity.md) — Theme does **not** add or raise any row |
| Task skeleton | [theme-001](../plan/tasks/theme-001.md) |

## 1. Ownership and dependency direction

### 1.1 Unique owner: `packages/zag-tui` only

```text
CLI / custom host (when -Dtui=true)
  · resolve HOME → user_themes_root (CLI only; library hosts pass explicit path)
  · parse flags → ThemeHostOptions
  · MUST NOT parse Theme bodies, own catalog, or emit Theme SGR
        │  pass ThemeHostOptions only
        ▼
packages/zag-tui/   (ONLY Theme owner + discovery I/O)
  · Theme types
  · strict parse / validate
  · catalog + selection (from options + FS/built-ins)
  · terminal capability / background detection (later impl)
  · Theme-derived SGR/color attributes from validated semantic roles only
  · host-owned structural control (alt-screen/cursor/clear/layout) per tui-minimal
  · reload transaction + UI invalidation
        │  assembles public coding-agent APIs (unchanged by Theme)
        ▼
zag-coding-agent   NO Theme types / ports / state / discovery / options
        │
        ▼
zag-agent-core     NO Theme types / ports / state / discovery
```

| Layer | Owns Theme | Must not own |
|-------|------------|--------------|
| **`zag-tui` only** | Theme type(s), `ThemeHostOptions` consumer, discovery I/O under options, strict parse/validate, in-process catalog, selection/default, capability/background detection, **Theme-derived SGR** from validated roles, reload transaction, UI invalidation after publish, built-in host themes, host diagnostics for Theme faults | Agent/Session durable state; Loop; Trace schema; permission risk; headless envelopes; Core ports; reading Agent/Session private fields for roots |
| `zag-cli` | When **and only when** built with `-Dtui=true`: parse/forward **explicit** `ThemeHostOptions` into the TUI entry; resolve `$HOME` → `user_themes_root` | Theme catalog, renderer, parse/validate of Theme bodies, capability detection, Theme SGR generation, discovery I/O beyond building options; Theme source under `zag-cli/src/**` |
| `zag-coding-agent` | — | Theme types, ports, state, discovery, catalog, options, SGR, reload |
| `zag-agent-core` | — | any Theme / terminal-palette / renderer concern |

**Forbidden shapes:**

- Theme types, ports, state, discovery, catalog, or Theme options in
  `zag-agent-core` or `zag-coding-agent` (not merely “no `@import`”)
- Theme catalog or renderer owned by `zag-cli`
- Theme implementation / Theme source files under `packages/zag-cli/src/**` or
  any package other than `packages/zag-tui/`
- Deriving Theme roots from Agent/Session private fields
- Shipping Theme as E2/E3 executable surface or raw-terminal capability

### 1.2 Build and CLI wire (inherits TUI law)

| Rule | Binding |
|------|---------|
| Package path | Theme code lives **only** under `packages/zag-tui/` |
| `-Dtui` default | **false** (unchanged) |
| When `-Dtui=false` | **must not** resolve/build Theme code paths that pull TUI; default `zig build` / `zig build test` graph unchanged; plain/headless/Kernel paths unchanged |
| When `-Dtui=true` | CLI may parse/forward explicit Theme options and call `zag-tui` public entry; catalog/renderer remain inside `zag-tui` |
| Kernel / coding-agent ban | must not `@import("zag-tui")` for Theme or otherwise (existing headless Kernel no-TUI scan remains) |
| This contract node | **docs only** — no product package files, no new deps, no build graph edits |

### 1.3 Public-API assembly (unchanged by Theme)

Theme does **not** introduce Core or coding-agent Theme APIs. The host continues
to assemble only the public surfaces already frozen by
[tui-minimal](./tui-minimal.md) (Agent/Session/LifecycleObserver/Observer/Gate/
control queues/`SignalHost`). Theme selection is a **host-shell presentation**
concern, not a Session schema field and not a Trace kind.

### 1.4 Binding `ThemeHostOptions` (zag-tui entry; conceptual shape)

Exact Zig field names may match package style; **behavior is binding**. These
options are defined and consumed by **`zag-tui`**. CLI / custom hosts only
**populate and pass** them when entering TUI. `zag-coding-agent` must **not**
add Theme options or Theme state. Library/SDK hosts must **not**
`getenv("HOME")` for Theme roots; only product CLI may map `HOME` →
`user_themes_root`.

```zig
// Conceptual — binding behavior, not a shipped API claim.
pub const ProjectThemeTrust = enum { untrusted, trusted };

pub const ThemeHostOptions = struct {
    /// Default **true** for product TUI sessions. When false: no user/project
    /// discovery; render with built-in `zag-default` tokens only.
    theme_enabled: bool = true,

    /// Default **untrusted**. Project root is scanned only when `.trusted`.
    project_theme_trust: ProjectThemeTrust = .untrusted,

    /// Optional host-owned user themes directory authority root.
    /// CLI: resolve $HOME → "<HOME>/.agents/themes" (or equivalent) and pass.
    /// Library hosts: explicit path or null; MUST NOT getenv("HOME").
    /// zag-tui owns all discovery I/O under this root when non-null + enabled.
    user_themes_root: ?[]const u8 = null,

    /// Workspace authority root used for project Theme containment.
    /// Required for any project Theme scan; may also equal the product workspace.
    workspace_root: ?[]const u8 = null,

    /// Optional project themes directory (typically
    /// "<workspace>/.agents/themes"). Scanned only when theme_enabled and
    /// project_theme_trust == .trusted and both workspace_root and this path
    /// are set. zag-tui owns discovery I/O.
    project_themes_root: ?[]const u8 = null,

    /// Optional explicit Theme id selection after catalog build.
    /// Unknown → zag-default + fixed diagnostic (see §3.5).
    selected_theme_id: ?[]const u8 = null,
};
```

| Rule | Binding |
|------|---------|
| Who builds options | CLI (`-Dtui=true`) or custom TUI host only |
| Who discovers / parses / catalogs | **`zag-tui` only** |
| Roots source | options fields above only — **never** Agent/Session private fields |
| coding-agent | **no** Theme option struct, Session field, or discovery call |
| Independence | Theme knobs independent of Skills / Prompt Templates / `--no-project` |

## 2. Theme data is completely passive

Theme documents are **data only**. The host is the sole interpreter.

### 2.1 Host structural control vs Theme-derived attributes (unique freeze)

TTY output has two **disjoint** host-owned channels. Theme does **not** own
structural terminal control required by [tui-minimal](./tui-minimal.md).

| Channel | Source of truth | May Theme data supply? |
|---------|-----------------|------------------------|
| **Host-owned structural control** | Fixed host code in `zag-tui` (today: `terminal.zig` / `render.zig`) | **No** |
| **Theme-derived SGR / color attributes** | Host maps **validated semantic role tokens** → SGR sequences | Values only as constrained color specs (§3.1.1); **never** raw escape strings |

**Host-owned structural control** (non-exhaustive; continues to satisfy
tui-minimal regardless of Theme):

- alt-screen enter/leave, cursor hide/show, raw/restore termios
- clear / home / cursor address used for full-frame layout
- fixed layout glyphs and chrome characters (box-drawing, prompts, separators)
- wake/poll, geometry, permission-modal key routing (non-color)

**Theme-derived attributes only:**

- SGR / color (and only color-adjacent) attributes generated by **host code**
  from **already-validated** role → color-spec maps in the active Theme snapshot
- optional host mapping of `bg`/`fg` roles under capability policy (§3.6)

**Absolute rules:**

1. Theme file/document bytes must **never** be identity-piped to the TTY.
2. Theme-derived SGR must come **only** from validated semantic roles — not from
   Theme-supplied CSI/OSC/DCS fragments.
3. Structural control remains host-owned even when Theme is disabled or
   fail-closed to `zag-default`.
4. Existing hard-coded layout CSI/box output in current seams is **not** a
   contract violation; Theme **adds** a later palette layer and does **not**
   require deleting structural sequences.

### 2.2 Forbidden in Theme data (hard reject)

| Class | Examples (non-exhaustive) | Host action |
|-------|---------------------------|-------------|
| Raw ANSI / escape in values | CSI/OSC/DCS sequences, `\x1b`, raw terminal control bytes | **reject** document |
| Scripts / hooks / commands | shell snippets, JS/TS, Zig, any executable body | **reject** |
| Env / substitution engines | `$VAR`, `${…}`, `!command`, recursive includes | **reject** |
| Import / include / network | `import`, `include`, URLs, package fetches | **reject** |
| Dynamic Zig ABI / shared libs | `.so`/`.dylib`/plugin paths | **reject** |
| E2/E3 UI pointers | renderer/widget/allocator/Host pointers, component factories | **reject** (never a Theme field) |

### 2.3 Carrier placement

| Axis | Theme v1 |
|------|----------|
| Feature surface | Theme (Pi correspondence; not API parity) |
| Carrier | E1-style **passive resource** + **host built-in** data |
| Execution tier | **none** — no E2/E3 Theme renderer, no loader execution privilege |
| Bundle | may later appear in a runtime package manifest as passive data only; package/trust is a **separate** Gate and is **out of v1 scope** |

## 3. Minimal v1 surface (frozen)

v1 freezes the smallest host Theme surface that is independently reviewable and
implementable **after** dual contract PASS. Items marked **later
implementation requirement** are binding product law but are **not** claimed as
present in current `zag-tui` sources.

### 3.1 File format and schema

| Item | Binding |
|------|---------|
| Encoding | UTF-8 only; reject invalid UTF-8 |
| Container | single **JSON object** document per Theme file (extension **`.json`**) |
| Version field | required top-level `"schema": "zag-theme-v1"` (exact string) |
| Identity | required `"id"`: lower-kebab Theme id (see §3.2) |
| Optional display name | `"name"`: human label, bounded, no control chars |
| Optional `"variant"` | enum string only: `"dark"` \| `"light"` \| `"unknown"` — host hint; not an escape hatch |
| Color values | **only** constrained semantic color specs (§3.1.1) — **never** raw escape strings |
| Roles object | required `"roles"` object mapping **known role keys** → color specs |
| Unknown top-level keys | **reject** (strict; no open extension bag in v1) |
| Comments | **not** allowed (strict JSON) |

#### 3.1.1 Color spec (v1)

A color value is exactly one of:

| Form | Syntax | Meaning |
|------|--------|---------|
| Hex sRGB | `"#RRGGBB"` (exactly 7 ASCII chars, hex digits) | 24-bit color token |
| Named system | one of the fixed enum: `default`, `black`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `bright_black`, `bright_red`, `bright_green`, `bright_yellow`, `bright_blue`, `bright_magenta`, `bright_cyan`, `bright_white` | host maps to terminal palette / default fg-bg |
| `none` | exact `"none"` | no color attribute for that role (host omits SGR for that role) |

**Forbidden color forms in v1:** raw CSI fragments, 256-color integer alone
without a host-defined form, rgba/hsla strings, gradients, images, font names,
styles beyond the role set, or any string containing ESC (`0x1B`) / CSI
introducers.

#### 3.1.2 Role keys (exact v1 set)

Host recognizes **only** these role keys under `"roles"` (all required in a
user/project Theme document; built-ins supply a complete set):

| Role key | Presentation use |
|----------|------------------|
| `fg` | default foreground |
| `bg` | default background (host may apply only when capability allows; never forces unsafe OSC without support) |
| `status_fg` / `status_bg` | status strip |
| `card_fg` / `card_border` | card text / border chrome |
| `editor_fg` / `editor_bg` | editor pane |
| `modal_fg` / `modal_border` | permission modal |
| `error_fg` | host/error emphasis |
| `muted_fg` | secondary / constrained chrome |
| `accent_fg` | non-secret emphasis (ids counters only; not a redaction bypass) |

Unknown role keys → **reject**. Missing required role → **reject**.

### 3.2 Naming

| Rule | Binding |
|------|---------|
| Theme `id` | ASCII lower-kebab: `[a-z][a-z0-9-]*`; length **1..64** bytes |
| File name | `<id>.json` under a Theme root; stem **must** equal JSON `"id"` or document is rejected |
| Reserved ids | `zag-default`, `zag-default-dark`, `zag-default-light` are **host built-in** ids; user/project documents claiming these ids are **rejected** (no override of built-in identity) |
| Display `name` | optional; ≤ **64** bytes; printable UTF-8 without C0 controls except none |

### 3.3 Roots, trust, precedence, and containment (normative)

Discovery is **host-owned** (`zag-tui`), non-recursive, deterministic, driven
only by `ThemeHostOptions` (§1.4).

| Root | Path shape (typical) | When scanned |
|------|----------------------|--------------|
| **Built-in** | host-embedded / compile-time Theme snapshots inside `zag-tui` | **always** (not filesystem discovery) |
| **User** | `user_themes_root` / `<id>.json` (CLI maps `$HOME/.agents/themes`) | `theme_enabled` **and** `user_themes_root != null` |
| **Project** | `project_themes_root` / `<id>.json` (typically `<workspace>/.agents/themes`) | `theme_enabled` **and** `project_theme_trust == trusted` **and** `project_themes_root != null` **and** `workspace_root != null` |

#### 3.3.1 Listing discipline

1. Direct children only; **no** recursive walk; byte-sorted directory listing.
2. Only regular-file candidates with extension `.json` enter parse (after
   containment checks). Non-files soft-skip.
3. Missing roots / null roots soft-skip (catalog may be built-ins only).
4. Theme enable/trust knobs are **independent** of Skills / Prompt Templates /
   `--no-project` / AGENTS.md trust.
5. Default v1 via `ThemeHostOptions`: `theme_enabled=true`,
   `project_theme_trust=untrusted`, default selection host built-in (§3.5).

#### 3.3.2 Realpath containment (binding; not deferred)

Containment is **normative product law** for any later implementation. It is
not an optional algorithm sketch.

For **every** filesystem Theme root and **every** candidate path considered for
read/parse:

| Check | Binding |
|-------|---------|
| Authority root realpath | Resolve the configured root (`user_themes_root` or `project_themes_root`) with realpath/symlink-aware resolution. If the root cannot be resolved as a directory under policy, **skip the entire root** (soft) with fixed diagnostic code only. |
| Candidate realpath-contain | Resolve each candidate; require `realpath(candidate)` is **strictly contained under** `realpath(authority_root)` (prefix boundary at path-component edges — no `../` escape, no sibling prefix tricks). |
| Project dual containment | For project candidates: additionally require `realpath(candidate)` (and the project authority root) is contained under `realpath(workspace_root)`. Missing `workspace_root` while trust is on → **do not scan** project root. |
| Symlink escape | Any candidate or intermediate symlink that resolves outside the required authority (and workspace for project) → **skip/reject** that candidate (or root if root itself escapes). |
| Fail-closed | Escaping candidates never contribute bytes to catalog or active snapshot. |
| Snapshot purity | Catalog entries and the active Theme snapshot must contain **zero** outside-of-root file bytes; only validated in-memory Theme objects built from contained reads + built-ins. |
| Process integrity | Containment failure must **not** hard-crash into open presentation or identity-pipe path/body bytes; keep LKG/`zag-default`. |

Built-in Themes are not filesystem candidates and do not use this FS containment
path.

**Collision after valid parse** (same `id`):

```text
project (if trusted + scanned)  >  user  >  built-in (for non-reserved ids only)
```

Reserved built-in ids cannot be overridden (§3.2). Selection still chooses among
**validated** catalog entries only.

### 3.4 Built-in fallback

| Built-in id | Role |
|-------------|------|
| `zag-default` | **Always-present** safe host Theme; deterministic; complete role set |
| `zag-default-dark` / `zag-default-light` | Optional additional built-ins for explicit selection / adaptation; if not shipped in an impl tip, selection falls back to `zag-default` |

Properties:

- Built-ins are **host code/data**, not loaded as untrusted filesystem identity.
- `zag-default` is the **fail-closed** target for missing/invalid/unsupported/
  OOM/reload-failure paths (§5).
- Built-ins never contain secrets, paths, or user content.

### 3.5 Selection and default

| Source | Binding |
|--------|---------|
| Explicit host option | `ThemeHostOptions.selected_theme_id` (CLI flag spelling is impl detail; behavior: select **one** catalog id) |
| Default | If `selected_theme_id == null`: host selects **`zag-default`**, unless a later capability path implements **optional** background adaptation that chooses between shipped dark/light built-ins **without** reading untrusted files for the decision |
| Unknown explicit id | **fail closed** → use `zag-default` + fixed code `theme_unknown_id`; **do not** refuse to start TUI solely for unknown Theme id if built-in exists (presentation degrades safely) |
| `theme_enabled == false` | no user/project discovery; render with `zag-default` tokens only; **never** identity-pipe raw file bytes |

Selection never writes Theme id into Session JSONL, Trace, or headless envelopes.

### 3.6 Terminal capability and background adaptation

**Current code:** `terminal.zig` has **no** color-depth or background detection.
The following is a **later implementation requirement** under this contract:

| Concern | Binding |
|---------|---------|
| Capability detection | Host-owned only (query terminal / environment heuristics as impl chooses); results are host process state, not Theme file fields |
| Supported depths | Host maps tokens to a **safe subset**: monochrome / 16-color / truecolor as detected; unsupported depth **degrades** SGR generation — never fails open into raw Theme bytes |
| Background light/dark | Optional host detection may bias default built-in choice among shipped built-ins only |
| Detection failure | Treat as unknown → `zag-default` token mapping; no hang; no network |
| OSC / bg set | Applying `bg` role via terminal reset/colors is **host policy**; must not execute Theme-supplied OSC strings (Theme cannot supply OSC) |

### 3.7 Reload transaction and atomicity

Reload is **host-owned UI** behavior (manual trigger and/or explicit host API in
a later impl). It must not run inside Core/coding-agent.

**Transaction (unique):**

```text
1. Read candidate Theme bytes (built-in snapshot or filesystem) under budgets
2. Parse + strict validate into a temporary host-owned Theme snapshot
3. If any step fails → discard temp; keep last-known-good active snapshot
   (or zag-default if none); emit bounded diagnostic; do not partial-apply
4. If full success → atomic publish: swap active snapshot pointer/generation
   under the host render lock discipline compatible with tui-minimal
   card/render rules (UI thread applies; worker must not paint with a torn Theme)
5. UI invalidation: schedule one full frame re-render with the new snapshot
```

| Rule | Binding |
|------|---------|
| Partial apply | **forbidden** |
| Last-known-good (LKG) | retain previous validated snapshot on failure |
| No LKG yet | use `zag-default` |
| Worker thread | must not parse Theme files or swap Theme mid-callback without the same atomic publish rules; preferred: UI thread owns reload |
| During busy reply | reload may be deferred or applied only at safe UI points; never blocks permission rendezvous forever; never changes permission decision |
| Atomicity scope | presentation tokens only — **not** Session/Trace/Tool terminal |

### 3.8 Lifetime and ownership

| State | Owner | Durable? |
|-------|-------|----------|
| Theme catalog (validated summaries + snapshots) | `zag-tui` App / host services | **process memory only** |
| Active Theme snapshot | `zag-tui` | process memory; generation counter monotonic |
| Session JSONL / schema v1 | coding-agent (unchanged) | **must not** store Theme catalog/body |
| Trace v1 | coding-agent (unchanged) | **must not** gain Theme kinds |
| Headless-v1 | CLI process protocol (unchanged) | Theme irrelevant; no Theme fields |

Theme lifetime ends with TUI App teardown. Resume Session does **not** restore
a prior Theme selection from durable session state in v1 (selection is host/
flag/default each process unless the host re-supplies an explicit option).

### 3.9 Errors, fallback, budgets

#### Budgets (exact v1)

| Budget | Cap |
|--------|----:|
| Theme file size | **16 KiB** |
| Themes per root (user or project) | **32** accepted entries |
| Aggregate accepted Theme source bytes (user+project) | **256 KiB** |
| `id` / file stem | **64** bytes |
| display `name` | **64** bytes |
| Role key count | exact v1 set only (§3.1.2) |
| Diagnostic line | **≤ 160** bytes ASCII |

Over-budget candidates: **reject/skip** that candidate; do not accept partial
oversized bodies.

#### Fail-closed matrix

| Condition | Active Theme result | TUI / product truth |
|-----------|---------------------|---------------------|
| Missing file / empty root | keep LKG or `zag-default` | continue |
| Invalid JSON / schema / id / roles / color | reject candidate; LKG or `zag-default` | continue |
| Reserved id spoof by user/project | reject candidate | continue |
| Symlink escape / containment fail | skip/reject candidate | continue |
| OOM during parse/snapshot | hard-fail **that reload**; keep LKG/`zag-default`; if OOM at **initial** preallocate of host Theme slot storage before first paint, follow tui-minimal preallocate fail-closed (fixed stderr, exit **1**, no raw mode) — **later impl** must preallocate Theme slot storage with other TUI preallocs |
| Unsupported capability | degrade SGR mapping | continue |
| Theme failure of any kind | **never** identity-through raw Theme file bytes | **never** disable redaction, ask, jail, shell protect, or invent Tool/run success |

### 3.10 Bounded diagnostics (no leak; closed vocabulary)

Theme diagnostics (stderr before raw, or TUI `status_note` / host_note after)
use a **closed vocabulary**. Implementers **must not** invent pathful or
bodyful free text.

#### Allowed diagnostic atoms (only)

| Atom | Form | When |
|------|------|------|
| Fixed reason codes | exact ASCII tokens below | required primary signal |
| Validated Theme `id` | already id-shaped ≤64 (`[a-z][a-z0-9-]*`) | optional; only if validation accepted the id shape **before** failure of a later stage, or the id is a built-in reserved id |
| Saturating counters | exact `rejected=<n>` / `skipped=<n>` style ASCII | optional aggregate |

**Fixed reason codes (exact; closed set for v1):**

| Code | Meaning |
|------|---------|
| `theme_invalid` | schema/parse/role/color/UTF-8 rejection |
| `theme_unknown_id` | selection id not in catalog |
| `theme_budget` | file/entry/aggregate budget |
| `theme_oom` | allocation failure during Theme path |
| `theme_reload_failed` | reload transaction failed (retain LKG) |
| `theme_using_default` | active snapshot is built-in fallback |
| `theme_containment` | realpath/symlink containment skip/reject |
| `theme_root_unresolved` | authority root could not be used |
| `theme_disabled` | `theme_enabled == false` (optional note) |

Composite product lines may only concatenate these atoms (e.g.
`theme_containment rejected=1`) within the **≤ 160** byte ASCII cap. No other
words that embed paths or bodies.

#### Forbidden in diagnostics (hard)

| Forbidden | Examples |
|-----------|----------|
| Absolute or canonical filesystem paths | `/Users/...`, `/home/...`, resolved realpaths |
| `$HOME` / env expansion text | expanded home strings |
| Theme file **body** bytes | any JSON/content snippet |
| Secrets / API keys | configured provider keys, tokens |
| Session paths / ids beyond non-Theme host law | durable session path strings in Theme diagnostics |
| User / model content | assistant/tool/control text |
| Implementer-invented pathful prose | `"failed to open /x/y/z"` |

Diagnostics must not bypass [tui-minimal](./tui-minimal.md) §8 when any
non-enum user-influenced bytes would otherwise appear — prefer **codes only**.

## 4. Non-interference (closed contracts stay closed)

Theme **must not** change:

| Contract | Rule |
|----------|------|
| Outward redaction | Still mandatory before publish of arbitrary bytes; Theme colors decorate **already-redacted** presentation buffers only |
| Permission **ask** default | unchanged; fail-closed; Theme cannot yolo |
| Workspace jail | unchanged |
| Shell **protect** default | unchanged |
| Session schema **v1** | no Theme fields |
| Trace **v1** | no Theme kinds; Theme failure ≠ Trace terminal rewrite |
| `headless-v1` | unchanged; Theme not in headless path |
| plain CLI | unchanged when not `--tui` |
| `-Dtui=false` build graph | unchanged; Theme code not required to build |
| Tool / run terminal truth | Theme failure **cannot** invent `completed` success, alter `stop_reason`, soft-error bodies, or permission allow/deny |
| Permission decision | colors/modals chrome only; keys/rendezvous unchanged |
| Core / coding-agent imports | no Theme |

## 5. Host UI refresh / reload (normative summary)

```text
                    ┌─────────────────────────────┐
                    │  last-known-good snapshot   │
                    │  (or zag-default)           │
                    └──────────────▲──────────────┘
                                   │ fail: retain
 parse+validate ──► temp snapshot ─┤
                                   │ success
                                   ▼
                         atomic publish active
                                   │
                                   ▼
                         full frame invalidate
```

- No half-applied role maps.
- No torn reads across UI paint (UI thread snapshot of active generation).
- Reload is orthogonal to reply-worker lifecycle facts; it does not emit
  lifecycle events and does not clear control queues.

## 6. Relationship to post-TUI remote Gate, RPC, ACP, extension UI

| Node | Relationship to Theme |
|------|------------------------|
| [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md) | **Orthogonal.** TARGET `f352b60d08e81c19d70ba46198fb06b71ddc85a1`; Phase A rebind review PASS @ `7f9cfa4`; **no** Phase B grant; **no** run id; **no** Gate green; **no** push; **no** remote `-Dtui`. Theme docs/impl **must not** claim that remote path. Theme **must not** wait on or unblock that Gate. |
| `rpc-v1` | **pending** separate capability; not bundled with Theme |
| ACP / editor | **pending** / blocked on host consumer; not Theme |
| extension-UI schema | **pending**; host-rendered intents later; **no** Theme-as-extension-renderer; E2/E3 still forbid raw ANSI/widget pointers |

Theme and the post-TUI default-path remote evidence node are **mutually
independent**. Neither grants the other.

## 7. Later implementation Gate matrix

Fixtures below are **implementation-track** only (separate Goal/node after dual
contract PASS). This docs node does **not** execute them.

Develop and verify remain **different agents**. Candidate task Gates and
merged-main Gates are both required before `done`. **No** maturity raise. **No**
remote claim unless a separate evidence node explicitly freezes one.

| # | Fixture class | Expect |
|---|---------------|--------|
| 1 | Happy path built-in | TUI paints with `zag-default` (or explicit built-in) **role colors** via host SGR; **structural** control (alt-screen/clear/box) still host-owned per tui-minimal |
| 2 | Happy path user Theme | valid user `.json` under contained `user_themes_root` accepted; roles → host SGR only |
| 3 | Project trust off | project Theme ignored even if files exist |
| 4 | Project trust on + override | project overrides user same id; reserved built-in ids still rejected |
| 5 | Invalid schema / bad color / unknown role / raw ESC in value | reject; LKG or `zag-default`; no Theme body bytes on TTY |
| 6 | Budget oversize file / too many entries | reject/skip; diagnostic uses closed codes only |
| 7 | Unknown selection id | `zag-default` + exact `theme_unknown_id` |
| 8 | Capability degrade | monochrome/16-color path still paints; no crash |
| 9 | Background adaptation (if implemented) | only switches among built-ins; detection fail → `zag-default` |
| 10 | Reload success | atomic publish; one full invalidate; no partial roles |
| 11 | Reload failure mid-way | retain LKG; fixed `theme_reload_failed` (and/or `theme_using_default`); no partial apply |
| 12 | LKG after prior success then bad reload | prior good Theme remains active |
| 13 | Redaction still mandatory | secret in assistant/tool fields never appears raw; Theme colors do not bypass present pipeline |
| 14 | No raw escape in Theme data | fixture file containing ESC/`\x1b[` in values rejected (`theme_invalid`) |
| 15 | Structural vs Theme SGR split | host still emits structural CSI/layout without Theme file bytes; Theme only affects role color mapping |
| 16 | Ownership — Core | `zag-agent-core` has **no** Theme import **and no** Theme types/ports/state/discovery/catalog symbols |
| 17 | Ownership — coding-agent | `zag-coding-agent` has **no** Theme import **and no** Theme types/ports/state/discovery/catalog/options |
| 18 | Ownership — CLI | with `-Dtui=true`, CLI only parse/forward `ThemeHostOptions`; **no** Theme body parse, catalog, or Theme SGR generation in CLI sources |
| 19 | Ownership — source locus | all Theme parse/catalog/SGR/reload sources live only under `packages/zag-tui/` |
| 20 | Host options defaults | `theme_enabled` default true; `project_theme_trust` default untrusted; library path does not `getenv("HOME")` |
| 21 | Roots not from Agent/Session | options-only roots; no private field derivation |
| 22 | User symlink escape | candidate symlink resolving outside `user_themes_root` → skip/reject; catalog has zero outside bytes; code `theme_containment` |
| 23 | Project symlink escape | candidate (or root) escaping `project_themes_root` **or** `workspace_root` → skip/reject; `theme_containment` |
| 24 | Direct-child / non-recursive | nested subdirectory Theme files are **not** discovered |
| 25 | Diagnostics leak ban | containment/parse/budget/reload failures emit **only** fixed reason codes (+ optional validated id + counters); **no** absolute/canonical path, HOME expansion, Theme body, secret/API key, Session path, user/model content |
| 26 | `-Dtui=false` | default build/test green; no Theme/TUI resolve requirement |
| 27 | plain + headless std **and** curl | unchanged green |
| 28 | TUI std **and** curl (local) | Theme fixtures + existing tui-minimal matrix green |
| 29 | Permission/ask/jail/shell unchanged | mode matrix + deny paths unchanged |
| 30 | Session v1 / Trace v1 / headless-v1 | schemas unchanged; no Theme fields/kinds |
| 31 | Docs/diff | contract consistency; no maturity raise language |

## 8. Non-goals

- Pi Theme API / file-format / package-manager parity
- CSS, images, fonts, animation, gradient, true theming of non-TUI surfaces
- Theme marketplace / remote install in v1
- E2/E3 Theme execution or raw-terminal Theme plugins
- Theme ownership in Core or coding-agent
- Durable Theme selection in Session schema v1
- Dashboard / cost explorer / extension UI host
- Maturity row add/raise (any subsystem)
- Claiming current `render.zig` / `terminal.zig` already implement Theme
- This contract node adding packages, deps, product code, or CI workflow changes
- Remote Linux/`-Dtui` Gate, post-TUI Phase B grant/run/green claims
- RPC / ACP packaging with Theme

## 9. Contract-node acceptance (docs only)

- [x] Binding module authored (`docs/modules/theme.md`)
- [x] Task file authored (`docs/plan/tasks/theme-001.md`) with required frontmatter
- [x] Round-1 architecture/ownership **BLOCKED** findings addressed in docs (structural vs Theme SGR; `ThemeHostOptions`; ownership Gate expansion)
- [x] Round-1 safety/fail-closed **BLOCKED** findings addressed in docs (normative containment; closed diagnostics; fixtures)
- [x] Independent **architecture/ownership** contract **re-review** PASS @ reviewed tip `9e1b9f9` (**zero blockers**)
- [x] Independent **safety/fail-closed** contract **re-review** PASS @ reviewed tip `9e1b9f9` (**zero blockers**)
- [x] Docs lint + score + `git diff --check` green on contract docs path (at reviewed tip / this PASS-record path)
- [x] Contract freeze does **not** invent product acceptance or implementation
- [x] **No** maturity row raise; **no** remote/grant/run/green claim; **no** product implementation authz on this tip
- [x] Scope excludes `packages/**`, `src/**`, `build.zig*`, `.github/**`, `chapters/**`
- [x] This tip is a **PASS-record only** — records prior reviewed tip `9e1b9f9`; **does not** claim this PASS-record commit was dual re-reviewed
- [ ] Implementation Goal selected / product Theme code (later node only)
- [ ] Implementation Gate matrix §7 (later node only)

## 10. Current delivery state

| Track | Status |
|-------|--------|
| Contract | **PASS** @ reviewed tip `9e1b9f9be94fd0763ee194602c2d20a6eb9bf8ed` (dual re-reviews, zero blockers) |
| PASS-record tip | **this commit** — records prior-tip PASS only; **not** self-reviewed as a new contract freeze |
| Task status | **`ready`** (contract frozen; may be selected by a fresh implementation Goal) |
| Implementation | **not started** / **not authorized** by contract PASS alone |
| Product Theme code | **absent** (seams above) |
| Maturity | **unchanged** |
| Post-TUI remote Gate | **independent** in-progress Phase A (TARGET `f352b60…`; no Phase B grant/run/green); no Theme coupling |
| RPC / ACP / extension-UI | remain **pending**/blocked; not packaged |

## Related

- [task theme-001](../plan/tasks/theme-001.md)
- [tui-minimal](./tui-minimal.md) · [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
- [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md)
- [extensions](./extensions.md) · [C9-product-shell](../phases/C9-product-shell.md)
- [Pi feature correspondence](../plan/analysis/2026-07-26-pi-feature-correspondence.md)
- [roadmap](../roadmap.md) · [maturity](../maturity.md) · [packaging](../packaging.md)
