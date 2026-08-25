## Liquid filter benchmark
## =======================
##
## One workload per registered Liquid filter, so a change to any single
## filter reports its own cost instead of hiding inside a page render.
## `bench_vm` covers the VM's shapes — loops, scopes, partials — and
## deliberately keeps its workload list short enough to read; this is the
## wide, flat companion that covers the filter surface.
##
## Each workload applies its filter `repeats` times per render, so the
## filter dominates the fixed per-render setup rather than disappearing
## into it. `ns_per_call` is the number to read: the workload's time,
## minus the measured floor for the same shape without a filter, divided
## by the repeat count.
##
## Run with:
##   nim c -r -d:release bench/bench_filters.nim
##
## Compare two builds (same JSON shape as bench_vm, so bench_compare
## reads either):
##   nim c -r -d:release bench/bench_filters.nim --json > before.json
##   ...edit a filter...
##   nim c -r -d:release bench/bench_filters.nim --json > after.json
##   nim c -r bench/bench_compare.nim before.json after.json
##
## A single filter can be run on its own by name substring:
##   nim c -r -d:release bench/bench_filters.nim sort

import std/[times, tables, strutils, strformat, os, json, sets]

import ../src/pitchfork/tines/liquid/api

# ─── Context ──────────────────────────────────────────────────────────
#
# One context serves every workload. The values are deliberately small:
# a filter benchmark should measure the filter's own work, not how long
# it takes to walk a large collection.

proc make_context(): Table[string, VMValue] =
  result = initTable[string, VMValue]()

  result["s"] = vm_string("the quick brown fox")
  result["padded"] = vm_string("   spaced out   ")
  result["html"] = vm_string("<p>a & b</p><script>x()</script>")
  result["escaped"] = vm_string("&lt;p&gt;done&lt;/p&gt;<p>raw</p>")
  result["lines"] = vm_string("alpha\nbeta\ngamma\n")
  result["csv"] = vm_string("alpha,beta,gamma,delta")
  result["url"] = vm_string("email address is bob@example.com!")
  result["encoded"] = vm_string("email+address+is+bob%40example.com%21")
  result["b64"] = vm_string("cGl0Y2hmb3Jr")
  result["title"] = vm_string("Some Product Title")
  result["stamp"] = vm_string("2026-08-25 13:00:00")

  result["i"] = vm_int(42)
  result["neg"] = vm_int(-7)
  result["f"] = vm_float(10.1)
  result["frac"] = vm_float(4.6)

  result["nothing"] = VMValue(kind: vmNull)

  result["words"] = vm_array(@[
    vm_string("delta"), vm_string("Alpha"), vm_string("charlie"),
    vm_string("bravo"), vm_string("Alpha"),
  ])
  result["nums"] = vm_array(@[vm_int(3), vm_int(1), vm_int(4), vm_int(1), vm_int(5)])
  result["holey"] = vm_array(@[
    vm_string("a"), VMValue(kind: vmNull), vm_string("b"), VMValue(kind: vmNull),
  ])
  result["more"] = vm_array(@[vm_string("x"), vm_string("y")])

  var rows: seq[VMValue] = @[]
  for (t, p, avail) in [("foo", 30, true), ("bar", 10, false), ("Baz", 20, true)]:
    rows.add(vm_object({
      "title": vm_string(t),
      "price": vm_int(p.int64),
      "available": vm_bool(avail),
    }.toOrderedTable))
  result["rows"] = vm_array(rows)

# ─── Workloads ────────────────────────────────────────────────────────

type Workload = object
  name: string        ## the filter's registered name, or a floor/variant label
  source: string      ## one application of the filter
  repeats: int        ## how many times it is applied per render
  iterations: int
  floor: string       ## name of the workload to subtract as this one's floor

const default_repeats = 20

func wl(name, source: string, iterations = 40_000,
        repeats = default_repeats, floor = "floor-output"): Workload =
  Workload(name: name, source: source, repeats: repeats,
           iterations: iterations, floor: floor)

proc workloads(): seq[Workload] =
  result = @[]

  # Floors. Every filter workload is `{{ x }}` plus a filter, so the cost
  # of `{{ x }}` itself is what has to come off before the numbers mean
  # anything. The empty template pins the per-render setup underneath both.
  result.add wl("floor-empty", "", repeats = 1, floor = "")
  result.add wl("floor-output", "{{ s }}", floor = "")

  # ── strings ────────────────────────────────────────────────────────
  result.add wl("append", "{{ s | append: \"!\" }}")
  result.add wl("prepend", "{{ s | prepend: \">\" }}")
  result.add wl("capitalize", "{{ s | capitalize }}")
  result.add wl("downcase", "{{ title | downcase }}")
  result.add wl("upcase", "{{ s | upcase }}")
  result.add wl("camelize", "{{ s | camelize }}")
  result.add wl("handleize", "{{ title | handleize }}")
  result.add wl("strip", "{{ padded | strip }}")
  result.add wl("lstrip", "{{ padded | lstrip }}")
  result.add wl("rstrip", "{{ padded | rstrip }}")
  result.add wl("truncate", "{{ s | truncate: 10 }}")
  result.add wl("truncatewords", "{{ s | truncatewords: 2 }}")
  result.add wl("slice", "{{ s | slice: 4, 5 }}")
  result.add wl("split", "{{ csv | split: \",\" | join: \"-\" }}")
  result.add wl("remove", "{{ s | remove: \"o\" }}")
  result.add wl("remove_first", "{{ s | remove_first: \"o\" }}")
  result.add wl("remove_last", "{{ s | remove_last: \"o\" }}")
  result.add wl("replace", "{{ s | replace: \"o\", \"0\" }}")
  result.add wl("replace_first", "{{ s | replace_first: \"o\", \"0\" }}")
  result.add wl("replace_last", "{{ s | replace_last: \"o\", \"0\" }}")
  result.add wl("escape", "{{ html | escape }}")
  result.add wl("escape_once", "{{ escaped | escape_once }}")
  result.add wl("strip_html", "{{ html | strip_html }}")
  result.add wl("strip_newlines", "{{ lines | strip_newlines }}")
  result.add wl("newline_to_br", "{{ lines | newline_to_br }}")
  result.add wl("base64_encode", "{{ s | base64_encode }}")
  result.add wl("base64_decode", "{{ b64 | base64_decode }}")
  result.add wl("base64_url_safe_encode", "{{ url | base64_url_safe_encode }}")
  result.add wl("base64_url_safe_decode", "{{ b64 | base64_url_safe_decode }}")

  # ── arrays ─────────────────────────────────────────────────────────
  result.add wl("first", "{{ words | first }}")
  result.add wl("last", "{{ words | last }}")
  result.add wl("size", "{{ words | size }}")
  result.add wl("join", "{{ words | join: \", \" }}")
  result.add wl("sort", "{{ words | sort | join: \",\" }}")
  result.add wl("sort_natural", "{{ words | sort_natural | join: \",\" }}")
  result.add wl("sort_natural-by-key", "{{ rows | sort_natural: \"title\" | map: \"title\" | join: \",\" }}")
  result.add wl("sort_by", "{{ rows | sort_by: \"price\" | map: \"title\" | join: \",\" }}")
  result.add wl("reverse", "{{ words | reverse | join: \",\" }}")
  result.add wl("map", "{{ rows | map: \"title\" | join: \",\" }}")
  result.add wl("where", "{{ rows | where: \"available\", true | map: \"title\" | join: \",\" }}")
  result.add wl("uniq", "{{ words | uniq | join: \",\" }}")
  result.add wl("compact", "{{ holey | compact | join: \",\" }}")
  result.add wl("concat", "{{ words | concat: more | join: \",\" }}")
  result.add wl("sum", "{{ nums | sum }}")

  # ── numbers ────────────────────────────────────────────────────────
  #
  # The arithmetic filters are split by operand type on purpose. Two
  # integers take a straight int64 path; anything else goes through
  # exact base-10 arithmetic built from the operands' rendered text, and
  # that difference is the whole reason this file exists.
  result.add wl("abs", "{{ neg | abs }}")
  result.add wl("ceil", "{{ frac | ceil }}")
  result.add wl("floor", "{{ frac | floor }}")
  result.add wl("round", "{{ frac | round }}")
  result.add wl("round-digits", "{{ f | round: 3 }}")
  result.add wl("plus-int", "{{ i | plus: 1 }}")
  result.add wl("plus-float", "{{ f | plus: 2.2 }}")
  result.add wl("minus-int", "{{ i | minus: 1 }}")
  result.add wl("minus-float", "{{ f | minus: 2.2 }}")
  result.add wl("times-int", "{{ i | times: 2 }}")
  result.add wl("times-float", "{{ f | times: 1.5 }}")
  result.add wl("divided_by-int", "{{ i | divided_by: 2 }}")
  result.add wl("divided_by-float", "{{ f | divided_by: 7.0 }}")
  result.add wl("modulo", "{{ i | modulo: 5 }}")
  result.add wl("at_least", "{{ i | at_least: 50 }}")
  result.add wl("at_most", "{{ i | at_most: 10 }}")

  # ── dates ──────────────────────────────────────────────────────────
  result.add wl("date", "{{ stamp | date: \"%Y-%m-%d\" }}", iterations = 10_000)
  result.add wl("date_add", "{{ stamp | date_add: 3, \"days\" }}", iterations = 10_000)
  # date_now reads the clock, so it is timed but never compared for output.
  result.add wl("date_now", "{{ \"\" | date_now: \"%Y\" }}", iterations = 10_000)

  # ── misc ───────────────────────────────────────────────────────────
  result.add wl("default", "{{ nothing | default: \"none\" }}")
  result.add wl("type_of", "{{ words | type_of }}")
  result.add wl("inspect", "{{ rows | inspect }}", iterations = 10_000)
  result.add wl("json", "{{ rows | json }}", iterations = 10_000)
  result.add wl("url_encode", "{{ url | url_encode }}")
  result.add wl("url_decode", "{{ encoded | url_decode }}")
  result.add wl("url_escape", "{{ url | url_escape }}")
  result.add wl("url_param_escape", "{{ url | url_param_escape }}")

  # ── float rendering ────────────────────────────────────────────────
  #
  # Not a filter, but the thing every float-producing filter ends in.
  # A double that renders short and one that needs all 17 digits take
  # different paths through float_to_string, so both are pinned here.
  result.add wl("output-float-short", "{{ f }}")
  result.add wl("output-float-long", "{{ f | divided_by: 7.0 }}")

# ─── Timing ───────────────────────────────────────────────────────────

type Result = object
  name: string
  ns_per_render: float
  ns_per_call: float
  output: string

proc expand(w: Workload): string =
  w.source.repeat(w.repeats)

proc bench(w: Workload, ctx: Table[string, VMValue]): Result =
  # Compile once: this measures filters, not the front end.
  let source = w.expand()
  let compiled = compile_source(source, false)

  template run: string =
    render(compiled.bytecode, compiled.strings, compiled.constants, ctx)

  # A filter that raises, or that is not registered under the name the
  # template spells, renders as the empty string and would otherwise
  # benchmark as impossibly fast. Fail loudly instead.
  let sample = run()
  if w.repeats > 1 and sample.len == 0:
    quit("workload '" & w.name & "' rendered nothing — filter missing or raising: " &
         w.source)

  var sink = 0
  for _ in 0 ..< max(w.iterations div 10, 5):
    sink += run().len

  # Three samples, keep the best: the fastest run is the one least
  # disturbed by other work on the machine.
  var best = Inf
  for _ in 0 ..< 3:
    let t0 = cpuTime()
    for _ in 0 ..< w.iterations:
      sink += run().len
    let per = (cpuTime() - t0) * 1_000_000_000.0 / w.iterations.float
    if per < best: best = per

  doAssert sink >= 0  # keep the optimizer honest
  Result(name: w.name, ns_per_render: best, ns_per_call: 0.0, output: sample)

# ─── Main ─────────────────────────────────────────────────────────────

when isMainModule:
  var as_json = false
  var filter = ""
  var show_output = false
  for i in 1 .. paramCount():
    case paramStr(i)
    of "--json": as_json = true
    of "--output": show_output = true
    else: filter = paramStr(i)

  let ctx = make_context()
  let all = workloads()

  # Floors are always measured, even under a name filter: without them
  # ns_per_call would be meaningless for whatever the user asked for.
  var wanted: seq[Workload] = @[]
  var floor_names = initHashSet[string]()
  for w in all:
    if w.floor.len > 0: floor_names.incl(w.floor)
  for w in all:
    if filter.len == 0 or filter in w.name or w.name in floor_names:
      wanted.add w

  var results: seq[Result] = @[]
  var floors = initTable[string, float]()
  for w in wanted:
    var r = bench(w, ctx)
    if w.floor.len == 0:
      floors[w.name] = r.ns_per_render
    results.add r

  # Per-call cost, once every floor has been measured.
  for i, w in wanted:
    if w.floor.len > 0 and w.floor in floors:
      results[i].ns_per_call =
        (results[i].ns_per_render - floors[w.floor]) / w.repeats.float

  if as_json:
    var arr = newJArray()
    for r in results:
      arr.add(%*{"name": r.name, "ns_per_render": r.ns_per_render,
                 "ns_per_call": r.ns_per_call})
    echo (%*{"results": arr}).pretty()
  else:
    echo ""
    echo &"""{"filter":<24}{"per render":>12}{"per call":>12}"""
    echo "─".repeat(48 + (if show_output: 30 else: 0))
    for i, r in results:
      let per_call = if wanted[i].floor.len == 0: "        floor"
                     else: &"{r.ns_per_call:>9.1f} ns"
      var line = &"{r.name:<24}{r.ns_per_render:>9.1f} ns{per_call}"
      if show_output:
        let o = r.output
        line.add("   " & (if o.len > 26: o[0 ..< 26] & "…" else: o).escape())
      echo line
    echo "─".repeat(48 + (if show_output: 30 else: 0))
