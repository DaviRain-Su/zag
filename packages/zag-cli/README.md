# zag-cli

Product shell for the `zag` executable: flag parsing, provider resolve, one-shot and REPL.

```text
src/main.zig          → packages/zag-cli (this)
                         → zag-coding-agent
                         → zag-agent-core
                         → zag-ai
```

Public API: `run(std.process.Init)`.
