# C5 — Context Engineering

| 项 | 内容 |
|----|------|
| 前置 | Phase H session/context L2 ✅ |
| 近期路线位置 | M1 `session-fork-001` |
| 失败模式 | 旁问污染主线；中型仓库选错文件；长会话 view 退化 |
| 模块 | [context-compaction](../modules/context-compaction.md)、[session-store](../modules/session-store.md)、[memory](../modules/memory.md) |

## 目标

先补齐 Pi-style session branch/fork 这一条高价值语义，同时保留 Zag 的 atomic save、writer lock、redaction、schema 和 deterministic final-view accounting。

## Delivery order

| Domain label | 主题 | 当前取舍 |
|--------------|------|----------|
| C5.2 | **Session fork / tree** | M1：立即分析/交付；parent 不变、child durable、无 schema fallback |
| C5.1 | Repo map | deferred：先要 measured file-selection failure；不因竞品存在而内置 |
| C5.3 | Compaction 升级 | optional：现有 deterministic fixed-point 保持默认；LLM summary 需独立质量 fixture |
| C5.4 | Memory Repo | default-off/deferred：无当前跨 session retrieval use case |

编号保留历史 domain identity；交付顺序不按编号。

## Session fork invariants

- fork 不修改 parent transcript/session bytes；
- child 有新 identity/lock，继承路径与 lineage 可审计；
- secret redaction、Tool bundle validation、open-mode fail-closed 不退化；
- branch selection 不静默丢消息或跨越 compaction boundary；
- 格式迁移显式版本化，未知 schema 拒绝打开。

## Memory boundary

Memory 不是 transcript、compaction summary 或 `AGENTS.md`。关闭时必须零行为变化；在真实 write→retrieve→delete 场景出现前不建立 Kernel hook。

## 验收

- [ ] fork 后 parent byte-equal；
- [ ] child resume 得到预期 branch view；
- [ ] lock/redaction/schema fault matrix 通过；
- [ ] repo map/LLM summary/Memory 保持未启用且不改变现有行为。

## 对标

Pi session tree/fork；Nanocodex fork。旧 `pi-mono-zig` session fixtures 可在 provenance task 中借鉴，不直接移植其 manager 架构。
