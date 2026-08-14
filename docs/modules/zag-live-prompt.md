# zag-live-003 — coding-agent live prompt surface

> Binding draft for [zag-live-003](../plan/tasks/zag-live-003.md)
> (D-014 Route A — first product surface).
> Depends on [zag-live.md](./zag-live.md) and
> [zag-live-provider.md](./zag-live-provider.md).
>
> **Status:** **draft** — docs-only. No product code until dual review
> PASS. Flag/config off must be byte-stable vs today's static prompt.

## 1. Purpose

Make system-prompt / policy construction a kernel-tracked live binding
when the operator opts in. The image can redefine that binding at
runtime; journal + generations give audit and rollback. When the image
is disabled, dead, or Chez is missing, the Agent uses the **current
static** prompt path unchanged.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| `zag-coding-agent` | Flag/config; construct `Live` + optional provider bridge; call into the prompt binding; fall back | Core types for live/Chez/PID |
| `zag-live` | Image lifecycle, journal, generations | Product policy of *which* surface is live |
| `zag-cli` / `zag-tui` | Thin flag routing only | Prompt assembly |

## 3. Invariants

1. **Opt-in.** Default off. Off → today's `base_system` / project layers
   byte-identical (no extra Live init).
2. **Degradable.** Chez missing, boot probe fail, image death mid-run →
   static default for that surface. Must not fail the Agent init of the
   base product.
3. **One surface.** v1 is prompt construction only. Tool registry /
   memory policy / input vault are later tasks.
4. **No Core changes.** Loop still receives a projected `ContextView`.
5. **No schema change.** Session v1 / Trace v1 / headless-v1 unchanged.
   Live journal lives under the Live `state_dir`, not `.zag/sessions/`.
6. **Ask remains default.** Live prompt cannot widen ToolPolicy / Jail /
   ShellPolicy.

## 4. Config sketch (not a flag freeze until review)

```text
.zag/config.json  "live": { "enabled": false, "state_dir": ".zag/live" }
# or env ZAG_LIVE=0|1
```

Exact key names freeze at review. `--yolo` must not imply live-on.

## 5. Tests (when implemented)

| # | Class | Expect |
|---|-------|--------|
| 1 | Flag off | no Chez spawn; prompt bytes equal current static |
| 2 | Chez missing | surface off; Agent still inits |
| 3 | Flag on + redefine | next turn uses new prompt; journal has `redefine` |
| 4 | SIGKILL + replay | committed prompt restored |
| 5 | Image down mid-run | that turn falls back to static; no hang |
| 6 | Ownership | Core has no zag-live symbols |

## 6. Non-goals

- Route B (loop in the image)
- TUI chrome for live inspect (later)
- Maturity row
- Enabling live in docs/demos by default

## Related

- [zag-live.md](./zag-live.md) · [zag-live-provider.md](./zag-live-provider.md)
- [D-014](../decisions/active/D-014-live-runtime-productization-route-a.md)
- [context-compaction.md](./context-compaction.md)
