# aowlmcp — Model Context Protocol servers in Nimony

`aowlmcp` is a small, self-contained library for building [Model Context
Protocol](https://modelcontextprotocol.io) (MCP) servers in **Nimony**. It
speaks the MCP stdio transport — line-delimited JSON-RPC 2.0 — so any MCP client
(Claude Code, Claude Desktop, editor agents) can drive a tool server you write
in a few lines of Nimony.

No framework runtime, no C dependencies, no exceptions across the wire: errors
are values, in keeping with the rest of the aoughwl stack. The only thing under
it is Nimony's standard library.

## Why

MCP is not a language feature — it is JSON-RPC 2.0 with a fixed method
vocabulary (`initialize`, `tools/list`, `tools/call`, …). Nimony had everything
needed to speak it (`std/syncio`, `std/strutils`, `std/tables`) except an
ergonomic JSON value type, so `aowlmcp` ships one and wraps the protocol loop.
The result: expose a Nimony proc as an LLM-callable tool without leaving Nimony.

## Install / build

Requires the Nimony compiler (`~/nimony/bin/nimony`). There is no external
dependency.

```sh
git clone https://github.com/aoughwl/aowlmcp
cd aowlmcp
./build.sh examples/echo_server.nim   # builds bin/echo_server
./tests/e2e.sh                        # unit + end-to-end tests
```

Point your compiler elsewhere with `NIMONY=/path/to/nimony ./build.sh …`.

## Hello, tool

```nim
import aowlmcp

proc greet(args: JsonValue): JsonValue =
  let who = args{"name"}.getStr("world")
  result = newJObject()
  result["greeting"] = newJString("hello " & who)

let srv = newServer("my-server", "0.1.0")
srv.registerTool("greet", "Greet someone by name.",
  """{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}""",
  greet)
srv.run()
```

`srv.run()` reads one JSON request per line from stdin, dispatches it, and writes
one JSON response per line to stdout, flushing after each — exactly what an MCP
client expects. A handler receives the call's `arguments` object as a
`JsonValue` and returns a structured `JsonValue`; the library encodes it as the
MCP text content block. Return an object with an `"error"` key to signal a
tool-level failure (the response comes back with `isError: true`).

## The JSON value type

`aowlmcp/json` provides a plain reference `JsonValue` with:

- **parse** — `parseJson(s, err): JsonValue` (error returned by value, never raised)
- **serialize** — `$v` (compact, faithful: numbers round-trip by lexeme)
- **navigate** — `v{"key"}` for objects, `v.at(i)` for arrays; missing paths
  chain safely to a JNull so `req{"params"}{"name"}.getStr("")` never faults
- **read** — `getStr`, `getInt`, `getBool`, `len`, `hasKey`, `items`, `pairs`
- **build** — `newJObject`, `newJArray`, `newJString`, `newJInt`, `newJBool`,
  `newJNull`, `obj["k"] = v`, `arr.add(v)`

## Protocol coverage

aowlmcp speaks **both** protocol versions — the original **`2024-11-05`** and the
stateless **`2026-07-28`** revision — negotiated per request.

| Method | Behaviour |
|---|---|
| `server/discover` | **(2026-07-28)** `protocolVersions`, `capabilities` (incl. `extensions`), `serverInfo`; also the stdio back-compat probe. |
| `initialize` | **(legacy)** Negotiates `protocolVersion` from the client, else the legacy version. |
| `notifications/initialized` / `initialized` | Acknowledged with no response. |
| `ping` | Empty result. |
| `tools/list` | Every registered tool (`name`, `description`, `inputSchema`) + `ttlMs`/`cacheScope`. |
| `tools/call` | Dispatches to the handler; wraps as a text content block, or returns an `InputRequiredResult` (MRTR) / task handle. |
| `tasks/get` / `tasks/cancel` / `tasks/update` | **(2026-07-28 Tasks extension)** |
| batch arrays | Each sub-request dispatched; one response line per non-notification. |
| bad JSON | `-32700` parse error. |
| unknown method (with id) | `-32601` method not found. |
| unsupported `_meta` protocol version | `-32602` invalid params. |

Tool-level errors ride back as `isError: true` responses, not JSON-RPC errors —
JSON-RPC `error` objects are reserved for transport/method faults, matching the
MCP convention.

### 2026-07-28 (stateless revision)

No `initialize` handshake and no `Mcp-Session-Id`: every request carries its
context in `_meta` (`io.modelcontextprotocol/protocolVersion` / `clientInfo` /
`clientCapabilities`), `server/discover` advertises capabilities, and the
Streamable-HTTP `Mcp-Method` / `Mcp-Name` routing headers are accepted. Tools can
elicit input via **MRTR** (`registerToolMRTR` + `newInputRequired`) and return
task handles via the **Tasks** extension (`registerTaskTool`). Requests without
`_meta` are treated as legacy `2024-11-05` and work unchanged. See
`examples/mrtr_server.nim`.

## Transports

Two transports share one dispatch core (`handleMessage`):

- **stdio** (`srv.run()`) — line-delimited JSON-RPC over stdin/stdout, for local
  MCP clients. No networking dependency.
- **HTTP** (`import aowlmcp/http`; `srv.serveHttp(port)`) — the modern MCP
  Streamable-HTTP transport, for *remote* clients. A client POSTs a JSON-RPC
  message to `/mcp` and gets the response as `application/json` (a notification
  gets `202`). Served over the [aoughwl net stack](https://github.com/aoughwl/serve).
  This transport is opt-in: `import aowlmcp` alone pulls no networking.

```sh
./build.sh examples/http_server.nim && ./bin/http_server 8130 &
curl -s localhost:8130/mcp -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Examples

- **`examples/echo_server.nim`** — stdio; `greet` and `add`; the minimal shape.
- **`examples/http_server.nim`** — the same tools over HTTP (`serveHttp`).
- **`examples/nimtools_server.nim`** — a real toolchain front-end: `compile`
  (runs Nimony/Nim, returns structured diagnostics) and `nif_outline` (lists the
  top-level nodes of a NIF artifact). This is the nimony-native cousin of the
  aowlcode plugin's Python `server.py`.

## Using it from Claude Code (the aowlcode plugin)

The [aowlcode](https://github.com/aoughwl/nim-code) plugin registers the
nimony-native server alongside its Python one in `.mcp.json`:

```json
"nimtools": {
  "command": "bash",
  "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/nimtools_launch.sh"]
}
```

The launcher builds `bin/nimtools_server` on first use and execs it, so the tools
appear in Claude Code with no manual build step.

## Layout

```
src/aowlmcp.nim          umbrella module (import this); re-exports jsonref
src/aowlmcp/server.nim   Server: registry, JSON-RPC dispatch, handleMessage, stdio run
src/aowlmcp/http.nim     opt-in HTTP (Streamable-HTTP) transport over the net stack
examples/                echo_server, http_server, nimtools_server
tests/tjson.nim          JSON unit tests
tests/e2e.sh             build + drive servers over stdio, assert responses
```

## Licence

See [LICENSE](LICENSE).
