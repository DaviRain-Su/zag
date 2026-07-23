# Zag project notes (for the coding agent)

- This is **Zag**: a Zig coding-agent tutorial + implementation.
- Prefer changing **business** code under `src/agent/`; put FS/shell details in `src/runtime/`.
- Keep **chapters/** in sync when behavior changes.
- Default permission mode is **ask**; do not suggest `--yolo` for production.
- Sessions are JSONL under `.zag/sessions/` when the user passes `-c` / `--session`.
- Zig version is **0.16** (`std.process.Init`, `std.Io`).
- Phase status: 0–3 complete (loop · edit/permissions · session/context · jail/policy/trace). Version 0.3.0.
- Paths must stay relative (workspace jail). Prefer `--shell-policy protect`.
