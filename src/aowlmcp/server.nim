## aowlmcp/server — a Model Context Protocol server over stdio for Nimony.
##
## Wire protocol (matching the MCP stdio transport): one JSON object per line on
## stdin, one JSON response per line on stdout, JSON-RPC 2.0 envelopes. Tool
## results are returned as a single text content block whose text is the
## compact-JSON encoding of the handler's return value; tool-level failures ride
## back as `isError: true` responses rather than JSON-RPC errors (JSON-RPC errors
## are reserved for transport/method faults).
##
## Dual protocol version. This server speaks BOTH:
##   * `2026-07-28` — the stateless revision: no `initialize` handshake, per-request
##     `_meta` carries protocol version / client info / client capabilities, and a
##     `server/discover` RPC advertises capabilities up front.
##   * `2024-11-05` — the original stateful handshake (`initialize` /
##     `notifications/initialized`), kept alive for older clients.
## The version is negotiated per request from `_meta`; when absent we assume the
## legacy version so pre-2026 clients keep working unchanged.

when defined(nimony):
  {.feature: "lenientnils".}

import std/syncio
import aowljson

const
  ProtocolVersionLatest* = "2026-07-28"
    ## Newest MCP revision this server implements (stateless).
  ProtocolVersionLegacy* = "2024-11-05"
    ## Original stateful revision, retained for backwards compatibility.
  ProtocolVersion2025_03* = "2025-03-26"
  ProtocolVersion2025_06* = "2025-06-18"
    ## The intervening stateful revisions. For the surface this server
    ## implements -- initialize, tools/list, tools/call -- they are wire
    ## compatible with the legacy handshake, and a client that asks for one
    ## and is answered "2024-11-05" is entitled to hang up. Echoing the
    ## version it asked for is both cheaper and more correct than being
    ## downgraded by a server that would have behaved identically.
  ProtocolVersion* = ProtocolVersionLatest
    ## The version advertised by default (e.g. `server/discover`, `initialize`
    ## when the client does not request a specific one).
  SupportedProtocolVersions* = [ProtocolVersionLatest, ProtocolVersion2025_06,
                                ProtocolVersion2025_03, ProtocolVersionLegacy]

  # `_meta` keys defined by the 2026-07-28 revision (statelessness SEPs).
  MetaProtocolVersion* = "io.modelcontextprotocol/protocolVersion"
  MetaClientInfo* = "io.modelcontextprotocol/clientInfo"
  MetaClientCapabilities* = "io.modelcontextprotocol/clientCapabilities"

  ListTtlMs* = 60000'i64
    ## Default `ttlMs` cache hint on `tools/list` (2026-07-28 caching fields).

  TasksExtension* = "io.modelcontextprotocol/tasks"
    ## Identifier of the official Tasks extension (SEP-2663).

proc isSupportedVersion(v: string): bool =
  for s in SupportedProtocolVersions:
    if s == v: return true
  false

type
  ToolHandler* = proc(args: JsonValue): JsonValue
    ## Receives the `arguments` object of a `tools/call`, returns a structured
    ## result. Return an object containing an `"error"` key to signal failure.

  ToolHandlerNamed* = proc(name: string; args: JsonValue): JsonValue
    ## A handler that also receives the tool NAME. Registered with
    ## `registerFallback`, it serves every tool the server did not register
    ## itself -- which is what a server being migrated tool-by-tool needs: the
    ## ported tools are real registrations, and everything else is forwarded
    ## somewhere that still implements it, without the caller seeing a seam.

  ToolHandlerMRTR* = proc(args, inputResponses, requestState: JsonValue): JsonValue
    ## Multi-Round-Trip (2026-07-28) handler. In addition to `arguments` it
    ## receives the `inputResponses` map and echoed `requestState` from a follow-up
    ## call. On the first call both are `JNull`; return `newInputRequired(...)` to
    ## ask the client for input, then complete on the follow-up call.

  Tool = object
    name: string
    description: string
    inputSchema: JsonValue
    handler: ToolHandler          ## simple handler (nil when `mrtr` is set)
    mrtr: ToolHandlerMRTR         ## MRTR handler (nil when `handler` is set)
    taskBased: bool               ## return a task handle instead of a direct result

  Task = object
    id: string
    status: string                ## "working" | "completed" | "failed" | "cancelled"
    payload: JsonValue            ## the wrapped tool result once completed

  Server* = ref object
    name: string
    version: string
    tools: seq[Tool]
    fallback: ToolHandlerNamed    ## serves tools this server did not register
    tasks: seq[Task]              ## Tasks-extension store (2026-07-28)
    taskSeq: int

proc newServer*(name: string; version = "0.1.0"): Server =
  ## Create an MCP server that will identify itself as `name`/`version`.
  Server(name: name, version: version, tools: @[], tasks: @[], taskSeq: 0,
         fallback: nil)

proc parseSchema(schemaJson: string): JsonValue =
  ## Parse a JSON-Schema string; a malformed schema is a programming error, so
  ## fall back to a permissive object schema rather than aborting registration.
  var err = ""
  result = parseJson(schemaJson, err)
  if err.len > 0:
    result = newJObject()
    result["type"] = newJString("object")

proc registerTool*(srv: Server; name, description, schemaJson: string;
                   handler: ToolHandler) =
  ## Register a tool. `schemaJson` is the JSON-Schema string describing the
  ## tool's `arguments` object (e.g. `{"type":"object","properties":{...}}`).
  srv.tools.add(Tool(name: name, description: description,
                     inputSchema: parseSchema(schemaJson),
                     handler: handler, mrtr: nil))

proc hasTool*(srv: Server; name: string): bool =
  ## Is `name` already registered? A migrating server asks this before
  ## advertising a proxied descriptor, so a ported tool is never shadowed by
  ## the implementation it replaced.
  for t in srv.tools:
    if t.name == name: return true
  result = false

proc registerFallback*(srv: Server; handler: ToolHandlerNamed) =
  ## Serve any tool this server did not register. `tools/list` still reports
  ## only the registered tools -- a fallback answers calls, it does not
  ## advertise; combine it with explicitly registered descriptors (or a proxied
  ## listing) when the extra tools should be visible.
  srv.fallback = handler

proc registerProxied*(srv: Server; name, description, schemaJson: string) =
  ## Advertise a tool in `tools/list` whose CALLS go to the fallback handler.
  ## This is the other half of a tool-by-tool migration: the descriptor is
  ## real, so the client sees one coherent tool set, while the implementation
  ## still lives wherever the fallback forwards to.
  srv.tools.add(Tool(name: name, description: description,
                     inputSchema: parseSchema(schemaJson),
                     handler: nil, mrtr: nil))

proc registerToolMRTR*(srv: Server; name, description, schemaJson: string;
                       handler: ToolHandlerMRTR) =
  ## Register a Multi-Round-Trip (2026-07-28) tool. The handler may return
  ## `newInputRequired(...)` to elicit client input and is re-invoked with the
  ## client's `inputResponses` and the echoed `requestState`.
  srv.tools.add(Tool(name: name, description: description,
                     inputSchema: parseSchema(schemaJson),
                     handler: nil, mrtr: handler))

proc registerTaskTool*(srv: Server; name, description, schemaJson: string;
                       handler: ToolHandler) =
  ## Register a Tasks-extension (2026-07-28) tool. A `tools/call` returns a task
  ## handle (server-directed); the client then drives `tasks/get` / `tasks/cancel`.
  ## The handler still runs to completion inline — this server records the result
  ## against the task id so `tasks/get` can return it — but the surface lets
  ## async-capable transports poll for long-running work.
  srv.tools.add(Tool(name: name, description: description,
                     inputSchema: parseSchema(schemaJson),
                     handler: handler, mrtr: nil, taskBased: true))

proc newInputRequired*(inputRequests: JsonValue; requestState = ""): JsonValue =
  ## Build a 2026-07-28 `InputRequiredResult`. `inputRequests` is a map of
  ## elicitation/sampling requests the client must fulfil; `requestState` is an
  ## opaque blob the client echoes back verbatim on the follow-up call.
  result = newJObject()
  result["resultType"] = newJString("inputRequired")
  result["inputRequests"] = inputRequests
  result["requestState"] = newJString(requestState)

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

proc serverInfo(srv: Server): JsonValue =
  result = newJObject()
  result["name"] = newJString(srv.name)
  result["version"] = newJString(srv.version)

proc hasTaskTool(srv: Server): bool =
  for t in srv.tools:
    if t.taskBased: return true
  false

proc capabilities(srv: Server): JsonValue =
  ## Capabilities advertised in both `initialize` and `server/discover`.
  result = newJObject()
  result["tools"] = newJObject()
  # `extensions` is the 2026-07-28 negotiation map (Tasks, MCP Apps, …). We list
  # the Tasks extension only when a task tool is registered; harmless for legacy
  # clients to ignore.
  let ext = newJObject()
  if srv.hasTaskTool():
    ext[TasksExtension] = newJObject()
  result["extensions"] = ext

proc negotiateInitVersion(requested: string): string =
  ## Version to echo from the legacy `initialize` handshake: honour the client's
  ## request when we support it, else default to the LEGACY version — a client
  ## using `initialize` at all is legacy-style; stateless clients use
  ## `server/discover` instead.
  if requested.len > 0 and isSupportedVersion(requested): requested
  else: ProtocolVersionLegacy

proc handleInitialize(srv: Server; id: JsonValue; params: JsonValue): JsonValue =
  ## Legacy (`2024-11-05`) stateful handshake. Retained for older clients; the
  ## 2026-07-28 flow uses `server/discover` instead.
  let res = newJObject()
  res["protocolVersion"] = newJString(negotiateInitVersion(params{"protocolVersion"}.getStr))
  res["capabilities"] = srv.capabilities()
  res["serverInfo"] = srv.serverInfo()
  return makeResponse(id, res)

proc handleDiscover(srv: Server; id: JsonValue): JsonValue =
  ## 2026-07-28 stateless discovery: advertise supported protocol versions,
  ## capabilities (including the extensions map), and server identity. Doubles as
  ## the stdio backwards-compatibility probe.
  let versions = newJArray()
  for v in SupportedProtocolVersions:
    versions.add(newJString(v))
  let res = newJObject()
  res["protocolVersions"] = versions
  res["protocolVersion"] = newJString(ProtocolVersion)
  res["capabilities"] = srv.capabilities()
  res["serverInfo"] = srv.serverInfo()
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
  # 2026-07-28 caching hints (SEP): tool lists are stateless and cacheable across
  # instances. Conservative defaults; legacy clients ignore the extra fields.
  res["ttlMs"] = newJInt(ListTtlMs)
  res["cacheScope"] = newJString("public")
  return makeResponse(id, res)

proc findTool(srv: Server; name: string): int =
  for i in 0 ..< srv.tools.len:
    if srv.tools[i].name == name: return i
  return -1

proc createTask(srv: Server; payload: JsonValue): string =
  ## Record a completed task and return its server-issued id. State lives in this
  ## explicit handle, not in a protocol session — the store is per-process.
  inc srv.taskSeq
  result = "task-" & $srv.taskSeq
  srv.tasks.add(Task(id: result, status: "completed", payload: payload))

proc findTask(srv: Server; id: string): int =
  for i in 0 ..< srv.tasks.len:
    if srv.tasks[i].id == id: return i
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
  var args = params{"arguments"}
  if args.kind != jnObject:
    args = newJObject()
  if idx < 0:
    if srv.fallback != nil:
      return makeResponse(id, wrapToolResult(srv.fallback(name, args)))
    let e = newJObject()
    e["error"] = newJString("unknown tool: " & name)
    return makeResponse(id, wrapToolResult(e))

  var res: JsonValue
  if srv.tools[idx].handler == nil and srv.tools[idx].mrtr == nil:
    # A proxied descriptor: advertised here, implemented by the fallback.
    if srv.fallback == nil:
      let e = newJObject()
      e["error"] = newJString("no implementation for tool: " & name)
      return makeResponse(id, wrapToolResult(e))
    res = srv.fallback(name, args)
  elif srv.tools[idx].mrtr != nil:
    # 2026-07-28 MRTR tool: hand it the follow-up `inputResponses` + echoed
    # `requestState` (both JNull on the first call).
    res = srv.tools[idx].mrtr(args, params{"inputResponses"}, params{"requestState"})
  else:
    res = srv.tools[idx].handler(args)

  # An InputRequiredResult is itself the JSON-RPC `result` — it is NOT wrapped as
  # a text content block; the client re-issues the call with the responses.
  if res.kind == jnObject and res{"resultType"}.getStr == "inputRequired":
    return makeResponse(id, res)

  let wrapped = wrapToolResult(res)
  if srv.tools[idx].taskBased:
    # Tasks extension: return a handle; the result is fetched via `tasks/get`.
    let tid = srv.createTask(wrapped)
    let handle = newJObject()
    handle["taskId"] = newJString(tid)
    handle["status"] = newJString("completed")
    return makeResponse(id, handle)
  return makeResponse(id, wrapped)

proc handleTasksGet(srv: Server; id: JsonValue; params: JsonValue): JsonValue =
  let tid = params{"taskId"}.getStr
  let i = srv.findTask(tid)
  if i < 0:
    return makeError(id, -32602, "unknown task: " & tid)
  let res = newJObject()
  res["taskId"] = newJString(tid)
  res["status"] = newJString(srv.tasks[i].status)
  if srv.tasks[i].status == "completed":
    res["result"] = srv.tasks[i].payload
  return makeResponse(id, res)

proc handleTasksCancel(srv: Server; id: JsonValue; params: JsonValue): JsonValue =
  let tid = params{"taskId"}.getStr
  let i = srv.findTask(tid)
  if i < 0:
    return makeError(id, -32602, "unknown task: " & tid)
  if srv.tasks[i].status == "working":
    srv.tasks[i].status = "cancelled"
  let res = newJObject()
  res["taskId"] = newJString(tid)
  res["status"] = newJString(srv.tasks[i].status)
  return makeResponse(id, res)

proc handleTasksUpdate(srv: Server; id: JsonValue; params: JsonValue): JsonValue =
  ## Accept client→server input for a task (MRTR-over-tasks). This sync server
  ## completes work inline, so there is nothing to feed a running task; we
  ## acknowledge with the current status.
  let tid = params{"taskId"}.getStr
  let i = srv.findTask(tid)
  if i < 0:
    return makeError(id, -32602, "unknown task: " & tid)
  let res = newJObject()
  res["taskId"] = newJString(tid)
  res["status"] = newJString(srv.tasks[i].status)
  return makeResponse(id, res)

# ---------------------------------------------------------------------------
# dispatch + run loop
# ---------------------------------------------------------------------------

proc metaProtocolVersion(req: JsonValue): string =
  ## The protocol version carried in the 2026-07-28 per-request `_meta` (a member
  ## of `params`), or "" for legacy requests that omit it. Also tolerate a
  ## top-level `_meta` placement.
  result = req{"params"}{"_meta"}{MetaProtocolVersion}.getStr
  if result.len == 0:
    result = req{"_meta"}{MetaProtocolVersion}.getStr

proc dispatch(srv: Server; req: JsonValue): JsonValue =
  ## Returns the response object, or nil for notifications (no reply).
  let meth = req{"method"}.getStr
  let hasId = req.hasKey("id")
  let id = req{"id"}   # JNull when absent

  # 2026-07-28: validate the per-request protocol version from `_meta`. Absent
  # `_meta` => a legacy (2024-11-05) client, which is fine. `server/discover` and
  # `initialize` self-negotiate, so they are never rejected here.
  if hasId and meth != "server/discover" and meth != "initialize":
    let v = req.metaProtocolVersion()
    if v.len > 0 and not isSupportedVersion(v):
      return makeError(id, -32602, "unsupported protocol version: " & v)

  case meth
  of "server/discover":
    return handleDiscover(srv, id)
  of "initialize":
    return handleInitialize(srv, id, req{"params"})
  of "notifications/initialized", "initialized":
    return nil
  of "ping":
    return makeResponse(id, newJObject())
  of "tools/list":
    return handleToolsList(srv, id)
  of "tools/call":
    return handleToolsCall(srv, id, req{"params"})
  of "tasks/get":
    return handleTasksGet(srv, id, req{"params"})
  of "tasks/cancel":
    return handleTasksCancel(srv, id, req{"params"})
  of "tasks/update":
    return handleTasksUpdate(srv, id, req{"params"})
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
