## An MCP server reachable over HTTP (the Streamable-HTTP transport), built on
## aowlmcp + the aoughwl net stack. Same tools as echo_server, but remote.
##
## Build: ./build.sh examples/http_server.nim   (needs the net-stack --path set)
## Run  : bin/http_server [port]                (default 8130)
## Talk : curl -s localhost:8130/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

import std/[cmdline, strutils]
import "../src/aowlmcp"
import "../src/aowlmcp/http"   # opt-in HTTP transport

proc greet(args: JsonValue): JsonValue =
  let who = args{"name"}.getStr("world")
  result = newJObject()
  result["greeting"] = newJString("hello " & who)

proc add2(args: JsonValue): JsonValue =
  result = newJObject()
  result["sum"] = newJInt(args{"a"}.getInt(0) + args{"b"}.getInt(0))

proc deleteFiles(args, inputResponses, requestState: JsonValue): JsonValue =
  ## MRTR (2026-07-28): confirm before acting, over HTTP.
  if inputResponses.kind != jnObject:
    let confirm = newJObject()
    confirm["type"] = newJString("elicitation")
    confirm["message"] = newJString("Delete " & $args{"count"}.getInt(0) & " files?")
    let schema = newJObject()
    schema["type"] = newJString("boolean")
    let requests = newJObject()
    requests["confirm"] = confirm
    return newInputRequired(requests, $args{"count"}.getInt(0))
  result = newJObject()
  result["message"] = newJString(
    if inputResponses{"confirm"}.getBool(false): "deleted " & requestState.getStr & " files"
    else: "cancelled")

var port = 8130
if paramCount() >= 1:
  try: port = parseInt(paramStr(1))
  except: port = 8130

let srv = newServer("aowlmcp-http", "0.1.0")
srv.registerTool("greet", "Greet someone by name.",
  """{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}""",
  greet)
srv.registerTool("add", "Add two integers.",
  """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""",
  add2)
srv.registerToolMRTR("delete_files", "Delete files (asks to confirm first).",
  """{"type":"object","properties":{"count":{"type":"integer"}},"required":["count"]}""",
  deleteFiles)
srv.registerTaskTool("slow_add", "Add two integers, returned as a task.",
  """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""",
  add2)

srv.serveHttpAsync(port)   # single-threaded epoll reactor: many clients, one thread
