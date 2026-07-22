#!/usr/bin/env bash
# E2E for MCP over HTTP/3 (QUIC): build the aowlmcp H3 server + a QUIC POST
# client, then exercise the JSON-RPC contract (initialize, tools/list,
# tools/call) over QUIC on the server's single thread.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVE="$HOME/aoughwl-serve"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLJSON="${AOWLJSON:-$HOME/aowljson/src}"
NC="$(mktemp -d)"; PORT="${PORT:-8480}"
CERT="$NC/cert.pem"; KEY="$NC/key.pem"

NET_PATHS=""
for d in serve http tcp net tls compress; do
  p="$HOME/aoughwl-$d"; [[ -d "$p" ]] && NET_PATHS="$NET_PATHS --path:$p"
done

echo "== build QUIC glue shim =="
bash "$SERVE/quic/build.sh" >/dev/null

echo "== self-signed cert =="
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$KEY" -out "$CERT" -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" 2>/dev/null

echo "== build aowlmcp H3 server =="
"$NIMONY" c --base:"$ROOT" -d:nimony --nimcache:"$NC" --path:"$AOWLJSON" $NET_PATHS \
  "$ROOT/examples/http3_server.nim" 2>&1 | grep -iE 'Error:|FAILURE' && exit 1 || true
SBIN="$(find "$NC" -type f -name http3_server -executable | head -1)"

echo "== build H3 POST client =="
"$NIMONY" c --nimcache:"$NC" $NET_PATHS "$SERVE/examples/h3_post.nim" 2>&1 \
  | grep -iE 'Error:|FAILURE' && exit 1 || true
CBIN="$(find "$NC" -type f -name h3_post -executable | head -1)"
[[ -n "$SBIN" && -n "$CBIN" ]] || { echo "build failed"; exit 1; }

export LD_LIBRARY_PATH="$SERVE/quic"
"$SBIN" "$PORT" "$CERT" "$KEY" &
SRV=$!
trap 'kill $SRV 2>/dev/null || true; rm -rf "$NC"' EXIT
sleep 0.6

pass=0; total=0
check() { # name  jsonrpc-body  expected-substring
  total=$((total+1))
  local out; out="$("$CBIN" "$PORT" /mcp "$2" 2>&1)"
  if echo "$out" | grep -q "STATUS=200" && echo "$out" | grep -qF "$3"; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    echo "  FAIL: $1"; echo "$out" | sed 's/^/    /'
  fi
}

check "initialize" \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"c","version":"0"}}}' \
  '"protocolVersion"'
check "tools/list" \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '"greet"'
check "tools/call add" \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":40,"b":2}}}' \
  '42'
check "tools/call greet" \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"greet","arguments":{"name":"quic"}}}' \
  'hello quic'

THREADS="$(ls /proc/$SRV/task | wc -l)"
echo "MCP-over-HTTP/3: $pass/$total checks passed"
echo "server OS threads: $THREADS (expected 1)"
[[ "$pass" -eq "$total" && "$THREADS" -eq 1 ]] || { echo FAIL; exit 1; }
echo PASS
