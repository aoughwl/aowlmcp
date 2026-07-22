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

import serve
import http/request
import http/response
import ./server

proc mcpResponse(srv: Server; req: Request; endpoint: string): Response =
  if req.path != endpoint:
    return response(404, "text/plain", "not found")
  if req.meth == "POST":
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
  ## Blocks, serving the net stack's accept loop.
  proc handler(req: Request): Response {.closure.} =
    mcpResponse(srv, req, endpoint)
  serve(port, handler)
