# Cross-tree Liquid VM benchmark: identical workload, each tree's liquid_lib.
import std/[json, monotimes, times, tables, strutils]
import ../src/pitchfork/liquid_lib

const small_tmpl = "Hello {{ name }}, you have {{ count }} new {% if plural %}messages{% else %}message{% endif %}."
const page_tmpl = """<html><head><title>{{ title }}</title></head><body>
<h1>{{ title }}</h1>
{% for product in products %}
  <div class="product">
    <h2>{{ product.name }}</h2>
    <p>{{ product.description }}</p>
    <span class="price">{{ product.price }}</span>
    <ul>{% for tag in product.tags %}<li>{{ tag }}</li>{% endfor %}</ul>
    {% if product.inStock %}<b>In stock</b>{% else %}<i>Sold out</i>{% endif %}
  </div>
{% endfor %}
</body></html>
"""

proc page_data(n: int): JsonNode =
  var products = newJArray()
  for i in 0 ..< n:
    products.add(%*{
      "name": "Product " & $i,
      "description": "A fine product and a bargain no. " & $i,
      "price": 999 + i,
      "tags": ["new", "sale", "tag" & $(i mod 7)],
      "inStock": i mod 2 == 0,
    })
  %*{"title": "Catalog", "products": products}

var blackhole = 0

template bench(label: string, iterations: int, body: untyped) =
  block:
    for _ in 0 ..< max(iterations div 10, 1): body
    let start = getMonoTime()
    for _ in 0 ..< iterations: body
    let elapsed_us = (getMonoTime() - start).inNanoseconds.float / 1e3
    stdout.write(label & "\t")
    stdout.write(formatFloat(elapsed_us / iterations.float, ffDecimal, 2))
    stdout.write(" us/render\n")

let sdata = %*{"name": "Alice", "count": 3, "plural": true}
let pdata = page_data(100)

echo "checksum small=", render(small_tmpl, sdata).len,
     " page=", render(page_tmpl, pdata).len

bench("full     small", 100_000):
  blackhole += render(small_tmpl, sdata).len
bench("full     page ", 2_000):
  blackhole += render(page_tmpl, pdata).len

let cs = compile_template(small_tmpl)
let cp = compile_template(page_tmpl)
bench("precomp  small", 100_000):
  blackhole += cs.render(sdata).len
bench("precomp  page ", 2_000):
  blackhole += cp.render(pdata).len
echo "(", blackhole, ")"
