# Review: lsp-001 — architecture / ownership (closeout)

- Task: [lsp-001](../tasks/lsp-001.md)
- Binding: [lsp.md](../../modules/lsp.md)
- Code: `runtime/code_intel_tool.zig` + `runtime/lsp/`
- Track: Wave 2 closeout (architecture)
- Result: **PASS**

## What holds

- Owner is `zag-coding-agent`. No Core LSP / process / pipe types.
- Model-visible surface is one Tool `code_intel` (hover / definition /
  references / diagnostics). Results are text bodies, not UI overlays.
- Persistent per-workspace-root child; killed on `Agent.deinit`.
- **Documented exception:** the client owns its spawn until
  [process-supervisor-long-lived-001](../tasks/process-supervisor-long-lived-001.md).
  Wave 1 v1 (foreground `runForeground`) cannot host zls.

## Known exception (binding §12 Q2)

- Env allow-list `{PATH, HOME, LANG, LC_*, ZLS_*}` is **not** enforced.
  v1 inherits the parent env (`environ_map = null`). Hardening TODO; not
  a closeout blocker.

## Decision

**PASS** — closeout. No maturity row. Class 16 (real zls smoke) remains
deferred when zls is absent.
