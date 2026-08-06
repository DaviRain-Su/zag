---
id: session-resume-tui-001
scope: tui/session-resume
status: implemented
priority: P2
depends-on:
  - tui-slash-host-001
---

# objective

Replay a durable session into the TUI transcript: a `/resume` command
lists saved sessions; selecting one loads it and rebuilds the card ring
(user/tool/assistant cards incl. reasoning when the thinking toggle is
on) so the user sees the full history before continuing. The CLI `-c` /
`--continue` machinery already exists end-to-end; only the TUI replay
surface is missing.

# status truth

| Track | Status |
|-------|--------|
| Contract | **implemented** — independent review passed with fixes; fixes absorbed (v1 = read-only replay browsing; no session-swap) |
| Implementation | **done** — see commit line at the bottom |
| Session v1 / Trace v1 | unchanged (read-only replay of the existing schema) |
| Headless / CLI `-c` | unchanged |

# context

- `-c/--continue` resolves and loads a session before entering the TUI
  (recon: "session resume already works end-to-end via -c/--continue but
  the TUI never replays past turns into cards").
- Session v1 persists messages incl. `reasoning`, `synthetic`,
  `prompt_index` (session_store.zig save/load round-trip tests pass).
- TUI card ring: `publishOrdinaryPrepared` /
  `replaceNewestOrdinaryTitlePrefix` / `publishUser` —
  replay = walk the loaded transcript and publish cards in order.
- TUI slash surface: slash_route.zig builtin list + overlay.zig Kind
  enum (help/settings/model/theme) — add `resume`.

# path

| Path | Role |
|------|------|
| `packages/zag-tui/src/app.zig` | `/resume` command → session-list overlay; selection → replay; replay = walk loaded session transcript → publish cards; state/editor reset |
| `packages/zag-tui/src/overlay.zig` | Kind gains `resume`; Builtin gains `resume` ("/resume") |
| `packages/zag-tui/src/render.zig` | resume overlay title only (rows = session labels) |
| `packages/zag-coding-agent/src/session_store.zig` | expose a read-only listing API (session dir entries → labels) + expose load (verify existing public API; add minimal listing if absent) |
| `packages/zag-tui/src/slash_route.zig` | none (slash_route is skill/template routing — verify builtin routing path) |
| Forbidden | Session schema changes, session_store write-path changes, Trace, headless |

# contract summary

### Frozen choices

| Topic | Freeze |
|-------|--------|
| Entry | `/resume` opens the resume overlay (list); selecting an entry loads that session and rebuilds the transcript cards; Esc closes. **v1 scope: read-only replay browsing** — the active bound Session cannot be swapped (no rebind API; review blocker). "Continue" (new turns appending to the selected session) is a separate session-swap slice. Sending after a replay appends to the ACTIVE session as today, with a note when the replayed session differs |
| Listing | session dir (existing `-c` root): one label per `*.jsonl` entry (lock sidecars excluded); label = filename stem after stripping `.jsonl`; labels route through the SAME redaction pipeline as setIdentity (filenames can embed secrets); cap 24 rows; empty dir → "(no sessions)" + Enter closes |
| Replay | walk the loaded session transcript in order → publish per message: user → publishUser (redacted); assistant → title `assistant turn={n}` + content (reasoning published as a `thinking` card first when the toggle is on); tool messages → `tool {name}` title + body; **the replay uses the existing redaction pipeline** (never raw). render.zig drawHostOverlay title switch + activateOverlaySelection gain a `.resume` arm |
| Turn numbering | assistant cards renumber 1..N in replay order (transcript order is authoritative) |
| After replay | editor cleared, scrollback reset to follow, state stays idle; the ACTIVE session is unchanged (v1 read-only replay); selecting the already-active session replays from the already-loaded transcript (no re-load, no lock conflict — resumeExisting would return SessionBusy) |
| Card ceiling | replay respects the ring cap (125); oldest cards drop with the existing drop-note behavior |
| Loading failures | missing/corrupt session → note "resume_failed" + close (never crash); fail-closed; header-only file → InvalidSession handled the same; replay loads into a fresh arena-owned Transcript then deinits (no leak) |
| Non-goals | session deletion/rename, tree navigation, fork-from-history, memory browsing |

# verification

### Fixture classes

| Class | Intent |
|-------|--------|
| Listing | saved sessions appear; empty dir → "(no sessions)"; cap at 24 |
| Replay order | user/tool/assistant cards in transcript order; turn numbering 1..N; thinking card when toggle on (and NOT when off) |
| Redaction | replayed bodies carry the redaction pipeline (markers present on secrets) |
| Continue | after replay, a new turn appends to the same session (round-trip save/load preserves both halves) |
| Fail-closed | corrupt file → note + close, no crash; ring cap respected |
| Gate | 4 matrices + PTY markers unchanged |

# non-goals

- Session management (delete/rename/tree)
- Memory browsing
- Schema changes

# implementation log

- `session_store.zig`: read-only `listSessions` (owned stems, `*.lock`/non-file
  exclusion, missing dir → empty list) + 3 listing tests.
- `overlay.zig`: `Kind`/`Builtin` gain `resume` (escaped `@"resume"` — `resume`
  is a Zig keyword) + routing tests.
- `app.zig`: `/resume` slash routing (palette + direct submit), resume overlay
  listing (labels through the setIdentity redaction pipeline, raw stems kept
  in parallel scratch for selection, cap 24, "(no sessions)" empty row),
  `replaySession` (user → publishUser; assistant → `assistant turn={n}`
  renumbered 1..N with gated `thinking` card; tool → `tool {name}` via the
  carrier's id→name map; redaction on every card; corrupt/missing → note
  `resume_failed` + close; selected == active session replays the live
  transcript without re-load; fresh arena-owned Transcript deinited after
  replay; editor cleared + scrollback reset + state idle) + 10 app-level
  fixtures (routing, listing cap/empty/secret-label redaction, replay order
  + numbering + thinking gating, content redaction markers, corrupt
  fail-closed, ring cap 125 with drop note, same-session no-reload, read-only
  replay preserving file bytes).
- `render.zig`: resume overlay title.
- Verified: all 4 matrices green (`zig build test`, `-Dhttp_backend=curl`,
  `-Dtui=true`, `-Dtui=true -Dhttp_backend=curl`); the 13
  `tui_process_fixture.zig` fixtures (incl. 6 PTY) pass on macOS; PTY markers
  (`state:{s}` contiguous, 1049h/l, ISIG) unchanged.

commit: 22b8980 "zag-tui: stream thinking deltas into a progressive card (Ctrl+T)" (combined-tree commit incl. this slice; doc-only closeout follows)


# related

- [session-store-001](./session-store-001.md) · [tui-slash-host.md](../modules/tui-slash-host.md)
