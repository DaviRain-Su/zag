# Process supervisor

> Binding draft for [process-supervisor-001](../plan/tasks/process-supervisor-001.md)
> (D-012 item 3 — process ownership before LSP / MCP / subagents / mid-flight
> shell preemption). Architecture direction from
> [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md) and
> [2026-08-06 analysis](../plan/analysis/2026-08-06-pi-omp-hyper-local-agent-analysis.md).
>
> **Status:** implementation **landed** (Wave 1b) — dual review still **open**;
> task remains `draft` until reviews PASS. Not a maturity raise.
> Semantic references: Hyper `Computer`/workspace process lifecycle, OMP bash-pty
> ownership — **not** API/source parity (D-009).

## 1. Principles

1. **Every executable child has an owner** in product code (`zag-coding-agent`
   or a future dedicated process package under coding-agent ownership). The
   Kernel loop never spawns OS processes.
2. **Truthful terminal**: every started child ends in exactly one closed
   terminal code (`completed` / `timed_out` / `cancelled` / `failed` /
   `spawn_failed`). No silent loss of exit status.
3. **Bounded output**: stdout/stderr (and combined body) are capped; overflow
   is visible in the result vocabulary, never unbounded RAM growth.
4. **Tree ownership v1**: supervisor tracks the **direct child** PID (and, when
   platform-supported without new maturity claims, process-group membership).
   Full recursive reaper for grandchildren is a **later Gate** unless proved
   without OS-sandbox claims.
5. **Cancel is explicit**: cooperative cancel (close stdin / signal) plus a
   bounded hard kill deadline. Mid-flight Tool preemption for *arbitrary* Tools
   remains product-layer; supervisor only owns process-shaped work.
6. **Reuse shell-v1 where honest**: existing `run_shell` body limits, redaction,
   and soft-error first-lines stay binding; supervisor generalizes lifecycle
   without inventing a second shell dialect.

## 2. Ownership

| Layer | Owns | Must not |
|-------|------|----------|
| **`zag-coding-agent`** | Supervisor API; `run_shell` migration onto supervisor; future LSP/MCP/subagent process slots | Core ports for spawn; Session schema fields for live PIDs |
| `zag-agent-core` | Existing cancel/control seams only | OS process types, PID tables, pipes |
| `zag-cli` / `zag-tui` | Thin signal forwarding into existing Cancel/ControlInput | Direct kill of children bypassing supervisor |
| Future services (LSP/MCP) | Register as supervised slots | Raw `std.process.Child` outside supervisor |

## 3. Model-visible surface (v1)

v1 does **not** add a new model Tool by default. It **replaces the process
backend** under `run_shell` and exposes a coding-agent-internal API:

```text
Supervisor
  spawn(spec) -> Handle | spawn_failed
  wait(handle, budget) -> Terminal
  cancel(handle, mode) -> void   // cooperative then hard
  collect(handle) -> bounded Output
  // optional later: list / kill_all_on_run_end
```

| Item | Binding |
|------|---------|
| `spec.argv` or shell form | Prefer argv for new callers; `run_shell` may keep `sh -c` with existing ShellPolicy |
| Working directory | Workspace-relative; jail unchanged |
| Env | Explicit allow-list only (no ambient secret dump); redaction on bodies |
| Timeout | Mandatory deadline for v1 foreground; background jobs **out of v1** |
| Body caps | ≥ shell-v1 stream/envelope caps; single combined result body ≤ 64 KiB for Tool path |
| Cancellation | Align with Agent Cancel: first request cooperative; hard kill after bounded wait |

### 3.1 Result vocabulary (process-v1 sketch)

Closed first-line atoms (exact strings frozen at ready review):

| code | Meaning |
|------|---------|
| `spawn_failed` | never ran |
| `completed` | exit status recorded (include `exit=` atom) |
| `timed_out` | deadline; child hard-killed or kill attempted |
| `cancelled` | cancel path; child reaped |
| `failed` | I/O or unexpected supervisor error after spawn |
| `output_truncated` | body hit cap (may combine with completed) |

No absolute paths, raw OS errno strings, or secret env values on the first line.

## 4. Pipeline (normative sketch)

```text
validate spec + ShellPolicy (if shell form)
  → spawn direct child (record handle, start clock)
  → pump stdout/stderr under caps until exit | deadline | cancel
  → on deadline/cancel: cooperative signal → wait budget → hard kill
  → reap; emit exactly one Terminal
  → map to Tool soft body for run_shell path
```

Pre-spawn failures never leave zombie PIDs. Post-spawn failures still reap.

## 5. Relationship to existing contracts

| Contract | Rule |
|----------|------|
| [tools-shell.md](./tools-shell.md) | shell-v1 body/policy remain; supervisor is the **execution owner** post-migration |
| [harness-steering.md](./harness-steering.md) / cancel | Cancel flag observed at pump boundaries; no claim of mid-batch Tool preemption for non-process Tools |
| Session v1 / Trace v1 / headless-v1 | **unchanged** in v1 (no PID fields in durable session) |
| Core / D-011 | **no** process ports in Core |
| Maturity | Shell / Workspace rows stay **L2** unless a separate Gate raises them; no OS-sandbox claim |
| D-012 successors | LSP, ACP, rpc-v1, and in-process subagents **already landed** as documented exceptions (they do not wait on this draft). MCP/E2 and long-lived stdio slots **do** depend on supervisor existing. This contract still owns `run_shell` migration. |

## 6. Fixtures (implementation track — when ready)

| # | Class | Expect |
|---|-------|--------|
| 1 | Happy echo | completed + exit=0 + body |
| 2 | Nonzero exit | completed + exit≠0 truthful |
| 3 | Timeout | timed_out; no hang; process gone |
| 4 | Cancel cooperative | cancelled; reaped |
| 5 | Hard kill after cancel budget | cancelled/timed_out; no orphan under test harness |
| 6 | Output over cap | truncated marker; finite memory |
| 7 | ShellPolicy deny | no spawn |
| 8 | Jail cwd escape | fail closed pre-spawn |
| 9 | run_shell matrix regression | existing shell-v1 goldens green |
| 10 | Ownership | no Core process symbols |

## 7. Non-goals (v1)

- Background job scheduler / `monitor` product surface (Hyper-style)
- Full process-tree kill on all platforms without evidence
- OS sandbox / seccomp / seatbelt
- PTY interactive shell (OMP bash-pty) — later Gate
- MCP/LSP protocol itself
- WASM E3
- Desktop Computer Hub / browser / computer-use
- Power-loss durable process journal

## 8. Open questions — proposed v1 freeze (pending dual review)

These are the Wave 1a recommended freezes from
[2026-08-13 next delivery plan](../plan/analysis/2026-08-13-next-delivery-plan.md).
They do **not** move this task to `ready` until two independent reviews PASS.

| # | Question | Proposed v1 freeze |
|---|----------|-------------------|
| 1 | New Zig file vs package | `packages/zag-coding-agent/src/runtime/process_supervisor.zig`. No new package until a second consumer. |
| 2 | Atomic `run_shell` migration vs flag | **Atomic** in one impl PR. shell-v1 goldens are the regression Gate. No long-lived dual backend flag. |
| 3 | Linux `setpgid` vs portable direct-child | Portable **direct-child PID** only. Process-group / full tree reaper = later Gate. |
| 4 | First-line atom table | Reuse overlapping shell-v1 strings. Supervisor-specific terminals may add `spawn_failed` and `timed_out` only if not already present. |

## Related

- [process-supervisor-001](../plan/tasks/process-supervisor-001.md)
- [tools-shell.md](./tools-shell.md) · [workspace-sandbox.md](./workspace-sandbox.md)
- [D-012](../decisions/active/D-012-complete-local-coding-agent-target.md)
- [D-011](../decisions/active/D-011-thin-agent-core-boundary.md)
- Hyper: `packages/tools/xai-grok-tools` Computer / terminal lifecycle
- OMP: bash tool runtime + natives shell/pty docs
