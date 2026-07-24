# Module: extensions (Capability stub)

| Item | Content |
|------|---------|
| Status | L0 / not implemented |
| Stage | [C8](../phases/C8-extensions.md) |
| Prerequisite | Phase H + SDK/process contracts; executable paths also require process safety |
| Reference | Pi packages; Hyper Skills/Hooks/MCP; goose |

## Invariants

1. Validate a workflow as an external Skill/package before promoting it into product core.
2. Imported Tools use [D-007](../decisions/active/D-007-tool-runtime-descriptor.md) descriptors and the same permission/containment/trace path as built-ins.
3. Missing capability metadata fails closed.
4. Hooks may deny but cannot weaken mandatory policy or sandbox requirements.
5. Executable extension processes are owned/cancelled/reaped by the process supervisor.
6. Process protocol is preferred; no stable Zig dynamic plugin ABI is required.

## Surfaces by risk

| Surface | Dependency |
|---------|------------|
| Passive Skills/prompt package | injection/budget + SDK/headless contract |
| Hooks | versioned lifecycle + Tool descriptor |
| MCP stdio Tool server | descriptor + process supervisor + permission/sandbox policy |
| Package directory | combines only surfaces whose gates pass |

## Acceptance (C8)

- passive Skill loads without core recompilation and respects prompt budget;
- a hook denies a mutating custom Tool through core policy;
- MCP Tool registration rejects missing capabilities;
- executable child cancel/output/process ownership is tested;
- extension failure cannot create false successful session/trace state.

## Non-goals

- Phase H implementation
- Marketplace
- Stable C/shared-library plugin ABI
- Large built-in extension catalog before usage evidence
