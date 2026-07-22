## aowlmcp/server — a Model Context Protocol server over stdio for Nimony.
##
## Wire protocol (matching the MCP stdio transport): one JSON object per line on
## stdin, one JSON response per line on stdout, JSON-RPC 2.0 envelopes,
## `protocolVersion` `2024-11-05`. Tool results are returned as a single text
## content block whose text is the compact-JSON encoding of the handler's return
## value; tool-level failures ride back as `isError: true` responses rather than
## JSON-RPC errors (JSON-RPC errors are reserved for transport/method faults).

when defined(nimony):
  {.feature: "lenientnils".}

import std/syncio
import aowljson

const ProtocolVersion* = "2024-11-05"

type
  ToolHandler* = proc(args: JsonValue): JsonValue
    ## Receives the `arguments` object of a `tools/call`, returns a structured
    ## result. Return an object containing an `"error"` key to signal failure.

  Tool = object
    name: string
    description: string
    inputSchema: JsonValue
    handler: ToolHandler

  Server* = ref object
    name: string
    version: string
    tools: seq[Tool]

proc newServer*(name: string; version = "0.1.0"): Server =
  ## Create an MCP server that will identify itself as `name`/`version`.
  Server(name: name, version: version, tools: @[])

proc registerTool*(srv: Server; name, description, schemaJson: string;
                   handler: ToolHandler) =
  ## Register a tool. `schemaJson` is the JSON-Schema string describing the
  ## tool's `arguments` object (e.g. `{"type":"object","properties":{...}}`).
  var err = ""
  var schema = parseJson(schemaJson, err)
  if err.len > 0:
    # A malformed schema is a programming error; fall back to a permissive one
    # rather than aborting the whole server at registration time.
    schema = newJObject()
    schema["type"] = newJString("object")
  srv.tools.add(Tool(name: name, description: description,
                     inputSchema: schema, handler: handler))

# ---------------------------------------------------------------------------
# JSON-RPC envelopes
# ---------------------------------------------------------------------------

proc makeResponse(id: JsonValue; res: JsonValue): JsonValue =
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["id"] = id
  result["result"] = res

proc makeError(id: JsonValue; code: int64; message: string): JsonValue =
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["id"] = id
  let e = newJObject()
  e["code"] = newJInt(code)
  e["message"] = newJString(message)
  result["error"] = e

# ---------------------------------------------------------------------------
# method handlers
# ---------------------------------------------------------------------------

proc handleInitialize(srv: Server; id: JsonValue): JsonValue =
  let caps = newJObject()
  caps["tools"] = newJObject()
  let info = newJObject()
  info["name"] = newJString(srv.name)
  info["version"] = newJString(srv.version)
  let res = newJObject()
  res["protocolVersion"] = newJString(ProtocolVersion)
  res["capabilities"] = caps
  res["serverInfo"] = info
  return makeResponse(id, res)

proc handleToolsList(srv: Server; id: JsonValue): JsonValue =
  let arr = newJArray()
  for t in srv.tools:
    let entry = newJObject()
    entry["name"] = newJString(t.name)
    entry["description"] = newJString(t.description)
    entry["inputSchema"] = t.inputSchema
    arr.add(entry)
  let res = newJObject()
  res["tools"] = arr
  return makeResponse(id, res)

proc findTool(srv: Server; name: string): int =
  for i in 0 ..< srv.tools.len:
    if srv.tools[i].name == name: return i
  return -1

proc wrapToolResult(res: JsonValue): JsonValue =
  ## Encode a handler's structured result as an MCP tool-result payload.
  let isError = res.kind == jnObject and res.hasKey("error")
  let block0 = newJObject()
  block0["type"] = newJString("text")
  block0["text"] = newJString($res)
  let content = newJArray()
  content.add(block0)
  result = newJObject()
  result["content"] = content
  if isError:
    result["isError"] = newJBool(true)

proc handleToolsCall(srv: Server; id: JsonValue; params: JsonValue): JsonValue =
  let name = params{"name"}.getStr
  let idx = srv.findTool(name)
  if idx < 0:
    let e = newJObject()
    e["error"] = newJString("unknown tool: " & name)
    return makeResponse(id, wrapToolResult(e))
  var args = params{"arguments"}
  if args.kind != jnObject:
    args = newJObject()
  let res = srv.tools[idx].handler(args)
  return makeResponse(id, wrapToolResult(res))

# ---------------------------------------------------------------------------
# dispatch + run loop
# ---------------------------------------------------------------------------

proc dispatch(srv: Server; req: JsonValue): JsonValue =
  ## Returns the response object, or nil for notifications (no reply).
  let meth = req{"method"}.getStr
  let hasId = req.hasKey("id")
  let id = req{"id"}   # JNull when absent
  case meth
  of "initialize":
    return handleInitialize(srv, id)
  of "notifications/initialized", "initialized":
    return nil
  of "ping":
    return makeResponse(id, newJObject())
  of "tools/list":
    return handleToolsList(srv, id)
  of "tools/call":
    return handleToolsCall(srv, id, req{"params"})
  else:
    if hasId:
      return makeError(id, -32601, "method not found: " & meth)
    return nil

proc handleMessage*(srv: Server; msg: string): string =
  ## Process one incoming JSON-RPC message (a single object, or a batch array)
  ## and return the response text to send back, or "" when there is nothing to
  ## reply with (a notification, or a batch of only notifications). This is the
  ## transport-agnostic core: both the stdio `run` loop and the HTTP transport
  ## (aowlmcp/http) feed raw message text through here.
  var err = ""
  let req = parseJson(msg, err)
  if err.len > 0:
    return $makeError(newJNull(), -32700, "parse error")
  if req.kind == jnArray:
    let arr = newJArray()
    for sub in req:
      let r = dispatch(srv, sub)
      if r != nil: arr.add(r)
    if arr.len == 0: return ""
    return $arr
  let resp = dispatch(srv, req)
  if resp == nil: return ""
  return $resp

proc run*(srv: Server) =
  ## Serve MCP over stdin/stdout until EOF (the stdio transport).
  var line = ""
  while readLine(stdin, line):
    if line.len == 0: continue
    let outp = srv.handleMessage(line)
    if outp.len > 0:
      writeLine(stdout, outp)
      flushFile(stdout)
