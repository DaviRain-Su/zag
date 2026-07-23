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

## 2. Zag 目标包分层

Zig monorepo，`packages/` 下逐步成形。**目录即未来包边界**；现有 `src/agent` 是 L3+L4 的胚胎。

```text
L0 契约          zag-types           message · tool 定义/调用/结果 · sampling · config · workspace 类型（无 IO）
L1 基础设施      （暂并入各包；token 估算 / paths 等膨胀后再拆 zag-utils）
L2 领域服务      openai-zig          HTTP SDK（已存在，最底层传输）
                 zag-ai              providers · catalog · stream · contract（已存在）
                 zag-tools           fs/edit/grep/shell 工具实现（H2 后拆出）
                 zag-workspace       jail · git · worktree（H5 后拆出）
                 zag-sandbox         OS 沙箱（C7 新包）
                 zag-hooks / zag-mcp / zag-memory / zag-compaction（C 轨按需新包）
L3 agent 定义    zag-agent           Agent/子代理/persona = 工具 + 采样 + hooks 组合（C6 拆出）
L4 内核 ★SDK 主入口
                 zag-kernel          session · turn loop · permissions · trace · subagent 编排
L5 产品面        zag-cli             headless/CLI（现 src/main.zig 迁移方向）
                 zag-tui             TUI（C9）
                 zag-acp             ACP 嵌 IDE（C9）
L6 发行          zag (bin)           all-in-one 组装
```

### 依赖规则（强制）

1. **只准朝下依赖**；L4 不得 import L5/L6。
2. L2 包之间不互相依赖，经 L0 契约通信（例外须在本文件登记）。
3. HTTP/网络细节 quarantine 在 `openai-zig` / `zag-ai` / 未来 `zag-mcp` 内部；`zag-kernel` 不见 HTTP。
4. 每个包独立 `zig build test`；契约测试放在被依赖方。

### 与现有代码 / 概念名映射

[architecture.md](./architecture.md) 的概念层 ↔ 包名：

| 概念层（architecture） | 包（本文件） |
|------------------------|--------------|
| Product shell | zag-cli / zag-tui / zag-acp + zag (bin) |
| Kernel（Agent Core） | zag-kernel（+ C6 拆出 zag-agent） |
| Model plane（canonical + WireAdapter） | zag-ai（adapters）+ openai-zig（首个 wire 后端） |
| Runtime | zag-tools / zag-workspace / zag-sandbox |
| 契约 | zag-types（canonical 类型现暂住 `zag-ai/types`，届时上提） |

| 现在 | 未来包 | 拆分时机 |
|------|--------|----------|
| `packages/openai-zig` | openai-zig | 已就位 |
| `packages/zag-ai` | zag-ai | 已就位 |
| `zag-ai/types` + `src/agent/{message,tool}.zig` 中的类型 | zag-types | H 期间先归目录，C 轨拆包 |
| `src/runtime/*` + toolset | zag-tools | H2 完成后 |
| `src/agent/{workspace,shell_policy}.zig` | zag-workspace | H5 完成后 |
| `src/agent/{loop,permissions,context,session_store,trace,agent}.zig` | zag-kernel | C6 前后（subagent 需要它成形） |
| `src/main.zig` | zag-cli | zag-kernel 拆出后 |

**原则：先按包边界整理目录与 import 方向（零成本），API 稳定后才真正 `build.zig.zon` 化。**

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

- **Phase H**：不拆包；但 H 各切片的模块规格（`docs/modules/*`）即未来包的 API 草稿，实现时按第 2 节目录归位。
- **C 轨**：每个新能力必须在设计中声明「落进哪个包」；不允许新能力直接长在 zag-cli/main 里。
- **maturity.md** 增补视角：某包达到「API 冻结 + 测试自洁」即可标记 SDK-ready。

## 6. 刻意不做

- 一开始就把 `src/agent` 炸成十个 zon 包（先目录、后包、最后 repo）；
- 双向同步的多 repo 开发流；
- 为对齐 Grok Build 而复刻其 60+ crate 粒度——Zag 按第 2 节 10 包量级起步，膨胀再分。

## 相关

- [architecture.md](./architecture.md) — 分层图（与本文件一致）
- [vision.md](./vision.md) — 双轨定位
- [roadmap.md](./roadmap.md) — 阶段推进
