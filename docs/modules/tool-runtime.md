# Module: tool-runtime

| Item | Content |
|------|---------|
| Code | `packages/zag-types/src/root.zig`; `packages/zag-agent-core/src/tool.zig` |
| Maturity | **L2** — instance-aware Tool + mandatory descriptor; missing capability fail-closed |
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
                                      Tool { descriptor, instance, handler }
```

`ToolDefinition` is serialized to providers. `ToolCapabilities`, instance pointers, handlers, and policy state are never sent to providers. The core `Provider` port accepts only `[]const ToolDefinition`.

## Types and invariants

### `ToolCapabilities` — H minimum (all required, no default-to-read)

| Field | Contract |
|-------|----------|
| `risk` | Required enum: `read`, `write`, or `execute` |
| `workspace` | `none` or `path_field: name` — absence means no filesystem path claim, not unrestricted access |
| `cancellation` | `none` or `cooperative` — whether the handler honors cancel/deadline mid-invocation |
| `shell` | `none` or `command_argument` — only shell-command tools parse `command` and apply shell policy |

Future-compatible fields may include `max_concurrency`, progress streaming, and `behavior_version`; they are not H exit requirements.

### `Tool`

A validated Tool owns or borrows:

- one `ToolDescriptor` (definition + mandatory capabilities);
- one opaque instance pointer (`?*anyopaque`);
- one instance-aware handler `(Context, ?*anyopaque, args) → []u8`.

**Lifetime:** caller owns the instance and all borrowed descriptor strings (name, description, schema, `path_field` name). They must outlive every invocation. `Tool` is copyable by value; copies share the same borrowed pointers (no deep clone). Registration does not take ownership.

## Registration and execution

1. **Public fallible boundary:** `tool.Registration` may carry optional `capabilities`; `tool.buildTool` validates name/schema and **fails with `MissingCapabilities`** when risk metadata is omitted. Static struct field omission is not enough for dynamic adapters.
2. **Toolset validation:** `tool.validateTools` rejects invalid name/schema and duplicate names before the first provider call (`loop.run` → `error.InvalidToolset`).
3. Validated `Tool` never carries optional capability fields.
4. Send only `ToolDefinition[]` to the Provider (built per turn from the registry).
5. `Registry.find` returns `?*const Tool`. Loop uses the same descriptor for permission, path jail, shell policy, trace, and execute.
6. Unknown model-requested tools soft-fail as `unknown_tool` **without** name-based risk inference.
7. Expected handler failures map to stable machine-readable tool-result shapes.

## Errors

| Error | Boundary behavior |
|-------|-------------------|
| Missing/invalid risk or capabilities | Fail registration (`RegistrationError`); never infer read |
| Duplicate / invalid toolset | `error.InvalidToolset` before provider (call count 0) |
| Unknown requested tool | Soft tool result `unknown_tool` |
| Invalid arguments | Soft tool result `invalid_arguments` |
| Handler failure | Soft tool result `tool_failed` |
| Host allocation failure | Typed run error |
| Cancellation | Handler observes cancel per capability; between-tool cancel is soft `cancelled` |

## L2 tests

- [x] external stateful Tool increments instance state without globals;
- [x] custom write/execute Tool is denied by a dangerous-tool deny gate;
- [x] missing capability registration fails closed;
- [x] malformed toolset fails before provider (provider call count = 0);
- [x] built-ins all declare descriptors (risk/workspace/cancellation/shell);
- [x] provider serialization / port contains definition only;
- [x] workspace enforcement selected by descriptor, not tool name;
- [x] unknown model tool remains soft `unknown_tool`.

## Non-goals for H

- Dynamic shared-library plugins or stable C ABI
- Parallel tool execution
- MCP transport implementation
- Progress UI protocol
- Symlink-aware containment (see [workspace-sandbox](./workspace-sandbox.md) / h-workspace-001)
