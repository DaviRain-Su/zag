---
id: tui-model-settings-001
scope: host-shell/tui-model-settings
status: done
priority: P1
depends-on:
  - tui-slash-host-001
---

# objective

Model picker + settings overlays on host catalog/config labels.

**Binding (shared overlay shell):** [tui-slash-host.md](../../modules/tui-slash-host.md)

| Surface | Behavior (v1) |
|---------|----------------|
| `/model` | List `Name  ·  model` rows for every env-keyed provider (catalog + current-host live `/models`); select updates host `model_label` and rebinds the wire when the provider changes |
| `/settings` | Read-mostly: perm / shell / model / theme labels |
| `/theme` | Builtin + user theme ids under `$HOME/.agents/themes` |

# non-goals

Ask-mode mutation; Pi provider plugins; effort/cloud sync; maturity raise.
