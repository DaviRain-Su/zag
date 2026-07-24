# Zag project notes (for the coding agent)

- This is **Zag**: a Zig coding-agent tutorial + implementation.
- Business code lives in packages: L0 `packages/zag-types/`; kernel in `packages/zag-agent-core/` (depends on zag-types only); product harness in `packages/zag-coding-agent/`; CLI in `packages/zag-cli/`; model plane in `packages/zag-ai/`. `src/main.zig` is a thin entry only. New capabilities must declare their target package (`docs/packaging.md`).
- Keep **chapters/** in sync when behavior changes; keep **docs/maturity.md** in sync when capability level changes.
- Default permission mode is **ask**; do not suggest `--yolo` for production.
- Sessions are JSONL under `.zag/sessions/` when the user passes `-c` / `--session`.
- Zig version is **0.16** (`std.process.Init`, `std.Io`).
- **Teaching Phase 0–3 = tutorial-complete only.** Not production-ready.
- **Next mainline = Phase H** (Production Floor → maturity L2). Specs: `docs/phases/H-harden.md`, `docs/modules/*`.
- Do not claim “production-ready” or “Phase 3 = shipped for prod” in docs or replies until Phase H L2 exit criteria in `docs/maturity.md` are met.
- Paths must stay relative (workspace jail). Prefer `--shell-policy protect`.
- Doc map: `docs/README.md`. Vision: `docs/vision.md`. Roadmap: `docs/roadmap.md`.
