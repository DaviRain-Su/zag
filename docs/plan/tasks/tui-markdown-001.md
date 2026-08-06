---
id: tui-markdown-001
scope: tui/markdown-render
status: implemented — fixtures green, benchmark decision recorded, matrices green
priority: P1
depends-on:
  - tui-vaxis-001
  - tui-streaming-001
---

# objective

Render assistant output as **formatted Markdown** in the TUI transcript
(currently raw markdown source text is shown). Vendored **koino** (MIT,
GFM-100%, Comrak's Zig port, AST output) parses; a new renderer walks the
AST into vaxis cells (headings, bold/italic/inline-code/links, fenced code
blocks, lists, blockquotes, rules); the streaming delta path re-renders
incrementally; assistant cards upgrade from a 120-char preview to
multi-line rendered blocks.

**Binding:** this task. Reference architecture (direction only): hyper
`StreamingMarkdownRenderer` checkpoint model; `xai-grok-markdown` buffers
(Highlight/Replace/Transform).

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented** — independent review not yet done |
| Implementation | fixtures (parse/block/inline/streaming/transcript/redaction/fallback/regression), benchmark, four matrices, evidence — see below |
| Maturity | **unchanged** — no row add/raise |
| PTY marker contract | `state:{s}` contiguous, ISIG, 1049h/l, geometry exit — unchanged |
| Session v1 / Trace v1 / headless-v1 / Core | unchanged |

# measure-first benchmark decision (2026-08-06)

Measured in the test build (Debug, M3 Pro) with the real paint-path body sizes
(`md_render.zig` `md benchmark` fixture, 50 iters after warmup):

| Body | Parse + render per frame |
|------|--------------------------|
| 4096 B (the streaming delta cap — the LARGEST body a paint ever renders) | **0.96 ms** |
| 8192 B (contract's generous upper bound) | 1.8–2.0 ms |

**Decision: full re-parse per paint stands — no render throttle/checkpoint in
v1.** The realistic per-frame cost (the 4 KB delta-cap body) is 0.96 ms,
comfortably under the 2 ms contract boundary. The 8 KB figure (which exceeds
the product's 4 KB body cap) hovers at the boundary in Debug only; a
ReleaseFast build (production optimize) is expected sub-ms. If a future
measurement at the real cap crosses 2 ms, the contract's throttle
(re-render md at most every 50 ms while deltas are active) is the follow-up.

# context

- Assistant output streams as `assistant_delta` chunks into a progressive
  card; the transcript shows title + ≤120-char body preview (render.zig
  drawCards) — raw markdown syntax (`**`, `#`, `` ``` ``) is visible.
- vaxis provides `printSegment` grapheme wrap, `Cell.Style` attributes
  (bold/italic/dim/strikethrough), and `Cell.link` (OSC 8 hyperlinks).
- koino: MIT (vendored candidate at /tmp/koino, 4709 src lines, GFM-100%,
  `parse(allocator, md, options) !*AstNode` + nodes.zig AST).
- zigmark is PolyForm Noncommercial — NOT usable (zag provenance rule).

# path

| Path | Role |
|------|------|
| `packages/third_party/koino/` | vendored koino (MIT, provenance note + exact source record) |
| `packages/zag-tui/src/md_parse.zig` | koino wrapper: parse + node→span walk (allocation-light, arena) |
| `packages/zag-tui/src/md_render.zig` | AST → vaxis cells: block walk + inline walk (styles, wrap, link cells, code block tint) |
| `packages/zag-tui/src/render.zig` | assistant/user card body rendering uses md_render (multi-line, clipped); other cards unchanged |
| `packages/zag-tui/src/app.zig` | streaming delta path: re-render cadence (throttled re-parse of the accumulated buffer); keep card identity rules |
| `packages/zag-tui/build.zig` + zon | koino module wiring |
| Forbidden | zag-agent-core, zag-coding-agent, zag-cli production, Session v1, Trace v1 |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Parser | vendored koino (MIT) — exact commit recorded in provenance; NOT modified (stock). Parse failures (invalid/malformed) → plain-text fallback (raw source shown) — never crash, never blank |
| Render scope v1 | blocks: ATX headings (h1-h6 → bold + accent color, h1 largest visual via double-bold or accent), paragraphs (grapheme wrap via printSegment), fenced code blocks (dim/bg tint, no highlight), lists (unordered `• ` + 2-space indent, ordered `1. `), blockquotes (`│ ` prefix + muted), thematic breaks (`─` fill); inline: **bold**, *italic*, `inline code` (dim bg tint), [links](url) (Cell.link + accent), ~~strike~~ (strikethrough); GFM tables → v1 plain-text rows (aligned best-effort) |
| Styles | md roles reuse existing theme palette: headings accent_fg, code dim/muted, blockquote muted_fg, links accent_fg + link cell; NO new theme roles in v1 (theme.md role set stays frozen) |
| Streaming | delta accumulation unchanged (4096-cap buffer, UTF-8-safe, card identity); render cadence: re-parse + re-render the assistant card body on each paint IF the buffer changed since last render; full re-parse per change (measure first — 8KB parse is expected sub-ms; if >2ms per frame, add a checkpoint that freezes closed blocks). No checkpoint in v1 unless measurement demands it |
| Transcript | assistant + user cards render body via md_render (multi-line, clipped to region height, scroll via existing window); tool/terminal/host_error cards unchanged (single title rows) |
| Fallback | malformed markdown, parse OOM, or unsupported constructs → raw text of the failing region (or whole body) — never blank, never crash; redaction runs BEFORE md rendering (rendered from the redacted buffer) |
| Links | Cell.link set for inline links (OSC 8) when present; link text = visible text, URL in link field; no click handling in v1 (terminal emulator handles) |
| Constrained mode | unchanged (3-line minimal; no md render) |
| Divergence from reference | no syntax highlighting (v1), no streaming checkpoints (unless measurement demands), no HTML rendering, no GFM task-list/table fancy rendering, no markdown in user cards beyond the existing body preview upgrade |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Parse | koino parse of heading/paragraph/list/code/quote/link/bold/italic/strike inputs → expected AST walk output (span sequence); malformed input → fallback raw text; empty → empty |
| Block render | cells for each block type at known widths: h1 accent+bold, paragraph wrapped at width, code block tinted lines (no wrap loss), list bullets/indent, quote prefix, hr fill |
| Inline render | bold/italic/code/link/strike cell attributes; link cell carries URL; mixed inline in one paragraph |
| Streaming | delta sequence → re-render on paint; card identity rules intact (progressive prefix); final render equals one-shot render of the accumulated text |
| Transcript | assistant card renders multi-line md clipped to region height; user card body preview rendered; tool rows unchanged |
| Redaction | secret inside markdown (e.g. in a code block) redacted before render; redacted text never re-rendered from raw |
| Fallback | koino parse failure → raw text shown; OOM → raw text; no crash |
| Regression | all TUI gates + PTY markers + default/curl matrices green |

### Gate

- task Gate + merged-main Gate (default + TUI matrices, std + curl); no
  maturity raise.

# non-goals

- Syntax highlighting (no tree-sitter/syntect equivalent in v1)
- Streaming checkpoints unless measurement demands
- Clickable link handling beyond Cell.link
- GFM task lists, tables (beyond plain-text), footnotes, HTML passthrough
- Theme role expansion (frozen role set)
- Markdown for tool cards / overlays / modal

# related

- [tui-streaming-001](./tui-streaming-001.md) · [tui-vaxis-001](./tui-vaxis-001.md)
- Reference: hyper `xai-grok-markdown` (streaming checkpoints, buffers) —
  direction only
