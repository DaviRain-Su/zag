# Zag 包分层与拆包设计（Kernel SDK × All-in-One）

| 项 | 内容 |
|----|------|
| 状态 | **设计文档**（结构先行；迁移与实现随 Phase H / C 轨推进） |
| 对标 | Grok Build workspace 分层（`hyper-grok-build/Cargo.toml` 60+ crates） |
| 决策 | **单 monorepo 多包**；拆 repo 是发布动作，不是架构动作 |

---

## 0. 定位修正

此前文档偏向 Pi 的「最小内核」叙事。**修正为 Grok Build 路线：**

1. **产品目标 = all-in-one**：工具、子代理、沙箱、扩展、TUI 都是一等目标，不做「刻意极简」。
2. **实现纪律 = 严格分层**：功能多不等于泥球；每个能力落进一个小包，依赖只准朝下。
3. **SDK 目标 = 内核可嵌入**：`zag-kernel` 以下的所有包都是对外 SDK 面；别人拿内核就能造自己的 agent 产品。
4. Pi 保留的只有一条：**扩展验证纪律**（新工作流先 skill/plugin 验证再内置）——不再作为「默认面要小」的依据。

```text
      All-in-One 产品（zag bin / TUI / headless）
              ▲  组装
      Kernel SDK（zag-kernel + 领域包）
              ▲  依赖
      契约层（types / tool-protocol）
```

两个客户，一套代码：自己的产品是 SDK 的第一个、也是要求最苛刻的用户。

---

## 1. Grok Build 分层（依赖证据）

从 workspace Cargo.toml 实测的依赖方向：

```text
L0 契约      xai-tool-types → xai-tool-protocol → xai-grok-tools-api → xai-tool-runtime
             sampling-types · config-types · workspace-types · hooks-plugins-types
L1 基础设施  paths · env · version · tty-utils · file-utils · token-estimation · http · secrets · tracing
L2 领域服务  models · config · auth · sampler · tools · sandbox · workspace ·
             memory · hooks · mcp · compaction · codebase-graph · hunk-tracker · chat-state
L3 agent     xai-grok-agent   （tools + sampling-types + hooks 的组合定义）
L4 内核      xai-grok-shell   （session · turn loop · subagent · workflow —— kernel）
L5 产品 UX   xai-grok-pager · pager-render · dashboard · acp-lib
L6 发行      xai-grok-pager-bin（单一二进制，组装 L4+L5）
```

**可抄的三条纪律：**

| 纪律 | Grok Build 证据 |
|------|-----------------|
| 依赖单向，产品不反噬内核 | pager-bin → pager → shell → agent → tools → tool-protocol；无回边 |
| 重依赖隔离（quarantine） | shell 注释明确：reqwest/rmcp 关在 `xai-grok-mcp` 内部，"shell never sees it" |
| 类型与实现分包 | `*-types` / `tools-api` 独立于实现 crate，SDK 消费者可只依赖契约 |

---

## 2. Zag 包分层（0.5.0 已落地骨架）

Zig monorepo。**2026-07-24 已完成第一轮拆包**（`8c5f543` + `076183e`）：
`zag-agent-core` / `zag-coding-agent` / `zag-cli` 各自独立 `build.zig(.zon)`，`src/main.zig` 只剩进程入口，`src/root.zig` 为 umbrella re-export。

```text
L0 契约          zag-types           canonical message · tool 协议 · 中性 ChatError（**下一步拆出**；现暂住 zag-ai/types）
L1 基础设施      （暂并入各包；token 估算 / paths 膨胀后再拆 zag-utils）
L2 领域服务      openai-zig          HTTP SDK ✅
                 zag-ai              resolve · WireAdapter · catalog · stream · contract ✅
                 zag-tools           fs/edit/grep/shell 实现（今在 coding-agent/runtime；H2 稳定后拆出）
                 zag-workspace       jail · git · worktree（今在 agent-core；H5 稳定后拆出）
                 zag-sandbox         OS 沙箱（C7 新包）
                 zag-hooks / zag-mcp / zag-memory / zag-compaction（C 轨按需新包）
L3 产品 harness  zag-coding-agent ✅  Agent/Session 外观 · 默认 toolset · WireProvider 桥 · runtime tools
L4 内核 ★SDK 主入口
                 zag-agent-core ✅    loop · 纯 Provider 端口 · session · permissions · trace
L5 产品面        zag-cli ✅           flags · resolve · one-shot / REPL
                 zag-tui / zag-acp   （C9）
L6 发行          zag (bin)           `src/main.zig` 薄入口 → `zag_cli.run` ✅
```

> 命名说明：早稿虚名 `zag-kernel` / `zag-agent` 已由实际包名 **`zag-agent-core`** / **`zag-coding-agent`** 取代（Pi 式命名，分层语义与 Grok Build shell/agent 一致）。文档一律用实际包名。

### 依赖规则（强制）

1. **只准朝下依赖**；L4 不得 import L5/L6。
2. L2 包之间不互相依赖，经 L0 契约通信（例外须在本文件登记）。
3. HTTP/网络细节 quarantine 在 `openai-zig` / `zag-ai` / 未来 `zag-mcp` 内部；`zag-kernel` 不见 HTTP。
4. 每个包独立 `zig build test`；契约测试放在被依赖方。

### 概念层 ↔ 实际包名

| 概念层（architecture） | 实际包 | 状态 |
|------------------------|--------|------|
| Product shell | zag-cli（+ C9 zag-tui / zag-acp）+ zag (bin) | ✅ |
| Kernel（Agent Core） | **zag-agent-core** | ✅ |
| 产品 harness（agent 定义 + 组装） | **zag-coding-agent** | ✅ |
| Model plane（canonical + WireAdapter） | zag-ai + openai-zig | ✅ |
| Runtime / 领域包 | zag-tools / zag-workspace / zag-sandbox | 待拆（下表） |
| 契约 | zag-types | **下一步** |

### 后续拆分排期

| 拆什么 | 从哪拆 | 时机 | 动机 |
|--------|--------|------|------|
| **zag-types**（canonical message/tool/usage + 中性 ChatError） | `zag-ai/types` + core 的 `message/tool.zig` re-export | **H 内，优先** | 见 §2.1：解开 core → zag-ai 依赖 |
| zag-tools | `zag-coding-agent/src/runtime/*` + toolset | H2 出门后 | 编辑面 API 稳定 |
| zag-workspace | `zag-agent-core` 的 `workspace/shell_policy` | H5 出门后 | 安全面独立演进 + C7 sandbox 挂点 |
| zag-agent（若需要） | coding-agent 中的 agent 定义 | C6 | subagent/persona 成形时再议，勿提前 |

### 2.1 已知残留：core 仍依赖 zag-ai（下一步要解）

现状 `zag-agent-core` 的「纯」只到**源码级**（不 import `Client`/`openai_compat`），
但 `message.zig` / `tool.zig` / `provider.zig` 仍 `@import("zag-ai")` 取 canonical 类型与 `ChatError = ai.wire.Error`：

- 依赖图级不纯：core → zag-ai →（传递）openai-zig；
- 错误集方向反了：**core 应定义中性 ChatError，adapter 负责映射**，而不是 core 借 wire 的错误集。

解法 = 拆 **zag-types**：canonical 类型 + 中性错误集下沉 L0；`zag-ai` 与 `zag-agent-core` 都依赖 zag-types，core 不再依赖 zag-ai。这是 Packaging 轨的**下一个动作**。

---

## 3. 拆包 / 拆 repo 标准

Monorepo 是常态（Grok Build 也是单仓）。一个包升级为独立 repo 须同时满足：

1. **API 冻结**：语义化版本，破坏性变更有迁移文档；
2. **第二使用方**：除 zag bin 外至少一个真实外部消费者（或明确的 SDK 发布计划）；
3. **测试自洽**：不依赖 monorepo 其他包的私有测试设施；
4. **发布通道**：tag / zon 包可独立获取。

拆出方式优先 **read-only mirror + tag 同步**（monorepo 仍是唯一开发源），避免双向合并。`openai-zig` 是第一个候选。

---

## 4. SDK 面承诺

| 层 | 稳定性承诺 |
|----|------------|
| L0 zag-types | 最严：semver，破坏性变更必须 major |
| L2 zag-ai / zag-tools | 稳定 API + 文档化错误集 |
| L4 zag-kernel | 嵌入入口（`Agent.init` 一族）；事件/Observer 契约版本化 |
| L5/L6 | 产品面，不做兼容承诺 |

嵌入示例（目标形态，与现 `Agent.init` 连续）：

```zig
const zag = @import("zag-kernel");
var agent = zag.Agent.init(gpa, io, provider, .{
    .permission_mode = .ask,
    .toolset = my_tools,      // 可替换：SDK 用户带自己的工具
    .observer = my_observer,  // 事件流：UI/日志自定义
});
```

---

## 5. 与路线图的关系

- **Phase H**：骨架拆分已提前完成（core/coding/cli）；H 内 Packaging 动作只剩 **zag-types 抽取**（§2.1）。其余 H 切片按模块规格实现，不再动包结构。
- **C 轨**：每个新能力必须在设计中声明「落进哪个包」；不允许新能力直接长在 zag-cli/main 里。tools/workspace 拆分挂 H2/H5 出门之后（见 §2 排期表）。
- **maturity.md** 增补视角：某包达到「API 冻结 + 测试自洁」即可标记 SDK-ready。

## 6. 刻意不做

- 在 H 内继续碎拆（zag-types 之外的拆分等 H2/H5 出门）；
- 双向同步的多 repo 开发流；
- 为对齐 Grok Build 而复刻其 60+ crate 粒度——当前 6 包 + 排期 3 包足够，膨胀再分。

## 相关

- [architecture.md](./architecture.md) — 分层图（与本文件一致）
- [vision.md](./vision.md) — 双轨定位
- [roadmap.md](./roadmap.md) — 阶段推进
