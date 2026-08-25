import math, strutils
import ../../../values

# Helper to get numeric value
proc to_numeric(v: VMValue): float =
  case v.kind
  of vmInt: v.intVal.float
  of vmFloat: v.floatVal
  of vmString:
    try:
      v.stringVal.parseFloat()
    except:
      0.0
  else: 0.0

type Decimal = object
  ## An exact base-10 value, mantissa * 10^-scale.
  ##
  ## Liquid's arithmetic filters run on Ruby BigDecimals built from each
  ## operand's *text*, so 10.1 minus 2.2 is exactly 7.9 — not the
  ## 7.899999999999999 that binary doubles land on. Doing the same in
  ## scaled integers keeps our rendering identical to the reference.
  mantissa: int64
  scale: int   ## digits after the point
  ok: bool     ## false when the value does not fit; caller falls back to float

# Past this, an int64 mantissa risks overflow and a float mantissa stops
# being exactly representable.
const max_mantissa = 1'i64 shl 53
const max_scale = 17

proc decimal_from_text(s: string): Decimal =
  ## Parse plain decimal notation. Exponent form and anything non-numeric
  ## is refused rather than approximated.
  var i = 0
  var negative = false
  if i < s.len and s[i] in {'-', '+'}:
    negative = s[i] == '-'
    inc i
  var mantissa: int64 = 0
  var scale = 0
  var digits = 0
  var seen_dot = false
  while i < s.len:
    let c = s[i]
    if c == '.':
      if seen_dot: return Decimal(ok: false)
      seen_dot = true
    elif c in Digits:
      mantissa = mantissa * 10 + (c.ord - '0'.ord)
      if mantissa >= max_mantissa: return Decimal(ok: false)
      inc digits
      if seen_dot: inc scale
    else:
      return Decimal(ok: false)
    inc i
  if digits == 0 or scale > max_scale: return Decimal(ok: false)
  Decimal(mantissa: (if negative: -mantissa else: mantissa), scale: scale, ok: true)

proc decimal_from_float(f: float): Decimal =
  ## The decimal BigDecimal(f.to_s) would hold, found without producing
  ## the text. Rendering a double to its shortest round-trip form costs
  ## ~255ns; this finds the same value in ~2ns, and the arithmetic
  ## filters called it twice per operation.
  ##
  ## Walk the scales upward and take the first one that reproduces the
  ## double exactly. `f.to_s` is by definition the shortest decimal that
  ## reads back as f, so the fewest digits after the point that can do it
  ## is the same decimal — and where two integers could both sit at that
  ## scale, rounding picks the nearer one, which is the one to_s prints.
  ##
  ## The exact `m / p == f` test is what makes the search safe: a scale
  ## that only nearly works is rejected, so double rounding in `f * p`
  ## costs at most an extra digit, never a wrong value.
  ##
  ## NaN and the infinities fail the equality test (or the magnitude
  ## bound) at every scale and fall out as not-ok, which is what the
  ## text path did with them too.
  var scale = 0
  var p = 1.0
  while scale <= max_scale:
    let m = round(f * p)
    if m / p == f and abs(m) < max_mantissa.float:
      return Decimal(mantissa: m.int64, scale: scale, ok: true)
    inc scale
    p *= 10.0
  Decimal(ok: false)

proc to_decimal(v: VMValue): Decimal =
  case v.kind
  of vmInt:
    if abs(v.intVal) >= max_mantissa: Decimal(ok: false)
    else: Decimal(mantissa: v.intVal, scale: 0, ok: true)
  of vmFloat:
    # The value BigDecimal(float.to_s) holds, reached directly.
    #
    # This accepts a few doubles the text route refused: `$f` writes
    # 1e-05 and 1e+15 in exponent form and decimal_from_text rejects
    # exponents, dropping those to plain float maths. Ruby's BigDecimal
    # parses that notation happily, so taking them exactly is a step
    # toward the reference rather than away from it.
    decimal_from_float(v.floatVal)
  of vmString:
    let parsed = decimal_from_text(v.stringVal.strip())
    # A string that is not a number counts as zero, matching to_numeric.
    if parsed.ok: parsed else: Decimal(mantissa: 0, scale: 0, ok: true)
  of vmNull:
    Decimal(mantissa: 0, scale: 0, ok: true)
  else:
    Decimal(ok: false)

proc rescale(d: Decimal, scale: int): Decimal =
  ## Restate d with more digits after the point.
  var mantissa = d.mantissa
  for _ in 0 ..< scale - d.scale:
    if abs(mantissa) > max_mantissa div 10: return Decimal(ok: false)
    mantissa *= 10
  Decimal(mantissa: mantissa, scale: scale, ok: true)

proc to_float(d: Decimal): float =
  ## Exact numerator over an exact power of ten: one correctly rounded
  ## division, so the result is the nearest double to the decimal value.
  if d.scale == 0: d.mantissa.float
  else: d.mantissa.float / pow(10.0, d.scale.float)

proc decimal_op(a, b: VMValue, op: char): (float, bool) =
  ## Add, subtract or multiply exactly in base 10. The bool is false when
  ## the operands do not fit, leaving the caller on plain float maths.
  let da = to_decimal(a)
  let db = to_decimal(b)
  if not da.ok or not db.ok: return (0.0, false)

  if op == '*':
    let scale = da.scale + db.scale
    if scale > max_scale: return (0.0, false)
    # Guard the product before forming it.
    if da.mantissa != 0 and abs(db.mantissa) > max_mantissa div abs(da.mantissa):
      return (0.0, false)
    return (Decimal(mantissa: da.mantissa * db.mantissa, scale: scale, ok: true).to_float, true)

  let scale = max(da.scale, db.scale)
  let la = da.rescale(scale)
  let lb = db.rescale(scale)
  if not la.ok or not lb.ok: return (0.0, false)
  let mantissa = if op == '+': la.mantissa + lb.mantissa else: la.mantissa - lb.mantissa
  if abs(mantissa) >= max_mantissa: return (0.0, false)
  (Decimal(mantissa: mantissa, scale: scale, ok: true).to_float, true)

# Check if a value is integer-like (int, or string that parses as int without decimals)
proc is_int_like(v: VMValue): bool =
  case v.kind
  of vmInt: true
  of vmFloat: false
  of vmString:
    if '.' in v.stringVal: false
    else:
      try:
        discard v.stringVal.parseInt()
        true
      except:
        true  # Non-numeric strings convert to 0 (integer)
  of vmNull: true  # null → 0 (integer)
  else: true  # objects/arrays → 0 (integer)

# Returns the absolute value of a number
create_filter:
  proc abs(value: VMValue): VMValue =
    case value.kind
    of vmInt:
      result = VMValue(kind: vmInt, intVal: abs(value.intVal))
    of vmFloat:
      result = VMValue(kind: vmFloat, floatVal: abs(value.floatVal))
    of vmString:
      # Handle string numbers like Liquid does
      try:
        if '.' in value.stringVal:
          let floatVal = value.stringVal.parseFloat()
          result = VMValue(kind: vmFloat, floatVal: abs(floatVal))
        else:
          let intVal = value.stringVal.parseInt()
          result = VMValue(kind: vmInt, intVal: abs(intVal.int64))
      except:
        result = VMValue(kind: vmInt, intVal: 0)
    else:
      result = VMValue(kind: vmInt, intVal: 0)

# Returns the smallest integer greater than or equal to a number
create_filter:
  proc ceil(value: VMValue): VMValue =
    let num = to_numeric(value)
    result = VMValue(kind: vmInt, intVal: ceil(num).int64)

# Returns the largest integer less than or equal to a number
create_filter:
  proc floor(value: VMValue): VMValue =
    let num = to_numeric(value)
    result = VMValue(kind: vmInt, intVal: floor(num).int64)

# Rounds a number to the nearest integer
create_filter:
  proc round(value: VMValue, args: varargs[VMValue]): VMValue =
    if args.len > 1:
      raise newException(ValueError, "round filter takes at most 1 argument")

    let decimals = if args.len > 0:
      let arg = args[0]
      case arg.kind
      of vmInt: arg.intVal.int
      of vmFloat: arg.floatVal.int  # Truncate float to int
      of vmString:
        try: arg.stringVal.parseInt()
        except: 0
      else: 0
    else:
      0

    let num = to_numeric(value)
    if decimals <= 0:
      let multiplier = pow(10.0, decimals.float)
      let rounded = round(num * multiplier) / multiplier
      result = VMValue(kind: vmInt, intVal: rounded.int64)
    else:
      # If original value is integer-like and the result is a whole number, return int
      if is_int_like(value):
        let multiplier = pow(10.0, decimals.float)
        let rounded = round(num * multiplier) / multiplier
        if rounded == rounded.int64.float:
          result = VMValue(kind: vmInt, intVal: rounded.int64)
        else:
          result = VMValue(kind: vmFloat, floatVal: rounded)
      else:
        let multiplier = pow(10.0, decimals.float)
        let rounded = round(num * multiplier) / multiplier
        result = VMValue(kind: vmFloat, floatVal: rounded)

proc arithmetic(value, operand: VMValue, op: char): VMValue =
  ## Shared body of plus/minus/times. Two integers stay integers; anything
  ## else goes through exact base-10 arithmetic, falling back to doubles
  ## only for magnitudes a scaled int64 cannot hold.
  let a = to_numeric(value)
  let b = to_numeric(operand)

  if is_int_like(value) and is_int_like(operand):
    let n = case op
            of '+': a.int64 + b.int64
            of '-': a.int64 - b.int64
            else: a.int64 * b.int64
    return VMValue(kind: vmInt, intVal: n)

  let (exact, fitted) = decimal_op(value, operand, op)
  if fitted:
    return VMValue(kind: vmFloat, floatVal: exact)

  let n = case op
          of '+': a + b
          of '-': a - b
          else: a * b
  VMValue(kind: vmFloat, floatVal: n)

# Adds a number to another number
create_filter:
  proc plus(value: VMValue, addend: VMValue): VMValue =
    arithmetic(value, addend, '+')

# Subtracts a number from another number
create_filter:
  proc minus(value: VMValue, subtrahend: VMValue): VMValue =
    arithmetic(value, subtrahend, '-')

# Multiplies a number by another number
create_filter:
  proc times(value: VMValue, multiplier: VMValue): VMValue =
    arithmetic(value, multiplier, '*')

# Divides a number by another number
create_filter:
  proc divided_by(value: VMValue, divisor: VMValue): VMValue =
    let a = to_numeric(value)
    let b = to_numeric(divisor)

    if b == 0:
      raise newException(ValueError, "Division by zero")

    # Integer division if both are integers
    if is_int_like(value) and is_int_like(divisor):
      result = VMValue(kind: vmInt, intVal: a.int64 div b.int64)
    else:
      result = VMValue(kind: vmFloat, floatVal: a / b)

# Returns the remainder of division
create_filter:
  proc modulo(value: VMValue, divisor: VMValue): VMValue =
    let a = to_numeric(value)
    let b = to_numeric(divisor)

    # Check if divisor is undefined (converted to 0 by to_numeric)
    if divisor.kind == vmNull:
      raise newException(ValueError, "Modulo by zero")

    if b == 0:
      raise newException(ValueError, "Modulo by zero")

    if is_int_like(value) and is_int_like(divisor):
      result = VMValue(kind: vmInt, intVal: a.int64 mod b.int64)
    else:
      result = VMValue(kind: vmFloat, floatVal: a.mod(b))

# Coerce to the number the comparison actually used, so the winning side is
# returned as a number rather than as whatever it came in as. Handing back
# the raw value let `-1 | at_least: "abc"` render "abc" and
# `nosuchthing | at_most: 5` render nothing, where both should be 0.
proc to_number(v: VMValue): VMValue =
  if is_int_like(v):
    VMValue(kind: vmInt, intVal: to_numeric(v).int64)
  else:
    VMValue(kind: vmFloat, floatVal: to_numeric(v))

# Limits a number to a minimum value
create_filter:
  proc at_least(value: VMValue, minVal: VMValue): VMValue =
    if to_numeric(value) < to_numeric(minVal):
      result = to_number(minVal)
    else:
      result = to_number(value)

# Limits a number to a maximum value
create_filter:
  proc at_most(value: VMValue, maxVal: VMValue): VMValue =
    if to_numeric(value) > to_numeric(maxVal):
      result = to_number(maxVal)
    else:
      result = to_number(value)
