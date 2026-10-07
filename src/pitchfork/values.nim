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
  ## The renderer for the shapes the plain-notation paths do not cover:
  ## NaN, the infinities, and the magnitudes that want an exponent.
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

proc trim_zeros(s: var string) =
  ## Drop trailing zeros, keeping the one digit after the point that
  ## Ruby's "3.0" needs. A decimal denotes the same number without them,
  ## so this needs no parse to justify it.
  var stop = s.high
  while stop > 0 and s[stop] == '0' and s[stop - 1] != '.':
    dec stop
  s.setLen(stop + 1)

proc one_digit_shorter(s: string, round_up: bool): string =
  ## s with its last digit dropped, carrying into what remains when
  ## round_up, so a form only rounding can reach — 9.428571428571429 from
  ## 9.4285714285714288 — is actually reachable. Empty when s has no digit
  ## left to give.
  ##
  ## The digits are walked in place. Splitting them out around the point
  ## and reassembling cost 70ns, which is a third of the rendering this
  ## whole path exists to avoid.
  let point = s.find('.')
  if s.len - point <= 2: return ""

  result = s
  result.setLen(result.high)
  if not round_up:
    result.trim_zeros()
    return

  let first = if result[0] == '-': 1 else: 0
  var i = result.high
  while i >= first:
    if result[i] == '.':
      dec i
    elif result[i] == '9':
      result[i] = '0'
      if i == first:
        # The carry ran off the front: 9.99… became 10.0…, and the point
        # keeps its place while the integer side grows into the new digit.
        result.insert("1", first)
        break
      dec i
    else:
      result[i] = char(result[i].ord + 1)
      break
  result.trim_zeros()

proc plain_17_digits(f: float64): string =
  ## Render a plain-notation double the scale search could not pin down.
  ##
  ## Seventeen significant digits always read back as the double they came
  ## from, so one rendering is enough to be correct, and getting from there
  ## to the shortest text can then be paid for in parses instead of more
  ## renderings: a rendering is ~190ns against a parse's ~12. Asking `$`
  ## first and falling back to 17 digits when it did not read back paid
  ## for two renderings on every value that needed all 17 — which is 91%
  ## of what reaches here.
  var significant = 17
  result = f.formatFloat(ffDefault, significant)
  result.trim_zeros()
  while significant > 1:
    let last = result[result.high]
    var cand = result.one_digit_shorter(round_up = last > '5')
    if cand.len == 0: break
    var fits = cand.parseFloat() == f

    if last == '5':
      # Half way is not a rounding question at this many digits: the text
      # is itself rounded, so either side can be the one that reads back.
      # When only one does the parse has already settled it; when both do,
      # which is nearer needs a digit of the double this text does not
      # carry, so spend a rendering to have it rounded properly.
      let up = result.one_digit_shorter(round_up = true)
      let upFits = up.len > 0 and up.parseFloat() == f
      if fits and upFits:
        cand = f.formatFloat(ffDefault, significant - 1)
        cand.trim_zeros()
      elif upFits:
        cand = up
        fits = true

    if not fits: break
    result = cand
    dec significant

proc float_to_string*(f: float64): string =
  ## Format a float like Ruby's Float#to_s: the shortest text that reads
  ## back as the same double, always carrying a decimal point.
  ##
  ## Fixing the fraction at 10 digits, as this used to, silently truncated
  ## anything longer: 20 | divided_by: 7.0 rendered "2.8571428571".
  let d = shortest_decimal(f)
  if d.ok: return d.text
  # Inside the plain window `%.17g` cannot reach for an exponent, so the
  # cheap path is safe; outside it, the general renderer picks the shape.
  let a = abs(f)
  if a >= plain_low and a < plain_high:
    return plain_17_digits(f)
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

when isMainModule:
  import std/[unittest]

  suite "Float rendering":
    test "carries a decimal point the way Ruby does":
      check float_to_string(3.0) == "3.0"
      check float_to_string(1.5) == "1.5"
      check float_to_string(-1.5) == "-1.5"
      check float_to_string(0.0) == "0.0"
      check float_to_string(-0.0) == "-0.0"

    test "keeps every digit a double needs":
      # Fixing the fraction at ten digits truncated this to 2.8571428571.
      check float_to_string(20.0 / 7.0) == "2.857142857142857"
      # Sixteen digits are not always enough, and the length does not say so.
      check float_to_string(123456790.22345679) == "123456790.22345679"
      check float_to_string(1.16900163828531) == "1.16900163828531"

    test "shortens to the decimal that reads back, and no further":
      check float_to_string(2716.0491600000005) == "2716.0491600000005"
      check float_to_string(7.8999999999999995) == "7.8999999999999995"
      check float_to_string(0.1) == "0.1"

    test "a half-way last digit falls the side that reads back":
      # Rounding down and rounding up both produce a sixteen-digit text
      # here, and only one of each pair is the double it came from.
      check float_to_string(68.0 / 7.0) == "9.714285714285714"
      check float_to_string(66.0 / 7.0) == "9.428571428571429"

    test "the exponent forms keep Ruby's spelling":
      check float_to_string(1e20) == "1.0e+20"
      check float_to_string(1e-5) == "1.0e-05"
      check float_to_string(1e16) == "1.0e+16"

    test "NaN and the infinities fall through intact":
      check float_to_string(NaN) == "nan"
      check float_to_string(Inf) == "inf"
      check float_to_string(-Inf) == "-inf"

  suite "Shortening a decimal by one digit":
    test "drops a digit, rounding when asked":
      check one_digit_shorter("1.2345", round_up = false) == "1.234"
      check one_digit_shorter("1.2345", round_up = true) == "1.235"
      check one_digit_shorter("-1.2345", round_up = true) == "-1.235"

    test "trailing zeros go with it":
      check one_digit_shorter("1.2300", round_up = false) == "1.23"

    test "a carry runs off the front into a new digit":
      check one_digit_shorter("9.99", round_up = true) == "10.0"
      check one_digit_shorter("-9.99", round_up = true) == "-10.0"
      check one_digit_shorter("99.99", round_up = true) == "100.0"

    test "refuses the last digit after the point":
      check one_digit_shorter("1.2", round_up = false) == ""
      check one_digit_shorter("123.4", round_up = true) == ""
