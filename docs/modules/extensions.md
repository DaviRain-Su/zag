# Module: extensions（Capability stub）

| 项 | 内容 |
|----|------|
| 状态 | **stub** — 前置 Phase H |
| 阶段 | [C8](../phases/C8-extensions.md) |
| 对标 | Pi packages；Hyper skills/hooks/MCP；goose |

## 不变式（目标）

1. **先包后核**：工作流优先 Skills/插件验证，再考虑内置。  
2. Hooks 可 deny 工具调用。  
3. MCP 工具动态合并进 registry，仍过 permission/jail。  

## 表面（C8）

| 表面 | 说明 |
|------|------|
| Skills | `SKILL.md` + 触发；受控进 prompt |
| Hooks | PreToolUse / PostToolUse / Stop |
| MCP | stdio client |
| Plugins | 一目录打包 skills+hooks+agents |

## L2

不适用（H 不做）。

## 非目标（早期）

- 插件市场商业化  
- 与 Hyper marketplace 协议兼容硬性要求  

## 详设

见 [C8-extensions.md](../phases/C8-extensions.md)。  
