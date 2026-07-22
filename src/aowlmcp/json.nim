## aowlmcp/json — a small, self-contained JSON value type for Nimony.
##
## Nimony ships a NIF-backed `std/json`, but its document is move-only and only
## exposes root-level key lookup, which is awkward to thread through a tool
## handler API. This module provides a plain reference-counted `JsonValue` tree
## with ergonomic nested access (`v{"a"}{"b"}`), a recursive-descent parser and
## a compact serializer. Errors are returned as values, never raised — matching
## Nimony's status-based stance.
##
## Numbers are kept as their source lexeme (`num`) so any JSON number round-trips
## byte-for-byte; `getInt` / `getFloat` decode on demand.

when defined(nimony):
  {.feature: "lenientnils".}

import std/strutils

type
  JsonKind* = enum
    jnNull, jnBool, jnNumber, jnString, jnArray, jnObject

  JsonValue* = ref object
    case kind*: JsonKind
    of jnNull: discard
    of jnBool: bval*: bool
    of jnNumber: num*: string        ## the raw numeric lexeme
    of jnString: sval*: string
    of jnArray: elems*: seq[JsonValue]
    of jnObject: fields*: seq[(string, JsonValue)]   ## insertion-ordered

# ---------------------------------------------------------------------------
# constructors
# ---------------------------------------------------------------------------

proc newJNull*(): JsonValue = JsonValue(kind: jnNull)
proc newJBool*(b: bool): JsonValue = JsonValue(kind: jnBool, bval: b)
proc newJString*(s: string): JsonValue = JsonValue(kind: jnString, sval: s)
proc newJInt*(i: int64): JsonValue = JsonValue(kind: jnNumber, num: $i)
proc newJRawNumber*(lexeme: string): JsonValue =
  JsonValue(kind: jnNumber, num: lexeme)
proc newJArray*(): JsonValue = JsonValue(kind: jnArray, elems: @[])
proc newJObject*(): JsonValue = JsonValue(kind: jnObject, fields: @[])

# ---------------------------------------------------------------------------
# building
# ---------------------------------------------------------------------------

proc add*(arr: JsonValue; v: JsonValue) =
  ## Append to an array node.
  arr.elems.add(v)

proc `[]=`*(obj: JsonValue; key: string; v: JsonValue) =
  ## Set (or replace) an object member, preserving first-seen order.
  for i in 0 ..< obj.fields.len:
    if obj.fields[i][0] == key:
      obj.fields[i] = (key, v)
      return
  obj.fields.add((key, v))

# ---------------------------------------------------------------------------
# access
# ---------------------------------------------------------------------------

proc len*(n: JsonValue): int =
  ## Element count for arrays and objects; 0 otherwise.
  case n.kind
  of jnArray: n.elems.len
  of jnObject: n.fields.len
  else: 0

proc hasKey*(n: JsonValue; key: string): bool =
  if n.kind != jnObject: return false
  for f in n.fields:
    if f[0] == key: return true
  return false

proc `{}`*(n: JsonValue; key: string): JsonValue =
  ## Object member lookup. Returns a fresh JNull when `n` is not an object or
  ## the key is absent, so chains like `req{"params"}{"name"}` never fault.
  if n.kind == jnObject:
    for f in n.fields:
      if f[0] == key: return f[1]
  return newJNull()

proc at*(n: JsonValue; i: int): JsonValue =
  ## Array index; JNull when out of range or not an array.
  if n.kind == jnArray and i >= 0 and i < n.elems.len:
    return n.elems[i]
  return newJNull()

proc getStr*(n: JsonValue; default = ""): string =
  if n.kind == jnString: n.sval else: default

proc getInt*(n: JsonValue; default: int64 = 0): int64 =
  if n.kind != jnNumber: return default
  try:
    return int64(parseInt(n.num))
  except:
    return default

proc getBool*(n: JsonValue; default = false): bool =
  if n.kind == jnBool: n.bval else: default

proc isNull*(n: JsonValue): bool = n.kind == jnNull

iterator items*(n: JsonValue): JsonValue =
  if n.kind == jnArray:
    for e in n.elems: yield e

iterator pairs*(n: JsonValue): (string, JsonValue) =
  if n.kind == jnObject:
    for f in n.fields: yield f

# ---------------------------------------------------------------------------
# serialization (compact)
# ---------------------------------------------------------------------------

proc escapeInto(s: string; dst: var string) =
  dst.add('"')
  for i in 0 ..< s.len:
    let c = s[i]
    case c
    of '"': dst.add("\\\"")
    of '\\': dst.add("\\\\")
    of '\n': dst.add("\\n")
    of '\r': dst.add("\\r")
    of '\t': dst.add("\\t")
    of '\b': dst.add("\\b")
    of '\f': dst.add("\\f")
    else:
      if ord(c) < 0x20:
        const hex = "0123456789abcdef"
        dst.add("\\u00")
        dst.add(hex[(ord(c) shr 4) and 0xf])
        dst.add(hex[ord(c) and 0xf])
      else:
        dst.add(c)
  dst.add('"')

proc toStringInto(n: JsonValue; dst: var string) =
  case n.kind
  of jnNull: dst.add("null")
  of jnBool: dst.add(if n.bval: "true" else: "false")
  of jnNumber:
    if n.num.len == 0: dst.add("0") else: dst.add(n.num)
  of jnString: escapeInto(n.sval, dst)
  of jnArray:
    dst.add('[')
    for i in 0 ..< n.elems.len:
      if i > 0: dst.add(',')
      toStringInto(n.elems[i], dst)
    dst.add(']')
  of jnObject:
    dst.add('{')
    for i in 0 ..< n.fields.len:
      if i > 0: dst.add(',')
      escapeInto(n.fields[i][0], dst)
      dst.add(':')
      toStringInto(n.fields[i][1], dst)
    dst.add('}')

proc `$`*(n: JsonValue): string =
  ## Compact serialization (no insignificant whitespace).
  result = ""
  toStringInto(n, result)

# ---------------------------------------------------------------------------
# parsing (recursive descent, error-as-value)
# ---------------------------------------------------------------------------

type Parser = object
  s: string
  i: int
  err: string

proc fail(p: var Parser; msg: string) =
  if p.err.len == 0:
    p.err = msg & " at offset " & $p.i

proc skipWs(p: var Parser) =
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c == ' ' or c == '\t' or c == '\n' or c == '\r':
      inc p.i
    else:
      break

proc parseValue(p: var Parser): JsonValue

proc appendUtf8(dst: var string; cp: int) =
  if cp < 0x80:
    dst.add(char(cp))
  elif cp < 0x800:
    dst.add(char(0xC0 or (cp shr 6)))
    dst.add(char(0x80 or (cp and 0x3F)))
  elif cp < 0x10000:
    dst.add(char(0xE0 or (cp shr 12)))
    dst.add(char(0x80 or ((cp shr 6) and 0x3F)))
    dst.add(char(0x80 or (cp and 0x3F)))
  else:
    dst.add(char(0xF0 or (cp shr 18)))
    dst.add(char(0x80 or ((cp shr 12) and 0x3F)))
    dst.add(char(0x80 or ((cp shr 6) and 0x3F)))
    dst.add(char(0x80 or (cp and 0x3F)))

proc hexVal(c: char): int =
  if c >= '0' and c <= '9': ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': ord(c) - ord('a') + 10
  elif c >= 'A' and c <= 'F': ord(c) - ord('A') + 10
  else: -1

proc parse4Hex(p: var Parser): int =
  var v = 0
  var k = 0
  while k < 4:
    if p.i >= p.s.len:
      p.fail("truncated \\u escape")
      return -1
    let h = hexVal(p.s[p.i])
    if h < 0:
      p.fail("bad hex digit in \\u escape")
      return -1
    v = v * 16 + h
    inc p.i
    inc k
  return v

proc parseString(p: var Parser): string =
  # assumes current char is the opening quote
  result = ""
  inc p.i  # skip opening "
  while p.i < p.s.len:
    let c = p.s[p.i]
    if c == '"':
      inc p.i
      return result
    elif c == '\\':
      inc p.i
      if p.i >= p.s.len:
        p.fail("truncated escape")
        return result
      let e = p.s[p.i]
      case e
      of '"': result.add('"'); inc p.i
      of '\\': result.add('\\'); inc p.i
      of '/': result.add('/'); inc p.i
      of 'b': result.add('\b'); inc p.i
      of 'f': result.add('\f'); inc p.i
      of 'n': result.add('\n'); inc p.i
      of 'r': result.add('\r'); inc p.i
      of 't': result.add('\t'); inc p.i
      of 'u':
        inc p.i
        var cp = parse4Hex(p)
        if cp < 0: return result
        # surrogate pair?
        if cp >= 0xD800 and cp <= 0xDBFF and p.i + 1 < p.s.len and
           p.s[p.i] == '\\' and p.s[p.i+1] == 'u':
          inc p.i  # backslash
          inc p.i  # u
          let lo = parse4Hex(p)
          if lo < 0: return result
          cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
        appendUtf8(result, cp)
      else:
        p.fail("invalid escape character")
        return result
    else:
      result.add(c)
      inc p.i
  p.fail("unterminated string")
  return result

proc parseNumber(p: var Parser): JsonValue =
  let start = p.i
  if p.i < p.s.len and p.s[p.i] == '-': inc p.i
  while p.i < p.s.len:
    let c = p.s[p.i]
    if (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or
       c == '+' or c == '-':
      inc p.i
    else:
      break
  let lexeme = p.s[start ..< p.i]
  if lexeme.len == 0 or lexeme == "-":
    p.fail("invalid number")
    return newJNull()
  return newJRawNumber(lexeme)

proc parseArray(p: var Parser): JsonValue =
  result = newJArray()
  inc p.i  # [
  p.skipWs()
  if p.i < p.s.len and p.s[p.i] == ']':
    inc p.i
    return result
  while true:
    p.skipWs()
    let v = p.parseValue()
    if p.err.len > 0: return result
    result.add(v)
    p.skipWs()
    if p.i >= p.s.len:
      p.fail("unterminated array")
      return result
    let c = p.s[p.i]
    if c == ',':
      inc p.i
    elif c == ']':
      inc p.i
      return result
    else:
      p.fail("expected ',' or ']' in array")
      return result

proc parseObject(p: var Parser): JsonValue =
  result = newJObject()
  inc p.i  # {
  p.skipWs()
  if p.i < p.s.len and p.s[p.i] == '}':
    inc p.i
    return result
  while true:
    p.skipWs()
    if p.i >= p.s.len or p.s[p.i] != '"':
      p.fail("expected string key in object")
      return result
    let key = p.parseString()
    if p.err.len > 0: return result
    p.skipWs()
    if p.i >= p.s.len or p.s[p.i] != ':':
      p.fail("expected ':' after object key")
      return result
    inc p.i  # :
    p.skipWs()
    let v = p.parseValue()
    if p.err.len > 0: return result
    result[key] = v
    p.skipWs()
    if p.i >= p.s.len:
      p.fail("unterminated object")
      return result
    let c = p.s[p.i]
    if c == ',':
      inc p.i
    elif c == '}':
      inc p.i
      return result
    else:
      p.fail("expected ',' or '}' in object")
      return result

proc literalIs(p: var Parser; word: string): bool =
  if p.i + word.len > p.s.len: return false
  for k in 0 ..< word.len:
    if p.s[p.i + k] != word[k]: return false
  p.i = p.i + word.len
  return true

proc parseValue(p: var Parser): JsonValue =
  p.skipWs()
  if p.i >= p.s.len:
    p.fail("unexpected end of input")
    return newJNull()
  let c = p.s[p.i]
  case c
  of '{': return p.parseObject()
  of '[': return p.parseArray()
  of '"': return newJString(p.parseString())
  of 't':
    if p.literalIs("true"): return newJBool(true)
    p.fail("invalid literal"); return newJNull()
  of 'f':
    if p.literalIs("false"): return newJBool(false)
    p.fail("invalid literal"); return newJNull()
  of 'n':
    if p.literalIs("null"): return newJNull()
    p.fail("invalid literal"); return newJNull()
  else:
    if c == '-' or (c >= '0' and c <= '9'):
      return p.parseNumber()
    p.fail("unexpected character")
    return newJNull()

proc parseJson*(s: string; err: var string): JsonValue =
  ## Parse `s` into a JsonValue. On failure, `err` is set to a message and the
  ## return value is a JNull. On success `err` is "".
  var p = Parser(s: s, i: 0, err: "")
  result = p.parseValue()
  if p.err.len == 0:
    p.skipWs()
    if p.i != p.s.len:
      p.fail("trailing characters after JSON value")
  err = p.err
