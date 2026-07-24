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

1. provider authentication failure ends exactly once with `ok=false`, `provider_error`. ✅
2. explicit unwritable / invalid path observable; preflight does not truncate destination; provider not called on preflight failure. ✅
3. completed, max-turns, and cancelled each have one matching terminal (`cancelled` ok=true). ✅
4. session save failure → `ok=false`, `session_error`. ✅
5. `Agent.deinit` does not invent a success terminal. ✅
6. `schema_version` on `run_start`; duplicate `run_end` guarded. ✅
7. fail-before-replace preserves prior durable bytes; in-memory single `ok=false, trace_error`. ✅
8. transactional writeObj under FailingAllocator (no seq gap). ✅
9. two consecutive replies: one start/end each, seq reset, run-local ledger. ✅
10. provider/session primary + persist fault → fail-closed `TraceIoFailed` with truthful in-memory category. ✅
11. invalid toolset via Agent.reply injection → provider=0, facade `invalid_toolset` terminal. ✅
12. parent symlink outside workspace → `InvalidPath` before provider; outside bytes unchanged. ✅
13. contained parent symlink allows preflight/persist. ✅
14. post-start nonterminal OOM still commits one `ok=false,out_of_memory` terminal (FailingAllocator). ✅
15. recovery A success → B persist fault (A durable) → C success (latest-run only). ✅
16. provider failure after prior turn reports non-zero `turns` from `last_emitted_turn`. ✅
17. worst-case control-byte fields serialize under 8KiB stack, parse strictly, terminal ≤ reserve. ✅
18. intentional oversize → `TraceSerializationFailed` (not OOM) then `trace_error` terminal. ✅
19. final Guard OOM → `OutOfMemory` + in-memory `out_of_memory` (not TraceIoFailed). ✅
20. preflight OK then parent becomes escape → `InvalidPath`, outside unchanged. ✅
21. NaN/+Inf/-Inf estimated_usd omitted; strict-parseable terminal. ✅
22. intended terminal serialize failure → one minimal `trace_error` terminal, run closed. ✅
23. invalid UTF-8 string fields → `TraceSerializationFailed` (not OOM), then recoverable terminal. ✅

## P1 minimum fixtures

1. two-stage compaction: final `dropped` and summary/lineage match the returned view. ✅ h-context-001 (`context.zig` fixed-point fixtures + agent session/trace integration).
2. fake configured secrets do not appear in verbose, trace, or session bytes. ⬜ h-redact-001 (branch; pending Gate) (unit longest/boundary/xai/AWS/OOM; initial create; Session after Agent deinit; multi-tool ID pseudonyms; mid-trace OOM terminal; in-memory raw vs redacted resume).
3. timeout enforced on **curl**; **std** configured timeout → `unsupported_control` before network (default null = no timeout). ✅ h-provider-001 capability-truth
4. stream requires protocol completion; incomplete tool args reject whole turn. ✅ h-provider-001
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
