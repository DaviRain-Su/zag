---
id: h-doctor-001
scope: phase-h/doctor-readiness
status: in-progress
priority: P1
depends-on: [h-tool-runtime-001, h-workspace-001, h-redact-001]
---

# objective

Add a reusable typed readiness report and `zag --doctor` text command that exposes the controls actually selected for a run without requiring a provider, API key, session, trace, or network access. The doctor reports fixed, path-free status values; it never changes permission/shell policy and never claims an OS sandbox.

# contract

- `zag-coding-agent` owns a typed, provider-independent doctor report; CLI formatting is a product-shell adapter over that report.
- `zag --doctor` dispatches after argument validation but **before** `ai.resolve`, wire creation, Agent/session/trace construction, or any provider/network work.
- The report includes at least:
  - project-instruction candidate: `enabled_present | enabled_missing | disabled` (presence only; doctor does not read the body or claim the later load succeeds);
  - test-entry candidate, first match in this fixed order: `build.zig → zig_build`, `package.json → node_manifest`, `Cargo.toml → cargo_manifest`, `go.mod → go_module`, `pyproject.toml → python_project`, `Makefile → makefile`, `justfile → justfile`, else `none` (detection is not proof that a test command exists or passes);
  - permission mode: `ask | yolo`;
  - shell policy: `protect | off`;
  - lexical file jail: `enforced`;
  - real/symlink-aware file containment: `ready | unavailable_fail_closed` after resolving the current workspace root;
  - secret redaction: `enabled_on_agent_run`, with provider-key binding separately `deferred_until_provider_resolve` in doctor mode;
  - OS sandbox: exactly `os_sandbox=not_implemented`; shell containment is a separate fixed field, `shell_containment=not_path_contained`.
- Output uses fixed keys and enum labels only. It does not print cwd/realpath, project file contents, arbitrary argv/config values, environment values, secrets, or discovered manifest contents.
- Missing project instructions, missing test entry, and absent OS sandbox are reported states, not reasons to silently enable/disable another control.
- This task adds a human-readable diagnostic only. It does **not** establish the versioned JSON/event/exit-code contract owned by `headless-001`.

# context

- `docs/modules/workspace-sandbox.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/quality/evals.md`
- `docs/decisions/active/D-008-sdk-and-process-boundaries.md`
- `packages/zag-coding-agent/src/project.zig`
- `packages/zag-agent-core/src/{permissions,shell_policy,workspace,redact}.zig`

# path

- `packages/zag-coding-agent/src/doctor.zig`
- `packages/zag-coding-agent/src/project.zig`
- `packages/zag-coding-agent/src/root.zig`
- `packages/zag-cli/src/cli.zig`
- package/root build tests only as required for the no-provider CLI fixture
- `README.md`
- `SECURITY.md`
- `docs/modules/workspace-sandbox.md`
- `docs/maturity.md`
- `docs/phases/H-harden.md`
- `docs/roadmap.md`
- `docs/quality/evals.md`
- `chapters/H-harden/README.md`

# verification

- a deterministic CLI fixture runs `--doctor` with no provider/API-key environment and proves provider resolve/wire/network/session/trace paths are not entered;
- default output reports `permission=ask`, `shell_policy=protect`, file-jail/containment truth, redaction truth, and `os_sandbox=not_implemented` without policy mutation;
- `--yolo --shell-policy off --no-project --doctor` reports those explicit selections and still performs no provider work;
- temporary workspaces cover project instructions present/missing/disabled and every recognized test-entry enum without reading or printing file bodies;
- an unresolvable workspace-root fixture reports `unavailable_fail_closed`, never `ready` or a raw path;
- secret-shaped argv/environment/path/file-content fixtures do not appear in doctor output;
- root and package tests pass under both HTTP backends;
- `zig build test --summary all`;
- `zig build test -Dhttp_backend=curl --summary all`;
- docs lint/score pass;
- only after independent review and main-branch verification may Workspace/Safety doctor acceptance be checked; Phase H remains open until `h-integration-001` passes.
