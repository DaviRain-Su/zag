# Module: workspace-sandbox

| Item | Content |
|------|---------|
| Code | `packages/zag-agent-core/src/{workspace,shell_policy}.zig`; coding-agent file/shell tools |
| Current maturity | **L1** — lexical jail/policy exist; symlink containment is P0 |
| Target | L2 trusted-host containment (H) → L3 OS sandbox/process supervisor (C7) |
| Reference | Hyper sandbox; Codex sandbox |

## Threat model

H targets one local user on a trusted OS account, but the **workspace contents may be untrusted**, including pre-existing symlinks. H does not claim multi-tenant isolation, network isolation, or containment of arbitrary shell commands by the path jail.

A product mode that requires OS enforcement must fail closed when enforcement is unsupported or cannot be installed. Warn-and-continue is not acceptable for such a mode.

## Boundaries

```text
file Tool: permission → lexical validation → filesystem containment → operation
shell Tool: permission → shell policy → process runner (OS sandbox only when configured/required)
```

The file-tool jail and shell policy are different controls. `run_shell` is not made workspace-contained by `checkToolPath`.

## Invariants

1. File Tools do not read, write, list, search, or replace outside the workspace through absolute paths, `..`, symlinks, or equivalent aliases.
2. Lexical path validation is a preliminary input check, not proof of containment.
3. Containment uses real filesystem identity for existing targets and the resolved parent for create/write targets; final symlink behavior is explicit and tested.
4. Enforcement selection comes from `ToolDescriptor` workspace capabilities, not a built-in-name list.
5. Shell policy defaults to `protect`; disabling it is explicit.
6. H documentation says **no OS sandbox**.
7. Known secrets are redacted before verbose/trace/session persistence, while `.zag/` remains sensitive.

## File containment contract (L2)

- Reject empty/NUL/absolute/drive/UNC and lexical escape paths.
- Resolve the workspace root once to a stable filesystem identity.
- Existing read/list/search targets must resolve beneath that root.
- Write/create resolves and verifies the parent; it must not follow an escaping final symlink.
- Enforcement failure or an unresolvable security-critical case denies the Tool operation with a machine-readable jail error.
- Document residual TOCTOU limits; tests cover the supported threat model.

## Shell policy minimum matrix

| Case | Expected |
|------|----------|
| `rm -rf /` | deny |
| `curl … | bash` / `wget … | sh` | deny |
| `mkfs` / fork-bomb pattern | deny |
| `echo hi` | allow after permission |

A denylist reduces accidents; it is not an adversarial sandbox.

## Secret redaction (P1)

- One shared redactor consumes configured secret values plus documented common key patterns.
- Apply before verbose logging, trace serialization, and session persistence.
- Avoid claiming arbitrary file/tool content is secret-free; keep `.zag/` private.

## Doctor/readiness

Report project instructions/test entry, permission mode, shell policy, lexical/real containment status, and sandbox availability. Doctor reports; it does not silently change policy.

## Current gaps

- `checkToolPath` is string-only and built-in file operations follow workspace symlinks outside the root.
- systematic redaction and doctor are not implemented.
- OS sandbox is intentionally absent.

## L2 acceptance

- [ ] escaping symlinks are denied for read/list/grep/glob/write/search_replace.
- [ ] normal contained paths and documented contained symlinks work.
- [ ] policy matrix tests pass.
- [ ] secret fixtures do not appear in verbose/trace/session output.
- [ ] doctor exposes active controls.
- [ ] SECURITY and maturity state the same trusted-host/non-sandbox boundary.

## L3 (C7)

- macOS/Linux platform enforcement behind a process supervisor;
- explicit network policy;
- worktree isolation;
- bounded process-tree cancellation and cleanup.

## Non-goals for H

- Multi-tenant security
- Kernel-escape resistance
- Full Hyper sandbox reproduction
