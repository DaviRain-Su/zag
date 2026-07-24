# C9 — Product Shell

| Item | Content |
|------|---------|
| Prerequisite | Phase H + independent headless/process Gate; C4–C6 only as needed by a specific UI |
| Failure mode | Kernel works but daily/editor UX is weak or duplicates business logic |
| Reference | Hyper pager/dashboard/ACP |

## Scope split

Headless automation is **not deferred to late C9**. It is an earlier post-H Gate defined by [D-008](../decisions/active/D-008-sdk-and-process-boundaries.md) and [headless-001](../plan/tasks/headless-001.md):

- clean JSON/streaming JSON;
- versioned events;
- stable errors/exit codes;
- process E2E fixtures.

C9 starts only after that machine contract exists and focuses on optional product UX.

## C9 goals

1. Optional TUI: streaming text, Tool cards, permission prompts, diff/review pane.
2. Polished ACP/editor integration over the existing process contract.
3. Lightweight local dashboard for session cost/Tool timing/trace inspection.
4. Config UX/migration on top of versioned config contracts.

## Invariants

- Product shells assemble Kernel APIs; they do not implement loop, permission, session, or provider business logic.
- TUI and plain/headless modes expose the same correctness and errors.
- stdout protocol remains uncontaminated by logs.
- UI closure/drop cannot invent a successful run terminal state.
- No cloud collaboration requirement.

## Acceptance

- [ ] headless Gate remains green while C9 is enabled/disabled;
- [ ] TUI (if shipped) can complete core tasks without losing permission/error/session behavior;
- [ ] ACP/editor path negotiates protocol version and uses stable process errors;
- [ ] dashboard reads versioned trace rather than private Agent memory;
- [ ] CLI/help/config docs match behavior.

## Non-goals

- Loop implementation in UI
- First-release 10-language i18n
- Cloud thread/collaboration platform
- Dynamic Zig plugin ABI
