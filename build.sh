#!/usr/bin/env bash
# Build an aowlmcp example/server with the Nimony compiler (self-hosted).
# Usage: ./build.sh [src/file.nim]   (default: examples/echo_server.nim)
# Override the compiler with NIMONY=/path/to/nimony.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
# Dependency: the aowljson library (github.com/aoughwl/aowljson).
AOWLJSON="${AOWLJSON:-$HOME/aowljson/src}"
cd "$ROOT"
TARGET="${1:-examples/echo_server.nim}"
name="$(basename "$TARGET" .nim)"

"$NIMONY" c --base:. -d:nimony --path:"$AOWLJSON" "$TARGET"

mkdir -p bin
exe="$(find nimcache -type f -name "$name" -executable -printf '%T@ %p\n' \
       | sort -rn | head -1 | cut -d' ' -f2-)"
if [[ -z "${exe:-}" ]]; then
  echo "build.sh: could not locate built $name in nimcache/" >&2
  exit 1
fi
cp "$exe" "bin/$name"
echo "built bin/$name"
