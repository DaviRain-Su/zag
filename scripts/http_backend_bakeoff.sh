#!/usr/bin/env bash
# D-005 Phase 3: run live HTTP bake-off for both backends and print a summary.
# Requires network + system libcurl for the curl backend.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_URL="${ZAG_BAKEOFF_BASE_URL:-https://httpbingo.org}"
OUT_DIR="${ZAG_BAKEOFF_OUT:-$ROOT/.zag/bakeoff}"
mkdir -p "$OUT_DIR"

echo "== http bake-off =="
echo "base_url=$BASE_URL"
echo

run_one() {
  local backend="$1"
  local out="$OUT_DIR/${backend}.txt"
  echo "-- backend=$backend --"
  zig build http-bakeoff -Dhttp_backend="$backend" -- "$BASE_URL" | tee "$out"
  echo
}

run_one std
run_one curl

echo "== summary =="
python3 - <<'PY'
from pathlib import Path
import os

out_dir = Path(os.environ.get("ZAG_BAKEOFF_OUT", Path(".zag/bakeoff")))
rows = []
for backend in ("std", "curl"):
    path = out_dir / f"{backend}.txt"
    if not path.exists():
        continue
    cases = {}
    for line in path.read_text().splitlines():
        if not line.startswith("CASE="):
            continue
        parts = dict(p.split("=", 1) for p in line.split() if "=" in p)
        cases[parts.get("CASE", "?")] = parts
    rows.append((backend, cases))

print(f"{'backend':8} {'case':10} {'result':16} {'ms':>8} extra")
print("-" * 64)
for backend, cases in rows:
    for case in ("post_ok", "timeout"):
        p = cases.get(case, {})
        extra = p.get("ERR") or p.get("STATUS", "")
        print(f"{backend:8} {case:10} {p.get('RESULT','?'):16} {p.get('MS','?'):>8} {extra}")
PY
