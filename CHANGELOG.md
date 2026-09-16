# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
