#!/usr/bin/env bash
# End-to-end test for the HTTP (Streamable-HTTP) transport: build the HTTP MCP
# server and drive it with curl exactly as a remote MCP client would.
#
# Requires the aoughwl net stack checkouts under $HOME (serve/http/tcp/net/tls/
# compress) and a working Nimony (override with NIMONY=).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="${PORT:-8131}"

pass=0; fail=0
check() { if [[ "$3" == *"$2"* ]]; then pass=$((pass+1)); echo "  ok: $1";
  else fail=$((fail+1)); echo "  FAIL: $1"; echo "    want: $2"; echo "    got:  $3"; fi; }

echo "== build http_server =="
./build.sh examples/http_server.nim >/dev/null

echo "== run + curl =="
./bin/http_server "$PORT" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 0.6

INIT=$(curl -s "localhost:$PORT/mcp" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
check "initialize" '"protocolVersion":"2024-11-05"' "$INIT"
LIST=$(curl -s "localhost:$PORT/mcp" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
check "tools/list" '"name":"greet"' "$LIST"
CALL=$(curl -s "localhost:$PORT/mcp" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add","arguments":{"a":40,"b":2}}}')
check "tools/call add" '\"sum\":42' "$CALL"
NOTIF=$(curl -s -o /dev/null -w "%{http_code}" "localhost:$PORT/mcp" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
check "notification 202" "202" "$NOTIF"
NF=$(curl -s -o /dev/null -w "%{http_code}" "localhost:$PORT/wrong" -d '{}')
check "wrong path 404" "404" "$NF"
BAD=$(curl -s "localhost:$PORT/mcp" -d '{bad')
check "bad json -32700" '"code":-32700' "$BAD"

echo
echo "http e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
