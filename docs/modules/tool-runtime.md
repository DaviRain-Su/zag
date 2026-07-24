# Module: tool-runtime

| Item | Content |
|------|---------|
| Code | `packages/zag-types/src/root.zig`; `packages/zag-agent-core/src/tool.zig` |
| Maturity | L1 built-in registry → **L2 explicit runtime contract (H/P0)** → L3 streaming/concurrency |
| Decision | [D-007](../decisions/active/D-007-tool-runtime-descriptor.md) |
| Reference | Hyper ToolCapabilities; Pi tool lifecycle |

## Purpose

Define the public boundary between model-visible tool schemas, local execution policy, and tool instances. The registry is extensible only when custom tools pass the same permission, containment, cancellation, and trace contracts as built-ins.

## Boundary

```text
provider request                     local runtime only
┌────────────────────┐              ┌───────────────────────────┐
│ ToolDefinition     │              │ ToolDescriptor            │
│ name               │              │ definition                │
│ description        │─────────────►│ capabilities              │
│ parameters schema  │              └─────────────┬─────────────┘
└────────────────────┘                            │
                                      Tool { descriptor, ptr, handler }
```

`ToolDefinition` is serialized to providers. `ToolCapabilities`, instance pointers, handlers, and policy state are never sent to providers.

## Types and invariants

### `ToolCapabilities` — H minimum

| Field | Contract |
|-------|----------|
| `risk` | Required enum: `read`, `write`, or `execute`; no default-to-read behavior |
| workspace access | Declares whether/path arguments that require workspace containment; absence means no filesystem path claim, not unrestricted access |
| cancellation | Declares whether the handler honors the run cancellation/deadline context |

Future-compatible fields may include `max_concurrency`, progress streaming, and `behavior_version`; they are not H exit requirements.

### `Tool`

A Tool owns or borrows:

- one `ToolDescriptor`;
- one opaque instance pointer (`?*anyopaque` or an equivalent typed adapter);
- one handler callback receiving the instance, execution context, and arguments.

The caller owns instance lifetime. Toolset/Agent documentation must state that the instance and borrowed descriptor strings outlive all invocations.

## Registration and execution

1. Validate identifier/schema and required capabilities before a run.
2. Reject malformed/missing capabilities with a typed registration error.
3. Send only `ToolDefinition` to the Provider.
4. Pass the full descriptor to permission, workspace, trace, and scheduling decisions.
5. Execute through the instance-aware handler.
6. Convert expected handler failures into the stable machine-readable tool-result shape.

An unknown model-requested tool remains a soft `unknown_tool` result. A malformed registered tool is a host configuration error and fails before provider/tool execution.

## Errors

| Error | Boundary behavior |
|-------|-------------------|
| Missing/invalid risk or workspace declaration | Fail registration; never infer read |
| Unknown requested tool | Soft tool result `unknown_tool` |
| Invalid arguments | Soft tool result `invalid_arguments` |
| Handler failure | Soft tool result `tool_failed` |
| Host allocation failure | Typed run error |
| Cancellation | Handler returns/observes cancellation according to its capability; trace records terminal state |

## L2 tests

- [ ] external stateful Tool increments instance state without globals;
- [ ] custom write/execute Tool is denied by a dangerous-tool deny gate;
- [ ] missing capability registration fails closed;
- [ ] built-ins all declare descriptors;
- [ ] provider serialization contains definition only;
- [ ] workspace enforcement is selected by descriptor, not tool name.

## Non-goals for H

- Dynamic shared-library plugins or stable C ABI
- Parallel tool execution
- MCP transport implementation
- Progress UI protocol
