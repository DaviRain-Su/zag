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
| `/model` | List catalog ids from CLI `HostResourceOptions.model_ids`; select updates host `model_label` (display; wire resolve stays process-scoped) |
| `/settings` | Read-mostly: perm / shell / model / theme labels |
| `/theme` | Builtin + user theme ids under `$HOME/.agents/themes` |

# non-goals

Ask-mode mutation; Pi provider plugins; effort/cloud sync; maturity raise.
