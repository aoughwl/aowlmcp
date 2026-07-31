#!/usr/bin/env bash
# Build an aowlmcp example/server with the Nimony compiler (self-hosted).
# Usage: ./build.sh [src/file.nim]   (default: examples/echo_server.nim)
# Override the compiler with NIMONY=/path/to/nimony.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
# Dependency: the aowljson library (github.com/aoughwl/aowljson).
AOWLJSON="${AOWLJSON:-$HOME/aowljson/src}"
# The HTTP transport (aowlmcp/http) additionally needs the aoughwl net stack.
# These paths are harmless for the stdio-only examples (they import none of it).
NET_PATHS=""
for d in serve http tcp net tls compress; do
  p="$HOME/aoughwl-$d"
  [[ -d "$p" ]] && NET_PATHS="$NET_PATHS --path:$p"
done
cd "$ROOT"
TARGET="${1:-examples/echo_server.nim}"
name="$(basename "$TARGET" .nim)"

"$NIMONY" c --base:. -d:nimony --path:"$AOWLJSON" $NET_PATHS "$TARGET"

mkdir -p bin
exe="$(find nimcache -type f -name "$name" -executable -printf '%T@ %p\n' \
       | sort -rn | head -1 | cut -d' ' -f2-)"
if [[ -z "${exe:-}" ]]; then
  echo "build.sh: could not locate built $name in nimcache/" >&2
  exit 1
fi
# A server built here may be RUNNING (its binary held open by a live MCP
# session), and cp into a busy file fails with ETXTBSY. Write beside it and
# rename: the running process keeps the old inode, the next start gets this.
cp "$exe" "bin/.$name.new" && mv -f "bin/.$name.new" "bin/$name"
echo "built bin/$name"
