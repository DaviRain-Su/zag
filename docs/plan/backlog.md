# Backlog (non-blocking)

Deferrals and non-blocking review findings. Blocking P0/P1 items stay in [tasks/](./tasks/) and the [assessment](./analysis/2026-07-24-production-floor-assessment.md).

| Date | Source | Priority | Note |
|------|--------|----------|------|
| 2026-07-24 | H1 | P2 | Parallel read-only tool batches; serial execution remains acceptable for L2. |
| 2026-07-24 | H2 | P2 | Additional stale-anchor recovery golden after correctness gates. |
| 2026-07-24 | H3 | P2 | Full Plan UX/hotkeys after the permission contract; current stub is not an L2 SDK claim. |
| 2026-07-24 | H6 | P2 | Session usage/cost metadata after persistence semantics are safe. |
| 2026-07-25 | H1/H2 | P2 | Tool/shell preemption needs post-H process ownership; h-provider-001 covers provider I/O only. |
| 2026-07-24 | Assessment | P2 | C4 edit sharpness and C5.1 repo map may start after their H dependencies. |
| 2026-07-24 | Assessment | P2 | OS sandbox/process supervisor before higher-autonomy background jobs and executable extensions. |
| 2026-07-24 | Assessment | P2 | Memory Repo, Graph, TUI, full LSP/AST remain later capability work. |
| 2026-07-24 | Assessment | P2 | Measure startup/size/cross-build before making Zig performance claims. |
| 2026-07-24 | Packaging | P2 | Repo split/C ABI/dynamic plugin ABI deferred until second consumer/release channel (SDK gate is closed). |
| 2026-07-25 | h-doctor-001 N1 | P2 | `--doctor` silently ignores other legal product flags/prompt (`--stream`, `--config`, `--plan`, `-v`, free-text). Report-only surface still correct; optional reject-or-document UX later. |
| 2026-07-25 | h-integration-001 review | P2 | Jail composition still uses process-global `ScopedCwd` (restore is fail-loud). Prefer Dir-scoped Agent/tool workspace injection for future parallel isolation when product API allows. |
| 2026-07-25 | h-integration-001 review | P3 | Trace `tool_result` has no call-id field; pending cancelled pairing is transcript/session-owned (schema-true; optional future id on tool_result). |
| 2026-07-25 | h-integration-001 review | P3 | Jail fixture `SkipZigTest` on Windows / symlink `AccessDenied` — document CI hosts without symlink support skip rather than fail closed. |
| 2026-07-25 | h-shell-001 Oracle | P3 | Add a shell-specific valid UTF-8 NUL/control-byte transcript/session/resume/parsed-trace roundtrip fixture; core trace control-byte escaping already passes, so this is evidence hardening rather than an L2 blocker. |
| 2026-07-26 | D-009/D-010 | deferred | Provider/OAuth breadth, Bun/TS compatibility, Pi/npm package manager, Pi RPC command/schema parity, Oracle/Graph/Memory/dashboard are not parity work. Zag-native RPC and E2/E3 extensions follow separate explicit Gates. |
| 2026-07-26 | D-009 | P2 | Historical `pi-mono-zig` goldens may be imported only by a scoped provenance task (exact commit/path + MIT notice + relevance test). |
| 2026-07-26 | D-010 review | P2 | WASM runtime selection must measure Component Model support, macOS/Linux integration, license/security update path, metering, trap isolation, and binary/startup/RSS cost before choosing an engine. |
| 2026-07-26 | D-010 review | P3 | E2/E3 supply-chain work (signing/remote registry/updater) remains a separate Gate after local manifest+digest+quarantine. |
| 2026-07-26 | Pi feature correspondence | P2 | `skills-001` must decide Agent Skills interoperability, `.agents/skills` roots, `/skill:name`, manual-only behavior, and project-trust ordering. |
| 2026-07-26 | Pi feature correspondence | deferred | Zag-native `rpc-v1`, runtime model catalog, theme host, bundle configuration UI, and stateful extension view/action schema are formal capability placeholders, not ready tasks. |
| 2026-07-26 | Pi feature correspondence | P2 | E3 begins with compute-only Tools; later hooks/commands/Provider/UI worlds require separate semantic/capability/fallback Gates and do not inherit maturity. |
| 2026-07-26 | core-boundary-001 review | P2 | `core-observation-ownership-001` must make the exact current Trace `run_start`/`run_end` vocabulary → target facade/`LoopEvent` source transition explicit; current-vs-target docs are consistent but easy to misread. |
