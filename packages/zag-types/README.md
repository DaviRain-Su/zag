# zag-types

L0 canonical types for Zag: messages, tool definitions, stream events, and
neutral `ChatError`. No HTTP, no vendor wire formats.

```
zag-agent-core ──┐
                 ├──► zag-types
zag-ai ──────────┘
```

Agent Core must not depend on `zag-ai`; only on this package (+ std).
