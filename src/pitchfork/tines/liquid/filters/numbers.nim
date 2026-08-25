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
  ## Shared body of plus/minus/times. Two integers stay integers;
  ## anything else is plain double arithmetic.
  ##
  ## The reference implementation runs these on Ruby BigDecimals built
  ## from each operand's text, so it reports 10.1 minus 2.2 as exactly
  ## 7.9 where doubles land on 7.8999999999999995. We do not reproduce
  ## that: carrying a scaled-integer decimal type through every
  ## arithmetic filter is a lot of machinery to move the last digit of
  ## three golden cases, and the golden corpus records the doubles we
  ## actually produce.
  let a = to_numeric(value)
  let b = to_numeric(operand)

  if is_int_like(value) and is_int_like(operand):
    let n = case op
            of '+': a.int64 + b.int64
            of '-': a.int64 - b.int64
            else: a.int64 * b.int64
    return VMValue(kind: vmInt, intVal: n)

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
