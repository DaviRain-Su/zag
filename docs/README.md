# Zag 文档地图

> Zig 是载体；**harness** 是主角。  
> Teaching Track（Phase 0–3）已完成教程验收；**Production Floor（Phase H）尚未完成**——在此之前不要把 Zag 写成「已生产就绪」。

## 读者路径

```text
vision → maturity（看清自己在哪）
  → roadmap（Teaching 复习 / 直接 H / Capability）
  → modules/*（实现规格）
  → chapters/*（动手）
  → gaps/*（每章离生产还差什么）
```

## 入口

| 文档 | 作用 |
|------|------|
| [vision.md](./vision.md) | 产品定位、吸收原则、刻意不做 |
| [maturity.md](./maturity.md) | **真理源**：子系统 L0–L3 成熟度矩阵 |
| [roadmap.md](./roadmap.md) | Teaching / Phase H / Capability / Quality |
| [architecture.md](./architecture.md) | 现状 vs 目标分层 |
| [references.md](./references.md) | 外部教程与竞品对照入口 |

## 规格与阶段

| 目录 | 作用 |
|------|------|
| [gaps/](./gaps/) | Teaching 各章 → L2 生产缺口 |
| [modules/](./modules/) | 模块规格（不变式、API、验收） |
| [phases/](./phases/) | Phase H 与 Capability C4–C9 |
| [quality/](./quality/) | golden / security eval / provider 合同 |

## 教程章

| 章 | 状态 | 说明 |
|----|------|------|
| [chapters/00-loop](../chapters/00-loop/README.md) | tutorial-complete | 最小 loop |
| [chapters/01-edit-permissions](../chapters/01-edit-permissions/README.md) | tutorial-complete | write + ask/yolo |
| [chapters/02-session-context](../chapters/02-session-context/README.md) | tutorial-complete | session + context view |
| [chapters/03-production](../chapters/03-production/README.md) | tutorial-complete | jail + policy + trace（**非**生产完成） |
| [chapters/H-harden](../chapters/H-harden/README.md) | planned | Production Floor 硬化 |

## 相关根文档

- [../README.md](../README.md) — 项目入口  
- [../SECURITY.md](../SECURITY.md) — 安全默认  
- [../AGENTS.md](../AGENTS.md) — 给 coding agent 的仓库约定  
