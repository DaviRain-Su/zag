# Zag 文档地图

> **权威入口**：[INDEX.md](./INDEX.md)（XPlan buckets：Product Spec · Active · Complete · Reference · Quality）。  
> Zig 是载体；**harness** 是主角。Teaching 0–3 已验收；**Phase H 未完成前不要写「已生产就绪」**。

本页保留历史读者路径；新文档与决策请按 INDEX 落桶。

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
| [INDEX.md](./INDEX.md) | **桶地图** + lint / score 说明 |
| [vision.md](./vision.md) | 双轨定位（Kernel SDK × All-in-One）、吸收原则 |
| [packaging.md](./packaging.md) | 包分层与拆包设计（对齐 Grok Build workspace） |
| [maturity.md](./maturity.md) | **真理源**：子系统 L0–L3 成熟度矩阵 |
| [roadmap.md](./roadmap.md) | Teaching / Phase H / Capability / Quality |
| [architecture.md](./architecture.md) | **钉死**：Loop⊂Graph、WireAdapter、Agent/Memory/产品壳分层 |
| [production-floor assessment](./plan/analysis/2026-07-24-production-floor-assessment.md) | 评估结论、P0/P1/P2 与实施 DAG |
| [plan/](./plan/) | Active 交付（analysis · tasks · reviews · backlog） |
| [decisions/](./decisions/) | Active / Complete 设计决策 |
| [references.md](./references.md) | 外部教程与竞品对照（**Pi 主对照**） |
| [research/2026-harness-landscape.md](./research/2026-harness-landscape.md) | 2026 行业扫描 + Pi 对照 + Zag 缺口 |

## 规格与阶段

| 目录 | 作用 |
|------|------|
| [gaps/](./gaps/) | Teaching 各章 → L2 生产缺口 |
| [modules/](./modules/) | 模块规格（不变式、API、验收、[代码映射](./modules/README.md#代码映射表)） |
| [modules/memory.md](./modules/memory.md) | **Memory Repo**（C5；H 不做；默认可关） |
| [phases/](./phases/) | Phase H 与 Capability C4–C9 |
| [quality/](./quality/) | golden / security eval / provider 合同 / 生成评分报告 |

## 包边界（实现时）

```text
# consumer → dependency
main → zag-cli → coding-agent → agent-core → zag-types
                         └────→ zag-ai ─┬→ zag-types
                                       └→ openai-zig
```

详见 [architecture.md § Monorepo 包边界](./architecture.md#monorepo-包边界强制)。

## 教程章

| 章 | 状态 | 说明 |
|----|------|------|
| [chapters/00-loop](../chapters/00-loop/README.md) | tutorial-complete | 最小 loop |
| [chapters/01-edit-permissions](../chapters/01-edit-permissions/README.md) | tutorial-complete | write + ask/yolo |
| [chapters/02-session-context](../chapters/02-session-context/README.md) | tutorial-complete | session + context view |
| [chapters/03-production](../chapters/03-production/README.md) | tutorial-complete | jail + policy + trace（**非**生产完成） |
| [chapters/H-harden](../chapters/H-harden/README.md) | in progress | P0/P1 Production Floor hardening |

## 相关根文档

- [../README.md](../README.md) — 项目入口  
- [../SECURITY.md](../SECURITY.md) — 安全默认  
- [../AGENTS.md](../AGENTS.md) — 给 coding agent 的仓库约定（薄入口）  
