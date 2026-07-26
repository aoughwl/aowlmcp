## An MCP server exercising the 2026-07-28 additions:
##   * `delete_files` — a Multi-Round-Trip (MRTR) tool that elicits a confirmation
##     before "deleting", using `newInputRequired` / `registerToolMRTR`.
##   * `slow_sum`     — a Tasks-extension tool: `tools/call` returns a task handle,
##     the result is fetched via `tasks/get`.
##
## Build:  ./build.sh examples/mrtr_server.nim
## Run  :  bin/mrtr_server   (speaks MCP over stdin/stdout)

import "../src/aowlmcp"

proc deleteFiles(args, inputResponses, requestState: JsonValue): JsonValue =
  ## First call: no responses yet -> ask the client to confirm. Follow-up call:
  ## the client echoes `requestState` and supplies `inputResponses.confirm`.
  if inputResponses.kind != jnObject:
    # Build the elicitation request the client must fulfil.
    let confirm = newJObject()
    confirm["type"] = newJString("elicitation")
    confirm["message"] = newJString("Delete " & $args{"count"}.getInt(0) & " files?")
    let schema = newJObject()
    schema["type"] = newJString("boolean")
    confirm["schema"] = schema
    let requests = newJObject()
    requests["confirm"] = confirm
    # Stash what we need for the follow-up in the opaque requestState blob.
    return newInputRequired(requests, $args{"count"}.getInt(0))

  # `requestState` carried the file count across the round-trip.
  result = newJObject()
  if inputResponses{"confirm"}.getBool(false):
    result["message"] = newJString("deleted " & requestState.getStr & " files")
  else:
    result["message"] = newJString("cancelled")

proc slowSum(args: JsonValue): JsonValue =
  let a = args{"a"}.getInt(0)
  let b = args{"b"}.getInt(0)
  result = newJObject()
  result["sum"] = newJInt(a + b)

let srv = newServer("aowlmcp-mrtr", "0.1.0")

srv.registerToolMRTR("delete_files", "Delete files (asks for confirmation first).",
  """{"type":"object","properties":{"count":{"type":"integer"}},"required":["count"]}""",
  deleteFiles)

srv.registerTaskTool("slow_sum", "Add two integers, returned as a task.",
  """{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}""",
  slowSum)

srv.run()
