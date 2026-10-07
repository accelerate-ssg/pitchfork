# Liquid C Library API
# ====================
# C-compatible shared library interface for the Liquid template engine.
# Build with: nim c --app:lib -d:release -o:libliquid.dylib src/pitchfork/liquid_c.nim

import std/[json, tables]
import liquid_lib

proc liquid_render(template_src: cstring, context_json: cstring,
                   partials_json: cstring): cstring {.exportc, dynlib.} =
  ## Render a Liquid template.
  ##
  ## Parameters:
  ##   template_src:  Liquid template string
  ##   context_json:  JSON object string with template variables
  ##   partials_json: JSON object mapping partial names to source strings,
  ##                  or NULL for no partials
  ##
  ## Returns a heap-allocated cstring with the rendered output.
  ## Caller must free with liquid_free(). Returns NULL on error.
  try:
    let ctx = parseJson($context_json)

    var partials = initTable[string, string]()
    if not partials_json.isNil and partials_json[0] != '\0':
      let pj = parseJson($partials_json)
      if pj.kind == JObject:
        for key, val in pj:
          partials[key] = val.getStr

    let output = liquid_lib.render($template_src, ctx, partials)

    # Allocate a copy for C ownership
    let buf = cast[cstring](alloc(output.len + 1))
    copyMem(buf, output.cstring, output.len)
    cast[ptr char](cast[int](buf) + output.len)[] = '\0'
    return buf
  except:
    return nil

proc liquid_free(s: cstring) {.exportc, dynlib.} =
  ## Free a string returned by liquid_render.
  if not s.isNil:
    dealloc(s)

proc NimMain() {.importc.}

proc liquid_init() {.exportc, dynlib.} =
  ## Initialize the Nim runtime. Must be called once before any other
  ## liquid_* functions when using the library from C.
  NimMain()
