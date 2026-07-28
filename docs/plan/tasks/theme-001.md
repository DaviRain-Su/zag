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
(format/schema, naming, roots/trust/precedence, built-in fallback, selection,
capability/background adaptation, reload atomicity, lifetime, errors/budgets),
fail-closed fallback to a safe built-in host Theme, host-owned reload/UI
invalidation, and non-interference with closed L2 truth (redaction, ask, jail,
shell protect, Session v1, Trace v1, headless-v1, plain CLI, `-Dtui=false`).

**This node does not authorize product implementation.** After dual contract
review PASS, Theme may receive an **independent** implementation Goal/node.
Status remains **`pending`** until those reviews complete — **not** `ready`.

**Binding specification:** [theme.md](../../modules/theme.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract candidate | **authored** — awaiting independent architecture/ownership + safety/fail-closed reviews |
| Dual contract review | **not started** — **no PASS** |
| Implementation | **not authorized**; no Theme product code in this commit |
| Maturity | **unchanged** — no row add/raise |
| Session v1 / Trace v1 / headless-v1 / Core | **unchanged** (by contract law; no code touch) |
| Post-TUI remote dual-backend Gate | **orthogonal** — [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md) Phase A **in-progress**; TARGET `f352b60d08e81c19d70ba46198fb06b71ddc85a1`; Class C rebind review PASS @ `7f9cfa4`; **no** Phase B grant; **no** run id; **no** Gate green; **no** push; **no** remote `-Dtui`. Theme does **not** claim or depend on that path. |
| RPC / ACP / extension-UI | remain **pending**/blocked; **not** packaged with Theme |

## Contract vs implementation (discipline)

```text
CONTRACT NODE (this docs freeze — current)
  paths: docs only
  status: pending (await dual contract review)
  does not ship packages/zag-tui Theme code
  does not set status ready / in-progress for implementation

IMPLEMENTATION NODE (future; only after dual contract PASS + fresh Goal)
  paths: packages/zag-tui/** Theme parse/catalog/ANSI/reload (+ thin CLI options when -Dtui=true)
  forbidden: zag-agent-core / zag-coding-agent Theme types/ports/state/discovery
  develop ≠ verify; task Gate + merged-main Gate; no maturity raise; no remote claim by default
```

# context

- Closed minimal TUI: [tui-minimal-001](./tui-minimal-001.md) **done** @ `f8f7f55`
  (contract PASS @ `c7a8f3a`); binding [tui-minimal.md](../../modules/tui-minimal.md)
- E1 passive ladder: Skills @ `caafef5`, Prompt Templates @ `61326ae`; Theme is
  host-shell passive data **after** TUI, not a coding-agent catalog
- Decisions: [D-009](../../decisions/active/D-009-pi-semantics-not-parity-fork.md),
  [D-010](../../decisions/active/D-010-extension-tiers-and-process-protocol.md),
  [D-011](../../decisions/active/D-011-thin-agent-core-boundary.md)
- Feature map: [Pi feature correspondence](../analysis/2026-07-26-pi-feature-correspondence.md)
- Live seams (read-only; **not** Theme-ready today):
  - `packages/zag-tui/src/render.zig` — hard-coded layout ANSI; no palette
  - `packages/zag-tui/src/terminal.zig` — raw/alt/size; no color/bg detection
  - `packages/zag-tui/src/app.zig` / `present.zig` — host UI; no Theme catalog/reload
- Orthogonal evidence node: [post-tui-remote-dual-backend-gate-001](./post-tui-remote-dual-backend-gate-001.md)

# path

## Docs (this contract track)

| Path | Role |
|------|------|
| `docs/modules/theme.md` | **binding truth** |
| `docs/plan/tasks/theme-001.md` | this task skeleton |
| Minimal Active cross-links | `docs/modules/README.md`, `docs/plan/README.md`, `docs/roadmap.md`, `docs/phases/C9-product-shell.md`, `docs/modules/extensions.md`, `docs/modules/tui-minimal.md`, `docs/maturity.md` (no raise), optionally `docs/INDEX.md` + feature-correspondence |

## Implementation (forbidden on this node)

| Path | Role on this node |
|------|-------------------|
| `packages/**`, `src/**`, `build.zig*`, `.github/**`, `chapters/**` | **must not change** |
| Future Theme code | only under `packages/zag-tui/` after dual review PASS + separate Goal; CLI may only forward explicit options when `-Dtui=true` |

# contract summary

Authoritative detail lives in [theme.md](../../modules/theme.md). Do not restate
conflicting rules here.

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Package owner | **only** `packages/zag-tui`; Theme type/parse/catalog/selection/capability/ANSI/reload/UI invalidation |
| Core / coding-agent | **no** Theme types/ports/state/discovery |
| CLI | thin explicit options on `-Dtui=true` path only; **no** catalog/renderer |
| Theme data | completely passive; **no** raw ANSI/escape, scripts/hooks/commands, env/import/include/network, dynamic Zig ABI, E2/E3 pointers |
| Host ANSI | generated **only** from validated semantic tokens |
| Fail closed | missing/invalid/unsupported → safe built-in (`zag-default`); **never** identity-through raw bytes; **never** weaken redaction/permission/Tool/run truth |
| Reload | parse+validate → temp owned snapshot → atomic publish; failure keeps LKG or built-in; **no** partial apply; bounded diagnostics |
| Defaults | ask + jail + shell protect; `-Dtui` default **false**; Session/Trace/headless schemas unchanged |
| Status | **`pending`** until dual contract reviews PASS; then independent impl Goal — this commit does **not** authorize implementation |

# verification (contract track — this node)

- [x] Binding module authored
- [x] Task file authored with frontmatter (`id`, `scope`, `status: pending`, `priority: P1`, `depends-on: tui-minimal-001`)
- [ ] Independent **architecture/ownership** contract review PASS (fresh; different agent)
- [ ] Independent **safety/fail-closed** contract review PASS (fresh; different agent)
- [ ] Docs lint / score / `git diff --check` on contract docs path
- [x] Scope: docs only; no product/build/CI/chapter edits
- [x] No maturity raise; no grant/run/Gate green/remote `-Dtui` claim
- [x] Cross-links keep post-TUI remote Gate Phase B **no grant/run/green** truth

# verification (implementation track — later; not this commit)

See [theme.md §7](../../modules/theme.md#7-later-implementation-gate-matrix).
Summary classes only:

| Class | Intent |
|-------|--------|
| Happy / error / budget | accept valid; reject invalid; budget skip |
| Capability / background | degrade safely; built-in-only adaptation |
| Reload / atomic / LKG | no partial apply; retain LKG/`zag-default` |
| Redaction / no-ANSI-in-data | secrets stay redacted; ESC in Theme data rejected |
| No Core import / `-Dtui=false` | import scan + default graph green |
| std+curl + TUI matrices | plain/headless unchanged; TUI local matrices green |
| Schemas | Session v1 / Trace v1 / headless-v1 unchanged |
| Process | develop ≠ verify; task Gate + merged-main Gate; **no** maturity raise; **no** remote claim unless separate node |

# non-goals

- Product Theme implementation on this node
- Auto-select as `ready` without dual contract PASS
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
