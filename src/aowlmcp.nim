## aowlmcp — a Model Context Protocol (MCP) server library for Nimony.
##
## Import this module to build an MCP server over stdio:
##
## ```nim
## import aowlmcp
##
## proc greet(args: JsonValue): JsonValue =
##   let who = args{"name"}.getStr("world")
##   result = newJObject()
##   result["greeting"] = newJString("hello " & who)
##
## let srv = newServer("my-server", "0.1.0")
## srv.registerTool("greet", "Say hello to someone",
##   """{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}""",
##   greet)
## srv.run()
## ```

import aowljson
import aowlmcp/server

export aowljson
export server
