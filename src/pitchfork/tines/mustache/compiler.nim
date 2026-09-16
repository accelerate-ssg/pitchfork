# Mustache compiler
# =================
# Compiles the Mustache token stream to Pitchfork bytecode. Reuses the
# engine's existing machinery throughout:
# - name lookup:      opResolveName (context-stack walk) + opGetProp chains
# - sections:         the "mustache#section" normalizer (a registered filter
#                     carrying Mustache's truthiness policy) + the standard
#                     opBeginLoop/opIterNext loop, with opSetCtx binding each
#                     item as current context
# - inverted:         the same normalizer + comparison against `empty`
# - interpolation:    opOutputEscaped ({{ }}) / opOutput ({{{ }}})
# - partials:         opInclude with shared scope and optional indent

import std/[tables, sets, strutils]

import ../../bytecode
import ../../values
import ../../emitter
import lexer

const mustache_section_filter* = "mustache#section"
  ## Registered normalizer carrying Mustache's section semantics: which
  ## values are falsy and what iterates. Language policy lives in the tine;
  ## the engine only provides the filter-call mechanism.

const mustache_block_filter* = "mustache#block"
  ## Presence test for an inheritance block's captured override. Not the
  ## same question as a section's truthiness — see below.

proc mustache_section_normalizer(value: VMValue, args: varargs[VMValue]): VMValue =
  ## Normalize a section value to the list of contexts the body renders
  ## once per. Empty values are falsy — null, false, "", 0 and an empty
  ## list or object; lists iterate; anything else renders once with the
  ## value as context.
  ##
  ## The spec does not say what an empty value does to a section, so this
  ## is a choice: match nim-mustache, the library Accelerate rendered
  ## with before this engine, so a section guarding an optional text
  ## field skips when the field is unset instead of emitting an empty
  ## wrapper. For "", 0 and an empty list that is also what mustache.js
  ## and hogan do. The empty *object* follows nim-mustache alone —
  ## mustache.js tests JS truthiness, where {} is truthy and renders the
  ## body once.
  ##
  ## Handlebars states its own policy next door in hb#section, and Liquid
  ## the opposite one (only nil and false are falsy); the languages differ
  ## here deliberately, which is why the rule lives in the tine.
  var items: seq[VMValue] = @[]
  case value.kind
  of vmNull, vmEmpty:
    discard
  of vmBool:
    if value.boolVal: items.add(value)
  of vmString:
    if value.stringVal.len > 0: items.add(value)
  of vmInt:
    if value.intVal != 0: items.add(value)
  of vmFloat:
    if value.floatVal != 0.0: items.add(value)
  of vmArray:
    items = value.arrayVal
  of vmObject:
    if value.objectVal.len > 0: items.add(value)
  of vmNode:
    # Unreachable: opCallFilter materializes a lazy value before it
    # reaches a filter, because filters have no arena access. Named
    # rather than left to an else so the invariant is visible here.
    items.add(value)
  VMValue(kind: vmArray, arrayVal: items)

proc mustache_block_normalizer(value: VMValue, args: varargs[VMValue]): VMValue =
  ## Was an override captured for this block? Only an unset local counts
  ## as absent. An override that rendered to nothing is still an
  ## override, and must suppress the block's default body — so this
  ## cannot go through the section normalizer, where "" is falsy.
  var items: seq[VMValue] = @[]
  case value.kind
  of vmNull, vmEmpty:
    discard
  else:
    items.add(value)
  VMValue(kind: vmArray, arrayVal: items)

register_filter(mustache_section_filter, mustache_section_normalizer)
register_filter(mustache_block_filter, mustache_block_normalizer)

type
  Compiler* = object of Emitter
    tokens*: seq[MToken]
    pos*: int
    ctx_depth*: int   # For unique per-nesting iterator variable names

proc emit_resolve(c: var Compiler, name: seq[string]) =
  ## Emit name resolution: first segment through the context stack,
  ## remaining segments as property accesses.
  c.emit(Instruction(op: opResolveName, nameId: c.intern_string(name[0])))
  if name[0] != "." and c.scope_depth == 0:
    c.optional_vars.incl(name[0])
  for i in 1 ..< name.len:
    c.emit(Instruction(op: opGetProp, stringId: c.intern_string(name[i])))

proc compile_tokens(c: var Compiler, until_close: seq[string] = @[]) =
  ## Compile tokens until a matching section close (or end of input when
  ## until_close is empty).
  while c.pos < c.tokens.len:
    let tok = c.tokens[c.pos]
    inc c.pos
    case tok.kind
    of mText:
      c.emit(Instruction(op: opBatchOutput, stringId: c.intern_string(tok.text)))

    of mVariable:
      c.emit_resolve(tok.name)
      c.emit(Instruction(op: opOutputEscaped))

    of mUnescaped:
      c.emit_resolve(tok.name)
      c.emit(Instruction(op: opOutput))

    of mSectionOpen:
      # value -> item list -> loop, binding each item as current context
      c.emit_resolve(tok.name)
      c.emit(Instruction(op: opCallFilter,
        filterId: c.intern_string(mustache_section_filter), argCount: 0))
      # Reserve a context frame for the loop body (replaced per iteration)
      c.emit(Instruction(op: opPushNull))
      c.emit(Instruction(op: opPushCtx))
      let loop_var = "__ctx_" & $c.ctx_depth
      inc c.ctx_depth
      inc c.scope_depth
      c.emit(Instruction(op: opBeginLoop,
        loopVarIndex: c.intern_string(loop_var).uint16,
        hasLimit: false, hasOffset: false, hasOffsetContinue: false,
        isReversed: false, loopNameId: -1))
      let loop_start = c.instructions.len
      let iter_pos = c.instructions.len
      c.emit(Instruction(op: opIterNext, endOffset: 0, elseOffset: 0))
      c.emit(Instruction(op: opSetCtx))
      c.compile_tokens(tok.name)
      # Jump back to opIterNext
      c.emit(Instruction(op: opJump,
        offset: int32(loop_start - c.instructions.len - 1)))
      c.instructions[iter_pos] = Instruction(op: opIterNext,
        endOffset: int32(c.instructions.len - iter_pos - 1), elseOffset: 0)
      c.emit(Instruction(op: opPopCtx))
      dec c.scope_depth
      dec c.ctx_depth

    of mInvertedOpen:
      # Render the body only when the normalized section list is empty
      c.emit_resolve(tok.name)
      c.emit(Instruction(op: opCallFilter,
        filterId: c.intern_string(mustache_section_filter), argCount: 0))
      c.emit(Instruction(op: opPushEmpty))
      c.emit(Instruction(op: opEqual))
      let jmp = c.emit_jump(opJumpIfFalse)
      c.compile_tokens(tok.name)
      c.patch_jump(jmp)

    of mBlockOpen:
      # {{$name}}…{{/name}}: render the override an enclosing {{<parent}}
      # call captured into __block_<name>, or the default body when the
      # local is unset. Presence, not truthiness — an override that
      # rendered to nothing still wins over the default — so this uses
      # the block normalizer rather than the section one.
      let blockVar = "__block_" & tok.name.join(".")
      c.emit_resolve(@[blockVar])
      c.emit(Instruction(op: opCallFilter,
        filterId: c.intern_string(mustache_block_filter), argCount: 0))
      c.emit(Instruction(op: opPushEmpty))
      c.emit(Instruction(op: opEqual))
      let use_default = c.emit_jump(opJumpIfTrue)
      # Override present: emit the captured (already rendered) content
      # raw, then skip the default body's bytecode.
      c.emit_resolve(@[blockVar])
      c.emit(Instruction(op: opOutput))
      let skip_default = c.emit_jump(opJump)
      c.patch_jump(use_default)
      c.compile_tokens(tok.name)
      c.patch_jump(skip_default)

    of mParentOpen:
      # {{<parent}}…{{/parent}}: capture each {{$block}} body in the tag
      # into __block_<name>, then include the parent with shared scope —
      # its blocks read the captures. Content outside blocks is ignored,
      # per the inheritance spec.
      var boundBlocks: seq[string] = @[]
      while c.pos < c.tokens.len:
        let btok = c.tokens[c.pos]
        if btok.kind == mSectionClose and btok.name == tok.name:
          inc c.pos
          break
        inc c.pos
        if btok.kind == mBlockOpen:
          let blockVar = "__block_" & btok.name.join(".")
          boundBlocks.add(blockVar)
          c.emit(Instruction(op: opBeginCapture))
          c.compile_tokens(btok.name)
          c.emit(Instruction(op: opEndCapture,
            varId: c.intern_string(blockVar)))
      c.emit(Instruction(op: opInclude,
        templateId: c.intern_string(tok.name.join(".")),
        withContext: true,
        includeArgNames: @[],
        includeVarExpr: false,
        includeWithVar: -1,
        includeAlias: -1,
        includeForVar: -1,
        includeHasIndent: false,
        includeIndentId: 0))
      # Clear the captures so a later parent call without an override for
      # a block falls back to that block's default. Null, not "": the
      # block normalizer reads any non-null value as an override, so ""
      # would read as an (empty) one.
      for blockVar in boundBlocks:
        c.emit(Instruction(op: opPushNull))
        c.emit(Instruction(op: opStoreVar,
          stringId: c.intern_string(blockVar)))

    of mSectionClose:
      if until_close.len == 0 or tok.name != until_close:
        raise newException(ValueError,
          "Unexpected section close: {{/" & tok.name.join(".") & "}}")
      return

    of mPartial:
      c.emit(Instruction(op: opInclude,
        templateId: c.intern_string(tok.partial_name),
        withContext: true,
        includeArgNames: @[],
        includeVarExpr: false,
        includeWithVar: -1,
        includeAlias: -1,
        includeForVar: -1,
        includeHasIndent: tok.indent.len > 0,
        includeIndentId: c.intern_string(tok.indent)))

  if until_close.len > 0:
    raise newException(ValueError,
      "Unclosed section: {{#" & until_close.join(".") & "}}")

proc compile*(tokens: seq[MToken]): CompileResult =
  var c = Compiler(tokens: tokens, pos: 0, ctx_depth: 0)
  c.init_emitter(tokens.len * 4)
  c.compile_tokens()
  result = c.to_compile_result()
