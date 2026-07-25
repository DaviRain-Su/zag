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
| `workspace` | `none`, `path_field: name` (required), or `path_field_default: { field, default_path }` (explicit defaulted path) — absence means no filesystem path claim, not unrestricted access |
| `cancellation` | `none` or `cooperative` — whether the handler honors cancel/deadline mid-invocation |
| `shell` | `none` or `command_argument` — only shell-command tools parse `command` and apply shell policy |

Future-compatible fields may include `max_concurrency`, progress streaming, and `behavior_version`; they are not H exit requirements.

### `Tool`

A validated Tool owns or borrows:

- one `ToolDescriptor` (definition + mandatory capabilities);
- one opaque instance pointer (`?*anyopaque`);
- one instance-aware handler `(Context, ?*anyopaque, args) → []u8`.

**Lifetime:** caller owns the instance and all borrowed descriptor strings (name, description, schema, `path_field`/`field` name, and `default_path`). They must outlive every invocation. `Tool` is copyable by value; copies share the same borrowed pointers (no deep clone). Registration does not take ownership.

## API boundary

| Surface | Role |
|---------|------|
| `buildTool` / `Registration` | Recommended fallible registration for dynamic adapters |
| `Toolset.initValidated` | Optional fallible wrap of a tool slice |
| `loop.run` | **Security policy boundary** — always re-runs `validateTools` before any provider call |
| `Registry.execute` / `executeTool` | Raw dispatch only — **no** permission / jail / shell |

Zig cannot prevent a host from forging a `Tool` literal. Normal product path cannot bypass policy: `loop.run` revalidates definition **and** capabilities every run.

## Registration and execution

1. **Public fallible boundary:** `tool.Registration` may carry optional `capabilities`; `tool.buildTool` validates name/schema/capabilities and fails with `MissingCapabilities` / `InvalidCapabilities` / `InvalidName` / `InvalidSchema`.
2. **`validateCapabilities`** (called from `buildTool` and `validateTools`): rejects empty/whitespace/NUL `path_field` / defaulted `field`; rejects empty/whitespace/NUL or lexically unsafe default paths (absolute, drive/UNC, or escaping; `.` is valid); rejects `.shell=.command_argument` unless `risk=execute`; other contradictions fail closed.
3. **Toolset validation:** `tool.validateTools` also rejects duplicates; `loop.run` maps failure → `error.InvalidToolset` (provider call count = 0).
4. Validated runtime path never carries optional capability fields.
5. Send only `ToolDefinition[]` to the Provider (built per turn from the registry).
6. `Registry.find` returns `?*const Tool`. Loop uses the **same** extracted path for permission + jail (single parse).
7. When `workspace=path_field`, missing/empty/non-string/malformed path args → soft `invalid_arguments` **before** permission/handler.
8. When `workspace=path_field_default`, missing field yields an owned `default_path`; present empty string also yields the default to match raw handler behavior; present non-empty string is used as-is; non-string/malformed args → soft `invalid_arguments`. The extracted value still goes through permission and jail before the handler.
9. When `shell=command_argument`, missing/non-string command → soft `invalid_arguments`; denylist deny → soft `shell_deny`; handler runs only after allow.
10. Unknown model-requested tools soft-fail as a generic bounded `unknown_tool` body **without** echoing the requested name and without name-based risk inference.
11. Expected handler failures map to stable machine-readable tool-result shapes.

## Cancellation metadata

`cancellation` is required metadata. Built-ins are `.none`. `.cooperative` declares that a handler **claims** it can observe cancel/deadline when the host supplies context — it does **not** implement mid-flight cancel by itself. `tool.Context` does not currently carry a cancel flag. h-provider-001 owns provider I/O cancellation only; handler/shell preemption requires post-H process ownership and bounded cleanup.

## Errors

| Error | Boundary behavior |
|-------|-------------------|
| Missing capabilities | `MissingCapabilities` at `buildTool` |
| Invalid capabilities (empty path_field/default field, invalid default_path, shell≠execute, …) | `InvalidCapabilities` at `buildTool` / `validateTools` |
| Invalid name / non-object schema | `InvalidName` / `InvalidSchema` |
| Duplicate / invalid toolset | `error.InvalidToolset` before provider (call count 0) |
| Unknown requested tool | Soft generic bounded tool result `unknown_tool` (requested name omitted) |
| Invalid path/command args (missing/empty/non-string/malformed descriptor-required path fields, or non-string/malformed defaulted field) | Soft `invalid_arguments` before handler |
| Other invalid arguments | Soft tool result `invalid_arguments` |
| Handler failure | Soft tool result `tool_failed` |
| Host allocation failure | Typed run error |
| Cancellation | Handler observes cancel per capability; between-tool cancel is soft `cancelled` |

## L2 tests

- [x] external stateful Tool increments instance state without globals;
- [x] custom write/execute Tool is denied by a dangerous-tool deny gate;
- [x] missing capability registration fails closed;
- [x] invalid capabilities (forged Tool / empty path_field / invalid defaulted path / shell≠execute) fail `validateTools` + `loop.run` before provider;
- [x] invalid name/schema/duplicate fail closed;
- [x] custom required path: missing/empty/non-string/malformed/escape → soft error, handler count 0;
- [x] custom defaulted path: missing/empty → `.` through permission+jail+handler; escape/non-string fail before handler;
- [x] custom shell (non-`run_shell` name): missing/non-string/denied/allowed descriptor-driven;
- [x] built-ins all declare descriptors (risk/workspace/cancellation/shell);
- [x] provider port + WireProvider→WireAdapter composition: definitions only;
- [x] unknown model tool remains soft `unknown_tool`.

## Non-goals for H

- Dynamic shared-library plugins or stable C ABI
- Parallel tool execution
- MCP transport implementation
- Progress UI protocol
- ~~Symlink-aware containment~~ → [workspace-sandbox](./workspace-sandbox.md) / h-workspace-001 (file tools)
