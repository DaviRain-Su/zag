# C8 — Extensions

| 项 | 内容 |
|----|------|
| 前置 | **Phase H 完成** |
| 失败模式 | 扩展必须改核心；生态无法分享 |
| 模块 | [extensions](../modules/extensions.md) |
| 哲学 | Pi：**先包后核** |

## 目标

不改 Zag 核心也能增加工作流：Skills、Hooks、MCP、可分享 plugin 目录。

## 范围

1. Skills：目录约定 + `SKILL.md`；触发与 prompt 注入预算  
2. Hooks：PreToolUse / PostToolUse / Stop；可 deny  
3. MCP client（stdio）；tool 合并进 registry，仍过权限/jail  
4. Plugin 包：一目录 = skills + hooks + agents 定义  
5. 示例包 ≥1（文档+夹具）

## 非目标

- 商业插件市场  
- 一上来内置 30+ 官方 skills  

## 验收

- [ ] 丢入 skill 目录无需重编译即可生效（或热加载策略成文）  
- [ ] Hook 能否决危险 write（测试）  
- [ ] 至少一个 MCP server 联调文档  

## 对标

Pi packages；Hyper skills/hooks/MCP；goose  
