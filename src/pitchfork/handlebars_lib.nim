# Handlebars Library API
# ====================
# Clean public API for the Handlebars template engine, built on the
# Pitchfork engine plus its Handlebars tine.
# Accepts JsonNode context data and returns rendered strings.
# Mirrors liquid_lib.

import std/[json, tables, sets]
import json_bridge
import tines/handlebars/api

export json_bridge

proc render*(template_source: string, context: JsonNode,
             partials: Table[string, string] = initTable[string, string]()): string =
  ## Compile and render a Handlebars template with JSON context data.
  ##
  ## Parameters:
  ##   template_source: The Handlebars template string
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
  ## Compile and render a Handlebars template, also returning the set of
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

