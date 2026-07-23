#!/usr/bin/env bash
# OpenAPI resource path coverage gate.
# Run from packages/openai-zig or any cwd (script locates package root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PKG_ROOT"

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing dependency: python3" >&2
  exit 2
fi

exec python3 "$SCRIPT_DIR/check-path-coverage.py" "$@"
