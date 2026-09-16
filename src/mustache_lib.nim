# Mustache Library API
# ====================
# Clean public API for the Mustache template engine, built on the
# Pitchfork engine plus its Mustache tine.
# Accepts JsonNode context data and returns rendered strings.
# Mirrors liquid_lib.

import std/[json, tables, sets]
import pitchfork/json_bridge
import pitchfork/tines/mustache/api

export json_bridge

proc render*(template_source: string, context: JsonNode,
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Compile and render a Mustache template with JSON context data.
  ##
  ## Parameters:
  ##   template_source: The Mustache template string
  ##   context: A JObject with template variables (keys become top-level variables)
  ##   partials: Optional partial templates (name -> source)
  ##
  ## Returns the rendered output string.
  let compiled = compile_source(template_source)
  let root = json_to_vmvalue(context)
  let data = json_to_vm_table(context)
  result = api.render(compiled.bytecode, compiled.strings, compiled.constants,
                      root, data, partials)

proc render_tracked*(template_source: string, context: JsonNode,
                     partials: Table[string, string] = initTable[string, string]()):
                     tuple[output: string, accessed: HashSet[string]] =
  ## Compile and render a Mustache template, also returning the set of
  ## context variable paths that were accessed during rendering.
  let compiled = compile_source(template_source)
  let root = json_to_vmvalue(context)
  let data = json_to_vm_table(context)
  result = api.render_tracked(compiled.bytecode, compiled.strings, compiled.constants,
                              root, data, partials)

type
  CompiledTemplate* = object
    ## A pre-compiled template that can be rendered multiple times
    ## with different context data.
    bytecode: seq[Instruction]
    strings: seq[string]
    constants: seq[VMValue]

proc compile_template*(template_source: string): CompiledTemplate =
  ## Pre-compile a template for repeated rendering.
  let compiled = compile_source(template_source)
  result = CompiledTemplate(
    bytecode: compiled.bytecode,
    strings: compiled.strings,
    constants: compiled.constants,
  )

proc render*(compiled: CompiledTemplate, context: JsonNode,
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Render a pre-compiled template with JSON context data.
  let root = json_to_vmvalue(context)
  let data = json_to_vm_table(context)
  result = api.render(compiled.bytecode, compiled.strings, compiled.constants,
                      root, data, partials)

proc render_tracked*(compiled: CompiledTemplate, context: JsonNode,
                     partials: Table[string, string] = initTable[string, string]()):
                     tuple[output: string, accessed: HashSet[string]] =
  ## Render a pre-compiled template with access tracking.
  let root = json_to_vmvalue(context)
  let data = json_to_vm_table(context)
  result = api.render_tracked(compiled.bytecode, compiled.strings, compiled.constants,
                              root, data, partials)

when isMainModule:
  import std/unittest

  suite "Mustache Library API":
    test "render simple template":
      check render("Hello, {{name}}!", %*{"name": "World"}) == "Hello, World!"

    test "HTML escaping by default, triple mustache raw":
      let ctx = %*{"html": "<b>&</b>"}
      check render("{{html}}", ctx) == "&lt;b&gt;&amp;&lt;/b&gt;"
      check render("{{{html}}}", ctx) == "<b>&</b>"

    test "section over list with context push":
      let ctx = %*{"items": [{"n": 1}, {"n": 2}]}
      check render("{{#items}}({{n}}){{/items}}", ctx) == "(1)(2)"

    test "implicit iterator":
      let ctx = %*{"words": ["a", "b"]}
      check render("{{#words}}{{.}}{{/words}}", ctx) == "ab"

    test "inverted section":
      check render("{{^gone}}nothing{{/gone}}", %*{}) == "nothing"
      check render("{{^here}}nothing{{/here}}", %*{"here": true}) == ""

    test "an empty value is falsy to a section":
      # The spec is silent on these; this follows mustache.js, hogan and
      # nim-mustache, so a section guarding an optional field skips when
      # the field is unset rather than rendering an empty wrapper.
      check render("{{#s}}[{{s}}]{{/s}}", %*{"s": ""}) == ""
      check render("{{#n}}[{{n}}]{{/n}}", %*{"n": 0}) == ""
      check render("{{#f}}[x]{{/f}}", %*{"f": 0.0}) == ""
      check render("{{#l}}[x]{{/l}}", %*{"l": []}) == ""
      # The empty object is the one case where nim-mustache and
      # mustache.js disagree; this follows nim-mustache.
      check render("{{#o}}[x]{{/o}}", %*{"o": {}}) == ""

    test "a non-empty value is still truthy to a section":
      check render("{{#s}}[{{s}}]{{/s}}", %*{"s": "v"}) == "[v]"
      check render("{{#n}}[{{n}}]{{/n}}", %*{"n": 1}) == "[1]"
      check render("{{#o}}[{{k}}]{{/o}}", %*{"o": {"k": "v"}}) == "[v]"

    test "an inverted section is the complement":
      check render("{{^s}}none{{/s}}", %*{"s": ""}) == "none"
      check render("{{^s}}none{{/s}}", %*{"s": "v"}) == ""
      check render("{{^n}}none{{/n}}", %*{"n": 0}) == "none"

    test "an override that renders to nothing still beats the default":
      # Presence, not truthiness: the captured override is "", which is
      # falsy to a section but is still an override.
      let parent = {"p": "<h1>{{$t}}default{{/t}}</h1>"}.toTable
      check render("{{<p}}{{$t}}{{/t}}{{/p}}", %*{}, parent) == "<h1></h1>"
      check render("{{<p}}{{$t}}given{{/t}}{{/p}}", %*{}, parent) == "<h1>given</h1>"
      check render("{{<p}}{{/p}}", %*{}, parent) == "<h1>default</h1>"

    test "context stack fallback":
      let ctx = %*{"outer": "o", "sec": {"inner": "i"}}
      check render("{{#sec}}{{inner}}{{outer}}{{/sec}}", ctx) == "io"

    test "partials with recursion":
      let ctx = %*{"content": "X", "nodes": [{"content": "Y", "nodes": []}]}
      let partials = {"node": "{{content}}<{{#nodes}}{{>node}}{{/nodes}}>"}.toTable
      check render("{{>node}}", ctx, partials) == "X<Y<>>"

    test "compiled template reuse":
      let tmpl = compile_template("Hi {{name}}")
      check tmpl.render(%*{"name": "A"}) == "Hi A"
      check tmpl.render(%*{"name": "B"}) == "Hi B"

    test "render_tracked reports root-level accesses":
      let (output, accessed) = render_tracked("{{a}}{{b}}", %*{"a": 1, "b": 2, "c": 3})
      check output == "12"
      check "a" in accessed
      check "b" in accessed
      check "c" notin accessed
