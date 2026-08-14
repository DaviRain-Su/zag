# Backlog (non-blocking)

Deferrals and non-blocking review findings. Blocking P0/P1 items stay in [tasks/](./tasks/) and the [assessment](./analysis/2026-07-24-production-floor-assessment.md).

| Date | Source | Priority | Note |
|------|--------|----------|------|
| 2026-08-14 | process-supervisor-001 N1–N3 | P3 | `collect` does not pump spawn-path pipes; cooperative cancel sleeps on the caller thread; `runForeground` uses `error.Timeout`/`StreamTooLong` not `Code.timed_out`. Long-lived slots must not inherit these. |
| 2026-08-14 | acp-001 gate15 | P1 | Named follow-up [acp-gate15-001](./tasks/acp-gate15-001.md): second tool-bearing turn in one Session returns provider `-32000` before the tool runs. |
| 2026-07-24 | H1 | P2 | Parallel read-only tool batches; serial execution remains acceptable for L2. |
| 2026-07-24 | H2 | P2 | Additional stale-anchor recovery golden after correctness gates. |
| 2026-07-24 | H3 | P2 | Full Plan UX/hotkeys after the permission contract; current stub is not an L2 SDK claim. |
| 2026-07-24 | H6 | P2 | Session usage/cost metadata after persistence semantics are safe. |
| 2026-07-25 | H1/H2 | P2 | Tool/shell preemption needs post-H process ownership; h-provider-001 covers provider I/O only. |
| 2026-07-24 | Assessment | P2 | C4 edit sharpness and C5.1 repo map may start after their H dependencies. |
| 2026-07-24 | Assessment | P2 | OS sandbox/process supervisor before higher-autonomy background jobs and executable extensions. |
| 2026-08-06 | D-012 | P2 | Local coding-agent route selects multi-file edit transactions, repo map/LSP, supervisor, `rpc-v1`/ACP, typed subagents, MCP/E2, session tree, runtime model data, and default-off Memory for separate task contracts; Graph remains optional. |
| 2026-07-24 | Assessment | P2 | Measure startup/size/cross-build before making Zig performance claims. |
| 2026-07-24 | Packaging | P2 | Repo split/C ABI/dynamic plugin ABI deferred until second consumer/release channel (SDK gate is closed). |
| 2026-07-25 | h-doctor-001 N1 | P2 | `--doctor` silently ignores other legal product flags/prompt (`--stream`, `--config`, `--plan`, `-v`, free-text). Report-only surface still correct; optional reject-or-document UX later. |
| 2026-07-25 | h-integration-001 review | P2 | Jail composition still uses process-global `ScopedCwd` (restore is fail-loud). Prefer Dir-scoped Agent/tool workspace injection for future parallel isolation when product API allows. |
| 2026-07-25 | h-integration-001 review | P3 | Trace `tool_result` has no call-id field; pending cancelled pairing is transcript/session-owned (schema-true; optional future id on tool_result). |
| 2026-07-25 | h-integration-001 review | P3 | Jail fixture `SkipZigTest` on Windows / symlink `AccessDenied` — document CI hosts without symlink support skip rather than fail closed. |
| 2026-07-25 | h-shell-001 Oracle | P3 | Add a shell-specific valid UTF-8 NUL/control-byte transcript/session/resume/parsed-trace roundtrip fixture; core trace control-byte escaping already passes, so this is evidence hardening rather than an L2 blocker. |
| 2026-08-06 | D-012 | deferred | Provider/OAuth breadth, Bun/TS compatibility, Pi/npm package manager, and Pi RPC command/schema parity remain out of scope. Cloud collaboration, marketplace operation, browser/desktop control, and voice/media are not the local coding-agent target. |
| 2026-07-26 | D-009 | P2 | Historical `pi-mono-zig` goldens may be imported only by a scoped provenance task (exact commit/path + MIT notice + relevance test). |
| 2026-07-26 | D-010 review | P2 | WASM runtime selection must measure Component Model support, macOS/Linux integration, license/security update path, metering, trap isolation, and binary/startup/RSS cost before choosing an engine. |
| 2026-07-26 | D-010 review | P3 | E2/E3 supply-chain work (signing/remote registry/updater) remains a separate Gate after local manifest+digest+quarantine. |
| 2026-07-26 | Pi feature correspondence | P2 | **resolved by skills-001** (done @ `caafef5`): Agent Skills v1 roots, `/skill:name`, manual-only, and project-trust ordering are binding in [skills.md](../modules/skills.md) / [skills-001](./tasks/skills-001.md); Runtime Extensions remains L0. |
| 2026-07-26 | Pi feature correspondence | deferred | Zag-native `rpc-v1`, runtime model catalog, theme host, bundle configuration UI, and stateful extension view/action schema are formal capability placeholders, not ready tasks. |
| 2026-07-26 | Pi feature correspondence | P2 | E3 begins with compute-only Tools; later hooks/commands/Provider/UI worlds require separate semantic/capability/fallback Gates and do not inherit maturity. |
| 2026-07-26 | core-boundary-001 review | P2 | **resolved by core-observation-ownership-001**: the exact current Trace `run_start`/`run_end` → facade and remaining kinds → `LoopEvent` source transition is now explicit in [core-boundary.md](../modules/core-boundary.md#trace-vocabulary-source-map-core-observation-ownership-001) and [trace-observability.md](../modules/trace-observability.md). `run_start`/`run_end` are facade-only and never added to Core `LoopEvent`; the twelve kinds source exactly once. |
| 2026-08-14 | live-runtime-spike-001 review F5 | P3 | **resolved by live-runtime-spike-002**: canonical Chez `write` escaping on both sides + strict decode; 1500-case fuzz + independent adversarial round-trips byte-identical. |
| 2026-08-14 | live-runtime-spike-001 review F6 | P3 | **resolved by live-runtime-spike-002**: 4 MiB frame cap both sides, clean rejection, image survives. |
| 2026-08-14 | live-runtime-spike-001 review F7 | P3 | Journal-intact check is shallow; gen-1 commit assertions hard-coded; dead `Scheme.shutdown` — cosmetic hardening for a future round. |
| 2026-08-14 | live-runtime-spike-001 review F8 | P3 | **resolved by live-runtime-spike-002**: staging-dir + rename-on-pass; no orphan generation dirs on failed commit. |
| 2026-08-14 | live-runtime-spike-001 review F9 | P3 | **resolved by live-runtime-spike-002**: quarantine `defer` covers apply/check error exits, not only value mismatch. |
| 2026-08-14 | live-runtime-spike-002 review G1 | P3 | `kernel.inspect` dependents list can duplicate across base/replay scans (no dedup). |
| 2026-08-14 | live-runtime-spike-002 review G2 | P3 | Chez error text shows raw `~?` format placeholders (cosmetic). |
| 2026-08-14 | live-runtime-spike-002 review G3 | P3 | `runtime.ss` comment describes dotted-pair alist but wire format is 2-element lists (doc nit). |
| 2026-08-14 | live-runtime-spike-002 review G4 | P3 | F9 quarantine defer also fires on supervisor-side infra failures (e.g. clean-spawn error) — safe-direction for spike; promotion must decide quarantine-vs-retry there. |
| 2026-08-14 | live-runtime-spike-003 review H1 | P2 | **resolved at closeout 2026-08-14**: round-4 findings appended to the analysis doc. |
| 2026-08-14 | live-runtime-spike-003 review H2 | P3 | Conversation append is two writes (entry, newline) — a crash between them can glue the next append into one line, silently hiding an entry; make append one write. |
| 2026-08-14 | live-runtime-spike-003 review H3 | P3 | TOCTOU between realpath containment check and actual read in `jailedRead`; acceptable for spike, must close at promotion. |
| 2026-08-14 | live-runtime-spike-003 review H4 | P3 | Pure provider-call-in-flight kill window is safe by construction but never demonstrably triggered across 12 chaos runs; add a deterministic trigger if this path matters at promotion. |
| 2026-08-14 | live-runtime-spike-003 review H5 | P3 | Killer thread polls the whole store file at 200 µs; FileNotFound-vs-JailEscape test nuance — cosmetic. |
| 2026-08-14 | zag-live-001 arch review R1 | P3 | `process-supervisor.md`'s own ownership table lacks the reciprocal zag-live exception pointer; fix at its next revision. |
| 2026-08-14 | zag-live-001 arch review R2 | P3 | No doc names the conversation store's owning later task (spike-003's store was not promoted to zag-live v1). |
| 2026-08-14 | zag-live-001 arch review R3 | P3 | Error→API-call mapping in zag-live.md still implicit. |
| 2026-08-14 | zag-live-001 safety review N4 | P3 | Commit pointer-flip fsync ordering + durability class unstated in zag-live.md. |
| 2026-08-14 | zag-live-001 safety review N5 | P3 | Threading model, `deinit` on a running image, pipe-EOF orphan reaping unspecified in zag-live.md. |
| 2026-08-14 | zag-live-001 impl review M3 | P3 | Request deadline covers only the first frame byte; partial-frame-then-hang blocks a request. |
| 2026-08-14 | zag-live-001 impl review M4 | P3 | `stop()` has no wall-clock kill budget (latent; every current hang path restarts first). |
| 2026-08-14 | zag-live-001 impl review M5 | P3 | Journal discard/suspect/commit lines only prefix-validated (tampering-only, trusted state_dir). |
| 2026-08-14 | zag-live-001 impl review M6 | P3 | Test seams (`forceKillImage`, `sendRawFrameUnchecked`, `fail_clean_spawn`) are `pub` on the product type — safe, needs a doc note. |
