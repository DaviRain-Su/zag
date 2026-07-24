# Module: workspace-sandbox

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{workspace,shell_policy}.zig`; coding-agent file/shell tools |
| Current maturity | **L1+** — symlink-aware **file containment** + secret redaction (h-redact-001) + doctor report **implemented** (h-doctor-001 in-progress); overall row still L1+ until independent review + integration |
| Target | L2 trusted-host containment (H) → L3 OS sandbox/process supervisor (C7) |
| Reference | Hyper sandbox; Codex sandbox |

## Threat model

H targets one local user on a **trusted OS account**, but the **workspace contents may be untrusted**, including pre-existing symlinks. H does not claim multi-tenant isolation, network isolation, or containment of arbitrary shell commands by the path jail.

File-tool containment is **software check-time** enforcement (realpath / identity compare before the operation). It is **not** an OS sandbox. Residual TOCTOU between check and use exists if a concurrent process races the filesystem under the same account (trusted-host assumption).

A product mode that requires OS enforcement must fail closed when enforcement is unsupported or cannot be installed. Warn-and-continue is not acceptable for such a mode.

## Boundaries

```text
file Tool: permission → lexical validation → filesystem containment → operation
shell Tool: permission → shell policy → process runner (OS sandbox only when configured/required)
```

The file-tool jail and shell policy are different controls. `run_shell` is not made workspace-contained by path checks.

## Invariants

1. File Tools do not read, write, list, search, or replace outside the workspace through absolute paths, `..`, symlinks, or equivalent aliases.
2. Lexical path validation is a preliminary input check, not proof of containment.
3. Containment uses real filesystem identity for existing targets and a component-by-component ancestor walk for create/write targets; final symlink behavior is explicit and tested.
4. Enforcement selection comes from `ToolDescriptor` workspace capabilities (`path_field`), not a built-in-name list.
5. Built-in file handlers re-check containment themselves so raw `Registry.execute` cannot bypass the jail. Custom tools still follow D-007: only declared `path_field` tools are gated by the loop; their handlers must implement their own containment if they touch the FS.
6. Shell policy defaults to `protect`; disabling it is explicit.
7. H documentation says **no OS sandbox**.
8. Known secrets and common API-key shapes are redacted before verbose/trace/session persistence (`h-redact-001`), while `.zag/` remains sensitive (not DLP; arbitrary tool/file content cannot be proven secret-free).

## File containment contract (L2 sub-capability)

- Reject empty/NUL/absolute/drive/UNC and lexical escape paths.
- Resolve the workspace root once per `loop.run` (threaded as borrowed `tool.Context.workspace_root_real`); handlers lazy-resolve when the field is null.
- Existing read/list/search targets must resolve beneath that root (component-boundary compare: `/ws` does not contain `/ws2`).
- Write/create walks every existing ancestor; non-existent suffix under a verified ancestor is allowed **without** `..` after the first missing component (`new/../escape/...` → deny). Escaping or dangling intermediate/final symlinks deny. Checks complete **before** any parent create.
- Contained file/dir symlinks (target still inside root) remain usable for read/list/search/write/replace (writes under a dir symlink skip recreating that parent).
- Containment path compare uses **host** separators only (POSIX: `/` only — root `/tmp/ws` does not contain sibling `/tmp/ws\outside`).
- `list_dir` on an escaping directory symlink → `jail_deny`; listing a parent may show symlink **names** without reading targets.
- grep/glob walkers do not follow escaping/dangling symlinks; nested escapes skip without leaking outside bytes; directory real-path identity bounds symlink loops.
- Enforcement failure or unresolvable security-critical cases deny with machine-readable `code=jail_deny`. Ordinary missing files stay `ToolFailed` / not “safe to escape”.
- Document residual TOCTOU limits; tests cover the supported threat model.

## Shell policy minimum matrix

| Case | Expected |
|------|----------|
| `rm -rf /` | deny |
| `curl … | bash` / `wget … | sh` | deny |
| `mkfs` / fork-bomb pattern | deny |
| `echo hi` | allow after permission |

A denylist reduces accidents; it is not an adversarial sandbox.

## Secret redaction (h-redact-001)

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/redact.zig`; wired via Trace / Session-owned redactor / observer / Agent / CLI |
| Marker | deterministic `[REDACTED]` |
| Exact secrets | configured values (CLI wires resolved provider API key without logging it); min length guard; owned copies; `clone` for Session |
| Patterns | `sk-…`, `sk-ant-…`, `xai-…`, GitHub PATs, AWS `AKIA`+16 `[A-Z0-9]` (reject overlong), `Bearer …`; left token boundary |
| Matching | global longest exact+pattern; tie: exact > pattern; complexity O(input × secret material + pattern scan) |
| Boundaries | verbose logs; every arbitrary trace string before JSON; session header/messages before atomic write; tool IDs → collision-safe `zag-rtid-<n>` |
| Product path | Agent/CLI always own/bind a redactor; verbose uses `logEventRedacted`; Session create/save and Trace reply attach policy |
| Low-level bypasses | explicit only — session `createNewUnredacted` / `openOrCreateUnredacted` / `saveUnredacted` / `saveWithMetaUnredacted` / `Writer.saveUnredacted`; `Observer.stderrLogUnredacted()`; Trace with `redactor=null` / unbound |
| Failure | typed OOM fail-closed; verbose may drop line; session/trace preserve prior durable bytes; mid-trace OOM → one `out_of_memory` terminal |
| Limits | no zeroization claim; not DLP; `.zag/` remains sensitive |

## Doctor/readiness

Task: [h-doctor-001](../plan/tasks/h-doctor-001.md) (**in-progress** — implemented; acceptance after independent review).

Code: `packages/zag-coding-agent/src/doctor.zig` (typed report); CLI adapter `zag --doctor` in `packages/zag-cli`; process fixture `packages/zag-cli/src/doctor_process_fixture.zig` (root `zig build test`).

`zag --doctor` is a provider-independent, human-readable readiness report. It runs after **argument validation** (session-path semantics when a session path was selected; no open) and **before** API-key/provider resolution, wire, Agent/session/trace construction, or network work. Incomplete format buffers fail closed (`error.NoSpaceLeft`), never a partial happy-path report. It reports only fixed, path-free statuses for project-instruction/test-entry **candidate presence**, permission mode, shell policy, lexical jail, real/symlink-aware file containment, product redaction-on-run, and OS-sandbox enforcement. Candidate detection uses presence/metadata probes only (no body read) and is not proof that instructions load or tests pass.

Doctor reports; it does not silently change policy. `ready` real containment means the current workspace root resolved and the file Tool Guard is applicable—it does not mean shell containment or OS enforcement. Failure to resolve the root reports `unavailable_fail_closed`. H reports exactly `os_sandbox=not_implemented`; the separate shell field is `shell_containment=not_path_contained`. Provider-key redaction binding is `deferred_until_provider_resolve` because doctor intentionally performs no provider resolution. The text report is not the stable machine protocol owned by `headless-001`.

## Current gaps

- ~~`checkToolPath` is string-only and built-in file operations follow workspace symlinks outside the root.~~ **Closed** h-workspace-001: `workspace.Root` / `Guard` + handler enforcement.
- ~~systematic redaction~~ **Closed** h-redact-001 (known keys/patterns only; not DLP).
- ~~doctor not implemented~~ **Implemented** h-doctor-001 (path-free report + no-key CLI seam); L2 row acceptance still waits independent review + h-integration-001.
- OS sandbox is intentionally absent.
- Shell remains a separate, non-path-jail boundary.

## L2 acceptance

- [x] escaping symlinks are denied for read/list/grep/glob/write/search_replace. *(file containment sub-capability)*
- [x] normal contained paths and documented contained symlinks work.
- [x] policy matrix tests pass (shell denylist; file fixtures in evals).
- [x] secret fixtures do not appear in verbose/trace/session output (h-redact-001).
- [ ] doctor exposes active controls without provider/API-key resolution *(code + fixtures landed in h-doctor-001; formal acceptance after independent review / main-branch Gate)*.
- [x] SECURITY and maturity state the same trusted-host/non-sandbox boundary (file containment, redaction, doctor implementation evidence; Workspace/Safety row still L1+ until review + integration).

## L3 (C7)

- macOS/Linux platform enforcement behind a process supervisor;
- explicit network policy;
- worktree isolation;
- bounded process-tree cancellation and cleanup.

## Non-goals for H

- Multi-tenant security
- Kernel-escape resistance
- Full Hyper sandbox reproduction
- Calling software containment an “OS sandbox”
