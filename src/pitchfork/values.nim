import tables, std/macros, sequtils, strutils, math
import bytecode
export bytecode

type
  Filter* = proc(value: VMValue, args: varargs[VMValue]): VMValue

var filters* = initTable[string, Filter]()

proc register_filter*(name: string, handler: Filter) =
  ## Register a custom filter function
  filters[name] = handler

# The window in which a double renders in plain notation. Outside it both
# Ruby and Nim switch to an exponent, which the general renderer handles.
const plain_low = 1e-4
const plain_high = 1e16
# 10^22 is the last power of ten a double holds exactly, and 2^53 the last
# integer. Past either, a digit string stops being trustworthy.
const max_plain_scale = 22
const two_53 = 9007199254740992.0

type DecimalText* = object
  ## The shortest plain-notation decimal that reads back as some double:
  ## its digits, and the same value as mantissa * 10^-scale.
  text*: string
  mantissa*: int64
  scale*: int
  ok*: bool

proc decimal_text(m: int64, scale: int): string =
  ## m * 10^-scale in plain notation, always carrying a decimal point:
  ## Ruby writes "3.0", never "3".
  result = $abs(m)
  if scale == 0:
    result.add(".0")
  else:
    # Left-pad so the point has a digit on both sides: the mantissa for
    # 0.001 is 1 at scale 3, and wants "0.001" rather than ".001".
    if result.len <= scale:
      result = '0'.repeat(scale - result.len + 1) & result
    result.insert(".", result.len - scale)
  if m < 0: result.insert("-", 0)

proc shortest_decimal*(f: float64): DecimalText =
  ## Find the fewest digits after the point that reproduce f exactly.
  ##
  ## Rendering a double to its shortest round-trip form costs ~255ns in
  ## Nim; walking the scales upward finds the same digits in ~2ns. But
  ## the walk is a filter, not a proof: `m / p == f` is a division with
  ## its own rounding, and it does accept digits that a correctly rounded
  ## parse would not map back to f. So the parse is the acceptance test —
  ## ~12ns, and it makes the result right by construction.
  ##
  ## A refuted candidate does not end the search — the next scale along
  ## is usually the true one, and reaching it still beats rendering the
  ## double. But each refutation costs a build and a parse, so after a
  ## few the search gives up and lets the caller render the long way,
  ## rather than turning a rare value into a long walk.
  let a = abs(f)
  if a < plain_low or a >= plain_high:
    return DecimalText(ok: false)
  var scale = 0
  var p = 1.0
  var refuted = 0
  while scale <= max_plain_scale:
    let m = round(f * p)
    # Once the mantissa outgrows 2^53 no larger scale can bring it back,
    # so a double that needs all 17 significant digits leaves here rather
    # than walking the rest of the scales to fail at each one.
    if abs(m) >= two_53: break
    if m / p == f:
      let text = decimal_text(m.int64, scale)
      if text.parseFloat() == f:
        return DecimalText(text: text, mantissa: m.int64, scale: scale, ok: true)
      inc refuted
      if refuted >= 3: return DecimalText(ok: false)
    inc scale
    p *= 10.0
  DecimalText(ok: false)

proc float_to_string_slow(f: float64): string =
  ## The general renderer: NaN, the infinities, and everything that wants
  ## an exponent or that the scale search could not pin down.
  result = $f

  # Nim's `$` can stop a digit short of what a double needs to read back
  # exactly, and how short is not something the text's length reveals —
  # "1.16900163828531" is sixteen characters and does not round-trip.
  # Ask the parse, not the length.
  if result.parseFloat() != f:
    result = f.formatFloat(ffDefault, 17)

  # Ruby writes the exponent form with a decimal point — "1.0e+20" where
  # Nim writes "1e+20".
  let e = result.find('e')
  if e > 0 and result.find('.', 0, e - 1) < 0:
    result.insert(".0", e)

proc float_to_string*(f: float64): string =
  ## Format a float like Ruby's Float#to_s: the shortest text that reads
  ## back as the same double, always carrying a decimal point.
  ##
  ## Fixing the fraction at 10 digits, as this used to, silently truncated
  ## anything longer: 20 | divided_by: 7.0 rendered "2.8571428571".
  let d = shortest_decimal(f)
  if d.ok: return d.text
  float_to_string_slow(f)

proc add_to_string*(dest: var string, v: VMValue) =
  ## Append a value's rendering to dest. This is the primitive; to_string
  ## is the same walk into a fresh buffer. Rendering straight into the
  ## destination is what lets output avoid an intermediate string per
  ## value — and, for an array, one per element on top of that.
  case v.kind
  of vmNull: discard
  of vmBool: dest.add(if v.boolVal: "true" else: "false")
  of vmInt: dest.addInt(v.intVal)
  of vmFloat: dest.add(float_to_string(v.floatVal))
  of vmString: dest.add(v.stringVal)
  of vmArray:
    for item in v.arrayVal:
      dest.add_to_string(item)
  of vmObject: dest.add("{}")
  else: discard

proc to_string*(v: VMValue): string =
  if v.kind == vmString:
    result = v.stringVal
  else:
    result.add_to_string(v)

# Enhanced macro that registers the filter and adds argument validation
macro create_filter*(body: untyped): untyped =
  var proc_def: NimNode
  if body.kind == nnkStmtList:
    if body.len != 1 or body[0].kind != nnkProcDef:
      error("Expected a single procedure definition", body)
    proc_def = body[0]
  elif body.kind == nnkProcDef:
    proc_def = body
  else:
    error("Expected a procedure definition", body)

  let proc_name = proc_def.name
  let proc_name_str = $proc_name

  # Analyze the function signature to determine expected argument count
  let formal_params = proc_def[3] # nnkFormalParams
  var expected_arg_count = 0
  var has_varargs = false

  # Skip return type (index 0) and first parameter (value: VMValue, index 1)
  # Count remaining parameters
  for i in 2..<formal_params.len:
    let param = formal_params[i]
    if param.kind == nnkIdentDefs:
      let param_type = param[^2] # Type is second-to-last node
      if (param_type.kind == nnkCommand and param_type[0].strVal == "varargs") or
         (param_type.kind == nnkBracketExpr and param_type[0].strVal == "varargs"):
        has_varargs = true
        break
      else:
        # Count the number of identifiers in this parameter group
        expected_arg_count += param.len - 2 # exclude type and default value

  # Create a wrapper function that validates arguments
  let wrapper_name = newIdentNode(proc_name_str & "_impl")
  let original_name = proc_name

  # Rename the original proc
  proc_def[0] = wrapper_name

  # Create the wrapper proc
  let wrapper_proc = if has_varargs:
    # For varargs functions, don't add validation (they handle it themselves)
    quote do:
      proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
        `wrapper_name`(value, args)
  else:
    # For fixed-arg functions, generate the appropriate call based on arg count
    if expected_arg_count == 0:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 0:
            raise newException(ValueError, `proc_name_str` & " filter takes no arguments")
          `wrapper_name`(value)
    elif expected_arg_count == 1:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 1:
            if args.len == 0:
              raise newException(ValueError, `proc_name_str` & " filter requires exactly 1 argument")
            else:
              raise newException(ValueError, `proc_name_str` & " filter takes at most 1 argument")
          `wrapper_name`(value, args[0])
    elif expected_arg_count == 2:
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != 2:
            raise newException(ValueError, `proc_name_str` & " filter requires exactly 2 arguments")
          `wrapper_name`(value, args[0], args[1])
    else:
      # For more than 2 args, fall back to generic handling
      quote do:
        proc `original_name`(value: VMValue, args: varargs[VMValue]): VMValue =
          if args.len != `expected_arg_count`:
            raise newException(ValueError, `proc_name_str` & " filter requires exactly " & $`expected_arg_count` & " arguments")
          # This will need manual handling for 3+ args - for now just pass through
          `wrapper_name`(value, args)

  result = newStmtList(
    proc_def,      # Original proc with new name
    wrapper_proc,  # Wrapper proc with validation
    quote do:
      filters[`proc_name_str`] = `original_name`
  )
