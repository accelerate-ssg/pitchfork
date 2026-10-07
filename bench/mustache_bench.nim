# Mustache benchmark: Pitchfork's Mustache tine, on its own or against
# moustachu and nim-mustache (the `mustache` package, as used by acc's
# mustache plugin)
# ======================================================================
# Our own numbers need nothing that is not already here:
#   nim c -d:release bench/mustache_bench.nim
#
# The comparisons are opt-in. Neither library is a dependency of this
# package, so importing them unconditionally left this file unbuildable
# anywhere they were missing — which is every clean checkout:
#   nim c -d:release -d:moustachu -p:<moustachu>/src \
#                    -d:nimMustache -p:<nim-mustache>/src \
#                    bench/mustache_bench.nim
#
# Scenarios:
#   A. parse + render every iteration (the other libraries' only mode)
#   B. compile once, render many (Pitchfork's precompiled mode)
# Contexts are pre-built for all libraries; outputs are verified equal
# before timing.

import std/[json, monotimes, times, strutils, strformat, tables]

import ../src/pitchfork/mustache_lib as pitchfork
import ../src/pitchfork/tines/mustache/api as pf_api
import ../src/pitchfork/json_bridge
const with_moustachu = defined(moustachu)
const with_nim_mustache = defined(nimMustache)

when with_moustachu:
  import moustachu
when with_nim_mustache:
  import mustache as nim_mustache

# ── Fixtures ──────────────────────────────────────────────────────────

const small_template = "Hello {{name}}, you have {{count}} new {{#plural}}messages{{/plural}}{{^plural}}message{{/plural}}."

const page_template = """<html><head><title>{{title}}</title></head><body>
<h1>{{title}}</h1>
{{#products}}
  <div class="product">
    <h2>{{name}}</h2>
    <p>{{description}}</p>
    <span class="price">{{price}}</span>
    <ul>{{#tags}}<li>{{.}}</li>{{/tags}}</ul>
    {{#inStock}}<b>In stock</b>{{/inStock}}{{^inStock}}<i>Sold out</i>{{/inStock}}
  </div>
{{/products}}
</body></html>
"""

proc small_data(): JsonNode =
  %*{"name": "Alice", "count": 3, "plural": true}

proc page_data(n: int): JsonNode =
  var products = newJArray()
  for i in 0 ..< n:
    products.add(%*{
      "name": "Product " & $i,
      "description": "A <fine> product & a \"bargain\" no. " & $i,
      "price": 999 + i,  # integer cents: float repr differs between libs
      "tags": ["new", "sale", "tag" & $(i mod 7)],
      "inStock": i mod 2 == 0,
    })
  %*{"title": "Catalog & <Friends>", "products": products}

# ── Timing helpers ────────────────────────────────────────────────────

var blackhole = 0  # defeat dead-code elimination

proc report(label: string, elapsed_ms, per_us: float) =
  echo &"  {label:<44} {elapsed_ms:>9.1f} ms total  {per_us:>9.2f} us/render"

template bench(label: string, iterations: int, body: untyped): float =
  block:
    # Warmup
    for _ in 0 ..< max(iterations div 10, 1):
      body
    let start = getMonoTime()
    for _ in 0 ..< iterations:
      body
    let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e6
    let per = elapsed * 1000.0 / iterations.float
    report(label, elapsed, per)
    per

proc main() =
  let sdata = small_data()
  let pdata = page_data(100)

  # Pre-built contexts
  when with_moustachu:
    let s_ctx_m = moustachu.newContext(sdata)
    let p_ctx_m = moustachu.newContext(pdata)
  when with_nim_mustache:
    let s_ctx_nm = nim_mustache.newContext(values = nim_mustache.toValues(sdata))
    let p_ctx_nm = nim_mustache.newContext(values = nim_mustache.toValues(pdata))
  let s_root = json_to_vmvalue(sdata)
  let s_table = json_to_vm_table(sdata)
  let p_root = json_to_vmvalue(pdata)
  let p_table = json_to_vm_table(pdata)
  let no_partials = initTable[string, string]()

  # Correctness cross-check before timing
  let pf_small = pitchfork.render(small_template, sdata)
  let pf_page = pitchfork.render(page_template, pdata)
  when with_moustachu:
    let m_small = moustachu.render(small_template, sdata)
    doAssert pf_small == m_small, "small outputs differ:\n" & pf_small & "\n---\n" & m_small
    let m_page = moustachu.render(page_template, pdata)
    doAssert pf_page == m_page, "page outputs differ"
  when with_nim_mustache:
    let nm_small = nim_mustache.render(small_template, s_ctx_nm)
    doAssert pf_small == nm_small, "nim-mustache small differs:\n" & nm_small
    let nm_page = nim_mustache.render(page_template, p_ctx_nm)
    doAssert pf_page == nm_page, "nim-mustache page differs"
  when with_moustachu or with_nim_mustache:
    echo &"outputs identical (small: {pf_small.len} bytes, page: {pf_page.len} bytes)"
  else:
    echo &"rendered (small: {pf_small.len} bytes, page: {pf_page.len} bytes)"
  echo ""

  echo "Scenario A - parse + render every iteration"
  let a1 = bench("pitchfork  small template", 100_000):
    let compiled = pf_api.compile_source(small_template)
    blackhole += pf_api.render(compiled.bytecode, compiled.strings,
                               compiled.constants, s_root, s_table, no_partials).len
  when with_moustachu:
    let a2 = bench("moustachu  small template", 100_000):
      blackhole += moustachu.render(small_template, s_ctx_m).len
  when with_nim_mustache:
    let a5 = bench("nim-mustache (acc's lib)  small template", 100_000):
      blackhole += nim_mustache.render(small_template, s_ctx_nm).len
  let a3 = bench("pitchfork  page template (100 products)", 2_000):
    let compiled = pf_api.compile_source(page_template)
    blackhole += pf_api.render(compiled.bytecode, compiled.strings,
                               compiled.constants, p_root, p_table, no_partials).len
  when with_moustachu:
    let a4 = bench("moustachu  page template (100 products)", 2_000):
      blackhole += moustachu.render(page_template, p_ctx_m).len
    echo &"  vs moustachu:    small {a2 / a1:.2f}x, page {a4 / a3:.2f}x  (their time / ours; >1 = we win)"
  when with_nim_mustache:
    let a6 = bench("nim-mustache (acc's lib)  page template", 2_000):
      blackhole += nim_mustache.render(page_template, p_ctx_nm).len
    echo &"  vs nim-mustache: small {a5 / a1:.2f}x, page {a6 / a3:.2f}x"
  echo ""

  echo "Scenario B - compile once, render many (pitchfork only mode)"
  let small_compiled = pf_api.compile_source(small_template)
  let page_compiled = pf_api.compile_source(page_template)
  let b1 = bench("pitchfork  small template, precompiled", 100_000):
    blackhole += pf_api.render(small_compiled.bytecode, small_compiled.strings,
                               small_compiled.constants, s_root, s_table, no_partials).len
  let b2 = bench("pitchfork  page template, precompiled", 2_000):
    blackhole += pf_api.render(page_compiled.bytecode, page_compiled.strings,
                               page_compiled.constants, p_root, p_table, no_partials).len
  when with_moustachu:
    echo &"  vs moustachu:    small {a2 / b1:.2f}x, page {a4 / b2:.2f}x  (their time / ours; >1 = we win)"
  when with_nim_mustache:
    echo &"  vs nim-mustache: small {a5 / b1:.2f}x, page {a6 / b2:.2f}x"
  echo ""
  echo "(blackhole: ", blackhole, ")"

main()
