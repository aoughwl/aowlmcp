## An MCP server reachable over HTTP/3 (QUIC) — the Streamable-HTTP transport on
## the net stack's single-threaded QUIC reactor. Same tools as http_server, but
## over QUIC/TLS 1.3.
##
## Build the QUIC shim first: aoughwl-serve/quic/build.sh
## Build: ./build.sh examples/http3_server.nim
## Run  : LD_LIBRARY_PATH=<serve>/quic bin/http3_server [port] [cert.pem] [key.pem]

import std/[cmdline, strutils]
import "../src/aowlmcp"
import "../src/aowlmcp/h3"   # opt-in HTTP/3 transport

proc greet(args: JsonValue): JsonValue =
  let who = args{"name"}.getStr("world")
  result = newJObject()
  result["greeting"] = newJString("hello " & who)

proc add2(args: JsonValue): JsonValue =
  result = newJObject()
  result["sum"] = newJInt(args{"a"}.getInt(0) + args{"b"}.getInt(0))

var port = 8130
var cert = "cert.pem"
var key = "key.pem"
if paramCount() >= 1:
  try: port = parseInt(paramStr(1))
  except: port = 8130
if paramCount() >= 2: cert = paramStr(2)
if paramCount() >= 3: key = paramStr(3)

let srv = newServer("aowlmcp-h3", "0.1.0")
srv.registerTool("greet", "Greet someone by name.",
  """{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}""",
  greet)
srv.registerTool("add", "Add two integers.",
  """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""",
  add2)

srv.serveH3(port, cert, key)   # single-threaded QUIC reactor: many clients, one thread
