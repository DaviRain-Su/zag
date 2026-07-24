---
status: active
id: D-007
title: Tool runtime capabilities are explicit and fail closed
date: 2026-07-24
---

# D-007 — Tool runtime capabilities are explicit and fail closed

## Decision

1. Provider-facing `ToolDefinition` remains limited to model-visible name, description, and argument schema.
2. A separate public runtime `ToolDescriptor` combines `ToolDefinition` with mandatory `ToolCapabilities`.
3. H requires at least these capabilities:
   - `risk`: `read | write | execute` — required, with no implicit read default;
   - workspace/path access metadata used by containment enforcement;
   - whether an in-flight invocation supports cancellation.
4. `Tool` registration carries the descriptor, an opaque instance pointer, and a handler callback. Custom tools can therefore own state without globals.
5. Permission, workspace enforcement, scheduling, and tracing consume the same descriptor. They must not infer security behavior from tool names.
6. Missing or invalid capability metadata fails registration/decoding. It never falls back to read.

Optional future capabilities such as concurrency limits, streaming progress, and behavior versions may be added compatibly after the H contract is stable.

## Why

The current `riskOf(tool_name)` and `toolUsesPath(tool_name)` recognize built-ins by string and classify unknown names as read/no-path. A registered mutating custom tool can therefore bypass dangerous-tool denial, which makes the Kernel extension surface fail open.

Risk data also must not be mixed into `ToolDefinition`: model wire schema and local execution security have different consumers and evolution rules.

## Consequences

- Built-in tools must declare capabilities explicitly.
- `permissions.Gate` remains injectable, but its input changes from a name-derived risk to a descriptor-derived risk.
- File-tool containment applies by capability, not a built-in-name list.
- MCP/plugin adapters must provide validated capabilities before adding tools to the registry.
- Unknown tool calls remain a machine-readable soft failure; malformed registered tools fail before a run starts.

## Required tests

- a stateful custom tool runs through the public Kernel surface;
- a registered custom mutating tool is denied by `denyAllDangerous`;
- registration without risk metadata fails closed;
- provider request serialization excludes local runtime capabilities;
- every built-in has an explicit descriptor.

## Related

- [assessment](../../plan/analysis/2026-07-24-production-floor-assessment.md)
- [tool-runtime module](../../modules/tool-runtime.md)
- [permissions module](../../modules/permissions.md)
- [task h-tool-runtime-001](../../plan/tasks/h-tool-runtime-001.md)
