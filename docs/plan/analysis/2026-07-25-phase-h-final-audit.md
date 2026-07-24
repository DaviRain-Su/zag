# Phase H final audit — 2026-07-25

| Item | Result |
|------|--------|
| Audited commit | `78621c8` (`docs: complete h-shell-001`) |
| Default Gate | `384/384` tests passed |
| Curl Gate | `383/383` tests passed |
| Focused coding-agent | `104/104` under each backend; supported macOS shell/jail fixtures zero skip |
| Docs Gate | lint pass; readability 91/100; security-awareness 64/100 |
| Verdict | **FAIL — Phase H remains below L2** |

## Why green suites did not close H

The retained Agent policy/containment/between-Tool-cancel chains, session/context/trace/redaction contracts, doctor, provider controls, and synchronous shell Gate are real and passed. The audit nevertheless found two counterexamples on default file tools that existing fixtures did not exercise.

### 1. Write/edit target preservation

`write_file` and `search_replace` call `Io.Dir.writeFile` with `.truncate = true`. Zig opens/truncates the destination before `writeStreamingAll` completes. A later write failure can therefore destroy prior bytes or publish a prefix while the handler reports failure. Success text is also allocated after mutation, so post-commit OOM can make the observed result disagree with disk state.

This violates the owning invariant that a failed mutation must not have undeclared partial effects. [h-edit-integrity-001](../tasks/h-edit-integrity-001.md) owns same-parent staging, writer flush, final containment recheck, atomic replacement, contained final-symlink semantics, stable `edit-v1` faults, cleanup, and one Agent/session/trace recovery chain.

### 2. Read/search bounded completeness

The handlers have count/node limits but not a complete shared result contract:

- `list_dir` and `glob` can exceed 64 KiB through legal long names/paths;
- `read_file` retries an oversized limited read with another limit that can return `StreamTooLong`, so its advertised truncated prefix is not reliable on Zig 0.16;
- `grep` does not reserve its final marker and silently skips oversized inputs;
- walker depth/per-directory/node and glob-pattern limits can omit eligible output without marking the result incomplete.

[h-read-search-bounds-001](../tasks/h-read-search-bounds-001.md) owns checked 64 KiB bodies, complete `fs-v1` incomplete markers, and small deterministic N/N+1/walker/source/pattern fixtures.

## Other row decisions

- **Provider / zag-ai → L2.** The audit found no H6 behavior blocker. Curl enforces configured deadline/active cancel; std ordinary no-control requests work and requested unsupported controls fail closed before network. Dual-wire, retry/error/usage, strict SSE/Tool completion, and redacted diagnostics are covered.
- **Permission remember stays L2 with a narrower contract.** H keys approval by exact lexical request path. Aliases conservatively re-prompt and execution always re-enters Guard. Canonical filesystem-object/path-domain authorization is L3, not an H promise; focused alias/jail evidence is attached to the edit task.
- **Quality remains L1+.** Existing tests are green but do not contain the two newly required failure matrices.

## Exit sentence disposition

| Exit | Result |
|-----:|:------:|
| 1 Session durability | PASS |
| 2 Tool contract | PASS |
| 3 Containment/readiness | PASS |
| 4 Truthful lifecycle | PASS |
| 5 Context accounting | PASS |
| 6 Secrets | PASS |
| 7 Deadline/cancel within H boundary | PASS |
| 8 Editing/runtime | **BLOCKED** by both file tasks |
| 9 Observability | PASS |
| 10 Regression evidence | **BLOCKED** by missing file fault/boundary fixtures |
| 11 Documentation truth | **BLOCKED** until tasks and fresh audit agree |

## Delivery correction

The original P0/P1 module DAG and its evidence remain valid. Final audit discovered two previously unowned contracts:

```text
h-edit-integrity-001 ───────┐
                            ├─► h-integration-001 fresh audit
h-read-search-bounds-001 ───┘
```

The tasks are independent in code but overlap global truth/teaching documents, so docs-sprint executes their develop→verify→merge cycles serially. `h-integration-001` remains blocked until both are independently verified and merged.

## Explicit exclusions

This correction does not add OS sandboxing, process-tree ownership, mid-flight Tool/shell preemption, power-loss/fsync durability, hostile concurrent-filesystem safety, canonical object authorization, multi-file transactions, SDK-ready, or headless-ready claims.
