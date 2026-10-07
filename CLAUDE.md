This is Pitchfork: a generic template VM that renders HTML templates for
several template languages. The engine core is language-agnostic; each
language gets a frontend (a "tine") with its own lexer and compiler that
emits the shared bytecode. Liquid is the primary tine; Mustache and
Handlebars also ship.

The VM is generic, for any template language, so common features from all
template languages are abstracted into a common set of OP codes — remember
this when naming things in the engine core.

# Focus

Keep every suite green and keep the render benchmarks from regressing.
Liquid rendering can also run lazily against an `arena_context_store`
arena (a sibling checkout wired via `nim.cfg`); the arena's access log is
what acc2 uses for incremental rebuilds, so its precision is
load-bearing.

# Basic instructions

- Validate changes against the test suites often to avoid regressions.
- As soon as a task is completed, including the failing test count going
  down, commit the changes with a clear message.
- If you write tools to modify files use bash or nim, I do not have python
  or javascript setup available.
- `rg` is available in path, use it to search for code.
- `template` is a keyword in Nim, use `liquidTemplate` or `tmpl` as
  variables in test files.

## Committing

- Cleanup any temporary debug/test files created during the session before
  committing
- Never commit compiled binaries: the test/bench roots build to
  extensionless files next to their sources. `.gitignore` lists them all;
  keep it current when adding a new buildable root.
- Commit before you run a script that modifies project files to avoid
  losing work.
- Use two sections in commit messages: Feature and Bug
- Use imperative mood words at the beginning of each item in the sections,
  like: Add, Remove, Change, Update etc

## Run tests

- Main suite: `nim c -r test/golden_liquid.nim` (874 Liquid conformance
  tests). Run a group or single test by appending its quoted name.
- Engine and tine suites: `test/engine.nim` (hand-assembled bytecode),
  `test/vm.nim` (Liquid through the VM, incl. tracking), 
  `test/mustache_spec.nim` (official spec JSONs), `test/handlebars.nim`.
- Library API + arena suite: `nim c -r src/pitchfork/liquid_lib.nim`.
- Float rendering and decimal shortening: `nim c -r src/pitchfork/values.nim`.
- All of the above must pass before a change lands.

## Benchmarks

- `nim c -r -d:release bench/bench_vm.nim` isolates VM hot paths; with
  `--json` it emits a snapshot for `bench/bench_compare.nim before.json
  after.json`.
- `bench/liquid_xbench.nim` measures the composite render pipeline.

# Codebase

## Implementation

- Engine core: src/pitchfork/{vm.nim, vm_types.nim, bytecode.nim,
  emitter.nim, values.nim, filters.nim, json_bridge.nim}
- Liquid tine: src/pitchfork/tines/liquid/{api,lexer,compiler,runtime}.nim
  plus lexer/ and filters/ subdirectories
- Mustache and Handlebars tines: src/pitchfork/tines/{mustache,handlebars}/
- Public libraries: src/pitchfork/{liquid_lib, mustache_lib,
  handlebars_lib, liquid_c}.nim — liquid_lib's arena render overloads and
  its exports of VMValue/VMValueKind/wrap_arena_node are used by acc_liquid
  (an acc2 plugin); do not break them. Consumers import them by package
  path, `import pitchfork/liquid_lib`, and they live under src/pitchfork/
  because nimble allows srcDir only one top-level module, pitchfork.nim.

## Tests

- The lexer and compiler files have baseline suites that run when you
  compile and run that file (isMainModule); liquid_lib.nim carries the
  API + arena suite and values.nim the float rendering suite, the same way.
  Add to these when a new feature is added and keep them passing when
  editing the implementation.
- Main test suite is test/golden_liquid.nim and the helpers in
  test/golden_liquid/helpers.nim

# Modifications

- A successful fix of a failing case results in no regressions.
- Don't forget to add base tests to the main files of each part when
  adding features. Adding a feature to the compiler in order to fix a
  failing test, add a test case for the new feature in the test section
  of compiler.nim
