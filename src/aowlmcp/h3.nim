## aowlmcp/h3 — the MCP Streamable-HTTP transport over **HTTP/3 (QUIC)**.
##
## The same JSON-RPC-over-POST contract as `aowlmcp/http`, but carried over
## QUIC instead of TCP: one endpoint, the client POSTs a JSON-RPC message and
## receives the JSON-RPC response as `application/json` (a notification gets
## `202 Accepted` with no body). Dispatch goes through the same
## transport-agnostic `handleMessage` the stdio and HTTP transports use.
##
## Opt-in (import it explicitly). It runs on the net stack's single-threaded
## HTTP/3 reactor (`serve/reactorh3`), so one OS thread multiplexes many
## concurrent QUIC clients. QUIC mandates TLS 1.3, so a PEM cert/key is required.
##
## Build prerequisite: the ngtcp2/nghttp3/GnuTLS glue shim (libaowlquic.so) —
## build it with `aoughwl-serve/quic/build.sh` and put it on the loader path.

when defined(nimony):
  {.feature: "lenientnils".}

import serve/reactorh3
import ./server

var gMcpSrv: nil Server = nil
var gMcpEndpoint = "/mcp"

proc mcpH3Handler(meth, path, body: string): H3Response {.nimcall.} =
  if path != gMcpEndpoint:
    return response(404, "text/plain", "not found")
  if meth == "POST":
    let outp = gMcpSrv.handleMessage(body)
    if outp.len == 0:
      return response(202, "application/json", "")   # notification, no reply
    return response(200, "application/json", outp)
  else:
    return response(405, "text/plain", "method not allowed")

proc serveH3*(srv: Server; port: int; certPath, keyPath: string;
              endpoint = "/mcp") =
  ## Serve MCP over HTTP/3 on `port` (UDP), answering JSON-RPC POSTs at
  ## `endpoint`. `certPath`/`keyPath` are PEM files. One thread, epoll over a
  ## single UDP socket.
  gMcpSrv = srv
  gMcpEndpoint = endpoint
  serveH3Reactor(port, certPath, keyPath, mcpH3Handler)
