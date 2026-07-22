## A minimal MCP server built with aowlmcp: two tools, `greet` and `add`.
## Build:  ./build.sh examples/echo_server.nim
## Run  :  bin/echo_server   (speaks MCP over stdin/stdout)

import "../src/aowlmcp"

proc greet(args: JsonValue): JsonValue =
  let who = args{"name"}.getStr("world")
  result = newJObject()
  result["greeting"] = newJString("hello " & who)

proc add2(args: JsonValue): JsonValue =
  let a = args{"a"}.getInt(0)
  let b = args{"b"}.getInt(0)
  result = newJObject()
  result["sum"] = newJInt(a + b)

let srv = newServer("aowlmcp-echo", "0.1.0")

srv.registerTool("greet", "Greet someone by name.",
  """{"type":"object","properties":{"name":{"type":"string","description":"Who to greet."}},"required":["name"]}""",
  greet)

srv.registerTool("add", "Add two integers.",
  """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""",
  add2)

srv.run()
