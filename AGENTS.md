# Zag — agent entry

Zig coding-agent: **tutorial harness + production floor**. Zig **0.16**.

## Where to change code

| Layer | Path |
|-------|------|
| L0 types | `packages/zag-types/` |
| Kernel loop | `packages/zag-agent-core/` |
| Coding product | `packages/zag-coding-agent/` |
| Model plane | `packages/zag-ai/` |
| CLI | `packages/zag-cli/` |
| Third-party (path-vendored) | `packages/third_party/` |
| Thin `main` | `src/main.zig` |

Package rules: [docs/packaging.md](docs/packaging.md).

## Hard rules (stable)

- Default permission: **ask** — do not push `--yolo` for real use.
- Paths stay **relative** (workspace jail). Prefer `--shell-policy protect`.
- Sessions: `.zag/sessions/` when `-c` / `--session`.
- Teaching 0–3 = tutorial only. Production claims need [docs/maturity.md](docs/maturity.md) L2 exit.

## Doc map (start here)

| Bucket | Entry |
|--------|-------|
| **Index** | [docs/INDEX.md](docs/INDEX.md) |
| **Product Spec** | vision · maturity · architecture · packaging · modules |
| **Active** | Phase H + [docs/plan/](docs/plan/) + [docs/decisions/active/](docs/decisions/active/) |
| **Complete** | Teaching chapters · [docs/decisions/complete/](docs/decisions/complete/) |
| **Reference** | [docs/references.md](docs/references.md) · [docs/research/](docs/research/) |
| **Quality** | [docs/quality/](docs/quality/) (evals · generated readability/security scores) |

When behavior changes: update `chapters/` and/or `docs/maturity.md` in the same change.
