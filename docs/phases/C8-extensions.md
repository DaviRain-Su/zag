# C8 — Extensions

| Item | Content |
|------|---------|
| Prerequisite | Phase H + SDK/process contracts; executable extension prerequisites depend on risk |
| Failure mode | every workflow requires core edits, or third-party Tools bypass policy/safety |
| Module | [extensions](../modules/extensions.md) |
| Philosophy | validate externally before promoting into product core |

## Scope by risk

### Passive Skills/packages

- `SKILL.md` discovery and bounded prompt injection;
- agent/prompt definitions with no executable privilege;
- may follow SDK/headless injection contracts without waiting for full OS sandbox.

### Hooks

- Pre/Post Tool and Stop lifecycle;
- consume versioned events and validated ToolDescriptor;
- a hook may deny but may not weaken mandatory policy/containment.

### MCP/executable servers

- stdio/process transport behind quarantine;
- every imported Tool supplies validated D-007 capabilities before registry insertion;
- process supervisor owns child lifecycle/output/cancel;
- permission and required sandbox policy apply exactly as for built-ins.

## Invariants

- Missing/unknown Tool capability fails closed.
- Extensions do not import provider wire types into Kernel.
- Executable extension failure is structured and cannot corrupt session/trace terminal state.
- No dynamic shared-library/C ABI requirement; process protocol is preferred.
- Expensive/privileged extension paths are configurable and default explainable.

## Acceptance

- [ ] passive Skill loads without recompiling core and respects prompt budget;
- [ ] hook can deny a custom mutating Tool and cannot bypass core policy;
- [ ] MCP custom Tool passes descriptor/permission/containment tests;
- [ ] child process cancel/reap/output bounds are tested;
- [ ] one example package has docs and deterministic fixtures.

## Non-goals

- Commercial marketplace
- 30+ built-in extension bundle before real use
- Stable Zig dynamic plugin ABI
