## aowlmcp/http — the MCP Streamable-HTTP transport, over the aoughwl net stack.
##
## This is the OPT-IN network transport (import it explicitly; the umbrella
## `aowlmcp` module does not, so stdio-only servers pull no networking). It lets
## an MCP server built with aowlmcp answer *remote* clients over HTTP instead of
## a local stdio pipe.
##
## The modern MCP "Streamable HTTP" transport uses one endpoint: the client
## POSTs a JSON-RPC message and receives the JSON-RPC response as
## `application/json` (a notification gets `202 Accepted` with no body). We serve
## it with `serve()` from the net stack, dispatching each request body through
## the same transport-agnostic `handleMessage` the stdio loop uses.
##
## Server-initiated streaming (the SSE `GET` channel) is intentionally not
## offered: a pure tools/resources server never pushes unsolicited messages, so
## a `GET` returns 405. Add it here if a future server needs push.

when defined(nimony):
  {.feature: "lenientnils".}

import serve
import serve/reactorhttp
import http/request
import http/response
import ./server

proc mcpResponse(srv: Server; req: Request; endpoint: string): Response =
  if req.path != endpoint:
    return response(404, "text/plain", "not found")
  if req.meth == "POST":
    # 2026-07-28 clients send `Mcp-Method` / `Mcp-Name` routing headers so
    # load balancers can route without inspecting the body. A single-instance
    # server needs no such routing, so we accept-and-ignore them (the actual
    # method/name are read from the JSON-RPC body by `handleMessage`). Legacy
    # clients omit them; both work unchanged.
    let body = srv.handleMessage(req.body)
    if body.len == 0:
      # notification / no reply
      return response(202, "application/json", "")
    return response(200, "application/json", body)
  elif req.meth == "GET":
    return response(405, "text/plain", "SSE stream not supported by this server")
  else:
    return response(405, "text/plain", "method not allowed")

proc serveHttp*(srv: Server; port: int; endpoint = "/mcp") =
  ## Serve MCP over HTTP on `port`, answering JSON-RPC POSTs at `endpoint`.
  ## Blocking accept loop (one request served at a time).
  proc handler(req: Request): Response {.closure.} =
    mcpResponse(srv, req, endpoint)
  serve(port, handler)

# ---------------------------------------------------------------------------
# async variant: the same transport on the single-threaded epoll reactor, so
# one OS thread multiplexes many concurrent MCP-over-HTTP clients.
# ---------------------------------------------------------------------------

var gMcpSrv: nil Server = nil
var gMcpEndpoint = "/mcp"

proc mcpNimcallHandler(req: Request): Response {.nimcall.} =
  mcpResponse(gMcpSrv, req, gMcpEndpoint)

proc serveHttpAsync*(srv: Server; port: int; endpoint = "/mcp") =
  ## Serve MCP over HTTP on `port` using the reactor: one thread, epoll, many
  ## simultaneous connections. Same protocol as `serveHttp`. The server is a
  ## process global (nimcall handler), so run one `serveHttpAsync` per process.
  gMcpSrv = srv
  gMcpEndpoint = endpoint
  serveHttpReactor(port, mcpNimcallHandler)
