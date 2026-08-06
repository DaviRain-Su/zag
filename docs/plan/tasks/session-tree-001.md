---
id: session-tree-001
scope: tui/session-tree
status: implemented
priority: P2
depends-on:
  - session-resume-tui-001
  - session-swap-001
---

# objective

Turn `/resume` into a **session browser with grouping and metadata**:
sessions under a PINNED root, grouped by the project subdirectory when
the user created nested `-s` sessions (default data is flat — one
ungrouped block; the grouping activates only for nested paths, which
validateSessionPath already allows), each row showing mtime + size,
with the existing replay/swap semantics on selection. Current
`listSessions` is a flat stem-only scan (session_store.zig:577-603) —
no subdirectories, no metadata.

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented** — see implementation log at the bottom |
| Implementation | **done** — see commit line at the bottom |
| Session v1 schema / Trace / headless / PTY | unchanged (metadata is READ-ONLY directory stats, never session content) |
| session-resume / session-swap | unchanged (replay + swap paths reused verbatim) |

# context

Recon facts (all verified):
- `listSessions(gpa, io, cwd: Io.Dir, dir, out: *ArrayList([]u8))`
  (session_store.zig:577-603): flat scan of one dir, stems only,
  subdirectories invisible, no mtime/size, missing dir → empty.
- The sessions root layout: `-c`/resume resolve a root dir (cli.zig
  session root resolution) — sessions may live directly in the root or
  under project subdirs (the root itself is project-scoped or shared per
  env).
- TUI resume overlay: single flat list, 24-row cap, labels through the
  redaction pipeline; selection → replay (resume slice) or swap
  (session-swap slice).
- Replay/swap take a PATH — the tree browser only needs to resolve a
  path per row; the rest is unchanged.

# path

| Path | Role |
|------|------|
| `packages/zag-coding-agent/src/session_store.zig` | `listSessionEntries` (recursive, 1 level of project subdirs; per entry: rel_path, stem, mtime (ns), size (bytes)) — read-only dir stats |
| `packages/zag-tui/src/app.zig` | resume overlay rows become `[project/]stem  mtime  size` (grouped; project header rows non-selectable); selection resolves the rel path → existing replay/swap |
| `packages/zag-tui/src/render.zig` | row rendering: group header styling (muted) vs selectable rows |
| Forbidden | Session schema, session_store write paths, replay/swap internals |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Root pinning | the browser ALWAYS scans the pinned root `{sessions_root}` — resolved once at open from the DEFAULT `.zag/sessions` when the active session path sits inside it, else the active session's dirname (current sessionRoot() behavior is unstable: dirname of the active path — for `-s proj/foo.jsonl` siblings are invisible; the contract pins: root = the default root if the active path is under it, else dirname — documented instability) |
| Layout | 1 level of grouping: a top-level project dir under the pinned root groups its `*.jsonl` sessions; sessions directly in the root are ungrouped (listed first). Group headers render muted and are NOT selectable — the row model gains a KIND (header vs session) with a parallel flag array (a header row with an empty stem currently CLOSES the overlay — the kind flag prevents that); fixture pins Enter-on-header no-op |
| Metadata | mtime (**UTC** `MM-DD HH:MM` — no TZif parsing in v1; the local-timezone dependency is a documented follow-up) + size (`KB` when ≥1KB else `B`) per session row; source = directory stats (std.posix.fstatat / Dir.statFile), NOT session file content (no heavy loadWithMeta per row); rows are SORTED mtime-desc (the current listing is unsorted dir order) |
| Row format | `{stem}` then `{mtime} {size}` in the same row, truncated at the row cap; group rows = `{project}/`; selection buffers hold the REL path (`project/stem` fits the existing [96]u8 stem buffer — reconstruction `{dir}/{rel}.jsonl` resolves correctly for grouped rows) |
| Ordering | ungrouped sessions first (mtime desc), then project groups (name asc), sessions within a group mtime desc |
| Selection | unchanged mechanics: Enter on a session row → existing replay (same-session) or swap+replay (non-active); the resolved path is `{pinned_root}/{rel}.jsonl` |
| Labels | stems + group names route through the redaction pipeline (existing resume behavior) |
| Cap | 24 rows incl. group headers (the overlay window is 24 rows — rows beyond are dropped at rebuild; PgUp/Dn move the cursor within the window; no windowing in v1 — with headers consuming rows the reachable set shrinks accordingly, documented) |
| Root missing | empty state "(no sessions)" (existing) |
| Non-goals | deep nesting, session deletion/rename, mtime-based pruning, content previews |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Listing | flat + grouped sessions both appear; subdir scan; mtime/size per row; missing root → empty |
| Ordering | ungrouped first (mtime desc), groups name asc, within-group mtime desc |
| Rows | group headers muted + non-selectable; Enter on header no-op; row text has mtime+size right-aligned within cap |
| Selection | session row → existing replay/swap paths resolve `root/{rel}` correctly for grouped + flat |
| Redaction | secret-bearing stems/groups carry markers |
| Gate | 4 matrices + PTY 14/14 unchanged |

# non-goals

- Deep tree (2+ levels), deletion/rename, previews, remote sessions

# implementation log

- `session_store.zig`: `listSessions` (flat stem-only) replaced by
  `SessionEntry` + `listSessionEntries` — read-only scan of the pinned root
  one level deep; per entry `{rel_path, mtime_ns, size_bytes}` from
  `Dir.statFile` (never session content); `.jsonl`-only with sidecars,
  empty stems, non-files, symlinks and deep nesting excluded; unstatable
  entries skipped; missing root → empty list; ordering = flat first (mtime
  desc), groups name asc, within group mtime desc (3 new tests replacing
  the 2 `listSessions` tests).
- `app.zig`: resume overlay rows become `{rel} {mtime} {size}` (rel =
  "stem" or "proj/stem") with muted `{project}/` group headers; the row
  model gains a parallel kind flag array (`resume_row_kinds`, reset every
  rebuild so stale flags never leak into other overlays) — headers are
  non-selectable (Enter no-op, preventing the empty-stem close path);
  selection buffers hold the REL path and resolution is
  `{pinned_root}/{rel}.jsonl` through the existing replay/swap paths; root
  pinning = default `resume_root` when the active path sits inside it,
  else the active path's dirname (`pinnedSessionRoot` replaces the
  unstable `sessionRoot`); UTC `MM-DD HH:MM` mtime + `B`/`KB` size
  formatting, metadata right-aligned within the 96-byte row cap (stem
  truncates first); 24-row cap includes headers (a header is only emitted
  when a session row can follow); stems + group names through the existing
  redaction pipeline (raw rel paths kept in parallel scratch).
- `render.zig`: `OverlayPaint.row_kinds` (per-row `RowKind` normal/muted);
  `drawHostOverlay` renders muted rows in `muted_fg` and suppresses the
  cursor marker on them (non-selectable).
- Fixtures: 8 new app-level tests (grouped listing/ordering/mtime+size
  rows, header no-op, cap-with-headers, group+stem redaction, grouped +
  flat selection resolution, root pinning both branches, 96-byte
  right-aligned metadata tail) + 1 render cell test (muted style + no
  marker) + 3 session_store tests.
- Verified: all 4 matrices green (`zig build test`, `-Dhttp_backend=curl`,
  `-Dtui=true`, `-Dtui=true -Dhttp_backend=curl`); the 14
  `tui_process_fixture.zig` gates (incl. 7 PTY incl.
  `gate33_pty_resume_swap_continue_appends_to_selected_session`) pass on
  macOS; the single skip is the pre-existing TTY-less `ISIG` test.

commit: (code commit line added by closeout)

# related

- [session-resume-tui-001](./session-resume-tui-001.md) · [session-swap-001](./session-swap-001.md)
