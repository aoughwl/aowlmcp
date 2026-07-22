## nimtools_server — a real MCP server, built on aowlmcp, that fronts the
## Nimony/Nim toolchain. It is the nimony-native cousin of the plugin's Python
## `server.py`: token-efficient, structured toolchain access over MCP/stdio.
##
## Tools:
##   compile(file, toolchain="nimony", extra_args=[])  -> {ok, diagnostics:[...]}
##   nif_outline(file)                                  -> {tags:[{tag,name}]}
##
## Build:  ./build.sh examples/nimtools_server.nim
## Run  :  bin/nimtools_server

when defined(nimony):
  {.feature: "lenientnils".}

import std/[strutils, osproc, syncio, os, envvars]
import "../src/aowlmcp"

# ---------------------------------------------------------------------------
# compile: run the compiler, return structured diagnostics
# ---------------------------------------------------------------------------

proc parseDiagLine(line: string): JsonValue =
  ## Parse `path(line, col) Severity: message` into a diagnostic object, or nil.
  let lp = line.find('(')
  if lp <= 0: return nil
  let rp = line.find(')', lp)
  if rp < 0: return nil
  let inside = line[lp+1 ..< rp]
  let comma = inside.find(',')
  if comma < 0: return nil
  var lineNo = 0
  var colNo = 0
  try:
    lineNo = parseInt(inside[0 ..< comma].strip())
    colNo = parseInt(inside[comma+1 ..< inside.len].strip())
  except:
    return nil
  # rest: " Severity: message"
  var rest = line[rp+1 ..< line.len].strip()
  var severity = "info"
  let colon = rest.find(':')
  if colon > 0:
    let sev = rest[0 ..< colon].strip().toLowerAscii()
    if sev == "error" or sev == "warning" or sev == "hint":
      severity = sev
      rest = rest[colon+1 ..< rest.len].strip()
  let d = newJObject()
  d["file"] = newJString(line[0 ..< lp])
  d["line"] = newJInt(int64(lineNo))
  d["col"] = newJInt(int64(colNo))
  d["severity"] = newJString(severity)
  d["message"] = newJString(rest)
  return d

proc compileTool(args: JsonValue): JsonValue =
  let file = args{"file"}.getStr
  if file.len == 0:
    result = newJObject()
    result["error"] = newJString("missing required arg: file")
    return result
  let toolchain = args{"toolchain"}.getStr("nimony")

  var cmd = ""
  if toolchain == "nim":
    cmd = "nim check --hints:off --colors:off " & quoteShell(file)
  else:
    let nimony = getEnv("NIMONY", getEnv("HOME") & "/nimony/bin/nimony")
    cmd = quoteShell(nimony) & " c " & quoteShell(file)

  # extra args
  for a in args{"extra_args"}:
    cmd.add(' ')
    cmd.add(quoteShell(a.getStr))

  var output = ""
  var code = 0
  try:
    let (o, c) = execCmdEx(cmd)
    output = o
    code = c
  except:
    result = newJObject()
    result["error"] = newJString("failed to run compiler")
    return result

  let diags = newJArray()
  var sawError = false
  for line in output.splitLines():
    let d = parseDiagLine(line)
    if d != nil:
      diags.add(d)
      if d{"severity"}.getStr == "error": sawError = true

  # nimony `c` can exit 0 on failure; any Error line means failure.
  let ok = (code == 0) and (not sawError)
  result = newJObject()
  result["ok"] = newJBool(ok)
  result["toolchain"] = newJString(toolchain)
  result["diagnostics"] = diags

# ---------------------------------------------------------------------------
# nif_outline: list the top-level (tag name ...) nodes of a NIF artifact
# ---------------------------------------------------------------------------

proc nifOutlineTool(args: JsonValue): JsonValue =
  let file = args{"file"}.getStr
  if file.len == 0:
    result = newJObject()
    result["error"] = newJString("missing required arg: file")
    return result
  var text = ""
  try:
    text = readFile(file)
  except:
    result = newJObject()
    result["error"] = newJString("cannot read file: " & file)
    return result

  # Walk the S-expression, emitting an entry each time we open a paren at
  # depth 1 (a top-level node): record its head tag and the following name.
  let tags = newJArray()
  var depth = 0
  var i = 0
  let n = text.len
  while i < n:
    let c = text[i]
    if c == '"':
      # skip string literal
      inc i
      while i < n and text[i] != '"':
        if text[i] == '\\': inc i
        inc i
      inc i
      continue
    if c == '(':
      inc depth
      if depth == 1:
        # read the head tag: token up to whitespace or paren
        var j = i + 1
        var tag = ""
        while j < n and text[j] notin {' ', '\t', '\n', '\r', '(', ')'}:
          tag.add(text[j]); inc j
        # skip whitespace, then read the name token (often a symbol)
        while j < n and text[j] in {' ', '\t', '\n', '\r'}: inc j
        var name = ""
        while j < n and text[j] notin {' ', '\t', '\n', '\r', '(', ')'}:
          name.add(text[j]); inc j
        let entry = newJObject()
        entry["tag"] = newJString(tag)
        entry["name"] = newJString(name)
        tags.add(entry)
      inc i
      continue
    if c == ')':
      if depth > 0: dec depth
      inc i
      continue
    inc i
  result = newJObject()
  result["tags"] = tags

# ---------------------------------------------------------------------------

let srv = newServer("aowlmcp-nimtools", "0.1.0")

srv.registerTool("compile",
  "Type-check a Nim or Nimony file; returns structured diagnostics.",
  """{"type":"object","properties":{"file":{"type":"string","description":"Path to the source file."},"toolchain":{"type":"string","enum":["nimony","nim"],"default":"nimony"},"extra_args":{"type":"array","items":{"type":"string"}}},"required":["file"]}""",
  compileTool)

srv.registerTool("nif_outline",
  "List the top-level (tag name ...) nodes of a NIF artifact.",
  """{"type":"object","properties":{"file":{"type":"string","description":"Path to a .nif file."}},"required":["file"]}""",
  nifOutlineTool)

srv.run()
