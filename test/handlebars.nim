# Handlebars tine test suite
# ==========================
# Hand-authored conformance tests modeled on handlebars.js behavior for
# the supported feature set (see compiler.nim header for scope notes).

import std/[unittest, json, tables, sets]
import ../src/pitchfork/handlebars_lib
import ../src/pitchfork/tines/handlebars/api as hb_api

suite "Handlebars interpolation":
  test "basic and missing":
    check render("Hello {{name}}!", %*{"name": "World"}) == "Hello World!"
    check render("Hello {{gone}}!", %*{}) == "Hello !"

  test "escaping default, triple and ampersand raw":
    let ctx = %*{"html": "<b>&\"</b>"}
    check render("{{html}}", ctx) == "&lt;b&gt;&amp;&quot;&lt;/b&gt;"
    check render("{{{html}}}", ctx) == "<b>&\"</b>"
    check render("{{&html}}", ctx) == "<b>&\"</b>"

  test "dotted paths and this":
    let ctx = %*{"a": {"b": {"c": "deep"}}}
    check render("{{a.b.c}}", ctx) == "deep"
    check render("{{this.a.b.c}}", ctx) == "deep"
    check render("{{a/b/c}}", ctx) == "deep"

  test "segment literals":
    let ctx = %*{"a": {"weird key": "v"}}
    check render("{{a.[weird key]}}", ctx) == "v"

  test "numbers format like handlebars":
    check render("{{n}} {{f}}", %*{"n": 85, "f": 1.21}) == "85 1.21"

suite "Handlebars #if / #unless":
  test "if truthy and falsy values":
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": true}) == "Y"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": false}) == "N"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": 0}) == "N"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": 1}) == "Y"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": ""}) == "N"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": "x"}) == "Y"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": []}) == "N"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{"v": [1]}) == "Y"
    check render("{{#if v}}Y{{else}}N{{/if}}", %*{}) == "N"

  test "if without else":
    check render("{{#if v}}Y{{/if}}", %*{"v": true}) == "Y"
    check render("{{#if v}}Y{{/if}}", %*{"v": false}) == ""

  test "if does not change context":
    check render("{{#if flag}}{{name}}{{/if}}", %*{"flag": true, "name": "n"}) == "n"

  test "unless":
    check render("{{#unless v}}N{{else}}Y{{/unless}}", %*{"v": false}) == "N"
    check render("{{#unless v}}N{{else}}Y{{/unless}}", %*{"v": "x"}) == "Y"

suite "Handlebars #each":
  test "array iteration with @index @first @last":
    let ctx = %*{"items": ["a", "b", "c"]}
    check render("{{#each items}}{{@index}}:{{this}} {{/each}}", ctx) ==
      "0:a 1:b 2:c "
    check render("{{#each items}}{{#if @first}}[{{/if}}{{this}}{{#if @last}}]{{/if}}{{/each}}", ctx) ==
      "[abc]"

  test "each with else on empty and missing":
    check render("{{#each items}}x{{else}}none{{/each}}", %*{"items": []}) == "none"
    check render("{{#each items}}x{{else}}none{{/each}}", %*{}) == "none"

  test "each over object values with @key":
    let ctx = %*{"obj": {"a": 1, "b": 2}}
    check render("{{#each obj}}{{@key}}={{this}};{{/each}}", ctx) == "a=1;b=2;"

  test "nested each with parent paths":
    let ctx = %*{"rows": [{"cells": ["x", "y"], "name": "r1"}],
                 "title": "T"}
    check render("{{#each rows}}{{#each cells}}{{../name}}.{{this}},{{/each}}{{/each}}", ctx) ==
      "r1.x,r1.y,"
    check render("{{#each rows}}{{#each cells}}{{../../title}}{{/each}}{{/each}}", ctx) == "TT"

  test "each item objects become context":
    let ctx = %*{"people": [{"name": "A"}, {"name": "B"}]}
    check render("{{#each people}}{{name}} {{/each}}", ctx) == "A B "

suite "Handlebars #with":
  test "with pushes context":
    let ctx = %*{"person": {"first": "F", "last": "L"}}
    check render("{{#with person}}{{first}} {{last}}{{/with}}", ctx) == "F L"

  test "with falls back to parent scope":
    let ctx = %*{"person": {"first": "F"}, "site": "S"}
    check render("{{#with person}}{{first}}@{{site}}{{/with}}", ctx) == "F@S"

  test "with else on missing":
    check render("{{#with gone}}{{x}}{{else}}none{{/with}}", %*{}) == "none"

  test "with keeps lists whole":
    let ctx = %*{"pair": ["a", "b"]}
    check render("{{#with pair}}{{[0]}}{{[1]}}{{/with}}", ctx) == "ab"

suite "Handlebars plain sections":
  test "section truthiness: empty string falsy, zero truthy":
    check render("{{#v}}Y{{/v}}", %*{"v": ""}) == ""
    check render("{{#v}}Y{{/v}}", %*{"v": 0}) == "Y"

  test "section over object pushes context":
    check render("{{#user}}{{name}}{{/user}}", %*{"user": {"name": "N"}}) == "N"

  test "section over list iterates":
    check render("{{#list}}{{this}}{{/list}}", %*{"list": [1, 2, 3]}) == "123"

  test "section with else":
    check render("{{#list}}{{this}}{{else}}empty{{/list}}", %*{"list": []}) == "empty"

  test "inverse section with and without else":
    check render("{{^gone}}none{{/gone}}", %*{}) == "none"
    check render("{{^v}}none{{else}}some{{/v}}", %*{"v": 1}) == "some"
    check render("{{#v}}some{{^}}none{{/v}}", %*{}) == "none"

suite "Handlebars helpers":
  test "registered helper with one argument":
    register_helper("shout", proc(value: VMValue, args: varargs[VMValue]): VMValue =
      vm_string(to_string(value) & "!"))
    check render("{{shout name}}", %*{"name": "hey"}) == "hey!"

  test "helper with extra args and literals":
    register_helper("wrap", proc(value: VMValue, args: varargs[VMValue]): VMValue =
      vm_string(to_string(args[0]) & to_string(value) & to_string(args[1])))
    check render("""{{wrap name "<" ">"}}""", %*{"name": "x"}) == "&lt;x&gt;"
    check render("""{{{wrap name "<" ">"}}}""", %*{"name": "x"}) == "<x>"
    check render("{{wrap n 1 2.5}}", %*{"n": "-"}) == "1-2.5"

  test "subexpressions":
    register_helper("upper", proc(value: VMValue, args: varargs[VMValue]): VMValue =
      var s = to_string(value)
      for i in 0 ..< s.len:
        if s[i] in {'a'..'z'}: s[i] = char(s[i].ord - 32)
      vm_string(s))
    register_helper("join2", proc(value: VMValue, args: varargs[VMValue]): VMValue =
      vm_string(to_string(value) & "-" & to_string(args[0])))
    check render("{{join2 (upper a) (upper b)}}", %*{"a": "x", "b": "y"}) == "X-Y"

  test "helper result feeds #if":
    register_helper("isLong", proc(value: VMValue, args: varargs[VMValue]): VMValue =
      vm_bool(to_string(value).len > 3))
    check render("{{#if (isLong word)}}long{{else}}short{{/if}}", %*{"word": "hippo"}) == "long"
    check render("{{#if (isLong word)}}long{{else}}short{{/if}}", %*{"word": "ox"}) == "short"

suite "Handlebars partials":
  test "basic partial with current context":
    let partials = {"greet": "Hi {{name}}"}.toTable
    check render("[{{> greet}}]", %*{"name": "N"}, partials) == "[Hi N]"

  test "partial with context argument":
    let partials = {"card": "{{first}} {{last}}"}.toTable
    check render("{{> card person}}", %*{"person": {"first": "A", "last": "B"}}, partials) == "A B"

  test "partial with hash arguments":
    let partials = {"link": "<a>{{label}}</a>"}.toTable
    check render("{{> link label=title}}", %*{"title": "Home"}, partials) == "<a>Home</a>"
    check render("""{{> link label="Lit"}}""", %*{}, partials) == "<a>Lit</a>"

  test "each data variables visible inside a partial":
    let partials = {"row": "{{@index}}:{{this}} "}.toTable
    check render("{{#each items}}{{> row}}{{/each}}",
                 %*{"items": ["a", "b"]}, partials) == "0:a 1:b "

  test "standalone partial indentation":
    let partials = {"p": "1\n2\n"}.toTable
    check render("a\n  {{> p}}\nb\n", %*{}, partials) == "a\n  1\n  2\nb\n"

  test "recursive partial":
    let ctx = %*{"content": "X", "nodes": [{"content": "Y", "nodes": []}]}
    let partials = {"node": "{{content}}<{{#each nodes}}{{> node}}{{/each}}>"}.toTable
    check render("{{> node}}", ctx, partials) == "X<Y<>>"

suite "Handlebars comments, raw blocks, whitespace":
  test "comments both flavors":
    check render("a{{! plain }}b", %*{}) == "ab"
    check render("a{{!-- has {{mustache}} inside --}}b", %*{}) == "ab"

  test "standalone comment line is stripped":
    check render("a\n{{! note }}\nb", %*{}) == "a\nb"

  test "standalone block lines are stripped":
    check render("a\n{{#if v}}\nX\n{{/if}}\nb", %*{"v": true}) == "a\nX\nb"

  test "raw block":
    check render("{{{{raw}}}}{{not parsed}}{{{{/raw}}}}", %*{}) == "{{not parsed}}"

  test "tilde whitespace control":
    check render("a  {{~x~}}  b", %*{"x": "-"}) == "a-b"
    check render("a\n{{~x}}", %*{"x": "-"}) == "a-"

suite "Handlebars @root and tracking":
  test "@root from nested scopes":
    let ctx = %*{"title": "T", "items": [{"n": 1}]}
    check render("{{#each items}}{{@root.title}}{{/each}}", ctx) == "T"

  test "render_tracked reports root accesses":
    let (output, accessed) = render_tracked("{{a}}{{#if b}}{{c}}{{/if}}",
                                            %*{"a": 1, "b": true, "c": 2, "d": 3})
    check output == "12"
    check "a" in accessed
    check "b" in accessed
    check "c" in accessed
    check "d" notin accessed
