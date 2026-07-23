#!/usr/bin/env python3
"""
Fail if any OpenAPI operation path in generated/ir.json is missing from
src/resources/*.zig string/path builders.

Usage (from packages/openai-zig):
  python3 scripts/check-path-coverage.py
  python3 scripts/check-path-coverage.py --json   # machine-readable
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def package_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_ir(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def collect_resource_source(resources_dir: Path) -> str:
    parts: list[str] = []
    for p in sorted(resources_dir.glob("*.zig")):
        parts.append(p.read_text(encoding="utf-8"))
    return "\n".join(parts)


def extract_path_tokens(source: str) -> set[str]:
    """Collect quoted path-like tokens and fmt path patterns from resource code."""
    tokens: set[str] = set()
    for m in re.finditer(r'"(/[^"]*)"', source):
        tokens.add(m.group(1))
    # Also bare segments used in print templates without leading quote pairs already covered
    return tokens


def normalize_path(path: str) -> str:
    """Strip query and map {param}/fmt placeholders to {}."""
    base = path.split("?", 1)[0]
    base = re.sub(r"\{[^}]+\}", "{}", base)
    base = re.sub(r"\{[sd]\}", "{}", base)  # zig fmt leftovers if any
    return base.rstrip("/") or "/"


def path_covered(op_path: str, tokens: set[str], source: str) -> bool:
    want = normalize_path(op_path)
    for tok in tokens:
        if normalize_path(tok) == want:
            return True

    # Fallback: last two static segments must appear together in source.
    static = [s for s in op_path.split("?", 1)[0].split("/") if s and not s.startswith("{")]
    if len(static) >= 2:
        needle = "/".join(static[-2:])
        if needle in source:
            return True
    elif len(static) == 1:
        # e.g. rare top-level — require exact segment in a path token
        for tok in tokens:
            if static[0] in tok:
                return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Check OpenAPI path coverage in resources")
    parser.add_argument(
        "--ir",
        type=Path,
        default=None,
        help="Path to ir.json (default: <pkg>/generated/ir.json)",
    )
    parser.add_argument(
        "--resources",
        type=Path,
        default=None,
        help="Resources directory (default: <pkg>/src/resources)",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON report")
    args = parser.parse_args()

    root = package_root()
    ir_path = args.ir or (root / "generated" / "ir.json")
    resources_dir = args.resources or (root / "src" / "resources")

    if not ir_path.is_file():
        print(f"missing IR: {ir_path}", file=sys.stderr)
        return 2
    if not resources_dir.is_dir():
        print(f"missing resources dir: {resources_dir}", file=sys.stderr)
        return 2

    ir = load_ir(ir_path)
    ops = ir.get("operations") or []
    source = collect_resource_source(resources_dir)
    tokens = extract_path_tokens(source)

    missing: list[dict] = []
    covered = 0
    for op in ops:
        path = op.get("path") or ""
        if not path:
            continue
        if path_covered(path, tokens, source):
            covered += 1
        else:
            missing.append(
                {
                    "id": op.get("id"),
                    "method": op.get("method"),
                    "path": path,
                    "tag": op.get("tag"),
                }
            )

    total = covered + len(missing)
    report = {
        "total": total,
        "covered": covered,
        "missing_count": len(missing),
        "missing": missing,
        "ir": str(ir_path),
        "resources": str(resources_dir),
    }

    if args.json:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
    else:
        print(f"OpenAPI path coverage: {covered}/{total}")
        if missing:
            print(f"MISSING ({len(missing)}):", file=sys.stderr)
            for m in missing:
                print(
                    f"  {m.get('method', '?'):6} {m.get('path', '?')}  ({m.get('id')})",
                    file=sys.stderr,
                )
        else:
            print("all operation paths have resource wrappers")

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
