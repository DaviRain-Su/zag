# MCP v1 — local stdio client (E2)

> Binding draft for [mcp-001](../plan/tasks/mcp-001.md)
> (D-012 item 6; D-010 E2 process adapter).
> Prerequisite: [process-supervisor-long-lived.md](./process-supervisor-long-lived.md)
> (slots exist). Do **not** implement against raw `std.process.Child`.
>
> **Status:** **draft** — **contract only**. Implementation starts only
> when a named user MCP server exists. No maturity raise. Runtime
> Extensions stays **L0**.

## 1. Purpose

Let a same-user, workspace-scoped, **user-configured** local MCP server
advertise Tools that Zag maps through D-007 descriptors. Missing
capabilities fail closed. This is not a marketplace.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| `zag-coding-agent` | Config parse; descriptor mapping; slot registration | Core MCP types |
| Supervisor long-lived slot | Child lifecycle | Protocol |
| `zag-cli` | Thin flag / config path later | Protocol engine |
| `zag-agent-core` | existing ToolPolicy / Jail / ShellPolicy ports | MCP / JSON-RPC / PID |

## 3. v1 freeze (proposed)

| Topic | Choice |
|-------|--------|
| Transport | local **stdio** MCP only |
| Cardinality | one OS process per configured server |
| Carrier | E2 = supervised long-lived slot |
| Surface | Tools advertised by the server, mapped to `ToolDefinition` + mandatory `ToolCapabilities` |
| Missing caps | fail-closed (D-007); do not guess risk/path/cancel |
| Trust | user-configured, same-user, workspace-scoped |
| Auth | none in v1 (no OAuth) |
| Network MCP | out |
| Resource subscriptions | out |
| Marketplace / hot install | out |

## 4. Config sketch

```text
.zag/mcp.json   { "servers": [ { "name": "…", "command": ["…"], "args": [] } ] }
```

Exact schema freezes at review. Command is argv, not `sh -c`, unless
review explicitly allows a jailed shell form. Env is the slot allow-list
plus explicit server `env` pairs — never the ambient host dump.

## 5. Invariants

1. No spawn until a long-lived slot exists.
2. Jail / permission / remember still apply to mapped Tools.
3. Server crash → truthful tool error; no silent retry loop.
4. Redaction before any MCP body hits Trace / session / verbose.
5. `--yolo` does not install or trust a new server.

## 6. Tests (when implemented — not now)

| # | Class | Expect |
|---|-------|--------|
| 1 | Fake stdio server | list tools → descriptors present |
| 2 | Missing cap | fail-closed; tool not registered |
| 3 | Slot kill | no orphan; next call fails closed |
| 4 | Jail | mapped path tool cannot escape |
| 5 | Ownership | no Core MCP symbols |

## 7. Non-goals

- Impl without a named consumer server
- Network / OAuth / remote registry
- E3 WASM
- OS sandbox
- Maturity raise

## Related

- [process-supervisor-long-lived.md](./process-supervisor-long-lived.md)
- [extensions.md](./extensions.md) · [tool-runtime.md](./tool-runtime.md)
- [D-010](../decisions/active/D-010-extension-tiers-and-process-protocol.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
