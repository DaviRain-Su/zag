---
status: active
scope: host-shell TUI slash + overlay binding
task: tui-slash-host-001
prerequisite:
  - tui-vaxis-001
  - theme-001
---

# TUI slash host (overlay + submit routing)

Authoritative binding for **tui-slash-host-001**. Host-shell only
(`packages/zag-tui` + thin CLI wire). No Core / Session schema / Trace /
headless change. Pi/Comet: **semantic reference, not API parity** (D-009).

## Goal screen (single column)

```text
header / transcript / composer
overlays: none | help | slash_palette | settings | model | theme
```

Esc closes overlay. ↑↓/Enter navigate lists. Permission modal still preempts
overlay key handling when pending.

## Overlay state machine

| Kind | Opens via | Content (v1) |
|------|-----------|--------------|
| `help` | `/help` or palette | Builtin + skill/template hints |
| `slash_palette` | composer text starts with `/` | Filtered builtins as `/name   hint` (+ note skill/template forms) |
| `settings` | `/settings` | Read-mostly: perm/shell/theme/model labels |
| `model` | `/model` | Catalog-driven picker: every configured provider's catalog + user manifest models (auth-gated); **no** live `/models` on launch; select switches provider+model. See [tui-model-picker.md](./tui-model-picker.md) |
| `theme` | `/theme` | Built-in + user theme ids; select reloads palette fail-closed |

## Slash routing (submit)

Precedence on Enter (idle):

1. Exact `/skill:` → coding-agent `expandSkillActivation` (same as CLI).
2. Known `/name` template → `expandTemplate` when catalog hit.
3. Bare builtin `/help` `/settings` `/model` `/theme` → open overlay (no reply).
4. Else raw prompt → reply worker.

Forbidden: second skill parser; Core types for slash; vxfw widgets.

## Non-goals

Maturity raise; ask-mode mutation without separate safety Gate; Comet sidebar.

## Related

- [theme.md](./theme.md) · [skills.md](./skills.md) · [prompt-templates.md](./prompt-templates.md)
- [tui-transcript.md](./tui-transcript.md) · [gap](../plan/analysis/2026-08-06-tui-canvas-grok-gap.md)
- Task: [tui-slash-host-001](../plan/tasks/tui-slash-host-001.md)
