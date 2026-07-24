---
id: h-tool-runtime-001
scope: phase-h/tool-runtime-permissions
status: done
priority: P0
depends-on: []
---

# objective

Implement D-007: an instance-aware Tool runtime descriptor with mandatory capabilities, and make permission/workspace decisions fail closed for custom tools without deriving security behavior from names.

# context

- `docs/decisions/active/D-007-tool-runtime-descriptor.md`
- `docs/modules/tool-runtime.md`
- `docs/modules/permissions.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-types/src/root.zig`
- `packages/zag-agent-core/src/tool.zig`
- `packages/zag-agent-core/src/permissions.zig`
- `packages/zag-agent-core/src/workspace.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-coding-agent/src/toolset.zig`
- `packages/zag-coding-agent/src/runtime/`
- `docs/modules/tool-runtime.md`
- `docs/modules/permissions.md`
- `docs/maturity.md`
- `chapters/01-edit-permissions/`

# verification

- an external-style stateful Tool executes without global state;
- a registered custom mutating Tool is denied by `denyAllDangerous`;
- missing capability metadata fails before a provider call;
- provider request serialization excludes runtime capabilities;
- every built-in declares risk/workspace/cancellation metadata;
- unknown model-requested tools remain machine-readable soft failures;
- `zig build test --summary all`.
