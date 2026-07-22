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

| Method | Behaviour |
|---|---|
| `initialize` | Returns `protocolVersion` `2024-11-05`, `capabilities.tools`, `serverInfo`. |
| `notifications/initialized` / `initialized` | Acknowledged with no response. |
| `ping` | Empty result. |
| `tools/list` | Every registered tool with its `name`, `description`, `inputSchema`. |
| `tools/call` | Dispatches to the handler; wraps the result as a text content block. |
| batch arrays | Each sub-request dispatched; one response line per non-notification. |
| bad JSON | `-32700` parse error. |
| unknown method (with id) | `-32601` method not found. |

Tool-level errors ride back as `isError: true` responses, not JSON-RPC errors —
JSON-RPC `error` objects are reserved for transport/method faults, matching the
MCP convention.

## Examples

- **`examples/echo_server.nim`** — `greet` and `add`; the minimal shape.
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
src/aowlmcp.nim          umbrella module (import this)
src/aowlmcp/json.nim     JsonValue: parser, serializer, accessors, builders
src/aowlmcp/server.nim   Server: registry, JSON-RPC dispatch, stdio run loop
examples/                echo_server, nimtools_server
tests/tjson.nim          JSON unit tests
tests/e2e.sh             build + drive servers over stdio, assert responses
```

## Licence

See [LICENSE](LICENSE).
