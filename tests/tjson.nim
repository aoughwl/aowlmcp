import std/[syncio, assertions]
import "../src/aowlmcp/json"

proc rt(s: string): string =
  var err = ""
  let v = parseJson(s, err)
  assert err.len == 0, "parse error: " & err & " for " & s
  result = $v

# round-trips (compact, key order preserved)
assert rt("""{"a":1,"b":[true,false,null],"c":"hi"}""") ==
       """{"a":1,"b":[true,false,null],"c":"hi"}"""
assert rt("[]") == "[]"
assert rt("{}") == "{}"
assert rt("""  {  "x" : 42 }  """) == """{"x":42}"""
assert rt("\"a\\nb\"") == "\"a\\nb\""
assert rt("-12.5e3") == "-12.5e3"

# nested access
var err = ""
let req = parseJson("""{"method":"tools/call","id":7,"params":{"name":"greet","arguments":{"who":"world"}}}""", err)
assert err.len == 0
assert req{"method"}.getStr == "tools/call"
assert req{"id"}.getInt == 7
assert req{"params"}{"name"}.getStr == "greet"
assert req{"params"}{"arguments"}{"who"}.getStr == "world"
# missing keys chain to null safely
assert req{"nope"}{"deep"}.getStr("fallback") == "fallback"
assert req{"nope"}.isNull

# builders
let o = newJObject()
o["jsonrpc"] = newJString("2.0")
o["id"] = newJInt(7)
let arr = newJArray()
arr.add(newJString("x"))
arr.add(newJBool(true))
o["items"] = arr
assert $o == """{"jsonrpc":"2.0","id":7,"items":["x",true]}"""

# error surfacing
var e2 = ""
discard parseJson("{bad}", e2)
assert e2.len > 0

# unicode escape decode
assert rt("\"\\u0041\\u00e9\"") == "\"Aé\""

echo "tjson: OK"
