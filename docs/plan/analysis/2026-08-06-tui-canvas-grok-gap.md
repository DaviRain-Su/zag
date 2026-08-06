# TUI canvas vs Grok/Comet gap (2026-08-06)

> Host-shell analysis after vaxis backend landed @ `76360ab`.
> Architecture direction only — **not** Comet/Pi API or product parity (D-009).
> Delivery route: Theme → slash/overlay → transcript → model/settings.

## Question

How should Zag's `--tui` grow from a minimal card shell into a daily-driver
canvas (slash, settings, model pick) without importing Comet's sidebar/daemon
or Pi's TypeScript TUI?

## Local evidence

| Project | Snapshot | Used as |
|---------|----------|---------|
| Zag | this tree @ vaxis tip | current header/cards/editor/modal + streaming |
| Hyper / Grok Build Comet TUI | `/Users/davirian/orca/hyper-grok-build/desktop/comet/crates/tui` | overlay menus, theme fills, transcript cache, composer meta |
| Pi / pi-mono-zig | references + `pi-mono-zig` interactive_mode | Theme tokens, `/model`, slash expansion semantics |

## Target Zag v1 screen (single column)

```text
┌─ header: id / perm / shell / state:{s} ─────────────┐
│ transcript (scroll; tool/assistant/user blocks)     │
│ …                                                   │
├─ working strip (busy / cancel hint) ────────────────┤
│ composer (multiline)                                │
│ meta: model · theme · hints     [/ opens palette]   │
└─────────────────────────────────────────────────────┘
     overlays: help | model | settings | slash match
```

**Out of v1:** Spaces sidebar, detached daemon engine, cloud/DeviceRoom, mouse-
first hit testing, desktop Changes pane, vxfw wholesale widgets.

## Gap matrix

| Capability | Zag now | Comet/Pi reference | Selected Zag direction |
|------------|---------|--------------------|------------------------|
| Terminal backend | vaxis quarantined ✅ | ratatui / vaxis | keep quarantine; no vxfw |
| Theme / role colors | 3 hard-coded styles | Comet theme ramp; Pi Theme files | **theme-001 impl** (contract ready) |
| Slash in TUI | CLI REPL only | Comet overlays; Pi slash | **tui-slash-host** overlay + reuse skill/template expand |
| Model picker | none in TUI | Comet `Overlay::Models` | catalog-backed picker; no custom-provider plugin parity |
| Settings | none | Comet menus | read-mostly overlay (theme, labels); ask-mode flips need safety Gate |
| Transcript scroll | short card ring | cached wrap + visible window | **tui-transcript** scroll region |
| Streaming | progressive card ✅ | stream collapse to one draw | keep `assistant_delta` path |

## Dependency order

1. Theme paint on existing geometry. ✅
2. Overlay state machine + slash palette + TUI submit routing. ✅
3. Transcript scroll canvas. ✅
4. Model picker + settings (may share overlay shell from step 2). ✅

Canvas track landed on branch `task/tui-canvas-grok` (worktree `.worktrees/tui-canvas-grok`).

## Non-goals

- Maturity raise; Session/Trace/headless schema change; Core Theme/slash types.
- Pi release parity; Comet daemon attachment model.
