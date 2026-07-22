#!/usr/bin/env bash
# End-to-end test: build the example servers and drive them over stdio exactly
# as an MCP client (Claude Code) would, asserting on the JSON-RPC responses.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0; fail=0
check() { # <label> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then pass=$((pass+1)); echo "  ok: $1";
  else fail=$((fail+1)); echo "  FAIL: $1"; echo "    want substr: $2"; echo "    got: $3"; fi
}

echo "== unit: json =="
"$HOME/nimony/bin/nimony" c -r tests/tjson.nim 2>/dev/null | grep -q "tjson: OK" \
  && { echo "  ok: tjson"; pass=$((pass+1)); } || { echo "  FAIL: tjson"; fail=$((fail+1)); }

echo "== build servers =="
./build.sh examples/echo_server.nim >/dev/null
./build.sh examples/nimtools_server.nim >/dev/null

echo "== e2e: echo_server =="
OUT=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"ping"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"greet","arguments":{"name":"aoughwl"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add","arguments":{"a":40,"b":2}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"does/not/exist"}' \
  '{bad json' \
  | ./bin/echo_server)
check "initialize handshake"    '"protocolVersion":"2024-11-05"' "$OUT"
check "notification suppressed"  '' "$OUT"   # (presence checked below)
check "ping empty result"       '"id":2,"result":{}' "$OUT"
check "tools/list has greet"    '"name":"greet"' "$OUT"
check "greet result"            'hello aoughwl' "$OUT"
check "add result"              '\"sum\":42' "$OUT"
check "unknown tool isError"    '"isError":true' "$OUT"
check "unknown method -32601"   '"code":-32601' "$OUT"
check "parse error -32700"      '"code":-32700,"message":"parse error"' "$OUT"
# there must be exactly 8 response lines (the notification produces none)
LINES=$(printf '%s' "$OUT" | grep -c '^{' || true)
check "8 responses (notif silent)" "8" "$LINES"

echo "== e2e: nimtools_server (compile) =="
TMP=$(mktemp -d)
printf 'import std/syncio\necho "hi"\n' > "$TMP/good.nim"
printf 'echo undefinedThing123\n' > "$TMP/bad.nim"
OUT2=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"compile\",\"arguments\":{\"file\":\"$TMP/good.nim\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"compile\",\"arguments\":{\"file\":\"$TMP/bad.nim\"}}}" \
  | ./bin/nimtools_server)
check "good compiles ok"     '\"ok\":true' "$OUT2"
check "bad fails"            '\"ok\":false' "$OUT2"
check "structured diagnostic" 'undeclared identifier' "$OUT2"
rm -rf "$TMP"

echo
echo "e2e: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
