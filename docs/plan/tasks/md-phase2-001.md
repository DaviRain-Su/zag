---
id: md-phase2-001
scope: tui/markdown-phase2
status: implemented
priority: P1
depends-on:
  - tui-markdown-001
---

# objective

Markdown phase 2: syntax-highlight fenced code blocks and give GFM
tables a real header row. Both are pure `md_render.zig` rendering
upgrades — no new AST handling (koino already parses `info` fences,
`TableRow: Header/Body`, `TableAlignment`), no layout/scroll changes
(row counts stay identical: highlighting is per-token styling, tables
keep one row per source row).

# status truth

| Track | Status |
|-------|--------|
| Contract | **contract-approved** — independent review absorbed; implemented AS WRITTEN (note: `zig` resolves to its own table — the v1 table lists zig separately; `rs→rust` is the rust alias) |
| Implementation | **implemented** — tokenizer + language tables + `renderCode` per-token wiring + table header bold + alignment padding, all in `md_render.zig`; fixtures: tokenizer (keywords/comments/strings/numbers/CJK/escapes), render (fences/plaintext/default/indented), table (bold header, right/center padding), measure parity, benchmark. 4 matrices green; PTY 14/14. md_bench: cap 926→929us/frame, 8KB 1785→2042us/frame (guard 50ms green) |
| Theme contract | unchanged — highlight colors DERIVE from existing roles (no new roles; theme.md role set frozen) |
| MD row counts | unchanged (measure mode parity: same rows with/without highlighting) |
| Session v1 / Trace v1 / PTY | unchanged |

# context

- `renderCode` (md_render.zig:304-332) renders every line in one
  `ctx.style.code` segment; `NodeCodeBlock.info` carries the fence
  language (koino nodes.zig:176-183).
- `renderTable` (md_render.zig:362-416) renders all rows with
  `ctx.style.base`; koino produces `.TableRow = .Header` for the header
  row (table.zig:118) and DROPS the `|---|---|` separator row — nothing
  to skip.
- Cell writes go through `writeSeg`/`putCell` (measure-safe no-op);
  syntax highlighting needs a per-line multi-segment writer with the
  same discipline.

# path

| Path | Role |
|------|------|
| `packages/zag-tui/src/md_render.zig` | highlight module (tokenizer + language tables), renderCode wiring, table header styling |
| `packages/zag-tui/src/theme.zig` | no change (roles derived at render time) |
| Forbidden | theme.md role changes, koino changes, row-count changes, layout/scroll changes |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Scope | fenced code blocks ONLY (indented code blocks render plain — rare in AI output); tables get a bold header row |
| Highlight colors | derived from EXISTING roles: keyword → `accent_fg`, string → `editor_fg`, comment → `muted_fg`, number → `status_fg`; base stays `code`. `MdStyle` gains keyword/string/comment/number fields, populated in `MdStyle.forCard` via `palette.style(.editor_fg)/.status_fg` etc. (theme.zig:95-97 pub API). No theme file/role changes (theme.md:258 accent_fg scope note acknowledged — keyword highlighting reuses a non-secret rendered text role) |
| Tokenizer | single-pass, allocation-free, per line, codepoint-wise (never splits a UTF-8 codepoint): strings (`"…"`, `'…'`, backtick) with ESCAPED DELIMITER handling (`"a\\"b"`, `'it\\'s'`, backticks inside bash `$()`), line comments (`//`, `#`, and `--` ONLY for languages that enable it), block comments (`/* */` for C-family, line-local: an unterminated `/*` styles the rest of the line), numbers (decimal/hex/floats), identifiers matched against the language's keyword set, everything else base. Tokens slice the ORIGINAL line (arena-backed) — no temp buffers |
| Language tables | v1 subset: zig, rust, python, javascript/typescript, bash, json, yaml, toml, markdown, plaintext (no highlight), plus a DEFAULT fallback (strings/numbers only — `--` line comments are NOT in the default because it mis-colors `--flag`; `//` and `#` comments only for languages whose table enables them). Language from `info`'s first word, lowercased, aliases mapped (zig/rs→rust, js/ts→javascript, py→python, sh/bash→bash, yml→yaml); **info == null or empty → plaintext (no highlight)** — bare ``` is the most common fence; non-empty unknown word → DEFAULT |
| Table header | the `.TableRow = .Header` row renders with `base` + bold; alignment from `Table` alignments applies to ALL rows: right-aligned columns pad left, centered columns pad both sides, left/none pad right — pure padding math on the measured widths (already computed) |
| Measure parity | highlighting must not change row counts or wrap behavior (code lines still clip, tables still one row per source row) — the md benchmark + existing md fixtures must pass unchanged |
| Performance | tokenizer O(line) per line; benchmark guard stays (4KB ≈ 1ms; re-run and record) |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Tokenizer | per-language keyword hits; string/comment/number extraction; UTF-8 boundary (CJK identifiers, multi-byte strings); escaped delimiters (`"a\\"b"`, `'it\\'s'`, backtick in `$()`); block comment spanning (unterminated `/*` styles the rest of the line) |
| Render | zig/rust/python code fences → keyword/string/comment/number cells carry the derived fg indices; bare fence (null info) → PLAIN (no highlight); unknown language word → default (strings/numbers only); indented code block → plain |
| Table | header row bold cells; right-aligned column padding direction; centered padding; one row per source row (count parity) |
| Measure | measure mode row counts identical with and without highlighting (the settle/scrollback heights never drift) |
| Benchmark | 4KB render stays ≈1ms (record before/after) |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Full language grammars (one-line tokenizer only), multi-line block
  comments (line-local), syntax-aware line wrapping, theme role changes,
  koino changes

# related

- [tui-markdown-001](./tui-markdown-001.md) · [tui-scrollback-001](./tui-scrollback-001.md)

# closeout

- Commit: `ab6f86b` (zag-tui: fenced-code syntax highlight + bold table headers (md-phase2-001)) — code commit; closeout line lands as a doc-only follow-up.
