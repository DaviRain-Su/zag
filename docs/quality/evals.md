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
| Shell runtime | Stable policy/runtime outcomes, capture budget, direct-child cleanup, and Agent trace composition | H2/P1 |
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

## P1 Phase H module and composition fixtures

1. two-stage compaction: final `dropped` and summary/lineage match the returned view. ✅ h-context-001 (`context.zig` fixed-point fixtures + agent session/trace integration).
2. fake configured secrets do not appear in verbose, trace, or session bytes. ✅ h-redact-001 (longest/boundary/pattern + allocator sweeps; initial create; Session after Agent deinit; collision-safe Tool IDs across resume; mid-trace OOM terminal; outward diagnostic helpers).
3. timeout enforced on **curl**; **std** configured timeout → `unsupported_control` before network (default null = no timeout). ✅ h-provider-001 capability-truth
4. stream requires protocol completion; incomplete tool args reject whole turn. ✅ h-provider-001
5. doctor runs without provider/API key and reports fixed, path-free project/test/policy/containment/redaction/sandbox states before provider resolution. ✅ h-doctor-001:
   - library: coding-agent `doctor.zig` candidate matrix, fail-closed format (`NoSpaceLeft` on tiny buffer), shared obtain→map body with injected `ResolveFailed`/`OutOfMemory` → `unavailable_fail_closed` + full path-free format, secret non-leak;
   - **process fixture** `doctor_process_fixture` (root `zig build test`, both HTTP backends): spawns built `zag` with **empty env** (no API keys/config) under isolated cwd — default `--doctor` exit 0 + full fixed keys; `--yolo --shell-policy off --no-project --doctor`; legal `-s`/`--trace` + `--doctor` creates **no** session/trace files; absolute/`../` session + `--doctor` exit 2 with generic validation error and **no** path/secret echo.
   - Independent review and main std/curl verification passed.
6. default Agent policy denial and escaping-symlink containment denial agree across unchanged outside/target bytes, machine-readable Tool result, transcript, persisted/resumed session, permission/jail trace, and truthful terminal. ✅ h-integration-001 coding-agent `Agent.reply` fixtures (`h-integration: default Agent ask-deny write…`, `…yolo escaping-symlink jail_deny…`); independent verification and both main backend suites passed.
7. cancel between accepted Tools preserves original IDs, skips pending handlers, writes cancelled bodies for every pending call, and agrees across Result/transcript/save-resume/one trace terminal. ✅ h-integration-001 (`h-integration: cancel between accepted Tools…`); independent verification and both main backend suites passed. This is not mid-flight Tool/shell preemption.
8. synchronous shell-v1 matrix is stable and bounded. 🟨 h-shell-001 in-progress — package matrix landed; independent/main Gate pending:
   - module: success with both streams, exit 7, POSIX signal, short absolute capture timeout, tiny per-stream output cap, invalid test shell path/process failure, direct stopped/unknown formatter cases, maximum 30 KiB + 30 KiB formatter, and OOM;
   - first lines distinguish `shell_success | shell_nonzero | shell_signal | shell_timeout | shell_output_limit | shell_process_failure`; process failure fixes `stage=run|term` plus stopped/unknown fields; policy remains `shell_deny`;
   - timeout/output-limit report no fake partial stream and return after Zig std direct-child kill/reap; no end-to-end wall-clock, process-tree, or mid-flight cancellation claim;
   - Agent: policy denial plus required runtime outcomes retain exact Tool IDs through transcript/session/resume, appear in parsed trace, and recover through exactly one `completed` terminal without becoming provider timeout/error;
   - checked arithmetic proves each Tool body is `<= 64 KiB`; the maximum first line is `<= trace.cap_tool_result_body` and survives parsed trace capping.

## Independent post-H gate fixtures

1. SDK-ready: an external stateful Tool/Provider/Observer/policy/session consumer passes (`sdk-contract-001`).
2. Headless: JSON stdout is clean and the failure exit/error matrix is stable (`headless-001`).

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
