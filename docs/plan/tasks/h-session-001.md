---
id: h-session-001
scope: phase-h/session
status: in-progress
priority: P0
depends-on: []
---

# objective

Replace implicit resume fallback and in-place truncate persistence with the D-006 contract: explicit create/resume semantics, preservation on failed save, visible persistence errors, and one active writer per persisted session.

# context

- `docs/decisions/active/D-006-session-open-and-durability.md`
- `docs/modules/session-store.md`
- `docs/plan/analysis/2026-07-24-production-floor-assessment.md`

# path

- `packages/zag-agent-core/src/session_store.zig`
- `packages/zag-coding-agent/src/agent.zig`
- `packages/zag-cli/src/cli.zig`
- `packages/zag-coding-agent/src/golden_tests.zig`
- `docs/modules/session-store.md`
- `docs/maturity.md`
- `chapters/02-session-context/`

# verification

- create-existing fails without changing the file;
- resume-missing, invalid, unsupported, and general I/O errors remain distinguishable;
- fault-injected save reports failure and leaves the previous session loadable;
- two active writers cannot both commit;
- no facade catches a persistence error and returns an unqualified successful reply;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`.
