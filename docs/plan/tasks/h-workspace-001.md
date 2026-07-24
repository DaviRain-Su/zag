---
id: h-workspace-001
scope: phase-h/workspace
status: pending
priority: P0
depends-on: [h-tool-runtime-001]
---

# objective

Make built-in file tools enforce real workspace containment across symlinks and document the trusted-host boundary without claiming that lexical validation is an OS sandbox.

# context

- `docs/modules/workspace-sandbox.md`
- `docs/decisions/active/D-007-tool-runtime-descriptor.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-agent-core/src/workspace.zig`
- `packages/zag-agent-core/src/loop.zig`
- `packages/zag-coding-agent/src/runtime/fs_tools.zig`
- `packages/zag-coding-agent/src/runtime/edit_tools.zig`
- `docs/modules/workspace-sandbox.md`
- `docs/quality/evals.md`
- `docs/maturity.md`
- `SECURITY.md`
- `chapters/03-production/`

# verification

- read/list/grep/glob through a workspace symlink targeting outside are denied;
- write/search_replace cannot replace or traverse an escaping symlink;
- ordinary relative in-workspace paths and in-workspace symlinks retain documented behavior;
- parent replacement/TOCTOU limits are either tested or explicitly excluded by the threat model;
- shell remains documented as a separate boundary;
- `zig build test --summary all`.
