# C5 — Context Engineering

| 项 | 内容 |
|----|------|
| 前置 | Phase H session/context L2 ✅ |
| 近期路线位置 | M1 `session-fork-001` ✅ at `0a3087f` |
| 失败模式 | 旁问污染主线；中型仓库选错文件；长会话 view 退化 |
| 模块 | [context-compaction](../modules/context-compaction.md)、[session-store](../modules/session-store.md)、[session-fork](../modules/session-fork.md)（done）、[memory](../modules/memory.md) |

## 目标

首个 Pi-style session fork 切片已闭合，同时保留 Zag 的 atomic save、writer lock、redaction、schema 和 deterministic final-view accounting。完整 tree/journal 仍后置。

## Delivery order

| Domain label | 主题 | 当前取舍 |
|--------------|------|----------|
| C5.2 | **Session fork / tree** | M1 idle-only durable fork **done @ `0a3087f`** — [session-fork](../modules/session-fork.md) · [session-fork-001](../plan/tasks/session-fork-001.md)；parent 不变、child durable、无 schema fallback；tree/journal 仍未实现，**不升 L3** |
| C5.1 | Repo map | deferred：先要 measured file-selection failure；不因竞品存在而内置 |
| C5.3 | Compaction 升级 | optional：现有 deterministic fixed-point 保持默认；LLM summary 需独立质量 fixture |
| C5.4 | Memory Repo | default-off/deferred：无当前跨 session retrieval use case |

编号保留历史 domain identity；交付顺序不按编号。

## Session fork invariants

Binding detail: [session-fork](../modules/session-fork.md) (task
[session-fork-001](../plan/tasks/session-fork-001.md), done at `0a3087f`).

- fork 不修改 parent transcript/session bytes、lease、queues；
- child 仅用 lexical relative distinct path + exclusive `create_new` /
  `createNewWithRedactor`；独立 arena / redactor / empty queues；
- secret redaction、Tool bundle validation、open-mode fail-closed 不退化；
- live deep-copy（含 content_parts）不得仅靠 JSONL load roundtrip；
- schema v1 不变（无 parent_id/tree）；未知 schema 仍拒绝打开；
- 本切片不宣称 L3 或 fsync/symlink/UI/RPC/CLI。

## Memory boundary

Memory 不是 transcript、compaction summary 或 `AGENTS.md`。关闭时必须零行为变化；在真实 write→retrieve→delete 场景出现前不建立 Kernel hook。

## 验收

- [x] fork 后 parent byte-equal；
- [x] child resume 得到预期 branch view；
- [x] lock/redaction/schema fault matrix 通过；
- [x] repo map/LLM summary/Memory 保持未启用且不改变现有行为；
- [x] merged-main std 579/579、curl 578/578、SDK 21/21，Session 仍为 L2。

## 对标

Pi session tree/fork；Nanocodex fork。旧 `pi-mono-zig` session fixtures 可在 provenance task 中借鉴，不直接移植其 manager 架构。
