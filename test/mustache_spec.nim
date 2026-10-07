# Official Mustache spec conformance suite
# ========================================
# Runs the vendored https://github.com/mustache/spec JSON suites against
# the Mustache tine. The optional ~lambdas and ~inheritance modules are
# not vendored (lambdas are deliberately out of scope for now).

import std/[json, os, tables, strutils]
import ../src/pitchfork/mustache_lib

const suites = ["interpolation", "sections", "inverted", "comments",
                "delimiters", "partials"]

var run = 0
var passed = 0
var failures: seq[string] = @[]

for suite in suites:
  let path = currentSourcePath().parentDir() / "mustache_spec" / suite & ".json"
  let spec = parseJson(readFile(path))
  for t in spec["tests"]:
    inc run
    let name = suite & " :: " & t["name"].getStr()
    let templ = t["template"].getStr()
    let data = t["data"]
    var partials = initTable[string, string]()
    if "partials" in t:
      for k, v in t["partials"]:
        partials[k] = v.getStr()
    let expected = t["expected"].getStr()
    var got: string
    try:
      got = render(templ, data, partials)
    except CatchableError as e:
      failures.add(name & "\n  ERROR: " & e.msg)
      continue
    if got == expected:
      inc passed
    else:
      failures.add(name &
        "\n  template: " & templ.escape() &
        "\n  expected: " & expected.escape() &
        "\n  got:      " & got.escape())

for f in failures:
  echo "[FAILED] ", f

echo ""
echo "Mustache spec: ", passed, "/", run, " passed"
if passed != run:
  quit(1)

# Inheritance blocks without a parent invocation: {{$block}} renders its
# default body (the "optional hook" pattern legacy acc sites rely on).
# Full inheritance ({{<parent}} with overrides) is not implemented.
block:
  var extra = 0
  var extraPassed = 0
  proc caseOk(name, templ, expected: string, data: JsonNode) =
    inc extra
    let got = render(templ, data, initTable[string, string]())
    if got == expected:
      inc extraPassed
    else:
      echo "[FAILED] blocks :: ", name, " expected ", expected.escape(),
        " got ", got.escape()
  caseOk("empty block renders nothing",
    "a{{$extra_styles}}{{/extra_styles}}b", "ab", %*{})
  caseOk("block default body renders",
    "{{$hook}}default {{name}}{{/hook}}!", "default World!",
    %*{"name": "World"})
  caseOk("standalone block line is stripped",
    "a\n{{$hook}}\nx\n{{/hook}}\nb\n", "a\nx\nb\n", %*{})
  proc caseP(name, templ, expected: string, data: JsonNode,
             partials: openArray[(string, string)]) =
    inc extra
    let got = render(templ, data, partials.toTable)
    if got == expected:
      inc extraPassed
    else:
      echo "[FAILED] blocks :: ", name, " expected ", expected.escape(),
        " got ", got.escape()
  caseP("parent renders with override",
    "{{<layout}}{{$title}}Home{{/title}}{{/layout}}", "[Home]", %*{},
    {"layout": "[{{$title}}Default{{/title}}]"})
  caseP("parent renders default when block not overridden",
    "{{<layout}}{{/layout}}", "[Default]", %*{},
    {"layout": "[{{$title}}Default{{/title}}]"})
  caseP("override body renders in the calling context",
    "{{<layout}}{{$title}}Hi {{name}}{{/title}}{{/layout}}", "[Hi World]",
    %*{"name": "World"},
    {"layout": "[{{$title}}Default{{/title}}]"})
  caseP("text outside blocks in the parent call body is ignored",
    "{{<layout}}IGNORED {{$title}}X{{/title}} ALSO{{/layout}}", "[X]", %*{},
    {"layout": "[{{$title}}Default{{/title}}]"})
  caseP("a second parent call does not inherit the first call's override",
    "{{<layout}}{{$title}}A{{/title}}{{/layout}}{{<layout}}{{/layout}}",
    "[A][Default]", %*{},
    {"layout": "[{{$title}}Default{{/title}}]"})
  caseP("parent name may contain a slash",
    "{{< partials/head}}{{$extra_styles}}<link>{{/extra_styles}}{{/partials/head}}",
    "(<link>)", %*{},
    {"partials/head": "({{$extra_styles}}{{/extra_styles}})"})
  echo "Inheritance blocks: ", extraPassed, "/", extra, " passed"
  if extraPassed != extra:
    quit(1)
