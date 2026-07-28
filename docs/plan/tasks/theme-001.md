---
id: theme-001
scope: host-shell/theme
status: pending
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

**This node does not authorize product implementation.** After dual contract
**re-review** PASS, Theme may receive an **independent** implementation
Goal/node. Status remains **`pending`** until those reviews complete — **not**
`ready`. This revision only closes round-1 **BLOCKED** findings in docs.

**Binding specification:** [theme.md](../../modules/theme.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract candidate | **hardened** after round-1 dual **BLOCKED** findings; still awaiting re-review |
| Dual contract review | round-1 **BLOCKED** → docs fixes; **no PASS** claimed |
| Implementation | **not authorized**; no Theme product code |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** (by contract law; no code touch) |
| Post-TUI remote dual-backend Gate | **orthogonal** — [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md) Phase A **in-progress**; TARGET `f352b60d08e81c19d70ba46198fb06b71ddc85a1`; Class C rebind review PASS @ `7f9cfa4`; **no** Phase B grant; **no** run id; **no** Gate green; **no** push; **no** remote `-Dtui`. Theme does **not** claim or depend on that path. |
| RPC / ACP / extension-UI | remain **pending**/blocked; **not** packaged with Theme |

## Contract vs implementation (discipline)

```text
CONTRACT NODE (docs freeze — current)
  paths: docs only
  status: pending (await dual contract re-review after blocker close)
  does not ship packages/zag-tui Theme code
  does not set status ready / in-progress for implementation
  does not claim review PASS

IMPLEMENTATION NODE (future; only after dual contract PASS + fresh Goal)
  paths: packages/zag-tui/** Theme parse/catalog/SGR/reload
         (+ thin CLI ThemeHostOptions when -Dtui=true)
  forbidden: zag-agent-core / zag-coding-agent Theme types/ports/state/discovery/catalog/options
  develop ≠ verify; task Gate + merged-main Gate; no maturity raise; no remote claim by default
```

# context

- Closed minimal TUI: [tui-minimal-001](./tui-minimal-001.md) **done** @ `f8f7f55`
  (contract PASS @ `c7a8f3a`); binding [tui-minimal.md](../../modules/tui-minimal.md)
- Round-1 dual contract reviews: **BLOCKED** (architecture/ownership + safety);
  this tip hardens binding text only
- Live seams (read-only; **not** Theme-ready today):
  - `packages/zag-tui/src/render.zig` — host-owned structural layout CSI/box; no palette
  - `packages/zag-tui/src/terminal.zig` — raw/alt/size; no color/bg detection
  - `packages/zag-tui/src/app.zig` / `present.zig` — host UI; no Theme catalog/reload
- Orthogonal evidence node: [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md)

# path

## Docs (this contract track)

| Path | Role |
|------|------|
| `docs/modules/theme.md` | **binding truth** |
| `docs/plan/tasks/theme-001.md` | this task skeleton |
| Minimal Active cross-links | already present from contract author tip; avoid scope expansion |

## Implementation (forbidden on this node)

| Path | Role on this node |
|------|-------------------|
| `packages/**`, `src/**`, `build.zig*`, `.github/**`, `chapters/**` | **must not change** |
| Future Theme code | only under `packages/zag-tui/` after dual review PASS + separate Goal; CLI may only forward `ThemeHostOptions` when `-Dtui=true` |

# contract summary

Authoritative detail lives in [theme.md](../../modules/theme.md). Do not restate
conflicting rules here.

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
| Status | **`pending`** until dual re-review PASS; this commit does **not** authorize implementation or claim PASS |

# verification (contract track — this node)

- [x] Binding module authored + round-1 blocker close
- [x] Task file frontmatter (`id`, `scope`, `status: pending`, `priority: P1`, `depends-on: tui-minimal-001`)
- [x] Architecture blockers closed in docs: structural vs Theme SGR; `ThemeHostOptions`; ownership Gate beyond import
- [x] Safety blockers closed in docs: normative containment; closed diagnostics; fixtures for symlink escape + diagnostics leak ban
- [ ] Independent **architecture/ownership** contract **re-review** PASS (different agent; **not claimed**)
- [ ] Independent **safety/fail-closed** contract **re-review** PASS (different agent; **not claimed**)
- [ ] Docs lint / score / `git diff --check` on contract docs path
- [x] Scope: docs only; no product/build/CI/chapter edits
- [x] No maturity raise; no grant/run/Gate green/remote `-Dtui` claim; no `ready`
- [x] Cross-links keep post-TUI remote Gate Phase B **no grant/run/green** truth

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
- Claiming dual review PASS or `status: ready`
- Auto-select implementation Goal without dual re-review PASS
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
