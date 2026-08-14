---
status: active
scope: host-shell TUI /model picker + user model manifest
task: tui-model-picker-001
prerequisite:
  - tui-slash-host-001
  - tui-minimal-001
---

# TUI model picker (catalog-driven + user manifest)

Authoritative binding for **tui-model-picker-001**. Host-shell only
(`packages/zag-tui` + `packages/zag-cli` + `packages/zag-ai` manifest
parser). No Core / Session / Trace / headless schema change. No maturity
row. Pi: **semantic reference, not API parity** (D-009).

## Problem this fixes

The `/model` overlay previously called `WireProvider.listModels` (live
`GET /models`) for the **current provider only** and appended all returned
ids under that provider's name. When the current provider was DeepSeek,
its live ids flooded the list on top of the 3 catalog entries, while other
configured providers contributed only their sparse static catalog (many
have 1 entry). A 24-row collection cap + a 24-row render buffer with no
scroll window then truncated the rest — so after configuring several
providers' API keys the picker still showed "mostly DeepSeek".

## Wave A — picker source contract

### A1. Picker source

`collectTuiModelPicker` builds the list from, in order:

1. `registry.listPickerProviders` → every provider whose env key is set,
   plus keyless local Ollama (builtin preset order; DeepSeek first).
2. for each available provider → `catalog.listForProvider` → **all** that
   provider's catalog models (display `Name  ·  catalog name`; key
   `spec\x1fmodel`). Catalog rows are seeded from models.dev (same feed
   Pi uses) plus Zag-only extras such as local Ollama.
3. auth-gated `models.json` models (Wave C): extend a matching builtin by
   id (manifest wins on collision) or add a new provider row.
4. a guaranteed row for the current `(spec, model)` if not already present.

**Removed:** the `wp.listModels(...)` block that appended the current
provider's live `/models` ids. `WireProvider.listModels` is retained for a
future `/models refresh` / `--list-models`; it is not called on TUI launch.

### A2. Caps

| Buffer | Old | New |
|--------|-----|-----|
| `tui_picker_cap` (collection) | 24 | 512 |
| `overlay_line_bufs` (render) | 24 | 512 |
| `overlay_line_ptrs` (render) | 24 | 512 |
| `resume_row_kinds` (render) | 24 | 512 |

The overlay **box height** stays small (`@min(24, …)`); reachability comes
from the scroll viewport (A3), not a taller box.

### A3. Overlay scroll viewport

`drawHostOverlay` renders a cursor-centered window over `ov.lines`:

- `top = clamp(cursor - viewport_h/2, 0, max(0, lines.len - viewport_h))`
- render `ov.lines[top .. top + min(viewport_h, lines.len - top)]`
- the cursor marker (`> `) is drawn on the row at `cursor - top`

↑↓ move the cursor (existing wrap behavior); the viewport follows so the
focused row is always visible. PgUp/PgD/Home/End continue to work; they
already mutate `overlay.cursor`, and the viewport derives from it.

## Wave C — user model manifest

### C1. Paths + reload

| Path | Precedence |
|------|------------|
| `.zag/models.json` (project, cwd-relative) | wins |
| `$HOME/.zag/models.json` (user) | base |

Project entries upsert over user entries by provider id. The manifest is
re-read each time `/model` opens (no restart), mirroring pi's `models.json`
reload. Missing files / missing `$HOME` are not errors.

### C2. Schema (v1, minimal)

```json
{
  "providers": {
    "<provider-id>": {
      "name": "Optional display name",
      "base_url": "https://…",
      "api": "openai_compat | anthropic_messages",
      "api_key": "$ENV_VAR | ${ENV_VAR} | literal",
      "models": [
        { "id": "model-id", "name": "Optional label" }
      ]
    }
  }
}
```

Only `providers.<id>.models[].id` is required. Unknown fields are ignored
(v1 does not parse per-model cost/context_window/compat — those stay
catalog-only for now).

### C3. Auth + availability

A manifest provider's models appear in the picker iff its auth resolves:

- If `<id>` matches a builtin preset → use that preset's `env_keys`
  (existing `auth_env.resolveApiKeySource`).
- Else → resolve `api_key` (`$ENV`/`${ENV}`/literal). Unresolved env → no
  auth → models absent (pi parity: "models load but stay unavailable").

No auth configured ⇒ the provider's models are **not** listed. This is
fail-closed: a misconfigured manifest never silently sends requests to an
unauthed endpoint.

### C4. Merge semantics

- A manifest provider id that matches a builtin preset **extends** that
  preset's catalog: manifest models are upserted by `id` (manifest wins on
  id collision).
- A new id adds a new provider row. Selecting it builds a wire from the
  manifest's resolved `base_url` / `api` / `api_key` (same fail-closed
  auth as listing). Builtin ids still switch via `registry.resolvePreset`.

## Non-goals

- Live `/models` in the picker.
- OAuth / interactive login.
- Per-model cost / context_window / compat / thinkingLevelMap in manifest v1.
- Raising any maturity row; adding a "TUI L2" row.
- Pi API/CLI/schema parity (D-009).
- Core / Session v1 / Trace v1 / headless-v1 schema changes.

## Related

- [tui-slash-host.md](./tui-slash-host.md) — overlay row updated by this task
- [tui-minimal.md](./tui-minimal.md) · [tui-vaxis.md](./tui-vaxis.md)
- Task: [tui-model-picker-001](../plan/tasks/tui-model-picker-001.md)