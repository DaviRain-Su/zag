---
id: theme-001
scope: host-shell/theme
status: ready
priority: P1
depends-on:
  - tui-minimal-001
---

# objective

Freeze the **host-shell Theme binding contract** (docs only): unique
`packages/zag-tui` ownership, completely passive Theme data, minimal v1 surface
(format/schema, naming, roots/trust/precedence, **normative containment**,
built-in fallback, selection, capability/background adaptation, reload
atomicity, lifetime, errors/budgets, **closed diagnostics**), fail-closed
fallback to a safe built-in host Theme, host-owned reload/UI invalidation,
binding **`ThemeHostOptions`**, and non-interference with closed L2 truth
(redaction, ask, jail, shell protect, Session v1, Trace v1, headless-v1, plain
CLI, `-Dtui=false`).

**Contract freeze PASS** at reviewed tip
`9e1b9f9be94fd0763ee194602c2d20a6eb9bf8ed` (independent architecture/ownership +
safety/fail-closed re-reviews, **zero blockers**). This tip is a **PASS-record
only**: it records that prior-tip result and sets task **`status: ready`** so a
later **fresh Goal** may select an independent implementation node. It does
**not** authorize product code, does **not** start implementation, and does
**not** claim that *this* PASS-record commit was dual re-reviewed.

**Binding specification:** [theme.md](../../modules/theme.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze | **PASS** @ `9e1b9f9be94fd0763ee194602c2d20a6eb9bf8ed` — dual re-reviews **PASS**, **zero blockers** |
| PASS-record tip | **this commit** — records prior-tip PASS only; **not** self-reviewed |
| Task frontmatter | **`ready`** — contract frozen; eligible for a separate implementation Goal |
| Implementation | **not started**; contract PASS alone does **not** authorize product code |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** (by contract law; no code touch) |
| Post-TUI remote dual-backend Gate | **orthogonal** — [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md) Phase A **in-progress**; TARGET `f352b60d08e81c19d70ba46198fb06b71ddc85a1`; Class C rebind review PASS @ `7f9cfa4`; **no** Phase B grant; **no** run id; **no** Gate green; **no** push; **no** remote `-Dtui`. Theme does **not** claim or depend on that path. |
| RPC / ACP / extension-UI | remain **pending**/blocked; **not** packaged with Theme |

## Contract vs implementation (discipline)

```text
CONTRACT FREEZE (reviewed tip)
  tip: 9e1b9f9be94fd0763ee194602c2d20a6eb9bf8ed
  dual re-reviews: architecture/ownership PASS + safety/fail-closed PASS
  zero blockers; docs only at freeze

PASS-RECORD NODE (this commit)
  paths: docs only
  records prior-tip dual PASS; sets status: ready
  does NOT claim this record tip was dual re-reviewed
  does NOT ship packages/zag-tui Theme code
  does NOT authorize implementation by itself

IMPLEMENTATION NODE (future; only after fresh Goal selects ready task)
  paths: packages/zag-tui/** Theme parse/catalog/SGR/reload
         (+ thin CLI ThemeHostOptions when -Dtui=true)
  forbidden: zag-agent-core / zag-coding-agent Theme types/ports/state/discovery/catalog/options
  develop ≠ verify; task Gate + merged-main Gate; no maturity raise; no remote claim by default
```

# context

- Closed minimal TUI: [tui-minimal-001](./tui-minimal-001.md) **done** @ `f8f7f55`
  (contract PASS @ `c7a8f3a`); binding [tui-minimal.md](../../modules/tui-minimal.md)
- Contract lineage: define `f045e9e` → round-1 **BLOCKED** → harden `9e1b9f9`
  (reviewed PASS tip) → this PASS-record
- Live seams (read-only; **not** Theme-ready today):
  - `packages/zag-tui/src/render.zig` — host-owned structural layout CSI/box; no palette
  - `packages/zag-tui/src/terminal.zig` — raw/alt/size; no color/bg detection
  - `packages/zag-tui/src/app.zig` / `present.zig` — host UI; no Theme catalog/reload
- Orthogonal evidence node: [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md)

# path

## Docs (contract + PASS-record track)

| Path | Role |
|------|------|
| `docs/modules/theme.md` | **binding truth** + PASS-record |
| `docs/plan/tasks/theme-001.md` | this task (`status: ready`) |
| Minimal Active cross-links | plan/roadmap/C9/extensions/tui-minimal/maturity/INDEX/modules README/feature-correspondence |

## Implementation (forbidden until separate Goal)

| Path | Role |
|------|------|
| `packages/**`, `src/**`, `build.zig*`, `.github/**`, `chapters/**` | **must not change** on this node |
| Future Theme code | only under `packages/zag-tui/` after a fresh implementation Goal; CLI may only forward `ThemeHostOptions` when `-Dtui=true` |

# contract summary

Authoritative detail lives in [theme.md](../../modules/theme.md). Do not restate
conflicting rules here. Behavioral freezes at reviewed tip `9e1b9f9` are
unchanged by this PASS-record.

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Package owner | **only** `packages/zag-tui`; Theme type/parse/catalog/selection/capability/Theme-SGR/reload/UI invalidation + discovery I/O |
| Structural vs Theme SGR | host-owned structural CSI/alt-screen/clear/box layout **≠** Theme-derived role SGR; Theme bytes never identity-piped |
| `ThemeHostOptions` | `theme_enabled` (default true), `project_theme_trust` (default untrusted), optional `user_themes_root` / `workspace_root` / `project_themes_root`, optional `selected_theme_id`; CLI maps HOME; library no getenv |
| Core / coding-agent | **no** Theme types/ports/state/discovery/catalog/options |
| CLI | thin parse/forward options on `-Dtui=true` only; **no** parse/catalog/Theme SGR |
| Containment | realpath-contain under authority root; project also under workspace; symlink escape skip/reject; catalog/active zero outside bytes |
| Diagnostics | closed fixed reason codes (+ optional validated id + counters); **no** path/body/secret/session/model leak |
| Fail closed | missing/invalid/unsupported → `zag-default`; never identity-through raw bytes; never weaken redaction/permission/Tool/run truth |
| Reload | parse+validate → temp owned snapshot → atomic publish; failure keeps LKG or built-in; **no** partial apply |
| Status | **`ready`** after dual re-review PASS @ `9e1b9f9`; implementation still needs a **fresh Goal** |

# verification (contract track)

- [x] Binding module authored + round-1 blocker close
- [x] Task file frontmatter (`id`, `scope`, `status: ready`, `priority: P1`, `depends-on: tui-minimal-001`)
- [x] Architecture blockers closed in docs: structural vs Theme SGR; `ThemeHostOptions`; ownership Gate beyond import
- [x] Safety blockers closed in docs: normative containment; closed diagnostics; fixtures for symlink escape + diagnostics leak ban
- [x] Independent **architecture/ownership** contract **re-review** PASS @ `9e1b9f9` (**zero blockers**)
- [x] Independent **safety/fail-closed** contract **re-review** PASS @ `9e1b9f9` (**zero blockers**)
- [x] Docs lint / score / `git diff --check` on contract docs path
- [x] Scope: docs only; no product/build/CI/chapter edits
- [x] No maturity raise; no grant/run/Gate green/remote `-Dtui` claim
- [x] Cross-links keep post-TUI remote Gate Phase B **no grant/run/green** truth
- [x] PASS-record tip records prior-tip PASS only; does **not** claim self dual re-review
- [ ] Implementation Goal / product Theme code (later; not this tip)
- [ ] Implementation Gate matrix (later; not this tip)

# verification (implementation track — later; not this commit)

See [theme.md §7](../../modules/theme.md#7-later-implementation-gate-matrix).
Summary classes (must all appear in any later impl Goal):

| Class | Intent |
|-------|--------|
| Happy / error / budget | accept valid; reject invalid; budget skip |
| Structural vs Theme SGR | host structural control retained; Theme only role colors; no identity-pipe |
| Host options | defaults; CLI HOME map; library no getenv; options-only roots |
| Containment | user + project symlink escape skip/reject; dual project+workspace contain; zero outside bytes in catalog/active |
| Direct-child / non-recursive | nested dirs not discovered |
| Diagnostics | closed codes only on containment/parse/budget/reload failure; no path/body/secret/session/model leak |
| Ownership regressions | Core + coding-agent: no Theme types/ports/state/discovery/catalog/options; CLI: options-only; sources only under `packages/zag-tui/` |
| Capability / background | degrade safely; built-in-only adaptation |
| Reload / atomic / LKG | no partial apply; retain LKG/`zag-default` |
| Redaction / no-escape-in-data | secrets stay redacted; ESC in Theme data rejected |
| `-Dtui=false` + std/curl + TUI matrices | default graph + plain/headless green; TUI local matrices green |
| Schemas | Session v1 / Trace v1 / headless-v1 unchanged |
| Process | develop ≠ verify; task Gate + merged-main Gate; **no** maturity raise; **no** remote claim unless separate node |

# non-goals

- Product Theme implementation on this node
- Claiming this PASS-record tip was dual re-reviewed
- Auto-starting implementation without a fresh Goal
- Maturity raise; Runtime Extensions row raise via Theme
- Post-TUI Phase B grant/run/green; remote `-Dtui`
- RPC / ACP / extension-UI packaging
- Pi Theme parity; Core/coding-agent Theme ownership
- Weakening ask / jail / shell protect / redaction

# related

- [theme.md](../../modules/theme.md) (binding)
- [tui-minimal-001](./tui-minimal-001.md) · [tui-minimal.md](../../modules/tui-minimal.md)
- [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md)
- [C9-product-shell](../../phases/C9-product-shell.md)
- [extensions](../../modules/extensions.md)
- [roadmap](../../roadmap.md) · [maturity](../../maturity.md)
