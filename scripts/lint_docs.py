#!/usr/bin/env python3
"""Lint Zag documentation layout (XPlan-style buckets + agent entry).

Checks:
  - Required entry files exist
  - AGENTS.md stays thin and does not claim false production-ready
  - docs/INDEX.md links resolve
  - decisions/* have status: active|complete and live in the matching folder
  - decision index table lists every decision file
  - quality reports exist (run score_docs.py first if missing)

Usage:
  python3 scripts/lint_docs.py
  python3 scripts/lint_docs.py --root .
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

AGENTS_LINE_MAX = 48
REQUIRED = (
    "AGENTS.md",
    "docs/INDEX.md",
    "docs/maturity.md",
    "docs/vision.md",
    "docs/architecture.md",
    "docs/packaging.md",
    "docs/plan/README.md",
    "docs/plan/backlog.md",
    "docs/decisions/README.md",
    "docs/quality/evals.md",
    "docs/quality/readability-report.md",
    "docs/quality/security-report.md",
    "SECURITY.md",
)

LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
FRONT_STATUS_RE = re.compile(r"^status:\s*(active|complete)\s*$", re.M)


def fail(errors: list[str], msg: str) -> None:
    errors.append(msg)


def check_required(root: Path, errors: list[str]) -> None:
    for rel in REQUIRED:
        if not (root / rel).is_file():
            fail(errors, f"missing required file: {rel}")


def check_agents(root: Path, errors: list[str]) -> None:
    path = root / "AGENTS.md"
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if len(lines) > AGENTS_LINE_MAX:
        fail(
            errors,
            f"AGENTS.md too long ({len(lines)} lines > {AGENTS_LINE_MAX}); keep thin index",
        )
    if "docs/INDEX.md" not in text:
        fail(errors, "AGENTS.md must link docs/INDEX.md")
    # Hard ban on claiming shipped production in agent entry
    if re.search(r"\bproduction-ready\b", text, re.I) and "until" not in text.lower():
        fail(errors, "AGENTS.md must not claim production-ready without L2 gate language")


def resolve_link(base: Path, target: str) -> Path | None:
    if target.startswith(("http://", "https://", "mailto:")):
        return None
    clean = target.split("#", 1)[0].strip()
    if not clean:
        return None  # pure anchor
    return (base.parent / clean).resolve()


def check_links(root: Path, rel: str, errors: list[str]) -> None:
    path = root / rel
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    root_resolved = root.resolve()
    for _label, target in LINK_RE.findall(text):
        dest = resolve_link(path, target)
        if dest is None:
            continue
        try:
            dest.relative_to(root_resolved)
        except ValueError:
            # outside repo — skip
            continue
        if not dest.exists():
            fail(errors, f"broken link in {rel}: ({target})")


def check_decisions(root: Path, errors: list[str]) -> None:
    decisions = root / "docs" / "decisions"
    if not decisions.is_dir():
        return
    listed: set[str] = set()
    index = decisions / "README.md"
    if index.is_file():
        for m in re.finditer(r"\]\(\./(active|complete)/(D-\d+[^)]+)\)", index.read_text(encoding="utf-8")):
            listed.add(f"{m.group(1)}/{m.group(2)}")

    found: set[str] = set()
    for status_dir in ("active", "complete"):
        folder = decisions / status_dir
        if not folder.is_dir():
            fail(errors, f"missing decisions/{status_dir}/")
            continue
        for path in sorted(folder.glob("D-*.md")):
            rel = f"{status_dir}/{path.name}"
            found.add(rel)
            text = path.read_text(encoding="utf-8")
            if not text.startswith("---"):
                fail(errors, f"{rel}: missing YAML frontmatter")
                continue
            end = text.find("\n---", 3)
            if end < 0:
                fail(errors, f"{rel}: malformed YAML frontmatter")
                continue
            front = text[3:end]
            m = FRONT_STATUS_RE.search(front)
            if not m:
                fail(errors, f"{rel}: frontmatter needs status: active|complete")
            elif m.group(1) != status_dir:
                fail(
                    errors,
                    f"{rel}: status={m.group(1)} but file is under decisions/{status_dir}/",
                )

    missing_from_index = found - listed
    orphan_index = listed - found
    for rel in sorted(missing_from_index):
        fail(errors, f"decisions/README.md missing link to {rel}")
    for rel in sorted(orphan_index):
        fail(errors, f"decisions/README.md lists missing file {rel}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", type=Path, default=Path("."))
    args = ap.parse_args()
    root = args.root.resolve()
    errors: list[str] = []

    check_required(root, errors)
    check_agents(root, errors)
    check_links(root, "AGENTS.md", errors)
    check_links(root, "docs/INDEX.md", errors)
    check_links(root, "docs/decisions/README.md", errors)
    check_decisions(root, errors)

    if errors:
        print("docs lint FAILED:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("docs lint OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
