# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-10-07

### Changed

Migration note first: the public modules moved, so every consumer's import
line changes.

- The four public entry points are now `src/pitchfork/{liquid_lib,
  mustache_lib, handlebars_lib, liquid_c}.nim`, so `import liquid_lib`
  becomes `import pitchfork/liquid_lib` and likewise for the others. Nimble
  allows `srcDir` only one top-level module, named for the package, and
  `nimble check` had been failing validation over the other three — which
  0.3.2 recorded under Known and could not fix, because the two ways out
  nimble offers are renaming (only one of four can be `pitchfork.nim`) and
  `skipFiles` (which stops them being installed, the very bug 0.3.2 fixed).
  Moving them is the third way and the only one that keeps them installed.
  `pitchfork.nim` still exports the engine core alone, so importing it does
  not drag in `arena_context_store`.
- Floats render as the shortest decimal that reads back as the double. The
  scales are walked upward and the first whose parse reproduces the value is
  taken, so the result is right by construction rather than by argument;
  anything the walk cannot pin down is rendered once at seventeen
  significant digits, which always reads back, and shortened from there by
  parsing candidates rather than rendering again. Templates see:
  - Full precision, where the old renderer truncated at ten decimal places.
    `{{ 20 | divided_by: 7.0 }}` is now `2.857142857142857` rather than
    `2.8571428571`, and the doubles that need all 17 digits get all 17.
  - Double error no longer rounded out of sight. Truncating at ten places
    hid it, so `{{ 10.1 | minus: 2.2 }}` used to print `7.9`; it now prints
    `7.8999999999999995`, which is the double the arithmetic produced. This
    is the one rendering change an existing template can notice, and it
    only reaches templates doing arithmetic on non-integral numbers.
  - Short renderings get quicker and the longest get slower. A float of the
    length a template usually carries renders ~43% faster, `plus` and
    `minus` on float operands ~27% faster and `divided_by` ~18%; a value
    needing all seventeen digits costs about half again what 0.3.2 charged,
    which is the price of printing it correctly rather than truncating it.
    75157 of 8.6M sampled doubles now render shorter.
- Three `want` values in the golden corpus are deliberately edited away from
  the reference implementation's, which runs the arithmetic filters on Ruby
  BigDecimals built from each operand's text and so reports what a human
  would write. We use doubles and record what doubles produce.
  `test/golden_liquid.nim` names all three, since JSON has nowhere to say a
  value was changed. They are the whole of the difference.
- The group enable-list in the golden runner is now a skip-list: a group runs
  unless it is deliberately named. An entry matching no group fails the
  suite, so a rename cannot leave a stale entry protecting nothing, and the
  skipped case count and suite names are reported in both summary branches so
  a green run never implies full conformance. The list is currently empty.
- `is_int_like` decides from the decimal point alone instead of running
  `parseInt` inside a try/except for every string operand — both arms
  returned true, so the exception was raised and caught to reach an answer
  the point had already given. A non-numeric string operand renders ~23%
  faster.

### Added

- The `{% liquid %}` multi-line tag. Statements are separated by newlines and
  may also share the tag's opening line; CRLF endings, comment statements and
  a repeated `liquid` keyword all lex. The tag's own `{%-` and `-%}` are
  handed to the first and last statement it produces, so text around the tag
  trims as it would around any single tag, and a body of nothing but comments
  still emits an empty text section to carry those flags. The body may not
  close a block opened outside the tag, and must close whatever it opens.
- The leading-hash rule for inline comment tags: once a comment spans lines,
  every further line must open with its own `#`.
- `strip_html` strips `script`, `style` and comment blocks together with
  their contents before it removes loose tags, so
  `{{ '<script>var a=1</script>hi' | strip_html }}` renders `hi` where it
  used to render `var a=1hi`.
- A baseline suite in `src/pitchfork/values.nim` for float rendering and the
  decimal shortening underneath it, including the half-way last digit that
  can fall either way and the carry that runs off the front of 9.99.
- `bench/bench_filters.nim`, a wide flat companion to `bench_vm`: one
  workload for every registered filter, 76 in all with the arithmetic filters
  split by operand type, each with a measured floor subtracted so the column
  to read is the filter's own per-call cost. It emits the JSON shape
  `bench/bench_compare.nim` already reads, and quits on a workload that
  renders nothing rather than reporting a missing or raising filter as
  impossibly fast.
- `bench/fuzzfloat.nim`, which fuzzes float rendering over structured values,
  decimal fractions, division results and raw bit patterns and fails on any
  rendering that does not read back as the double it came from.

### Fixed

- The golden Liquid runner silently skipped 20 of its groups. The suite
  name was normalized with `replace("_", " ")` while the enable-list spelled
  multi-word filter names with underscores intact (`"at_least filter"`), so
  those entries could never match and their groups were dropped without a
  word: 171 of the 874 cases never ran, yet the summary still read "All 703
  tests passed!". All 874 cases in all 80 groups now run and pass, and most
  of the filter fixes below are what became visible once they did.
- `{% liquid %}` no longer raises `IndexDefect` out of the lexer. The scanner
  read past the end of the input on any body not ending in a newline, and its
  unterminated-block position ran backwards into a loop the caller could not
  leave.
- `{% liquidate %}` and friends are no longer lexed as a liquid tag; the
  keyword check now respects the word boundary.
- A lone carriage return no longer separates statements inside `{% liquid %}`.
  Only a newline does, so a CR-terminated body is the single malformed
  statement the reference implementation rejects.
- `url_encode` did neither form nor path encoding: it escaped a hand-picked
  five characters and left `@`, `!` and the rest of the reserved set
  standing. It now percent-encodes everything outside the unreserved set and
  writes a space as `+`.
- `url_decode` was the inverse of nothing. It now decodes `+` and every `%XX`
  escape, and leaves a truncated escape standing rather than raising, as
  `CGI.unescape` does.
- `newline_to_br` dropped the newline it replaced, so `"a\nb"` rendered as
  `a<br />b`; it is now `a<br />\nb`, and a CRLF collapses to a single break.
- `escape_once` decided per string instead of per character, which left raw
  markup unescaped whenever an entity appeared anywhere in the same string.
- `sort_natural` ignored its property argument, compared objects by a
  constant `"{}"`, and sorted nils first instead of last.
- `replace_first` raised on a single argument; the replacement is optional and
  defaults to empty, unlike `replace_last`.
- `escape_once`, `newline_to_br`, `strip_html`, `strip_newlines`,
  `url_decode` and `url_encode` silently ignored an unexpected extra
  argument.
- `base64_decode` and `base64_url_safe_decode` accepted input that is not
  base64, and base64 encoding refused non-string input.
- `at_least` and `at_most` returned the raw operand rather than the number
  they compared, so `-1 | at_least: "abc"` rendered `abc`.
- `date_now` raised on every call. It passed its strftime pattern to Nim's
  `DateTime.format`, which rejects the `%`, so `{{ x | date_now }}` threw
  `TimeFormatParseError` on the default format and on any format a template
  supplied. It now routes through `liquid_date_format`, the strftime
  formatter the `date` filter in the same module already uses. The golden
  suite does not cover `date_now`; the new filter benchmark found it.
- `bench/mustache_bench.nim` builds from a clean checkout. It imported
  `moustachu` and `mustache` unconditionally, neither of which is a
  dependency of this package, so the file could not compile anywhere they
  were absent. The comparisons are now opt-in behind `-d:moustachu` and
  `-d:nimMustache`, and Pitchfork's own numbers need nothing extra.
- Removed `test/bench_vm.nim` and `test/bench_compare.nim`, stale copies of
  the `bench/` versions that still imported the deleted `src/liquid/*` paths
  and no longer compiled.

## [0.3.2] - 2026-10-07

### Fixed

- The package installs its own public API again. `installDirs` listed
  `pitchfork`, `liquid` and `liquid_lib`; the last two have not been
  directories since the tine refactor, and naming only `pitchfork` meant
  nimble installed that subdirectory *alone* — so an installed copy had no
  `mustache_lib.nim`, `liquid_lib.nim`, `handlebars_lib.nim` or
  `pitchfork.nim`, and a consumer got "cannot open file: mustache_lib".
  Dropping `installDirs` lets nimble install all of `srcDir`, which is what
  a library package of this shape wants. The breakage was invisible to
  Accelerate because its `src/nim.cfg` prefers a sibling working copy, so
  only a build without one — CI — ever saw it.
- Fetch the arena dependency over HTTPS rather than `git+ssh://`. SSH has
  no anonymous mode, so a bare CI runner could not resolve it even with
  arena public, and the transitive requirement defeated the same fix made
  in Accelerate's own manifest.

### Known

- nimble warns that the package "has an incorrect structure" because the
  top level of `srcDir` holds more than one module. The four per-language
  entry points (`mustache_lib`, `liquid_lib`, `handlebars_lib`, `pitchfork`)
  are the public API and consumers import them by name, so collapsing them
  to a single module is an API change, not packaging. Warning today, an
  error in a future nimble.

## [0.3.1] - 2026-10-07

### Fixed

- Nested loops that share a loop variable name terminate.
  `{% for item in a %}{% for item in b %}{% endfor %}{% endfor %}` hung and
  grew the output without bound. The stale-iterator sweep that runs when a
  loop starts matched on the variable name alone, so the inner loop finished
  the enclosing loop's iterator; the outer `endfor` then found no iterator
  and, with nothing left to advance the loop, control fell back into its body
  forever. The sweep now also requires that the new loop begin past the stale
  loop's `endfor`. That still reaches a leftover from an earlier sibling loop
  — which is what records the offset a later `offset: continue` reads after a
  `{% break %}` — while leaving a running enclosing loop alone.
- `opIterNext` leaves its loop when the iterator is missing instead of
  falling through into the loop body, so a lost iterator can no longer spin.

## [0.3.0] - 2026-09-16

### Changed

- An empty value is falsy to a Mustache section. `""`, `0`, `0.0` and an
  empty list or object now skip the section body, where before only
  `null` and `false` did. The spec is silent on these, so this is a
  choice: match nim-mustache — the library Accelerate rendered with
  before this engine — so that a section guarding an optional text field
  skips when the field is unset instead of emitting an empty wrapper.
  For `""`, `0` and an empty list that is also what mustache.js and hogan
  do; the empty object follows nim-mustache alone, since mustache.js
  tests JS truthiness and renders `{}` once. Liquid and Handlebars are
  unaffected — each states its own policy.

  This is a behaviour change for templates that relied on `{{#field}}`
  rendering for an empty string. Measured across the eight Accelerate
  sites it was written for, it only ever removed empty markup — an
  `<a href="tel:+46"></a>` with no number, an empty alert banner, empty
  content wrappers.

### Fixed

- An inheritance block override that renders to nothing again suppresses
  the block's default body. Block presence and section truthiness were
  answering the same question through one filter; now `{{$block}}` asks
  a separate `mustache#block` normalizer where only an unset local counts
  as absent, so `{{<parent}}{{$title}}{{/title}}{{/parent}}` renders an
  empty title rather than falling back to the parent's default.

## [0.2.1] - 2026-09-08

### Changed

- Depend on arena v0.1.1 (clearTracking compaction — removes an
  accidental quadratic in consumer-tracking teardown on large builds).

## [0.2.0] - 2026-09-04

### Fixed

- The Liquid `for` loop variable is scoped to its loop again. It used to
  leak past `endfor` — and since `include` shares the caller's scope, any
  loop inside an included partial destroyed an `item` assigned by the
  enclosing template for the rest of the render.

### Added

- Mustache template inheritance: `{{<parent}}` renders a parent template
  with `{{$block}}` sections overridable by the caller, implemented as
  capture into `__block_<name>` variables plus a shared-scope include.
  This is what Accelerate's legacy-config converter renders pre-0.2
  sites with.

## [0.1.0] - 2026-08-25

First tagged release. Pitchfork compiles Liquid, Mustache and Handlebars to one
shared bytecode and renders them on a common VM: each language is a frontend — a
"tine" — over the same instruction set, so a project using more than one
template language carries one engine instead of three.

### Added

- Liquid support covering the tag set: `if`/`elsif`/`else`, `unless`,
  `case`/`when`, `for` with `limit`, `offset`, `offset: continue`, `reversed`
  and `else`, `tablerow`, `cycle`, `ifchanged`, `assign`, `capture`,
  `increment`/`decrement`, `include`, `render`, `raw`, `comment`, inline
  `{% # %}` comments and `echo`, plus ranges, bracket and dynamic variable
  access, whitespace control and blank-block suppression. The multi-line
  `{% liquid %}` tag is the one tag not implemented.
- 703 cases of the golden-liquid conformance suite pass. The suite holds 874:
  the runner's group list omits the `{% liquid %}` group and eighteen filter
  groups, of which 43 cases currently fail — chiefly `url_encode`/`url_decode`
  form escaping, the newline `newline_to_br` should keep after each `<br />`,
  `sort_natural` ordering, `strip_html` on `<script>` and `<style>` bodies, and
  argument-count errors several filters should raise but do not.
- Sixty-five built-in Liquid filters across strings, arrays, numbers, dates,
  encoding and inspection. Fifty-five are Ruby Liquid's own; the additions are
  `json`, `inspect`, `type_of`, `camelize`, `handleize`, `sort_by`,
  `url_escape`, `url_param_escape`, `date_add` and `date_now`. Edge cases follow
  Ruby Liquid where the enabled conformance groups check them, except float
  output, which is formatted to ten decimal places with trailing zeros stripped.
- Mustache support passing all 136 cases of the required modules of the official
  mustache/spec suite — interpolation, sections, inverted sections, comments,
  delimiter changes and partials, including standalone-line stripping and
  standalone-partial indentation. The optional lambda and inheritance modules
  are not implemented.
- Handlebars support for paths (`../`, `this`, segment literals),
  `#if`/`#unless`/`#each`/`#with` with `{{else}}`, plain and inverted sections,
  `@index`/`@key`/`@first`/`@last`/`@root`, registered helpers with literal
  arguments and subexpressions, partials with a context argument and hash
  arguments, both comment styles, raw blocks, `~` whitespace control, and
  escaping on `{{ }}` with `{{{ }}}` and `{{& }}` for raw output. Names resolve
  through parent scopes, as Handlebars' `compat` mode does. Custom block
  helpers, hash arguments on non-partial helpers, dynamic partial names, block
  parameters and lambdas are out of scope for this release.
- `liquid_lib`, `mustache_lib` and `handlebars_lib`, giving all three languages
  the same small API — `render`, `render_tracked` and `compile_template` —
  taking a `std/json` `JsonNode` as context and returning a string, so embedding
  the engine requires no knowledge of the VM underneath.
- `compile_template`, returning a `CompiledTemplate` that renders any number of
  times against different contexts, keeping lexing and compilation out of the
  loop when one template is rendered per page or per record.
- Partials passed as a name-to-source table, compiled on first use and cached
  for the rest of the render, each compiled in the language of the template that
  included it. Liquid's `include` (shared scope) and `render` (isolated scope)
  are both supported with `with`/`as`/`for` binding and keyword arguments, and
  `break` and `continue` propagate out of a partial into the enclosing loop.
- Lazy rendering of Liquid against an `arena_context_store` arena instead of a
  `JsonNode`: containers travel through the VM as node ids and materialize only
  where something consumes them whole, overlays shadow the context root for
  per-page values, and every access lands in the arena's log by node identity.
  An alias such as `{% assign s = site %}` leaves `s.title` as precise a
  dependency as `site.title`, which is what lets a build tool re-render only the
  templates whose data actually changed.
- `render_tracked`, returning the output together with the set of context paths
  the template read, for all three languages and for both one-shot and
  pre-compiled templates. Tracking stays off unless asked for; arena-backed
  renders record dependencies in the arena's access log instead.
- A shared, process-wide registry for filters and Handlebars helpers via
  `register_filter` and `register_helper`, with a `create_filter` macro that
  generates a filter's arity checking and registers it under its own name, so a
  host application can extend any of the three languages without forking the
  engine. Tags are not extensible on the same terms: the Liquid compiler builds
  its tag table at the start of every compile, so adding a tag means editing the
  tine.
- A C-callable shared library, built with `nimble clib`, exporting
  `liquid_render`, `liquid_free` and `liquid_init` and taking context and
  partials as JSON strings, so programs outside Nim can render Liquid.
- Copy avoidance throughout rendering: values are shared by reference, the
  caller's context and partial sources are borrowed rather than duplicated per
  render, sub-VMs share locals and the compiled-partial cache, `forloop` and
  `tablerowloop` metadata is built only when a loop body reads it, and values
  render straight into the output buffer.
- Tooling for working on the engine: `bench/bench_vm.nim` times isolated VM hot
  paths and emits JSON snapshots that `bench/bench_compare.nim` diffs,
  `bench/liquid_xbench.nim` times the whole Liquid pipeline,
  `bench/mustache_bench.nim` compares the Mustache tine against moustachu and
  nim-mustache after checking all three produce identical output,
  `test/engine.nim` drives the VM with hand-assembled bytecode as the contract a
  new tine compiles against, and a `-d:opcode_coverage` build reports which of
  the 51 opcodes a run never executed.

### Changed

Migration notes for anything built against the pre-release `liquid` package.

- The package is now `pitchfork`: the engine core lives under `src/pitchfork/`
  and the Liquid frontend under `src/pitchfork/tines/liquid/`, so imports of
  `liquid/vm`, `liquid/value_ops`, `liquid/vm/types` or `liquid/compiler/types`
  must be updated — `VMValue`, `Instruction` and `CompileResult` now come from
  `pitchfork/bytecode`. The `liquid_lib` API itself is unchanged.
- The tree-walking AST parser, the `liquid` command-line binary and the C bridge
  built on the parser's types are gone. Lexing to bytecode and executing it on
  the VM is the only remaining path, and `src/liquid_c.nim` is the C entry point.
- `VMValue` is a reference type and is treated as immutable: pushing, binding or
  storing a value shares it instead of deep-copying the subtree, so custom
  filters and tag handlers must build new values rather than mutate `arrayVal`
  or `objectVal` in place.
- The VM borrows the caller's context table, partial sources and arena through
  pointers instead of copying them, so code driving `new_vm` directly must keep
  all three alive for as long as the VM runs.
- `LiquidVM` is now `VM` and `register_liquid_tag_handlers` is now
  `register_liquid_runtime`, with deprecated aliases under the old names.
- The instruction set replaces `opLoadVar` with `opResolveName`, which walks a
  context stack before the flat scope chain and carries a `ctxHops` operand for
  Handlebars' `../`; it adds `opPushCtx`/`opPopCtx`/`opSetCtx` and
  `opOutputEscaped`, flattens `opBatchOutput` to a single string id, and drops
  the never-read `tagArgCount`, `includeArgCount` and `captureId` operands. This
  matters to anything emitting or inspecting Pitchfork bytecode directly.
- `liquid_lib` imports `arena_context_store` unconditionally, so every consumer
  of the Liquid API needs that package present even when rendering from a
  `JsonNode`.
