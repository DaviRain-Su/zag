---
status: active
scope: host-shell Theme binding contract (docs candidate; no implementation)
task: theme-001
prerequisite:
  - tui-minimal-001
---

# Theme (host-shell passive data + host renderer)

This module is the **single authoritative binding** for `theme-001`. It freezes
ownership, passive Theme data rules, the minimal v1 surface, fail-closed
fallback, host-owned reload/UI invalidation, non-interference with closed L2
truth, and the later implementation Gate matrix.

**Current status (honest):** this document is a **contract candidate** awaiting
independent **architecture/ownership** and **safety/fail-closed** reviews.
There is **no** product implementation, **no** dual contract review PASS, **no**
implementation Goal authorization, **no** grant/run, **no** Gate green, and
**no** maturity raise from this node.

**Implementation status:** **not started**. Live `packages/zag-tui` seams
(read-only evidence for this freeze):

| Seam | Current truth | Theme implication |
|------|---------------|-------------------|
| `render.zig` | Hard-coded layout ANSI (home/clear, box chrome); **no** palette / role colors | Theme-driven ANSI generation is a **later implementation requirement** |
| `terminal.zig` | Raw mode, alt-screen, geometry; **no** color-depth or background detection | Capability/background adaptation is a **later implementation requirement** |
| `app.zig` / `present.zig` | Dual-thread host, cards, redaction publish path; **no** Theme type/catalog/reload | Catalog, selection, reload transaction, UI invalidation are **later implementation requirements** |
| `constants.zig` | Frozen TUI capacities only | Theme budgets are additional host constants under this contract |

This docs node **must not** claim any of the above already exist. Closing the
contract track does **not** ship Theme code and does **not** auto-start an
implementation Goal.

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
passive Theme document (on disk or built-in bytes)
        │  host parse + validate only
        ▼
packages/zag-tui/   (ONLY Theme owner)
  · Theme types
  · strict parse / validate
  · catalog + selection
  · terminal capability / background detection (later impl)
  · ANSI generation from validated semantic tokens only
  · reload transaction + UI invalidation
        │  assembles public coding-agent APIs (unchanged by Theme)
        ▼
zag-coding-agent   NO Theme types / ports / state / discovery
        │
        ▼
zag-agent-core     NO Theme types / ports / state / discovery
```

| Layer | Owns Theme | Must not own |
|-------|------------|--------------|
| **`zag-tui` only** | Theme type(s), strict parse/validate, in-process catalog, selection/default, capability/background detection, ANSI generation, reload transaction, UI invalidation after publish, built-in host themes, host diagnostics for Theme faults | Agent/Session durable state; Loop; Trace schema; permission risk; headless envelopes; Core ports |
| `zag-cli` | When **and only when** built with `-Dtui=true`: parse/forward **explicit** Theme host options into the TUI entry; resolve `$HOME` for user-root option if exposed | Theme catalog, renderer, parse/validate of Theme bodies, capability detection, ANSI generation, discovery I/O beyond forwarding options; Theme code under `zag-cli/src/**` |
| `zag-coding-agent` | — | Theme types, ports, state, discovery, catalog, ANSI, reload |
| `zag-agent-core` | — | any Theme / terminal-palette / renderer concern |

**Forbidden shapes:**

- Theme types, ports, discovery, or state in `zag-agent-core` or `zag-coding-agent`
- Theme catalog or renderer owned by `zag-cli`
- Theme implementation under `packages/zag-cli/src/**` as an alternate owner
- Core/coding-agent `@import` of Theme modules
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

## 2. Theme data is completely passive

Theme documents are **data only**. The host is the sole interpreter.

### 2.1 Forbidden in Theme data (hard reject)

| Class | Examples (non-exhaustive) | Host action |
|-------|---------------------------|-------------|
| Raw ANSI / escape | CSI/OSC/DCS sequences, `\x1b`, raw terminal control bytes in values | **reject** document |
| Scripts / hooks / commands | shell snippets, JS/TS, Zig, any executable body | **reject** |
| Env / substitution engines | `$VAR`, `${…}`, `!command`, recursive includes | **reject** |
| Import / include / network | `import`, `include`, URLs, package fetches | **reject** |
| Dynamic Zig ABI / shared libs | `.so`/`.dylib`/plugin paths | **reject** |
| E2/E3 UI pointers | renderer/widget/allocator/Host pointers, component factories | **reject** (never a Theme field) |

**Host rule:** ANSI bytes are generated **only** by host code from
**already-validated semantic tokens**. Theme data must never be identity-piped
to the TTY as raw presentation bytes.

### 2.2 Carrier placement

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

### 3.3 Roots, trust, precedence

Discovery is **host-owned**, non-recursive, deterministic.

| Root | Path shape | When scanned |
|------|------------|--------------|
| **Built-in** | host-embedded / compile-time Theme snapshots inside `zag-tui` | **always** (not filesystem discovery) |
| **User** | `$HOME/.agents/themes/<id>.json` | when Theme enablement is on **and** user root resolved |
| **Project** | `<workspace>/.agents/themes/<id>.json` | only when Theme enablement is on **and** project Theme trust is **on** |

Rules:

1. Direct children only; **no** recursive walk; byte-sorted directory listing.
2. Symlink/realpath containment: user-root and project-root loaders apply
   **host path discipline** consistent with E1 passive loaders (no escape via
   symlink outside the declared root). Exact containment algorithm is a **later
   implementation requirement**; contract requires **fail-closed skip/reject** of
   escaping candidates without hard-crashing the process into open presentation.
3. Missing roots soft-skip (catalog may be built-ins only).
4. CLI (when `-Dtui=true`) may resolve `HOME` and flags; SDK/custom hosts if any
   later expose TUI must pass **host-owned** user-root options and must not
   imply Theme trust from unrelated knobs.
5. Theme enable/trust knobs are **independent** of Skills / Prompt Templates /
   `--no-project` / AGENTS.md trust.
6. Default v1: Theme feature **on** for TUI sessions; project Theme trust
   **off**; default selection is host built-in (§3.5).

**Collision after valid parse** (same `id`):

```text
project (if trusted)  >  user  >  built-in (for non-reserved ids only)
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
| Explicit host option | When `-Dtui=true`, CLI may accept an explicit Theme id option (exact flag spelling is implementation detail; behavior is: select **one** catalog id) |
| Default | If no explicit id: host selects **`zag-default`**, unless a later capability path implements **optional** background adaptation that chooses between shipped dark/light built-ins **without** reading untrusted files for the decision |
| Unknown explicit id | **fail closed** → use `zag-default` + bounded diagnostic; **do not** refuse to start TUI solely for unknown Theme id if built-in exists (presentation degrades safely) |
| Empty / disabled Theme feature | If an impl exposes disable: render with `zag-default` tokens only; **never** “no theme object” that pipes raw file bytes |

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

### 3.10 Bounded diagnostics (no leak)

Theme diagnostics (stderr before raw, or TUI status_note / host_note after):

| Allowed | Forbidden |
|---------|-----------|
| Fixed codes: `theme_invalid`, `theme_unknown_id`, `theme_budget`, `theme_oom`, `theme_reload_failed`, `theme_using_default` | Theme file **body** bytes |
| Optional Theme **id** if already validated as id-shaped (≤64) | Absolute paths, `$HOME` expansion, workspace canonical paths |
| Counts: `rejected=<n>` style fixed ASCII | Secrets, API keys, Session paths, user/model content |
| | Stack traces with path leakage in product paths |

Diagnostics must pass the same outward redaction discipline when they embed any
non-enum user-influenced bytes ([tui-minimal](./tui-minimal.md) §8). Prefer
**fixed codes only**.

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
| 1 | Happy path built-in | TUI paints with `zag-default` (or explicit built-in) tokens; layout still meets tui-minimal |
| 2 | Happy path user Theme | valid user `.json` accepted; roles applied via host ANSI only |
| 3 | Project trust off | project Theme ignored |
| 4 | Project trust on + override | project overrides user same id; reserved built-in ids still rejected |
| 5 | Invalid schema / bad color / unknown role / raw ESC in value | reject; LKG or `zag-default`; no raw bytes on TTY from Theme body |
| 6 | Budget oversize file / too many entries | reject/skip; diagnostic bounded |
| 7 | Unknown selection id | `zag-default` + `theme_unknown_id` (or equivalent fixed code) |
| 8 | Capability degrade | monochrome/16-color path still paints; no crash |
| 9 | Background adaptation (if implemented) | only switches among built-ins; detection fail → `zag-default` |
| 10 | Reload success | atomic publish; one full invalidate; no partial roles |
| 11 | Reload failure mid-way | retain LKG; fixed diagnostic; no partial apply |
| 12 | LKG after prior success then bad reload | prior good Theme remains active |
| 13 | Redaction still mandatory | secret in assistant/tool fields never appears raw; Theme colors do not bypass present pipeline |
| 14 | No ANSI in Theme data | fixture file containing ESC/`\x1b[` rejected |
| 15 | No Core / coding-agent Theme import | import scan green |
| 16 | `-Dtui=false` | default build/test green; no Theme/TUI resolve requirement |
| 17 | plain + headless std **and** curl | unchanged green |
| 18 | TUI std **and** curl (local) | Theme fixtures + existing tui-minimal matrix green |
| 19 | Permission/ask/jail/shell unchanged | mode matrix + deny paths unchanged |
| 20 | Session v1 / Trace v1 / headless-v1 | schemas unchanged; no Theme fields/kinds |
| 21 | Docs/diff | contract consistency; no maturity raise language |

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

## 9. Contract-node acceptance (docs only; this tip)

- [x] Binding module authored (`docs/modules/theme.md`)
- [x] Task file authored (`docs/plan/tasks/theme-001.md`) with required frontmatter
- [ ] Independent **architecture/ownership** contract review PASS (pending; different agent)
- [ ] Independent **safety/fail-closed** contract review PASS (pending; different agent)
- [ ] Docs lint + score + `git diff --check` green on contract docs path
- [x] Contract freeze does **not** invent product acceptance or implementation
- [x] **No** maturity row raise; **no** remote/grant/run/green claim
- [x] Scope excludes `packages/**`, `src/**`, `build.zig*`, `.github/**`, `chapters/**`

## 10. Current delivery state

| Track | Status |
|-------|--------|
| Contract candidate | **this node** — awaiting fresh dual contract reviews |
| Dual contract review | **not started** / no PASS |
| Implementation Goal | **not authorized** by this commit |
| Product Theme code | **absent** (seams above) |
| Maturity | **unchanged** |
| Post-TUI remote Gate | **independent** in-progress Phase A; no Theme coupling |

## Related

- [task theme-001](../plan/tasks/theme-001.md)
- [tui-minimal](./tui-minimal.md) · [task tui-minimal-001](../plan/tasks/tui-minimal-001.md)
- [post-tui-remote-dual-backend-gate-001](../plan/tasks/post-tui-remote-dual-backend-gate-001.md)
- [extensions](./extensions.md) · [C9-product-shell](../phases/C9-product-shell.md)
- [Pi feature correspondence](../plan/analysis/2026-07-26-pi-feature-correspondence.md)
- [roadmap](../roadmap.md) · [maturity](../maturity.md) · [packaging](../packaging.md)
