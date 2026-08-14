---
id: tui-model-picker-001
scope: host-shell/tui-model-picker (M2 / C9; no maturity row)
status: in-progress
priority: P1
depends-on:
  - tui-slash-host-001
  - tui-minimal-001
---

# objective

Fix the `/model` overlay so that, after a user configures API keys for
multiple providers, the picker lists **every catalog model from every
configured provider** — instead of being dominated by the current
provider's live `/models` response ("mostly DeepSeek"). Then add a
pi-style **user model manifest** (`models.json`) so models the built-in
catalog does not carry (Ollama local, vLLM, proxies) can be declared and
shown when the provider's auth is configured.

**Binding specification:** [tui-model-picker.md](../../modules/tui-model-picker.md).

Reference: pi `docs/models.md` — `/model` is catalog-driven (built-in +
`~/.pi/agent/models.json`), availability = auth presence, **no** live
`/models` probe per launch. Zag keeps its own wire/CLI; this is semantic
alignment, not API parity (D-009).

# problem (HEAD `73e4d95`)

`collectTuiModelPicker` (`packages/zag-cli/src/tui_entry.zig`) assembles the
list in this order:

1. `registry.listConfigured` → providers whose env key is set (DeepSeek first).
2. per configured provider → `catalog.listForProvider` → static catalog (1–6 each).
3. `wp.listModels` → **only the current provider's** `GET /models` (≤64), all
   tagged with the current provider's name.
4. the current model.

Two hard caps both = **24**: `tui_picker_cap` (collection) and
`overlay_line_bufs` (render). `drawHostOverlay` renders top-N with **no
scroll window**, so rows beyond the box height are unreachable.

Effect: when the current provider is DeepSeek, step 3 injects a flood of
DeepSeek live ids on top of the 3 catalog entries, while other configured
providers only contribute their sparse catalog (many have 1 entry). The 24-row
cap then truncates the rest. Result: "配了各家的 Key，TUI 大部分是 DeepSeek".

# fix (two waves)

## Wave A — catalog-driven picker + caps + scroll (the bug fix)

| Change | File |
|--------|------|
| Drop the `wp.listModels(...)` block from `collectTuiModelPicker`; keep catalog-for-each-configured-provider + current-model fallback | `packages/zag-cli/src/tui_entry.zig` |
| Raise `tui_picker_cap` 24 → 96 | `packages/zag-cli/src/tui_entry.zig` |
| Raise `overlay_line_bufs` / `overlay_line_ptrs` / `resume_row_kinds` 24 → 96 | `packages/zag-tui/src/app.zig` |
| `drawHostOverlay`: render a cursor-centered viewport (top offset) instead of top-N, so all rows are reachable | `packages/zag-tui/src/render.zig` |
| Update overlay module truth (live `/models` no longer feeds the picker) | `docs/modules/tui-slash-host.md` |

`WireProvider.listModels` is **kept** for a future `/models refresh` /
`--list-models`; it is just no longer called on every TUI launch.

## Wave C — user model manifest (`models.json`)

| Change | File |
|--------|------|
| New parser `models_file.zig`: `~/.zag/models.json` (user) + `.zag/models.json` (project, wins) | `packages/zag-ai/src/models_file.zig` |
| Merge user providers into the picker: list a user provider's models when its auth (env key or manifest `api_key`) is configured | `packages/zag-cli/src/tui_entry.zig` |
| CLI resolves `$HOME/.zag/models.json` root and passes it through | `packages/zag-cli/src/cli.zig` |
| Module contract | `docs/modules/tui-model-picker.md` |

Schema (minimal, pi-aligned):

```json
{
  "providers": {
    "my-ollama": {
      "name": "Ollama (home server)",
      "base_url": "http://192.168.1.10:11434/v1",
      "api": "openai_compat",
      "api_key": "$OLLAMA_API_KEY",
      "models": [ { "id": "qwen2.5-coder:7b" }, { "id": "deepseek-v4-flash:0731" } ]
    }
  }
}
```

`api_key` supports `$ENV` / `${ENV}` / literal (same resolution rules as pi).
A provider id that matches a builtin preset **extends** that preset's catalog
(upsert by model id); a new id adds a new provider row. No auth configured →
models load but stay absent from the picker (pi parity).

# path

| Path | Role |
|------|------|
| `docs/plan/tasks/tui-model-picker-001.md` | this task |
| `docs/modules/tui-model-picker.md` | **binding truth** |
| `docs/modules/tui-slash-host.md` | overlay row updated (live `/models` removed) |
| `docs/INDEX.md` · `docs/roadmap.md` | pointers |
| `packages/zag-cli/src/tui_entry.zig` | picker builder + cap |
| `packages/zag-tui/src/app.zig` | overlay buffer caps |
| `packages/zag-tui/src/render.zig` | overlay scroll viewport |
| `packages/zag-ai/src/models_file.zig` | manifest parser (Wave C) |
| `packages/zag-cli/src/cli.zig` | user models root wiring (Wave C) |

# contract summary

Authoritative detail in [tui-model-picker.md](../../modules/tui-model-picker.md).

| Freeze | Choice |
|--------|--------|
| Picker source | catalog for every configured provider + user manifest; **no** live `/models` on launch |
| Caps | collection + render buffers = 512; overlay box height stays small via scroll viewport |
| Scroll | cursor-centered viewport; ↑↓/PgUp/PgD/Home/End reach every row |
| Manifest paths | `$HOME/.zag/models.json` (user) + `.zag/models.json` (project wins); reload each `/model` open |
| Manifest auth | env key of matched preset, or manifest `api_key` (`$ENV`/literal); no auth → absent |
| Maturity | **no row add/raise**; TUI has no maturity row; Runtime Extensions stays L0 |
| Non-goals | live `/models` in picker; OAuth; model metadata beyond id/name in v1; per-model cost/compat in manifest v1; maturity raise |

# verification

- [x] Wave A: `collectTuiModelPicker` has no `wp.listModels` call; multi-provider fixture shows all catalog models
- [x] Wave A: cap 96 fixture — a configured set of >24 catalog models all appear and are reachable
- [x] Wave A: overlay scroll — cursor past box height still renders the focused row
- [x] Wave C: `models_file.zig` parse + auth-resolution unit tests
- [x] Wave C: a user manifest provider with auth appears; without auth it does not
- [ ] `zig build test` green (std + curl); docs lint; no maturity row change
- [x] `docs/modules/tui-slash-host.md` overlay row updated

# non-goals

- Live `/models` in the picker (kept on WireProvider for later `/models refresh`)
- OAuth / interactive login
- Per-model cost / context_window / compat fields in manifest v1 (later)
- Raising any maturity row or adding a "TUI L2" row
- Pi API/CLI/schema parity (D-009)
- Changing Core / Session v1 / Trace v1 / headless-v1 schemas