# Liquid Library API
# ==================
# Clean public API for the Liquid template engine, built on the
# Pitchfork engine plus its Liquid tine.
# Renders with JsonNode context data, or lazily against an arena
# context store so every context access is tracked by node identity.

import std/[json, tables, sets]
import arena_context_store
import json_bridge
import tines/liquid/api
import bytecode as pf_bytecode

export json_bridge
export pf_bytecode.VMValue, pf_bytecode.VMValueKind
export api.wrap_arena_node

proc render*(template_source: string, context: JsonNode,
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Compile and render a Liquid template with JSON context data.
  ##
  ## Parameters:
  ##   template_source: The Liquid template string
  ##   context: A JObject with template variables (keys become top-level variables)
  ##   partials: Optional partial templates (name -> source)
  ##
  ## Returns the rendered output string.
  let compiled = compile_source(template_source)
  let data = json_to_vm_table(context)
  result = api.render(compiled.bytecode, compiled.strings, compiled.constants,
                      data, partials)

proc render_tracked*(template_source: string, context: JsonNode,
                     partials: Table[string, string] = initTable[string, string]()):
                     tuple[output: string, accessed: HashSet[string]] =
  ## Compile and render a Liquid template, also returning the set of
  ## context variable paths that were accessed during rendering.
  ##
  ## Useful for dependency tracking / incremental rebuilds.
  let compiled = compile_source(template_source)
  let data = json_to_vm_table(context)
  result = api.render_tracked(compiled.bytecode, compiled.strings, compiled.constants,
                              data, partials)

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
  let data = json_to_vm_table(context)
  result = api.render(compiled.bytecode, compiled.strings, compiled.constants,
                      data, partials)

proc render_tracked*(compiled: CompiledTemplate, context: JsonNode,
                     partials: Table[string, string] = initTable[string, string]()):
                     tuple[output: string, accessed: HashSet[string]] =
  ## Render a pre-compiled template with access tracking.
  let data = json_to_vm_table(context)
  result = api.render_tracked(compiled.bytecode, compiled.strings, compiled.constants,
                              data, partials)

proc render*(compiled: CompiledTemplate, arena: var Arena, context_root: NodeId,
             overlays: Table[string, VMValue] = initTable[string, VMValue](),
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Render a pre-compiled template against an arena-backed context.
  ## Variables resolve lazily from the root object; containers stay lazy
  ## until consumed, so an alias like {% assign s = site %} keeps
  ## s.title as precise in the access log as site.title. Overlays shadow
  ## the root, for per-page values like item and items — build them with
  ## wrap_arena_node.
  api.render(compiled.bytecode, compiled.strings, compiled.constants,
             addr arena, context_root, overlays, partials)

proc render*(template_source: string, arena: var Arena, context_root: NodeId,
             overlays: Table[string, VMValue] = initTable[string, VMValue](),
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Compile and render against an arena-backed context.
  let compiled = compile_template(template_source)
  compiled.render(arena, context_root, overlays, partials)


when isMainModule:
  import std/unittest

  suite "Liquid Library API":
    test "render simple template":
      let ctx = %*{"name": "World"}
      let output = render("Hello, {{ name }}!", ctx)
      check output == "Hello, World!"

    test "render with missing variable":
      let ctx = newJObject()
      let output = render("Hello, {{ name }}!", ctx)
      check output == "Hello, !"

    test "render with nested context":
      let ctx = %*{"user": {"name": "Alice", "age": 30}}
      let output = render("{{ user.name }} is {{ user.age }}", ctx)
      check output == "Alice is 30"

    test "render with array":
      let ctx = %*{"items": ["a", "b", "c"]}
      let output = render("{% for item in items %}{{ item }}{% endfor %}", ctx)
      check output == "abc"

    test "render with partials":
      let ctx = %*{"title": "Test"}
      let partials = {"header": "<h1>{{ title }}</h1>"}.toTable
      let output = render("{% include 'header' %}", ctx, partials)
      check output == "<h1>Test</h1>"

    test "compiled template reuse":
      let compiled = compile_template("Hello, {{ name }}!")
      check compiled.render(%*{"name": "Alice"}) == "Hello, Alice!"
      check compiled.render(%*{"name": "Bob"}) == "Hello, Bob!"

    test "render_tracked returns accessed paths":
      let ctx = %*{"a": 1, "b": 2, "c": 3}
      let (output, accessed) = render_tracked("{{ a }}{{ b }}", ctx)
      check output == "12"
      check "a" in accessed
      check "b" in accessed
      check "c" notin accessed

    test "json_to_vmvalue null":
      let v = json_to_vmvalue(newJNull())
      check v.kind == vmNull

    test "json_to_vmvalue bool":
      let v = json_to_vmvalue(newJBool(true))
      check v.kind == vmBool
      check v.boolVal == true

    test "json_to_vmvalue int":
      let v = json_to_vmvalue(newJInt(42))
      check v.kind == vmInt
      check v.intVal == 42

    test "json_to_vmvalue float":
      let v = json_to_vmvalue(newJFloat(3.14))
      check v.kind == vmFloat
      check v.floatVal == 3.14

    test "json_to_vmvalue string":
      let v = json_to_vmvalue(newJString("hello"))
      check v.kind == vmString
      check v.stringVal == "hello"

    test "json_to_vmvalue array":
      let v = json_to_vmvalue(%*[1, "two", true])
      check v.kind == vmArray
      check v.arrayVal.len == 3
      check v.arrayVal[0].kind == vmInt
      check v.arrayVal[1].kind == vmString
      check v.arrayVal[2].kind == vmBool

    test "json_to_vmvalue object":
      let v = json_to_vmvalue(%*{"a": 1, "b": "two"})
      check v.kind == vmObject
      check v.objectVal["a"].kind == vmInt
      check v.objectVal["b"].kind == vmString

    test "vmvalue_to_json round-trip":
      let original = %*{
        "name": "Alice",
        "age": 30,
        "active": true,
        "score": 9.5,
        "tags": ["nim", "liquid"],
        "address": {"city": "Stockholm"}
      }
      let vm_val = json_to_vmvalue(original)
      let back = vmvalue_to_json(vm_val)
      check back["name"].getStr == "Alice"
      check back["age"].getInt == 30
      check back["active"].getBool == true
      check back["score"].getFloat == 9.5
      check back["tags"][0].getStr == "nim"
      check back["address"]["city"].getStr == "Stockholm"

    test "json_to_vm_table from non-object":
      let t = json_to_vm_table(newJArray())
      check t.len == 0

    test "json_to_vmvalue nil node":
      let v = json_to_vmvalue(nil)
      check v.kind == vmNull

    test "render with integers and booleans in context":
      let ctx = %*{"count": 3, "active": true}
      let output = render("Count: {{ count }}, Active: {{ active }}", ctx)
      check output == "Count: 3, Active: true"

    test "render with filters":
      let ctx = %*{"name": "hello world"}
      let output = render("{{ name | upcase }}", ctx)
      check output == "HELLO WORLD"

    test "render with conditional":
      let ctx = %*{"show": true, "message": "visible"}
      let output = render("{% if show %}{{ message }}{% endif %}", ctx)
      check output == "visible"

  suite "Arena-backed rendering":
    proc arenaFrom(j: JsonNode): (Arena, NodeId) =
      var arena = initArena()
      let root = arena.fromJson(j)
      (arena, root)

    test "variables resolve from the arena root":
      var (arena, root) = arenaFrom(%*{"name": "World"})
      check render("Hello, {{ name }}!", arena, root) == "Hello, World!"

    test "missing variables are null":
      var (arena, root) = arenaFrom(%*{"present": 1})
      check render("[{{ absent }}]", arena, root) == "[]"

    test "nested access stays lazy and correct":
      var (arena, root) = arenaFrom(%*{"user": {"name": "Alice", "address": {"city": "Stockholm"}}})
      check render("{{ user.name }} of {{ user.address.city }}", arena, root) ==
        "Alice of Stockholm"

    test "loops iterate arena arrays":
      var (arena, root) = arenaFrom(%*{"items": ["a", "b", "c"]})
      check render("{% for i in items %}{{ i }}{% endfor %}", arena, root) == "abc"

    test "loops iterate arena objects as key value pairs":
      var (arena, root) = arenaFrom(%*{"prices": {"apple": 3, "pear": 5}})
      check render("{% for p in prices %}{{ p[0] }}={{ p[1] }} {% endfor %}", arena, root) ==
        "apple=3 pear=5 "

    test "size, first and last work on arena containers":
      var (arena, root) = arenaFrom(%*{"items": [10, 20, 30]})
      check render("{{ items.size }}/{{ items.first }}/{{ items.last }}", arena, root) ==
        "3/10/30"

    test "indexing with negative and out-of-range indices":
      var (arena, root) = arenaFrom(%*{"items": ["x", "y"]})
      check render("{{ items[0] }}{{ items[-1] }}[{{ items[9] }}]", arena, root) == "xy[]"

    test "filters consume arena containers":
      var (arena, root) = arenaFrom(%*{"items": ["b", "c", "a"]})
      check render("{{ items | sort | join: '-' }}", arena, root) == "a-b-c"

    test "outputting a whole container materializes it":
      var (arena, root) = arenaFrom(%*{"items": [1, 2, 3]})
      check render("{{ items }}", arena, root) == "123"

    test "equality materializes containers":
      var (arena, root) = arenaFrom(%*{"a": [1, 2], "b": [1, 2], "c": [3]})
      check render("{% if a == b %}same{% endif %}{% if a == c %}!{% endif %}", arena, root) ==
        "same"

    test "overlays shadow the context root":
      var (arena, root) = arenaFrom(%*{"title": "from context", "posts": [{"title": "from item"}]})
      let item = arena.arrGet(arena.objGet(root, "posts"), 0)
      let overlays = {"item": wrap_arena_node(arena, item)}.toTable
      check render("{{ item.title }} / {{ title }}", arena, root, overlays) ==
        "from item / from context"

    test "partials share the arena context":
      var (arena, root) = arenaFrom(%*{"site": {"name": "Accodeing"}})
      let partials = {"head": "<title>{{ site.name }}</title>"}.toTable
      check render("{% include 'head' %}", arena, root,
                   initTable[string, VMValue](), partials) ==
        "<title>Accodeing</title>"

    test "a lazy value bound into a render partial resolves":
      # {% render %} isolates scope but the arena store still travels
      # into the sub-VM — a lazy container bound through with/for must
      # not dereference a nil arena.
      var (arena, root) = arenaFrom(%*{"posts": [{"title": "one"}, {"title": "two"}]})
      let partials = {"card": "[{{ card.title }}]"}.toTable
      check render("{% for p in posts %}{% render 'card' with p as card %}{% endfor %}",
                   arena, root, initTable[string, VMValue](), partials) ==
        "[one][two]"

    test "include-for expands a lazy collection":
      var (arena, root) = arenaFrom(%*{"items": [{"n": 1}, {"n": 2}]})
      let partials = {"row": "<{{ row.n }}>"}.toTable
      check render("{% include 'row' for items %}", arena, root,
                   initTable[string, VMValue](), partials) == "<1><2>"

    test "lazy elements inside an eager overlay group render":
      # An overlay built as an eager array of wrapped nodes (the merged
      # route group convention) must stringify its lazy elements.
      var (arena, root) = arenaFrom(%*{"a": [1, 2], "b": [3]})
      var group = VMValue(kind: vmArray)
      group.arrayVal.add(wrap_arena_node(arena, arena.objGet(root, "a")))
      group.arrayVal.add(wrap_arena_node(arena, arena.objGet(root, "b")))
      let overlays = {"merged": group}.toTable
      check render("{{ merged }}", arena, root, overlays) == "123"

    test "assign aliases stay lazy":
      var (arena, root) = arenaFrom(%*{"site": {"name": "Accodeing", "domain": "accodeing.com"}})
      check render("{% assign s = site %}{{ s.name }}", arena, root) == "Accodeing"

    test "reads are recorded with alias precision":
      var (arena, root) = arenaFrom(%*{
        "site": {"name": "Accodeing", "domain": "accodeing.com"},
        "other": {"unused": true}
      })
      let site = arena.objGet(root, "site")
      let nameNode = arena.objGet(site, "name")
      let domainNode = arena.objGet(site, "domain")
      let otherNode = arena.objGet(root, "other")
      arena.clearTracking()

      arena.pushConsumer(7)
      check render("{% assign s = site %}{{ s.name }}", arena, root) == "Accodeing"
      arena.popConsumer()

      # The alias carried the NodeId, so only the traversed edges and the
      # scalar actually read are in the log — not the sibling, not the
      # unrelated subtree, and no whole-context read.
      let reads = arena.readSet(7)
      check nameNode in reads
      check domainNode notin reads
      check otherNode notin reads
      check arena.iterateSet(7).len == 0

    test "a missed lookup records an iterate on the root":
      var (arena, root) = arenaFrom(%*{"present": 1})
      arena.clearTracking()
      arena.pushConsumer(8)
      discard render("{{ absent }}", arena, root)
      arena.popConsumer()
      check root in arena.iterateSet(8)

    test "untouched context stays out of the log entirely":
      var (arena, root) = arenaFrom(%*{"a": {"deep": [1, 2, 3]}, "b": "used"})
      arena.clearTracking()
      arena.pushConsumer(9)
      check render("{{ b }}", arena, root) == "used"
      arena.popConsumer()
      let touched = arena.readSet(9)
      check arena.objGet(root, "a") notin touched
