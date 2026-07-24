# Quality: Evals

> Phase H correctness is demonstrated by failure fixtures, not by test count alone.

## Suites

| Suite | Purpose | Gate |
|-------|---------|------|
| Golden transcript | Stable Tool sequence and transcript behavior under a fixed Provider | H1+ |
| Fault/persistence | Session, trace, context, and cancellation failures preserve truth | P0/P1 |
| Security | Permission, containment, policy, and redaction cannot regress | P0/P1 |
| Provider contract | Fixed bytes map to canonical turn/error/cancel behavior | H6 |
| Edit eval | Anchor/patch correctness and recovery | H2/C4 |
| External consumer | Public source SDK composition compiles and runs outside product defaults | SDK gate |
| Headless E2E | Stable process output/errors/exit status | Headless gate |

## Existing baseline

- `readonly-list-build` — fixed mock: list → read → answer.
- `deny-write` — permission denial and no target file.
- `cancel-resume` — pending Tool result marked cancelled and session roundtrip.
- provider request/turn/SSE/error fixtures under `zag-ai`.

These remain useful but do not cover the assessment blockers.

## P0 minimum fixtures

### Session

1. create-existing fails and preserves exact bytes.
2. resume-missing, invalid JSON, unsupported schema, and generic I/O failure are distinct.
3. save fault leaves the previous file loadable and is returned to caller.
4. a second active writer receives busy/conflict; last-writer-wins fails the test.

### Tool policy

1. a registered custom mutating Tool is denied by the dangerous-tool deny gate. ✅
2. Tool registration without required capabilities fails before a Provider call. ✅
3. invalid capabilities on forged Tool / shell≠execute / empty path_field fail before Provider. ✅
4. provider-visible schema: `loop → WireProvider → WireAdapter` sees only `ToolDefinition`. ✅
5. every built-in declares risk/workspace/cancellation/shell. ✅
6. custom path Tool: jail + missing/non-string/malformed → soft error, handler=0. ✅
7. custom shell Tool (non-`run_shell` name): missing/non-string/deny/allow. ✅
8. unknown model tool remains soft `unknown_tool`. ✅

### Workspace

1. absolute and `..` paths deny. ✅
2. workspace symlink → **sibling outside** denied for read/list/grep/glob/write/search_replace; outside bytes unchanged. ✅ (`workspace.zig` Guard + `fs_tools`/`edit_tools` fixtures; outside is not nested under workspace)
3. ordinary contained paths and **contained** file/dir symlinks remain usable (read/list/search/write/replace). ✅
4. dangling / parent-escape / nested walker escape: `code=jail_deny` or safe skip without leak; missing ordinary file ≠ jail_deny. ✅
5. prefix collision (`/ws` ⊄ `/ws2`) and symlink-loop walker bound. ✅
6. macOS/Linux via `Io.Dir.symLink`; Windows skips symlink fixtures (no false pass). ✅

### Run/trace lifecycle

1. provider authentication failure ends exactly once with `ok=false`, `provider_error`.
2. explicit unwritable trace path is observable.
3. completed, max-turns, and cancelled each have one matching terminal event.

## P1 minimum fixtures

1. two-stage compaction: final `dropped` and summary/lineage match the returned view.
2. fake configured secrets do not appear in verbose, trace, or session bytes.
3. timeout is enforced or explicitly unsupported for std/curl paths.
4. stream cancellation discards incomplete Tool-call fragments.
5. external stateful Tool/Provider/Observer/policy/session consumer passes.
6. headless JSON stdout is clean; failure exit/error matrix is stable.

## Edit eval (H2/C4)

1. unique anchor replacement succeeds;
2. ambiguous anchor fails without mutation;
3. stale anchor is recoverable after reread;
4. C4 adds hunk review and post-edit validation.

## Maintenance

- Every fixed P0/P1 failure remains a permanent regression fixture.
- Intentional behavior changes update the contract and fixture in one delivery.
- Never weaken an assertion merely to make a fixture green.
- Live-provider checks may supplement but never replace deterministic CI contracts.

## Related

- [assessment](../plan/analysis/2026-07-24-production-floor-assessment.md)
- [provider contracts](./contracts.md)
- [maturity](../maturity.md)
