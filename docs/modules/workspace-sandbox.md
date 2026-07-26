# Module: workspace-sandbox

| Item | Content |
|------|---------|
| Current code | `packages/zag-agent-core/src/{workspace,shell_policy}.zig`; coding-agent file/shell tools |
| D-011 target | required `Jail`/`ShellPolicy` contracts in Core; concrete containment/policy/redaction in coding-agent |
| Current maturity | **L2** — symlink-aware file containment, redaction, doctor/readiness, and default Agent policy/containment composition passed independent/main Gate |
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
4. Enforcement selection comes from `ToolDescriptor` workspace capabilities (`path_field` or explicit `path_field_default`), not a built-in-name list.
5. Built-in file handlers re-check containment themselves so raw `Registry.execute` cannot bypass the jail. Custom tools still follow D-007: only declared workspace path capabilities are gated by the loop; their handlers must implement their own containment if they touch the FS.
6. Shell policy defaults to `protect`; disabling it is explicit.
7. H documentation says **no OS sandbox**.
8. Known secrets and common API-key shapes are redacted before verbose/trace/session persistence (`h-redact-001`), while `.zag/` remains sensitive (not DLP; arbitrary tool/file content cannot be proven secret-free).

## File containment contract (L2 sub-capability)

- Reject empty required paths and NUL/absolute/drive/UNC/lexical escape paths. Descriptor defaults are validated with the same lexical jail (`.` allowed) before a toolset can run.
- Resolve the workspace root once per `loop.run` (threaded as borrowed `tool.Context.workspace_root_real`); handlers lazy-resolve when the field is null. Required `path_field` values treat present empty strings as `invalid_arguments`; for `path_field_default`, omitted path and present empty string become the descriptor default (grep/glob use `.`) and then follow the same permission and jail path as explicit arguments.
- Existing read/list/search targets must resolve beneath that root (component-boundary compare: `/ws` does not contain `/ws2`).
- Write/create walks every existing ancestor; non-existent suffix under a verified ancestor is allowed **without** `..` after the first missing component (`new/../escape/...` → deny). Escaping or dangling intermediate/final symlinks deny. Checks complete **before** any parent create.
- File mutators additionally require a lexical file endpoint (no trailing host separator or final `.`/`..`). Existing endpoints must resolve to regular files strictly below root; directory/root aliases are invalid arguments. After canonical selection, the target is re-proven strictly below root and its staging parent root-or-descendant before any atomic temporary is opened.
- Contained file/dir symlinks (target still inside root) remain usable for read/list/search/write/replace, subject to endpoint kind: final directory symlinks are valid directory endpoints for read/list/search but not file mutators; writes under a contained directory symlink skip recreating that parent.
- Containment path compare uses **host** separators only (POSIX: `/` only — root `/tmp/ws` does not contain sibling `/tmp/ws\outside`).
- `list_dir` on an escaping directory symlink → `jail_deny`; listing a parent may show symlink **names** without reading targets.
- grep/glob walkers do not follow escaping/dangling symlinks; nested escapes skip without leaking outside bytes; directory real-path identity bounds symlink loops.
- Enforcement failure or unresolvable security-critical cases deny with machine-readable `code=jail_deny` using a stable generic, path-free Tool body. Raw path details belong only to the separate trace/audit fields under their redacted/capped contract. Ordinary missing files stay `ToolFailed` / not “safe to escape”.
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
| Code | `packages/zag-coding-agent/src/redact.zig` (moved from Core by core-observation-ownership-001); wired via Trace / Session-owned redactor / observer / Agent / CLI |
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

Task: [h-doctor-001](../plan/tasks/h-doctor-001.md) (**done** — independent review + main std/curl verification passed).

Code: `packages/zag-coding-agent/src/doctor.zig` (typed report); CLI adapter `zag --doctor` in `packages/zag-cli`; process fixture `packages/zag-cli/src/doctor_process_fixture.zig` (root `zig build test`).

`zag --doctor` is a provider-independent, human-readable readiness report. It runs after **argument validation** (session-path semantics when a session path was selected; no open) and **before** API-key/provider resolution, wire, Agent/session/trace construction, or network work. Incomplete format buffers fail closed (`error.NoSpaceLeft`), never a partial happy-path report. It reports only fixed, path-free statuses for project-instruction/test-entry **candidate presence**, permission mode, shell policy, lexical jail, real/symlink-aware file containment, product redaction-on-run, and OS-sandbox enforcement. Candidate detection uses presence/metadata probes only (no body read) and is not proof that instructions load or tests pass.

Doctor reports; it does not silently change policy. `ready` real containment means the current workspace root resolved and the file Tool Guard is applicable—it does not mean shell containment or OS enforcement. Failure to resolve the root reports `unavailable_fail_closed`. H reports exactly `os_sandbox=not_implemented`; the separate shell field is `shell_containment=not_path_contained`. Provider-key redaction binding is `deferred_until_provider_resolve` because doctor intentionally performs no provider resolution. The text report is not the stable machine protocol owned by `headless-001`.

## Current gaps

- ~~`checkToolPath` is string-only and built-in file operations follow workspace symlinks outside the root.~~ **Closed** h-workspace-001: `workspace.Root` / `Guard` + handler enforcement.
- ~~systematic redaction~~ **Closed** h-redact-001 (known keys/patterns only; not DLP).
- ~~doctor not implemented~~ **Closed** h-doctor-001 (path-free report + permanent no-key process fixture).
- ~~default Agent policy/containment composition missing~~ **Closed** h-integration-001 (`Agent.reply` ask-deny write + yolo escaping-symlink jail); fresh 11-sentence integration audit PASS, panel SHIP, merged-main Gate passed at `d22ce6e`.
- OS sandbox is intentionally absent.
- Shell remains a separate, non-path-jail boundary.

## L2 acceptance

- [x] escaping symlinks are denied for read/list/grep/glob/write/search_replace. *(file containment sub-capability)*
- [x] normal contained paths and documented contained symlinks work.
- [x] policy matrix tests pass (shell denylist; file fixtures in evals).
- [x] secret fixtures do not appear in verbose/trace/session output (h-redact-001).
- [x] doctor exposes active controls without provider/API-key resolution (h-doctor-001; permanent process fixture).
- [x] SECURITY and maturity state the same trusted-host/non-sandbox boundary; Agent composition passed independent/main Gate.

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
