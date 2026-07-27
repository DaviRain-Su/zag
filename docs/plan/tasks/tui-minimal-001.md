---
id: tui-minimal-001
scope: host-shell/tui-minimal (M2 / C9 contract candidate)
status: ready
priority: P1
depends-on:
  - harness-events-001
  - harness-steering-001
  - cli-sigint-001
  - headless-001
  - edit-sharpness-001
---

# objective

Freeze the **minimal host TUI binding contract** so a later implementation
node can assemble public coding-agent / CLI APIs into a small interactive
shell **without** inventing lifecycle kinds, weakening ask/jail/shell,
polluting headless stdout, or placing UI logic in Kernel packages.

This task node is **docs-only (contract candidate)**. It does **not**
implement a product TUI, does **not** check off C9 product acceptance as
done, and does **not** claim maturity or Linux tip evidence.

**Binding specification:** [tui-minimal.md](../../modules/tui-minimal.md)
(+ phase constraints in [C9-product-shell.md](../../phases/C9-product-shell.md)).

# status truth

| Track | Status |
|-------|--------|
| Contract freeze (this node) | **candidate** — authored; independent reviews not yet run |
| Overall product task | **`ready`** for contract review; **implementation BLOCKED** |
| Production TUI implementation | **not started** — blocked (see split below) |
| Maturity / C9 product acceptance | **unchanged / not claimed** |
| Session v1 / Trace v1 / headless-v1 / Core | **must remain unchanged** by later impl |

## Contract vs implementation split

```text
THIS NODE (docs contract candidate)
  paths: docs only
  verify: lint_docs + score_docs --check + git diff --check
  review: architecture/ownership + safety/fail-closed
  merge: candidate only; does not ship TUI

LATER NODE (implementation; separate tip / Gate)
  BLOCKED until:
    1) independent architecture/ownership contract PASS
    2) independent safety/fail-closed contract PASS
    3) this contract merged to the integration branch used for impl
  paths: packages/zag-tui or zag-cli tui module, build wiring, tests
  verify: full fixture matrix in tui-minimal.md §10 + dual-backend Gates
```

Frontmatter `status: ready` means dependencies are met for **contract
review and docs freeze**, not that implementation may start before the
two contract PASS results and merge.

# context

- Closed M1 lifecycle: [harness-events-001](./harness-events-001.md) @ `aecf402`
  — public `LifecycleObserver` / `LifecycleEvent`; no `message_delta` /
  `tool_update`; end-only tool gaps; hard mid-call rules.
- Closed M1 steering: [harness-steering-001](./harness-steering-001.md) @
  `a5ff2b7` — Session queues + `control_applied`.
- Closed M0 SIGINT: [cli-sigint-001](./cli-sigint-001.md) +
  [cli-interaction](../../modules/cli-interaction.md).
- Closed headless: [headless-001](./headless-001.md) — stdout purity,
  `-Dtui` option default false, Kernel no-TUI scan.
- Closed C4 first slice: [edit-sharpness-001](./edit-sharpness-001.md) @
  `7be5151` — hunk review ≠ permission prompt; TUI v1 does not claim hunk UI.
- Public surfaces inspected for this freeze:
  `packages/zag-coding-agent/src/{lifecycle,observer,agent,permissions,root}.zig`,
  `packages/zag-cli/src/{cli,headless_writer,sigint}.zig`, root `build.zig`
  (`-Dtui` stub default false).

# path

## Docs (this node — only allowed changes)

| Path | Role |
|------|------|
| `docs/plan/tasks/tui-minimal-001.md` | this task |
| `docs/modules/tui-minimal.md` | **binding truth** |
| `docs/phases/C9-product-shell.md` | phase acceptance remains unchecked for product; link contract |
| `docs/modules/README.md` | module index row |
| `docs/plan/README.md` | DAG + task index |
| `docs/roadmap.md` | M2 / C9 pointer |
| `docs/INDEX.md` | product-spec link |
| optional minimal cross-links | packaging / cli / headless only if needed for single truth |

## Later implementation paths (NOT this node)

| Path | Role |
|------|------|
| `packages/zag-tui/**` **or** `packages/zag-cli/src/tui/**` | host UI (see module §1.2) |
| root / package `build.zig` / `build.zig.zon` | `-Dtui=true` optional wiring + lazy terminal dep |
| `packages/zag-cli/src/cli.zig` | `--tui` mode mutex + wiring |
| tests under TUI package / CLI | §10 fixture matrix |
| **forbidden for impl without new task** | Core lifecycle/schema changes; headless-v1 field adds; maturity raise |

# contract summary

Authoritative detail lives in [tui-minimal.md](../../modules/tui-minimal.md).
Do not restate conflicting rules here.

### Frozen choices (index)

| Topic | Freeze |
|-------|--------|
| Ownership | All UI state in host shell; coding-agent owns product policy/session/Trace/lifecycle; Core stays thin loop |
| Data sources | Lifecycle for run/tool/control/terminal; optional `Observer.assistant_text` only for progressive text; **no** invented `message_delta`/`tool_update` |
| assistant_text fact | Currently complete assistant body at message time — **not** provider token delta |
| Terminal truth | Only `run_terminal` / reply error; UI drop ≠ completed success |
| Layout | Status + card ring + editor + permission modal; constrained/closed variants |
| Editor caps | 64 KiB bytes, 512 lines; history 64 × 8 KiB process-only |
| Keys | Enter submit; Alt+Enter/Ctrl+J newline; Esc/EOF deny on modal; Ctrl+C = cli-interaction; Alt+S/F control enqueue |
| Session identity | CLI path + open mode + `run_start.session_configured` + `Session.path`; no forged resume |
| Permission | default ask; TUI `AskFn` fail-closed; yolo explicit only; jail/shell intact |
| Redaction | copy in callback to bounded host buffers; fail-visible; no stdout pollution |
| Build | `-Dtui` default false; no Kernel TUI import; no silent mode fallback |
| Non-goals | theme/dashboard/images/RPC/ACP/E2–E3 UI/OS sandbox/schema/maturity/Pi parity |

# verification (contract track — this node)

- [ ] Independent **architecture / ownership** contract review **PASS**
- [ ] Independent **safety / fail-closed** contract review **PASS**
- [ ] `python3 scripts/lint_docs.py`
- [ ] `python3 scripts/score_docs.py --check`
- [ ] `git diff --check`
- [ ] Diff contains **only** expected docs (+ quality reports if scores/file count change; timestamp-only restored)
- [ ] Confirm **no** `packages/`, `src/`, `build.zig*` product changes in this commit
- [ ] C9 product acceptance checkboxes remain **unchecked** for implementation
- [ ] No maturity raise; no “TUI implemented” / current-tip Linux claim

# verification (implementation track — later; blocked)

- [ ] Full matrix in [tui-minimal.md §10](../../modules/tui-minimal.md)
- [ ] Independent code review PASS
- [ ] Candidate + merged-main dual-backend Gates (std + curl) recorded on that tip
- [ ] Kernel import scan green; plain/headless unchanged
- [ ] Still no schema/maturity inflation unless a separate explicit Gate says so

# non-goals (both tracks unless a later task reopens)

- Theme / dashboard / images / plugin platform
- RPC / ACP / editor host
- E2/E3 extension UI
- OS sandbox; multi-file edit platform
- Core or session-v1 / Trace-v1 / headless-v1 schema changes
- Maturity promotion (Tools write/edit L3, Runtime Extensions > L0, etc.)
- Pi API or TUI parity; wholesale vaxis port
- This contract node adding packages, dependencies, or product code

# lineage (tips)

| Stage | Tip |
|-------|-----|
| Contract candidate (this docs freeze) | task branch tip with message `docs: freeze minimal TUI contract` |
| Contract PASS record | pending independent reviews |
| Implementation | blocked |
| Closeout | blocked |
