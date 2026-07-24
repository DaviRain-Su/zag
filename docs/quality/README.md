# Quality docs

| Artifact | Source |
|----------|--------|
| [evals.md](./evals.md) | Hand-written eval / security bar |
| [contracts.md](./contracts.md) | Provider / API contracts |
| [readability-report.md](./readability-report.md) | **Generated** by `scripts/score_docs.py` |
| [security-report.md](./security-report.md) | **Generated** by `scripts/score_docs.py` |

Layout gate: `python3 scripts/lint_docs.py`  
Score + thresholds: `python3 scripts/score_docs.py --check`  
Also: `zig build docs-lint` / `zig build test`
