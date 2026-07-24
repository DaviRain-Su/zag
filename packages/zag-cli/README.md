# zag-cli

Product shell for the `zag` executable: flag parsing, provider resolve, one-shot and REPL.

```text
src/main.zig          → packages/zag-cli (this)
                         → zag-coding-agent
                         → zag-agent-core
                         → zag-ai
```

Public API: `run(std.process.Init)`.

## Doctor (h-doctor-001)

`zag --doctor` prints a fixed, path-free human-readable control report after **argument validation** (including session-path semantics when `-s`/`-c` selected) and **before** `ai.resolve`, wire, Agent/session/trace open, or network. No API key required. Reports selected permission/shell/project flags without mutating them. Format overflow fails closed (non-zero). Not a stable JSON/exit protocol (see headless-001).

Process fixture: `packages/zag-cli/src/doctor_process_fixture.zig` (wired into root `zig build test`). Other legal flags/prompt with `--doctor` are currently ignored (P2 UX backlog).

## Logging boundary (h-redact-001)

Verbose (`-v`) and stream diagnostics use fixed/enum/numeric helpers only (no raw model/key/path/chunk bytes). Permission ask prompts log risk + `args_len` only. **Final assistant stdout** (one-shot/REPL) is intentional user-facing output and is outside that diagnostic gate.
